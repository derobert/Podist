use Test::More tests => 4;
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
delete $info->{offset}; # do not care
is_deeply(
	$info,
	{
		loudness  => -25.49,
		truepeak  => -6.58,
		range     => 6.90,
		threshold => -36.37,
	},
	'Input got expected ITU BS.1770 info (test-recording)'
);

$info = $proc->_get_bs1770_info('t-data/MountainKing.flac');
delete $info->{offset}; # do not care
is_deeply(
	$info,
	{
		loudness  => -12.43,
		truepeak  => 0.30,
		range     => 24.80,
		threshold => -26.34,
	},
	'Input got expected ITU BS.1770 info (Mountain King)'
);
