use strict;
use warnings qw(all);

use Test::More tests => 9;
use Test::Exception;
use Data::Dump qw(pp);
use Clone qw(clone);

use Log::Log4perl;

Log::Log4perl->easy_init(
	{level => $Log::Log4perl::OFF, layout => '[%r] [%c/%p{1}] %m%n'});

use_ok 'Podist::Misc';

our (%IN, %WANT);
sub do_test($) {
	my $name = shift;

	my $out = clone(\%IN);
	Podist::Misc::inherit_proc_profiles($out);
	is_deeply($out, \%WANT, $name);
	return;
}

%IN = (
	base => {
		foo => 1,
		bar => 2,
	},
	derived => {
		basedon => 'base',
		bar     => 3,
		baz     => 4,
	});
%WANT = (
	base => {
		foo => 1,
		bar => 2,
	},
	derived => {
		basedon => 'base',
		foo     => 1,
		bar     => 3,
		baz     => 4,
	});
do_test 'Simple inherit';

# ok, add a second trunk, make sure that multiple trees are OK
$IN{sapling} = { foo => 1 };
$WANT{sapling} = { foo => 1 };
do_test 'Two trees';

# try using a base twice
$IN{sibling} = {basedon => 'base'};
$WANT{sibling} = {basedon => 'base', foo => 1, bar => 2};
do_test 'Two children';

# grandchildren
$IN{grandchild} = {basedon => 'derived', taz => 42};
$WANT{grandchild}
	= {basedon => 'derived', foo => 1, bar => 3, baz => 4, taz => 42};
do_test 'Grandchild';

#### ERRORS
# First up, a profile based on itself.
$IN{stack_overflow} = { basedon => 'stack_overflow' };
throws_ok { do_test '(should die)'; }
	qr/problem with config/i, 'Catches self-referential profile';
delete $IN{stack_overflow};

# Longer chain
$IN{base}{basedon} = 'grandchild';
throws_ok { do_test '(should die)'; }
	qr/problem with config/i, 'Catches circular profiles';
delete $IN{base}{basedon};

# Too deep, but not infinit
$IN{0}{basedon} = 'base';
for (my $n = 1; $n < 1000; ++$n) { # order is random, so needs to be high
	$IN{$n}{basedon} = $n-1;
}
throws_ok { do_test '(should die)'; }
	qr/basedon chain too long/i, 'Refuses too-much but finite recursion';
for (my $n = 0; $n < 1000; ++$n) { delete $IN{$n} }

# How about based on a profile no one has heard of?
$IN{confused}{basedon} = 'does-not-exist';
throws_ok { do_test '(should die)'; }
	qr/does not exist/i, 'Notices base does not exist';
