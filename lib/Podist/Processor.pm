package Podist::Processor;
use Moose;
use Podist::Types;
use Log::Log4perl;
use IPC::Run3 qw(run3);
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
		sub { [qw(ffmpeg -nostdin -hide_banner -nostats -loglevel info)] },
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
);

sub BUILD {
	my $self = shift;

	my $info = $CODECS{$self->_encoder}
		or die "Unknown codec: @{[$self->_encoder]}";

	$self->_quality >= $info->{qual_min}
		or die "Quality @{[$self->_quality]} below min ($info->{qual_min})";
	$self->_quality <= $info->{qual_max}
		or die "Quality @{[$self->_quality]} above max ($info->{qual_max})";

	return;
}

sub process {
	my ($self, $infile) = @_;

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
	$self->_logger->debug("Sending normalized to $outfile");
	run3 [
		@{$self->_ffmpeg},
		-i          => $infile,
		'-filter:a' => $self->_get_filter($mode, $info),
		@{$CODECS{$self->_encoder}{ff_args}},
		$CODECS{$self->_encoder}{qual_arg} => $self->_quality,
		$outfile
	], \undef, \$stdout, \$stderr;
	if ($?) {
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
	$self->_logger->debug(
		{filter => \&Data::Dump::pp, value => $self->_last_process_info});

	return [ $outfile ]; # someday, will return 0 or more files
}

sub _get_filter {
	my ($self, $mode, $info) = @_;
	my $res;
	if ('loudnorm' eq $mode) {
		$res = 'loudnorm=I=' . $self->_loudness;
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
		$res = 'volume=replaygain=drop';
		$res .= ':volume=' . ($self->_loudness - $info->{loudness}) . 'dB';
	}

	$self->_logger->trace("Built filter: $res");
	return $res;
}

sub _get_bs1770_info {
	my ($self, $file) = @_;

	$self->_logger->debug("Getting volume of $file");
	my ($stdout, $stderr);
	run3 [
		@{$self->_ffmpeg},
		-i          => $file,
		'-filter:a' => $self->_get_filter('loudnorm'),
		-f          => 'null',
		'-'
	], \undef, \$stdout, \$stderr;
	if ($?) {
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
			loudness  => 0 + $json->{input_i},
			range     => 0 + $json->{input_lra},
			threshold => 0 + $json->{input_thresh},
			truepeak  => 0 + $json->{input_tp},
			offset    => 0 + $json->{target_offset},
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
	if ($stderr =~ /^\[Parsed_loudnorm_0.+?\]\s*^(\{.+\})/ms) {
		return decode_json($1);
	} else {
		return undef;
	}
}

sub _build_logger { Log::Log4perl->get_logger(__PACKAGE__) }

__PACKAGE__->meta->make_immutable;
1;
