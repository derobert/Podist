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

plan_dangerously_or_exit tests => 12;

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

# 1
my $podist_setup = basic_podist_setup();

my ($stdout, $stderr, $res);
my $store_dir = $podist_setup->{store_dir};
my $podist = $podist_setup->{podist};

# 2
my $dbh = connect_to_podist_db($podist_setup->{db_file});

# 3
add_test_feeds(
	podist       => $podist,
	n_base_feeds => 2,
	catch        => 0,
);

my $old = $dbh->selectall_hashref(q{SELECT * FROM feeds}, 'feed_no');
long_note('old:', pp $old);

run3 [@$podist, qw(editfeed -f 1 --disable --name NotGood --no-ordered --no-all-audio --is-music --limit-amount 10 --limit-period=2w --proc-profile NewProfile)], undef, \$stdout, \$stderr;
check_run("editfeed runs: change feed 1", $stdout, $stderr);

my $row = $dbh->selectrow_hashref(q{SELECT * FROM feeds WHERE feed_no = 1});
is_deeply(
	$row,
	{
		feed_no           => 1,
		feed_enabled      => 0,
		feed_name         => 'NotGood',
		feed_ordered      => 0,
		feed_all_audio    => 0,
		feed_is_music     => 1,
		feed_limit_amount => 10,
		feed_limit_period => 86400 * 14,
		feed_proc_profile => 'NewProfile',
		feed_url          => $old->{1}{feed_url}
	},
	'Row is as expected after edit'
);

my $row = $dbh->selectrow_hashref(q{SELECT * FROM feeds WHERE feed_no = 2});
is_deeply($row, $old->{2}, 'Feed 2 remains unchanged');

run3 [@$podist, qw(editfeed -f 1 --enable --ordered --all-audio --no-is-music)], undef, \$stdout, \$stderr;
check_run("editfeed runs: change feed 1 again", $stdout, $stderr);

my $row = $dbh->selectrow_hashref(q{SELECT * FROM feeds WHERE feed_no = 1});
is_deeply(
	$row,
	{
		feed_no           => 1,
		feed_enabled      => 1,
		feed_name         => 'NotGood',
		feed_ordered      => 1,
		feed_all_audio    => 1,
		feed_is_music     => 0,
		feed_limit_amount => 10,
		feed_limit_period => 86400 * 14,
		feed_proc_profile => 'NewProfile',
		feed_url          => $old->{1}{feed_url}
	},
	'Row is as expected after edit'
);

run3 [@$podist, qw(editfeed -f 1 --enable --disable)], undef, \$stdout, \$stderr;
check_run("editfeed refuses enabled & disabled together", $stdout, $stderr, 2<<8);

run3 [@$podist, qw(editfeed --enable)], undef, \$stdout, \$stderr;
check_run("editfeed refuses missing feed number", $stdout, $stderr, 2<<8);

run3 [@$podist, qw(editfeed -f 1 --enable --wtf)], undef, \$stdout, \$stderr;
check_run("editfeed refuses weird param", $stdout, $stderr, 2<<8);

run3 [@$podist, qw(editfeed -f 1)], undef, \$stdout, \$stderr;
check_run("editfeed notices no changes", $stdout, $stderr, 2<<8);
