use Test::More tests => 5;
use Test::Exception;
use File::Temp qw();
use Log::Log4perl;
use feature qw(state);

use constant TARG_loudness => -30;

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

BEGIN { use_ok 'Podist::Processor' }

throws_ok {
	Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'invalid',
		encodequality => 5,
		NC_temp_maker => \&temp_maker,
	);
} qr/unknown codec/i, 'Unknown codec';

throws_ok {
	Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'lame-cbr',
		encodequality => 123,
		NC_temp_maker => \&temp_maker,
	);
} qr/allowed list/, 'Invalid CBR bitrate';

throws_ok {
	Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'lame-vbr',
		encodequality => -1,
		NC_temp_maker => \&temp_maker,
	);
} qr/below min/, 'Too low quality';

throws_ok {
	Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'lame-vbr',
		encodequality => 11,
		NC_temp_maker => \&temp_maker,
	);
} qr/above max/, q{Can't turn it up to 11};
