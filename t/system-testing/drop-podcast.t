use 5.024;

use Data::Dump qw(pp);
use File::Temp qw();
use IPC::Run3;
use Test::More;
use Podist::Test::SystemTesting qw(
	setup_config check_run plan_dangerously_or_exit basic_podist_setup
	add_test_feeds add_test_randoms connect_to_podist_db
);
use Podist::Test::Notes qw(long_note);

plan_dangerously_or_exit tests => 6;

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

my $podist_setup = basic_podist_setup(); # test 1

my ($stdout, $stderr, $res);
my $podist = $podist_setup->{podist};

my $dbh = connect_to_podist_db($podist_setup->{db_file}); # test 2

add_test_feeds(
	podist       => $podist,
	n_base_feeds => 2,
	catch        => 1,
); # test 3

my ($count) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM enclosures where enclosure_use = 0});
is($count, 0, q{No don't-use enclosures});

run3 [@$podist, qw(drop -f 1)], undef, \$stdout, \$stderr;
check_run("drop runs: drop feed 1", $stdout, $stderr);

($count) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM enclosures where enclosure_use = 0});
ok($count > 0, q{After drop, have don't-use enclosures});
