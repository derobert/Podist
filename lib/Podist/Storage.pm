package Podist::Storage;
use Moose;
use namespace::autoclean;

use Carp qw(croak confess carp cluck);
use File::Path qw(mkpath);
use File::Temp qw(tempfile);
use File::Spec;
use Log::Log4perl qw(:easy :no_extra_logdie_message);
use Try::Tiny;

has _db => (
	required => 1,
	is       => 'ro',
	isa      => 'Podist::Database',
	init_arg => 'DB',
);

has _config => (
	required => 1,
	is       => 'ro',
	isa      => 'HashRef',
	init_arg => 'config',
);

has _temps => (
	required => 0,
	is       => 'ro',
	isa      => 'HashRef',
	init_arg => undef,
	default  => sub { { } },
);

sub BUILD {
	my $self = shift;
	my $config = $self->_config;

	foreach my $k (qw(
		PendingMedia UnusableMedia OriginalMedia ProcessedMedia
		ArchivedMedia ArchivedProcessed Playlists ArchivedPlaylists
		RandomMedia
	)) {
		my $d = $config->{lc $k};
		defined($d) && '' ne $d
			or croak "Storage config lacks $k option";

		-d $d
			or mkpath($d)
			or croak "Could not mkpath($d): $!";
	}

	return;
}

sub new_dl_temp {
	my $self = shift;

	my (undef, $tmp)
		= tempfile('download.XXXXXX', DIR => $self->_config->{pendingmedia});
	$self->_temps->{$tmp} = 1;

	return $tmp;
}

sub discard_dl_temp { shift->_discard_temp(@_) }

sub save_dl_temp {
	my ($self, %opts) = @_;

	defined(my $tmp  = $opts{temp})     or croak "temp param required";
	defined(my $name = $opts{new_name}) or croak "new_name param required";
	defined(my $e_no = $opts{enclosure_no})
		or croak "enclosure_no param required";

	delete $self->_temps->{$tmp}
		or confess "Tried to keep unknown DL temp $tmp";

	my $full = $self->_config->{pendingmedia} . '/' . $name;

	$self->_safe_move($tmp, $full);

	try {
		$self->_db->add_enclosure_storage($e_no, 'pending', $name);
	} catch {
		unlink($full); # we're rolling back the DB
		die "$@";
	}; # very critical semicolon...

	return;
}

sub new_speech_temp {
	my ($self, $suffix) = @_;

	my (undef, $tmp) = tempfile(
		'speech.XXXXXX',
		DIR    => $self->_config->{processedmedia},
		SUFFIX => $suffix,
	);
	$self->_temps->{$tmp} = 1;

	return $tmp;
}

sub discard_speech_temp { shift->_discard_temp(@_) }

sub save_speech_temp {
	my ($self, %opts) = @_;
	wantarray or croak "save_speech_temp returns a list";

	defined(my $tmp = $opts{temp})  or croak "temp param required";
	defined(my $p_no = $opts{playlist_no})
		or croak "playlist_no param required";
	# DB will check the rest
	
	delete $self->_temps->{$tmp}
		or confess "Tried to save unknown temp $tmp";

	my (undef, undef, $tmp_base) = File::Spec->splitpath($tmp);

	# TODO: switch to _compute_processed_path
	my $newfile = $self->_config->{processedmedia} . "/$p_no";
	-d $newfile || mkdir($newfile) or confess "mkdir($newfile): $!";
	$newfile .= "/$tmp_base";

	my $s_no = $self->_db->add_speech(%opts, 
		store => 'processed',
		file => $newfile,
	);
	$self->_safe_move($tmp, $newfile);

	return ($s_no, $newfile);
}

sub new_processed_temp {
	my ($self, $suffix) = @_;

	my (undef, $tmp);
	{
		# We don't open because otherwise ffmpeg will complain the file
		# exists, and this is safe since we're not actually working in a
		# system temp directory.
		#
		# Turn off warnings temporarily because File::Temp
		# unconditionally warns about OPEN=>0. The docs suggest tmpnam
		# or mktemp instead, but those don't take DIR. So they'd
		# actually be insecure...
		#
		# TODO: Remove if we switch to opusenc, which will probably be
		#       required to get art copied over.
		local $^W = 0;
		(undef, $tmp) = tempfile(
			'processed.XXXXXX',
			DIR    => $self->_config->{processedmedia},
			SUFFIX => $suffix,
			OPEN   => 0,
		);
	}
	$self->_temps->{$tmp} = 1;

	return $tmp;
}

sub discard_processed_temp { shift->_discard_temp(@_) }

sub save_processed_temp {
	my ($self, %opts) = @_;

	defined(my $tmp = $opts{temp})  or croak "temp param required";
	defined(my $p_no = $opts{playlist_no})
		or croak "playlist_no param required";
	defined(my $p_so = $opts{playlist_so})
		or croak "playlist_so param required";
	defined(my $pp_so = $opts{proc_part_so})
		or croak "proc_part_so param required";
	defined(my $store = $opts{store})
		or croak "store param required";

	delete $self->_temps->{$tmp}
		or confess "Tried to save unknown temp $tmp";

	my $dir
		= $self->_compute_processed_path($store, $p_no, '');
	-d $dir || mkdir($dir) or confess "mkdir($dir): $!";

	my (undef, undef, $tmp_basename) = File::Spec->splitpath($tmp);
	$tmp_basename =~ /^processed\.(.+)$/
		or confess "unexpected temp name: $tmp_basename";
	my $name = sprintf('%03i_%03i_%s', $p_so, $pp_so, $1);
	my $newfile = $self->_compute_processed_path($store, $p_no, $name);

	$self->_db->add_processed_part(%opts, proc_part_file => $name);
	$self->_safe_move($tmp, $newfile);

	return;
}

sub _discard_temp {
	my ($self, $tmp) = @_;

	delete $self->_temps->{$tmp}
		or confess "Tried to delete unknown temp $tmp";
	unlink($tmp) or confess "unlink($tmp): $!";

	return;
}

sub _compute_media_path {
	my ($self, $store, $p_no, $name) = @_;

	defined $store or confess "Tring to find location of enclosure name $name w/o a store; if this is an upgrade, review the UPGRADING file";

	my $k = ($store eq 'archived-legacy' ? 'archived' : $store) . 'media';
	exists $self->_config->{$k} or confess "Unknown media store: $store";

	if ('pending' eq $store || 'archived-legacy' eq $store || 'unusable' eq $store) {
		return $self->_config->{$k} . "/$name";
	} else {
		defined $p_no or confess "store $store requires a playlist number";
		return $self->_config->{$k} . "/$p_no/$name";
	}
}

sub _compute_processed_path {
	my ($self, $store, $p_no, $name) = @_;

	'deleted' eq $store
		and confess "Tried to find the path to a deleted processed file";

	my $k
		= ('processed' eq $store) ? 'processedmedia'
		: ('archived-processed' eq $store) ? 'archivedprocessed'
		:                                    $store;
	exists $self->_config->{$k} or confess "Unknown media store: $store [$k]";

	return $self->_config->{$k} . "/$p_no/$name";
}

sub _compute_playlist_path {
	my ($self, $p_archived, $p_file) = @_;

	my $k = (defined $p_archived) ? 'archivedplaylists' : 'playlists';
	defined(my $dir = $self->_config->{$k})
		or confess "BUG: No storage configured for $k";

	return "$dir/$p_file";
}

sub get_playlist_path {
	my ($self, $p_no) = @_;

	return $self->_compute_playlist_path(
		$self->_db->get_playlist_storage($p_no));
}

sub get_enclosure_path {
	my ($self, $e_no) = @_;

	return $self->_compute_media_path(
		$self->_db->get_enclosure_storage($e_no));
}

sub unusable_pending {
	my ($self, $e_no) = @_;
	my ($store, $p_no, $name) = $self->_db->get_enclosure_storage($e_no);
	'pending' eq $store
		or confess "Tried to move non-pending ($store) to unusable ($e_no)";

	my $old = $self->_compute_media_path($store,     $p_no, $name);
	my $new = $self->_compute_media_path('unusable', $p_no, $name);
	$self->_db->update_enclosure_storage($e_no, 'unusable');
	$self->_safe_move($old, $new);    # if dies, DB rolls back.

	return;
}

sub archive_original {
	my ($self, $e_no) = @_;

	my ($store, $p_no, $name) = $self->_db->get_enclosure_storage($e_no);
	'original' eq $store
		or confess "Enclosure $e_no ($name) in unexpected store '$store'";

	my $old = $self->_compute_media_path($store,    $p_no, $name);
	my $new = $self->_compute_media_path('archived', $p_no, $name);

	my $path = $self->_compute_media_path('archived', $p_no, '');
	-d $path || mkdir($path)
		or confess "mkdir($path): $!";

	$self->_db->update_enclosure_storage($e_no, 'archived');
	$self->_safe_move($old, $new);    # if dies, DB rolls back.

	return;
}

sub cleanup_original {
	my ($self, $p_no) = @_;

	my $path = $self->_compute_media_path('original', $p_no, '');

	# rmdir only removes empty dirs, so safe.
	rmdir($path)
		or confess "rmdir($path): $!";

	return;
}

sub archive_playlist {
	my ($self, $p_no) = @_;

	my ($archived, $file) = $self->_db->get_playlist_storage($p_no);
	defined $archived
		and croak "Playlist $p_no already archived";

	my $old = $self->_compute_playlist_path($archived, $file);
	my $new = $self->_compute_playlist_path(time, $file);

	$self->_safe_move($old, $new);
	$self->_db->mark_playlist_archived($p_no);

	return;
}

sub fsck {
	my ($self) = @_;

	return $self->_fsck_missing_store + $self->_fsck_check_exists;
}

sub _fsck_missing_store {
	my ($self) = @_;

	my $criteria
		= q{e.enclosure_store IS NULL AND e.enclosure_file IS NOT NULL};
	my ($count) = $self->_db->selectrow_array(qq{
		SELECT COUNT(*)
		  FROM enclosures e
		  WHERE $criteria
	});
	TRACE("Count of missing-store enclosures: $count");

	$count or return 0;

	INFO("Searching for $count enclosures missing store info.");
	my $sth = $self->_db->prepare(qq{
		SELECT
		    e.enclosure_no, e.playlist_no, e.enclosure_file,
		    e.enclosure_use, 
		    p.playlist_archived
		  FROM
		    enclosures e
            LEFT JOIN playlists p ON (e.playlist_no = p.playlist_no)
		  WHERE $criteria
	});
	$sth->execute;
	my $tried = 0;
	my $fixed = 0;
	while (my ($e_no, $p_no, $e_file, $e_use, $p_arch) = $sth->fetchrow_array) {
		++$tried;

		my $store;
		if (!defined $p_no && $e_use) {
			$store = 'pending';
		} elsif (!defined $p_no && !$e_use) {
			$store = 'unusable';
		} elsif (defined $p_no && !defined($p_arch)) {
			$store = 'original';
		} elsif (defined $p_no && defined($p_arch)) {
			$store = 'archived';
			-e $self->_compute_media_path($store, $p_no, $e_file)
				or $store = 'archived-legacy';
		} else {
			next;
		}

		my $path = $self->_compute_media_path($store, $p_no, $e_file);
		if (-e $path) {
			$self->_db->update_enclosure_storage($e_no, $store);
			++$fixed;
		}
	}
	$sth->finish;

	INFO("Tried to fix $tried and succeeded with $fixed");
	$tried == $count
		or ERROR("Tried to fix $tried, but count was $count -- should be the same!");
	return $count - $fixed;
}

sub _fsck_check_exists {
	my $self = shift;

	TRACE("Checking if files in database actually exist.");
	my $sth = $self->_db->prepare(q{
		SELECT enclosure_no, enclosure_store, playlist_no, enclosure_file
		  FROM enclosures
		  WHERE enclosure_store IS NOT NULL AND enclosure_file IS NOT NULL
	});
	$sth->execute;

	my $prob_count = 0;
	while (my ($e_no, $e_store, $p_no, $e_file) = $sth->fetchrow_array) {
		my $path = $self->_compute_media_path($e_store, $p_no, $e_file);
		next if -e $path;
		
		++$prob_count;
		if ('archived' eq $e_store) {
			WARN("Not found: archived file $e_file (enclosure $e_no).");
		} else {
			ERROR("Not found: non-archived file $e_file (enclosure $e_no).");
		}
	}

	return $prob_count;
}

sub _safe_move {
	my ($self, $src, $dst) = @_;

	$src eq $dst
		and confess "Source and destination literally the same ($src)";

	# blank check: can get e.g., / from concatenating two empty things
	$src =~ m!^/*$!
		and confess "Source is blank ($src)";

	$dst =~ m!^/*$!
		and confess "Destination is blank ($src)";

	# yes, this is a race, but duplicate name should never happen, this
	# is just a sanity check in case of e.g., DB corruption. Or bugs.
	# Also, we're single-threaded, so we don't race ourself.
	#
	# Unfortunately, there is no renameat2 in Perl. Guess could call it
	# via syscall someday.
	-e $dst and confess "rename $src -> $dst: destination already exists";
	rename($src, $dst) or confess "rename($src, $dst): $!";
}

sub DEMOLISH {
	my ($self, $in_global) = @_;

	foreach my $k (keys %{$self->_temps}) {
		cluck("Leftover temporary $k is being leaked");
	}
}

__PACKAGE__->meta->make_immutable;
1;
