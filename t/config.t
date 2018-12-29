use 5.024;
use strict;
use warnings qw(all);

use Test::More tests => 27;
use Test::Exception;
use File::Temp qw();

BEGIN { use_ok('Podist::Config') }

my $conf_dir = File::Temp::tempdir(CLEANUP => 1);

my $Cfg;
lives_ok { $Cfg = Podist::Config->new() } 'Constructor OK'
	or BAIL_OUT("New failed, this is hopeless");

lives_ok { $Cfg->default_config_text(conf_dir => $conf_dir) }
	'default_config_text runs';
dies_ok { $Cfg->default_config_text() }
	'default_config_text notices missing arg';

my ($config1, $config2);
lives_ok { $config1 = $Cfg->read_or_create_config(conf_dir => $conf_dir) }
	'creates a new config';
lives_ok { $config2 = $Cfg->read_or_create_config(conf_dir => $conf_dir) }
	'reads existing config';
is_deeply($config1, $config2, 'Re-read got the same config');

is($Cfg->_normalize_time('30'),   30, 'Understands unlabeled seconds');
is($Cfg->_normalize_time('30s'),  30, 'Understands seconds');
is($Cfg->_normalize_time('30 s'), 30, 'Understands seconds with space');
is($Cfg->_normalize_time('30 S'), 30, 'Understands SECONDS with space');
is($Cfg->_normalize_time('2 m'), 120,  'Understands minutes');
is($Cfg->_normalize_time('2 h'), 7200, 'Understands hours');

dies_ok { $Cfg->_normalize_time('purple') } 'rejects invalid format 1';
dies_ok { $Cfg->_normalize_time('2 d') } 'rejects invalid format 2';

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
