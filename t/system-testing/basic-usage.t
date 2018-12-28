use 5.024;

use Data::Dump qw(pp);
use File::Copy qw(copy);
use File::pushd qw(pushd);
use File::Slurper qw(read_text write_text read_lines);
use File::Spec;
use IPC::Run3;
use Test::Exception;
use Test::More;
use DBI;

# This test is somewhat dangerous (e.g., might ignore the non-default
# directories we say to use, and instead do weird things to your actual
# Podist install). So we won't run unless LIVE_DANGEROUSLY=1 is set.
# Note the GitLab CI sets this, as its run in a docker container, so no
# existing Podist to worry about.

if (!$ENV{LIVE_DANGEROUSLY}) {
	plan skip_all => 'LIVE_DANGEROUSLY=1 not set in environment';
	exit 0;
} else {
	plan tests => 29;
}

my $FEED_DIR = 't-gen/feeds/v1';

my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
my ($stdout, $stderr, $res);

my $conf_dir  = "$tmpdir/conf";
my $store_dir = "$tmpdir/store";

my @podist = ('./Podist', '--conf-dir', $conf_dir);

# 1
run3 \@podist, undef, \$stdout, \$stderr;
like($stderr, qr/set NotYetConfigured to false/, 'Podist conf init');
note("stdout: $stdout");
note("stderr: $stderr");

# 2
my $conf_file = "$conf_dir/podist.conf";
ok(-f $conf_file, "New config exists $conf_file");

# 3
lives_ok {
	setup_config(in => $conf_file, out => $conf_file, store => $store_dir)
} 'Configured Podist';

# 4
run3 [@podist, 'status'], undef, \$stdout, \$stderr;
check_run('Podist status runs', $stdout, $stderr);

# 5
my $dbh;
lives_ok {
	$dbh = DBI->connect(
		"dbi:SQLite:dbname=$conf_dir/podist.db",
		'', '',
		{
			ReadOnly         => 1,
			AutoCommit       => 1,
			RaiseError       => 1,
			FetchHashKeyName => 'NAME_lc'
		});
} q{"Connected" to Podist database};

# 6 .. 13
foreach my $feed ( 1 .. 8) {
	run3 [@podist, 'subscribe', "Feed $feed", "file://" . File::Spec->rel2abs("$FEED_DIR/feed_$feed.xml")], undef, \$stdout, \$stderr;
	check_run("Podist subscribe Feed #$feed", $stdout, $stderr);
}

# 14
run3 [@podist, qw(catch -l 1)], undef, \$stdout, \$stderr;
check_run("Catch with rollback", $stdout, $stderr);

# 15
($res) = $dbh->selectrow_array(q{SELECT count(*) FROM enclosures});
is($res, 0, 'No enclosures in DB after rollback');

# 16
run3 [@podist, qw(catch -l 999)], undef, \$stdout, \$stderr;
check_run("Catch without rollback", $stdout, $stderr);

# 17
($res) = $dbh->selectrow_array(q{SELECT count(*) FROM enclosures});
is($res, 32, '32 enclosures after catch');

# 18
run3 [@podist, 'status'], undef, \$stdout, \$stderr;
check_run("Status after catch", $stdout, $stderr);

# 19
TODO: {
	local $TODO = 'Podist bug, currently fails w/o random items';
	run3 [@podist, 'playlist'], undef, \$stdout, \$stderr;
	check_run("Generated playlist w/o randoms", $stdout, $stderr);
};

# 20
mkdir("$store_dir/random");
mkdir("$store_dir/random.in");
copy("t-data/MountainKing.flac", "$store_dir/random.in/");
my $make_random = File::Spec->rel2abs('make-random');
{
	my $dir = pushd($store_dir);
	run3 [$make_random], undef, \$stdout, \$stderr;
	check_run("Generated random items", $stdout, $stderr);
}

# 21
run3 [@podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist with randoms", $stdout, $stderr);

# 22
$res = $dbh->selectrow_arrayref(<<QUERY);
	SELECT playlist_no, playlist_archived, playlist_file FROM playlists
QUERY
is_deeply($res, [ 1, undef, 'Playlist 001.m3u' ], 'Playlist DB entry OK');

# count items that should be on playlist according to db.
my $db_item_count = 0;

# 23
($res) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM random_uses});
ok($res > 0, 'Random music uses recorded in DB');
note("DB random music count: $res");
$db_item_count += $res;

# 24
($res) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM speeches});
ok($res > 0, 'Speeches recorded in DB');
note("DB speeches count: $res");
$db_item_count += $res;

# 25
($res) = $dbh->selectrow_array(<<QUERY);
	SELECT COUNT(*) FROM enclosures WHERE playlist_no IS NOT NULL
QUERY
ok($res > 0, 'Used enclosures recorded in DB');
note("DB playlisted enclosure count: $res");
$db_item_count += $res;

note("Database says to expect $db_item_count items on the playlist");

# 26
my @playlist;
lives_ok {
	@playlist = read_lines("$store_dir/playlists/Playlist 001.m3u")
} 'Read generated playlist';
note("Generated playlist:\n".pp(@playlist));

# 27
is(scalar(@playlist), $db_item_count,
	"Found expected number of items in playlist");

# 28
subtest 'Playlist items exist' => sub {
	plan tests => scalar(@playlist);

	foreach my $item (@playlist) {
		ok(-e "$store_dir/playlists/$item", "Entry exists: $item");
	}
};

# 29
run3 [@podist, 'feed'], undef, \$stdout, \$stderr;
check_run("Generated feed", $stdout, $stderr);
note("Feed:\n", read_text("$store_dir/playlists/feed.xml"));

exit 0;

## subs from here on out
sub check_run {
	my ($message, $stdout, $stderr) = @_;

	if (0 == $?) {
		pass($message);
		note("stdout: $stdout");
		note("stderr: $stderr");
	} else {
		fail($message);
		diag("stdout: $stdout");
		diag("stderr: $stderr");
	}

	return;
}

sub setup_config {
	# options: in, out - files names to read/write (may be the same file)
	#          store - where to configure to store media/playlists
	#          dbdir - where to find podist.db (optional, only change if
	#                  specified)
	my %opts = @_;

	my $conf = read_text($opts{in});
	$conf =~ s!\$HOME/Podist/!$opts{store}/!g or die "No storage found";
	$conf =~ s!^NotYetConfigured true$!NotYetConfigured false!m
		or die "Couldn't find NotYetConfigured";
	$conf =~ s!^(\s*)Level info(\s+)!${1}Level trace$2!m
		or die "Couldn't find logging Level";

	if (exists $opts{dbdir}) {
		$conf =~ s!^DataDir .+ #!DataDir $opts{dbdir} #!m
			or die "Couldn't find DataDir to replace";
	}

	note("Writing config: $conf");
	write_text($opts{out}, $conf);

	return;
}
