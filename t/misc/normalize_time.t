use strict;
use warnings qw(all);

use Test::More tests => 11;
use Test::Exception;
use Log::Log4perl;

$Log::Log4perl::LOGDIE_MESSAGE_ON_STDERR = 1; # else it exists instead of dies
Log::Log4perl->easy_init(
	{level => $Log::Log4perl::OFF, layout => '[%r] [%c/%p{1}] %m%n'});

BEGIN { use_ok('Podist::Misc', qw(normalize_time)) }
is(normalize_time('30'),   30,        'Understands unlabeled seconds');
is(normalize_time('30s'),  30,        'Understands seconds');
is(normalize_time('30 s'), 30,        'Understands seconds with space');
is(normalize_time('30 S'), 30,        'Understands SECONDS with space');
is(normalize_time('2 m'),  120,       'Understands minutes');
is(normalize_time('2 h'),  7200,      'Understands hours');
is(normalize_time('2 d'),  86400 * 2, 'Understands days');
is(normalize_time('4 w'), 86400 * 28, 'Understands weeks');
dies_ok { normalize_time('purple') }  'rejects invalid format 1 (purple)';
dies_ok { normalize_time('2 y') }     'rejects invalid format 2 (years)';

