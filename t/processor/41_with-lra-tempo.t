use Test::More tests => 22;
use File::Temp qw();
use IPC::Run3 qw(run3);
use Log::Log4perl;
use feature qw(state);

use constant TARG_loudness => -23;
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

sub get_duration {
	my $file = shift;
	my $stdout;
	
	run3([
			qw(ffprobe -of default=nk=1:nw=1 -loglevel error -hide_banner
			           -show_entries format=duration),
			$file
		],
		\undef, \$stdout, undef
	);
	0 == $? or die "ffprobe failed: $?";

	return $stdout;
}

BEGIN { use_ok 'Podist::Processor' }

my $proc = new_ok(
	'Podist::Processor' => [
		loudness      => TARG_loudness,
		loudnessrange => TARG_range,
		tempo         => 1.3,
		encoder       => 'opus',
		encodequality => 96_000,
		NC_temp_maker => \&temp_maker,
	],
	'Podist::Processor'
);
my $proc_normal_tempo = new_ok(
	# used to check resulting volume; rubberband changes loudness causing
	# tests to fail.
	'Podist::Processor' => [
		loudness      => TARG_loudness,
		loudnessrange => TARG_range,
		tempo         => 1,
		encoder       => 'opus',
		encodequality => 96_000,
		NC_temp_maker => \&temp_maker,
	],
	'Podist::Processor'
);

is(@temps, 0, 'Started with no temps');
my $victim = 't-data/test-recording.flac';
my $resfiles = $proc->process($victim);
is(@$resfiles,     1,         'Got one file back');
is(@temps,         1,         'Have one temp after process');
is($resfiles->[0], $temps[0], 'Expected temp was returned');
ok($resfiles->[0] =~ /\.opus$/, 'Claims to be an opus file');
is($proc->_last_process_info->{MODE}, 'loudnorm',
	'ffmpeg loudnorm filter used');
is($proc->_last_process_info->{normalization_type}, 'dynamic',
	'Dynamic normalization used');

my $after = $proc_normal_tempo->_get_bs1770_info($resfiles->[0]);
is_range($after->{loudness}, TARG_loudness, 0.5, 'Processed loudness');
is_range($after->{range},    TARG_range,   2, 'Processed range');
is_range(
	get_duration($resfiles->[0]),
	get_duration($victim) / 1.3,
	1, 'Processed duration'
);

$victim = 't-data/MountainKing.flac';
$resfiles = $proc->process($victim);
is(@$resfiles,     1,         'Got one file back');
is(@temps,         2,         'Have two temps after second process');
is($resfiles->[0], $temps[1], 'Expected temp was returned');
ok($resfiles->[0] =~ /\.opus$/, 'Claims to be an opus file');
is($proc->_last_process_info->{MODE}, 'loudnorm',
	'ffmpeg loudnorm filter used');
is($proc->_last_process_info->{normalization_type}, 'dynamic',
	'Dynamic normalization used');
$after = $proc_normal_tempo->_get_bs1770_info($resfiles->[0]);
is_range($after->{loudness}, TARG_loudness, 0.5, 'Processed loudness');
TODO: { 
	local $TODO = "ffmpeg loudnorm doesn't guarantee LRA";
	is_range($after->{range},    TARG_range,   2, 'Processed range');
}
is_range(
	get_duration($resfiles->[0]),
	get_duration($victim) / 1.3,
	1, 'Processed duration'
);
