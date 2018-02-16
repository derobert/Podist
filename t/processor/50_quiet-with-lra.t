use Test::More tests => 8;
use File::Temp qw();
use Log::Log4perl;
use feature qw(state);

use constant TARG_loudness => -30;
use constant TARG_range => 10;

Log::Log4perl->easy_init(
	{level => $Log::Log4perl::INFO, layout => '[%r] [%c/%p{1}] %m%n'});

my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
my @temps;

sub temp_maker {
	my $suffix = shift;
	state $tnum = 0;

	my $name = sprintf('%s/%03i%s', $tmpdir, $tnum++, $suffix);
	push @temps, $name;
	return $name;
}

sub is_range {
	my ($got, $want, $epsilon, $msg) = @_;
	my $low  = $want - $epsilon;
	my $high = $want + $epsilon;

	if ($got >= $low && $got <= $high) {
		pass($msg);
	} else {
		fail("$got not in [$low, $high]: $msg");
	}
}

BEGIN { use_ok 'Podist::Processor' }

my $proc = new_ok(
	'Podist::Processor' => [
		loudness      => TARG_loudness,
		loudnessrange => TARG_range,
		encoder       => 'opus',
		bitrate       => 96_000,
		NC_temp_maker => \&temp_maker,
	],
	'Podist::Processor'
);

my $victim = 't-data/test-recording.flac';
my $resfiles = $proc->process($victim);
is($proc->_last_process_info->{MODE}, 'volume',
	'ffmpeg volume filter used');

my $after = $proc->_get_bs1770_info($resfiles->[0]);
is_range($after->{loudness}, TARG_loudness, 0.5, 'Processed loudness');

$victim = 't-data/MountainKing.flac';
$resfiles = $proc->process($victim);
is($proc->_last_process_info->{MODE}, 'loudnorm',
	'ffmpeg volume filter used');
is($proc->_last_process_info->{normalization_type}, 'dynamic',
	'Dynamic normalization used');
$after = $proc->_get_bs1770_info($resfiles->[0]);
is_range($after->{loudness}, TARG_loudness, 0.5, 'Processed loudness');
TODO: { 
	local $TODO = "ffmpeg loudnorm doesn't guarantee LRA";
	is_range($after->{range},    TARG_range,   2, 'Processed range');
}
