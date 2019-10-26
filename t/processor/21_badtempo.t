use Test::More tests => 7;
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
		encoder       => 'lame-cbr',
		encodequality => 128,
		tempo         => 0,
		NC_temp_maker => \&temp_maker,
	);
} qr/Tempo must be positive/, 'Prohibits 0 tempo';

throws_ok {
	Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'lame-cbr',
		encodequality => 128,
		tempo         => 'quertyuiop',
		NC_temp_maker => \&temp_maker,
	);
} qr/Unparseable tempo/, 'Does not parse nonsense';

my $proc;
lives_ok {
	$proc = Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'lame-cbr',
		encodequality => 128,
		tempo         => '1.3x',
		NC_temp_maker => \&temp_maker,
	);
} 'Accepts 1.3x form';
is($proc->_tempo, 1.3, 'Parsed 1.3x correctly');

lives_ok {
	$proc = Podist::Processor->new(
		loudness      => TARG_loudness,
		encoder       => 'lame-cbr',
		encodequality => 128,
		tempo         => '130%',
		NC_temp_maker => \&temp_maker,
	);
} 'Accepts 130% form';
is($proc->_tempo, 1.3, 'Parsed 130% correctly');
