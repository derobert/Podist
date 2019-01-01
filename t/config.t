use 5.024;
use strict;
use warnings qw(all);

use Test::More tests => 25;
use Clone qw(clone);
use File::Slurper q(read_text);
use File::Temp qw();
use Podist::Test::Notes qw(long_note);
use Test::Exception;

BEGIN { use_ok('Podist::Config') }

my $conf_dir = File::Temp::tempdir(CLEANUP => 1);

my $Cfg;
lives_ok { $Cfg = Podist::Config->new() } 'Constructor OK'
	or BAIL_OUT("New failed, this is hopeless");

lives_ok { $Cfg->_default_config_text(conf_dir => $conf_dir) }
	'default_config_text runs';
dies_ok { $Cfg->_default_config_text() }
	'default_config_text notices missing arg';

my ($config1, $config2);
lives_ok { $config1 = $Cfg->read_or_create_config(conf_dir => $conf_dir) }
	'creates a new config';
lives_ok { $config2 = $Cfg->read_or_create_config(conf_dir => $conf_dir) }
	'reads existing config';
is_deeply($config2, $config1, 'Re-read got the same config');

my $new_file = "$conf_dir/new.conf";
lives_ok {
	$Cfg->write_config(
		conf_file => $new_file,
		config    => $config1
		)
} 'writes a new config';
long_note('Written config:', read_text($new_file));
dies_ok {
	$Cfg->write_config(
		conf_file => "/nonexistent/bad/dir/new.conf",
		config    => $config1
		)
} 'fails with nonexistent path';

my $config3;
lives_ok { $config3 = $Cfg->read_config(conf_dir => $conf_dir, conf_file => $new_file) } 'reads written config';

is_deeply($config3, $config1, 'Read back what we wrote');

my $config4 = clone($config1);
delete $config4->{article}{titleignorere};
lives_ok {
	$Cfg->write_config(
		conf_file => $new_file,
		config    => $config4
		)
} 'writes a new config without TitleIgnoreRE';

$config4->{article}{titleignorere} = qr/whatever/ai;
dies_ok {
	$Cfg->write_config(
		conf_file => $new_file,
		config    => $config4
		)
} 'notices wrong regexp flags';


is($Cfg->_normalize_fraction('1.234'), 1.234, 'Understands decimals');
is($Cfg->_normalize_fraction('.234'),  0.234, 'Omitted leading 0');
is($Cfg->_normalize_fraction('2'),     2,     'Understands integers');
is($Cfg->_normalize_fraction('1/2'),   0.5,   'Understands fractions');
is($Cfg->_normalize_fraction('1/0.5'), 2,     'Decimal fract');
is($Cfg->_normalize_fraction('1./2.'), 0.5,   'Trailing dot');

dies_ok { $Cfg->_normalize_fraction('-1') } 'rejects negative decimal';
dies_ok { $Cfg->_normalize_fraction('1/-2') } 'rejects negative denom';
dies_ok { $Cfg->_normalize_fraction('a/b') } 'rejects text';
dies_ok { $Cfg->_normalize_fraction('.') } 'rejects plain dot';

is($Cfg->_compile_regex('a?bc'), qr/a?bc/, 'Compiles regexes');
dies_ok { $Cfg->_compile_regex('Hello )') } 'Dies on invalid regex';
