use Test::More tests => 6;
use Test::Deep qw(cmp_deeply ignore num);
use Log::Log4perl;

Log::Log4perl->easy_init(
	{level => $Log::Log4perl::INFO, layout => '[%r] [%c/%p{1}] %m%n'});

BEGIN { use_ok 'Podist::Processor' }

my $proc = new_ok(
	'Podist::Processor' => [
		loudness      => -23,
		loudnessrange => 10,
		encoder       => 'opus',
		encodequality => 96_000,
		NC_temp_maker => \&temp_maker,
	],
	'Podist::Processor'
);

my $info = $proc->_get_bs1770_info('t-data/test-recording.flac');
cmp_deeply(
	$info,
	{
		offset        => ignore,
		loudness      => num(-25.49, 0.02),
		truepeak      => num(-6.58,  0.02),
		range         => num(6.90,   0.05),
		threshold     => num(-36.37, 0.02),
		mixed_layouts => 0,
	},
	'Input got expected ITU BS.1770 info (test-recording)'
);

$info = $proc->_get_bs1770_info('t-data/MountainKing.flac');
cmp_deeply(
	$info,
	{
		offset        => ignore,
		loudness      => num(-12.43, 0.02),
		truepeak      => num(0.30,   0.02),
		range         => num(24.80,  0.05),
		threshold     => num(-26.34, 0.02),
		mixed_layouts => 0,
	},
	'Input got expected ITU BS.1770 info (Mountain King)'
);

$info = $proc->_get_bs1770_info('t-data/mono.flac');
cmp_deeply(
	$info,
	{
		offset        => ignore,
		loudness      => num(-22.42, 0.02),
		truepeak      => num(-3.00,  0.02),
		range         => num(6.30,   0.05),
		threshold     => num(-32.72, 0.02),
		mixed_layouts => 0,
	},
	'Input got expected ITU BS.1770 info (mono)'
);

$info = $proc->_get_bs1770_info('t-data/stereo-mono.mp3');
cmp_deeply(
	$info,
	{
		offset        => ignore,
		loudness      => num(-19.19, 0.02),
		truepeak      => num(-3.01,  0.02),
		range         => num(0.30,   0.05),
		threshold     => num(-29.31, 0.02),
		mixed_layouts => 1,
	},
	'Input got expected ITU BS.1770 info (mixed stereo & mono)'
);
