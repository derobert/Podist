use Test::More tests => 12;
use File::Temp qw();
use Log::Log4perl;
use feature qw(state);

use constant TARG_loudness => -15;
use constant TARG_range => 5;

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

# we're testing if something sane happened, not if ffmpeg gave exact
# results, so accept a range:
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
		encodequality => 96_000,
		NC_temp_maker => \&temp_maker,
	],
	'Podist::Processor'
);

is(@temps, 0, 'Started with no temps');
my $victim = 't-data/stereo-mono.mp3';
my $resfiles = $proc->process($victim);
is(@$resfiles,     1,         'Got one file back');
is(@temps,         1,         'Have one temp after process');
is($resfiles->[0], $temps[0], 'Expected temp was returned');
ok($resfiles->[0] =~ /\.opus$/, 'Claims to be an opus file');
is($proc->_last_process_info->{MODE}, 'loudnorm',
	'ffmpeg loudnorm filter used');
is($proc->_last_process_info->{normalization_type}, 'dynamic',
	'Dynamic normalization used');
is($proc->_last_process_info->{mixed_layouts}, 1,
	'Mixed channel-layout mode used');

my $after = $proc->_get_bs1770_info($resfiles->[0]);
is_range($after->{loudness}, TARG_loudness, 0.5, 'Processed loudness');
TODO: { 
	local $TODO = "ffmpeg loudnorm doesn't guarantee LRA";
	is_range($after->{range},    TARG_range,   2, 'Processed range');
}
