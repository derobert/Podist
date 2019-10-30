package Podist::Processor;
use Moose;
use Podist::Types;
use File::Copy qw();
use Log::Log4perl;
use IPC::Run qw(run);
use JSON::MaybeXS qw(decode_json);
use Data::Dump qw(pp);
use Carp;
use namespace::autoclean;

# TODO: As we add more processing, this will eventually grow a more
# flexible plugin architecture. For now, just enough to get volume
# leveling working!
#
# TODO: Look into ffmpeg resampling behavior. Especially when lowering
# the volume, probably want to compute at higher sample size then
# dither. Also, a lot of our input is probably 44.1, but we output at
# 48... so make sure that resample is good.

has _temp => (
	required => 1,
	is       => 'ro',
	isa      => 'CodeRef',
	init_arg => 'NC_temp_maker',
);

has _loudness => (
	init_arg => 'loudness',
	required => 1,
	is       => 'ro',
	isa      => 'Podist::LUFS',
	coerce   => 1,
);

has _loudness_range => (
	init_arg => 'loudnessrange',
	required => 1,
	is       => 'ro',
	isa      => 'Podist::LU',
	default  => undef,
	coerce   => 1
);

has _tempo => (
	init_arg => 'tempo',
	required => 1,
	is       => 'ro',
	isa      => 'Podist::Tempo',
	default  => 1.0,
	coerce   => 1,
);

has _rb_opts => (
	init_arg => 'rubberbandoptions',
	required => 1,
	is       => 'ro',
	isa      => 'Str',
	default  => ':pitchq=quality:window=short',
);

has _encoder => (
	init_arg => 'encoder',
	required => 1,
	is       => 'ro',
	isa      => 'Str',
);

has _quality => (
	init_arg => 'encodequality',
	required => 1,
	is       => 'ro',
	isa      => 'Podist::Quality',
	coerce   => 1
);

has _logger => (
	init_arg => 'NC_logger',
	required => 1,
	is       => 'ro',
	builder  => '_build_logger',
);

# this is for the test suite
has _last_process_info => (
	init_arg => undef,
	is       => 'rw',
	isa      => 'Maybe[HashRef]',
);

has _ffmpeg => (
	init_arg => undef,
	required => 1,
	is       => 'ro',
	default =>
		sub { [qw(ffmpeg -nostdin -hide_banner -nostats)] },
);

has _ffprobe => (
	init_arg => undef,
	required => 1,
	is       => 'ro',
	default =>
		sub { [qw(ffprobe -hide_banner)] },
);

my %CODECS = (
	opus => {
		# opus basically doesn't do 44.1 kHz
		ff_args => [ qw(-vn -c:a libopus -ar 48000 -vbr on) ],
		qual_name => 'VBR bitrate',
		qual_arg => '-b:a',
		qual_min => 6_000,
		qual_max => 510_000,
		file_ext => '.opus',
	},
	vorbis => {
		ff_args => [ qw(-vn -c:a libvorbis) ],
		qual_name => 'quality',
		qual_arg => '-q:a',
		qual_min => -1,
		qual_max => 10,
		file_ext => '.ogg',
	},
	'lame-vbr' => {
		# ffmpeg seems like it might manage to copy cover art for mp3
		ff_args => [ qw(-c:a libmp3lame -c:v copy -compression_level 0 -id3v2_version 4 ) ],
		qual_name => 'quality',
		qual_arg => '-q:a',
		qual_min => 0,
		qual_max => 9.999,
		file_ext => '.mp3',
	},
	'lame-cbr' => {
		# ffmpeg seems like it might manage to copy cover art for mp3
		ff_args => [ qw(-c:a libmp3lame -c:v copy -compression_level 0 -id3v2_version 4 ) ],
		qual_name => 'CBR bitrate',
		qual_arg => '-b:a',
		qual_list => [qw(32 40 48 56 64 80 96 112 128 160 192 224 256 320)],
		file_ext => '.mp3',
	},
);

sub BUILD {
	my $self = shift;
	local $_;

	my $info = $CODECS{$self->_encoder}
		or die "Unknown codec: @{[$self->_encoder]}";
	my $quality = $self->_quality;

	if ($info->{qual_list}) {
		my $list = $info->{qual_list};
		grep($_ == $quality, @$list)
			or die("Quality $quality not in allowed list ("
			       . join(', ', @$list)
			       . ")");
	} else {
		$quality >= $info->{qual_min}
			or die "Quality $quality below min ($info->{qual_min})";
		$quality <= $info->{qual_max}
			or die "Quality $quality above max ($info->{qual_max})";
	}

	return;
}

sub process {
	my ($self, $infile) = @_;

	# TODO: workaround for lack of plugins, avoid CPU-intensive work
	#       during some tests that don't actually need it.
	if ($ENV{PODIST_FAST_FAKE_PROCESSOR}) {
		my $res = $self->_fast_fake_process($infile);
		return $res if $res;
	}

	my $info = $self->_get_bs1770_info($infile)
		or die "failed to get ITU BS.1770 info";
	my $outfile = $self->_temp->($CODECS{$self->_encoder}{file_ext});

	# unfortunately, loudnorm does not permit LRA>20, so if we're trying
	# not to limit LRA, that could be a problem. If we're lowering the
	# volume, though, we don't have to worry about clipping — so we can
	# use the volume filter instead.
	my $mode;
	if ($self->_loudness <= $info->{loudness}) { # lowering volume
		if (defined $self->_loudness_range) {
			if ($info->{range} <= $self->_loudness_range) {
				$mode = 'volume';
			} else {
				$mode = 'loudnorm';
			}
		} else {
			$mode = 'volume';
		}
	} else { # making it louder
		$mode = 'loudnorm';
		defined $self->_loudness_range || $info->{range} <= 20
			or $self->_logger->warn("Implementation limitations force LRA adjustment of $infile (original LRA $info->{range}, target 20)");
	}

	my ($stdout, $stderr);

	# if we have mixed mono/stereo, the only way I found to make this
	# work is convert everything to stereo. Avoid if possible since
	# that's space-inefficient and also loses any cover art.
	my $run_ok;
	if ($info->{mixed_layouts}) {
		$self->_logger->debug("Sending mixed-layout normalized to $outfile");
		$run_ok = run(
			[
				@{$self->_ffmpeg},
				-loglevel   => 'warning',
				-i          => $infile,
				-map 		=> 'a:',
				'-filter:a'	=> 'aeval=val(0)|val(nb_in_channels-1):c=stereo',
				'-c:a'      => 'pcm_s16le',
				-f			=> 'nut',
				'pipe:'
			], q{|}, [
				@{$self->_ffmpeg},
				-loglevel   => 'info',
				-f			=> 'nut',
				-i			=> 'pipe:',
				'-filter:a' => $self->_get_filter($mode, $info),
				@{$CODECS{$self->_encoder}{ff_args}},
				$CODECS{$self->_encoder}{qual_arg} => $self->_quality,
				$outfile
			], \$stdout, \$stderr
		);
	} else {
		$self->_logger->debug("Sending single-layout normalized to $outfile");
		$run_ok = run(
			[
				@{$self->_ffmpeg},
				-loglevel   => 'info',
				-i          => $infile,
				'-filter:a' => $self->_get_filter($mode, $info),
				@{$CODECS{$self->_encoder}{ff_args}},
				$CODECS{$self->_encoder}{qual_arg} => $self->_quality,
				$outfile
			], \undef, \$stdout, \$stderr
		);
	}
	unless ($run_ok) {
		$self->_logger->error("ffmpeg exited status $?");
		$self->_logger->error("ffmpeg stdout: $stdout");
		$self->_logger->error("ffmpeg stderr: $stderr");
		die "ffmpeg failed to apply volume";
	}
	if ('loudnorm' eq $mode) {
		$self->_last_process_info($self->_read_ffmpeg_json($stderr));
	} else {
		$self->_last_process_info({}); # none from volume filter
	}
	$self->_last_process_info->{MODE} = $mode;
	$self->_last_process_info->{mixed_layouts} = $info->{mixed_layouts};
	$self->_logger->debug(
		{filter => \&Data::Dump::pp, value => $self->_last_process_info});

	return [ $outfile ]; # someday, will return 0 or more files
}

# TODO: get rid of this hacked solution once we have a plugin-based
#       approach where we could just configure a "copy the file" plugin.
sub _fast_fake_process {
	my ($self, $infile) = @_;

	if ($self->_encoder !~ /^lame-/) {
		$self->_logger->warn(
			'Fast fake process only supports lame, not ' . $self->_encoder);
		return;
	}

	if ($infile !~ /\.mp3$/) {
		$self->_logger->warn("Fast fake process requires MP3 input");
		return;
	}

	my $outfile = $self->_temp->($CODECS{$self->_encoder}{file_ext});
	File::Copy::copy($infile, $outfile);
	$self->_logger->trace("Fast fake processed $infile -> $outfile.");

	return [$outfile];
}

sub _get_filter {
	my ($self, $mode, $info) = @_;
	my $res;

	if (abs($self->_tempo - 1) > 0.0001) {
		$res .= 'rubberband=tempo=' . $self->_tempo;
		$res .= $self->_rb_opts;
		$res .= ',';
	}

	if ('loudnorm' eq $mode) {
		$res .= 'loudnorm=I=' . $self->_loudness;
		$res .= ':LRA=' . ($self->_loudness_range//20); # max per ffmpeg
		$res .= ':print_format=json';
		$res .= ':dual_mono=true';
		$res .= ':measured_I=' . $info->{loudness} if defined $info;
		$res .= ':measured_LRA=' . $info->{range} if defined $info;
		$res .= ':measured_TP=' . $info->{truepeak} if defined $info;
		$res .= ':measured_thresh=' . $info->{threshold} if defined $info;
		$res .= ':offset=' . $info->{offset} if defined $info;
	} elsif ('volume' eq $mode) {
		$info or confess "BUG: no first-pass info in volume mode";
		$res .= 'volume=replaygain=drop';
		$res .= ':volume=' . ($self->_loudness - $info->{loudness}) . 'dB';
	}

	$self->_logger->trace("Built filter: $res");
	return $res;
}

sub _get_bs1770_info {
	my ($self, $file) = @_;
	my ($run_ok, $stdout, $stderr);

	# Check if we need to work around an MP3 file that contains both
	# mono and stereo frames. That's apparently a thing. That causes
	# loudnorm to re-init and do weird things.
	$self->_logger->debug("Checking for mono/stereo mix in $file");
	$run_ok = run(
		[
			@{$self->_ffprobe},
			-loglevel       => 'warning',
			-select_streams => 'a',
			-show_entries   => 'frame=channels',
			-of             => 'csv',
			-i              => $file,
		], q{|}, [ qw(uniq) ], q{|}, [ qw(wc -l) ],
		\$stdout, \$stderr
	);
	unless ($run_ok) {
		$self->_logger->error("ffprobe exited status $?");
		$self->_logger->error("ffprobe stderr: $stderr");
		return undef;
	}
	my $need_mp3_workaround = ( 1 != $stdout );
	$need_mp3_workaround
		&& $self->_logger->debug("Mono/stereo mix detected.");

	$self->_logger->debug("Getting volume of $file");
	if ($need_mp3_workaround) {
		# Can't just use -ac 2 because then ffmpeg insists on lowering
		# volume of mono sections by 3dB.
		$run_ok = run(
			[
				@{$self->_ffmpeg},
				-loglevel   => 'warning',
				-i          => $file,
				-map 		=> 'a:',
				'-filter:a'	=> 'aeval=val(0)|val(nb_in_channels-1):c=stereo',
				'-c:a'      => 'pcm_s16le',
				-f			=> 'nut',
				'pipe:'
			], q{|}, [
				@{$self->_ffmpeg},
				-loglevel   => 'info',
				-f			=> 'nut',
				-i			=> 'pipe:',
				'-filter:a'	=> $self->_get_filter('loudnorm'),
				-f 			=> 'null',
				'pipe:'
			], \$stdout, \$stderr
		);
	} else {
		$run_ok = run(
			[
				@{$self->_ffmpeg},
				-i          => $file,
				'-filter:a' => $self->_get_filter('loudnorm'),
				-f          => 'null',
				'-'
			], \undef, \$stdout, \$stderr
		);
	}
	if (!$run_ok) {
		$self->_logger->error("ffmpeg exited status $?");
		$self->_logger->error("ffmpeg stderr: $stderr");
		return undef;
	} else {
		$self->_logger->trace("ffmpeg stdout: $stdout") if '' ne $stdout;
		$self->_logger->trace("ffmpeg stderr: $stderr") if '' ne $stderr;
	}

	# unfortunately, ffmpeg will not completely shut up and only give
	# us the JSON, so we have to look for it.
	if (my $json = $self->_read_ffmpeg_json($stderr)) {
		$self->_logger->debug({filter => \&Data::Dump::pp, value => $json});
		return {
			loudness      => 0 + $json->{input_i},
			range         => 0 + $json->{input_lra},
			threshold     => 0 + $json->{input_thresh},
			truepeak      => 0 + $json->{input_tp},
			offset        => 0 + $json->{target_offset},
			mixed_layouts => 0 + $need_mp3_workaround,
		};
	} else {
		$self->_logger->error(
			"Could not find loudnorm result in ffmpeg output: $stderr");
		return undef;
	}
}

sub _read_ffmpeg_json {
	my ($self, $stderr) = @_;

	# unfortunately, ffmpeg will not completely shut up and only give
	# us the JSON, so we have to look for it.
	if ($stderr =~ /^\[Parsed_loudnorm_.+?\]\s*^(\{.+\})/ms) {
		return decode_json($1);
	} else {
		return undef;
	}
}

sub _build_logger { Log::Log4perl->get_logger(__PACKAGE__) }

__PACKAGE__->meta->make_immutable;
1;
