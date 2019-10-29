use 5.024;

use Data::Dump qw(pp);
use File::Find qw(find);
use File::Slurper qw(read_text read_lines);
use IPC::Run3;
use Test::Deep;
use Test::Exception;
use Test::More;
use Text::CSV;
use Podist::Config;
use Podist::Test::SystemTesting qw(
	setup_config check_run plan_dangerously_or_exit basic_podist_setup
	add_test_feeds add_test_randoms connect_to_podist_db
);
use Podist::Test::Notes qw(long_note);

# This test is somewhat dangerous (e.g., might ignore the non-default
# directories we say to use, and instead do weird things to your actual
# Podist install). So we won't run unless LIVE_DANGEROUSLY=1 is set.
# Note the GitLab CI sets this, as its run in a docker container, so no
# existing Podist to worry about.
plan_dangerously_or_exit tests => 17;

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

my $pids_query = <<QUERY;
SELECT COUNT(DISTINCT processed_pid) AS distinct_pids,
       SUM(CASE WHEN processed_pid IS NULL THEN 1 ELSE 0 END) AS null_pids
  FROM processed
 WHERE playlist_no = ?
QUERY

# 1
my $podist_setup = basic_podist_setup();

my ($stdout, $stderr, $res1, $res2);
my $store_dir = $podist_setup->{store_dir};
my $podist = $podist_setup->{podist};

# 2
my $dbh = connect_to_podist_db($podist_setup->{db_file});

# 3
add_test_feeds(
	podist       => $podist,
	n_base_feeds => 8,
	catch        => 1,
);

# 4
my $Cfg = Podist::Config->new;
my $config = $Cfg->read_config(
	conf_dir  => $podist_setup->{conf_dir},
	conf_file => $podist_setup->{conf_file});
long_note('Initial parsed config:', pp($config));
ok($config, 'Parsed initial config');

# 5
add_test_randoms(store_dir => $store_dir, how_many => 1);

# 6
$config->{processing}{parallel} = 0;
lives_ok {
	$Cfg->write_config(
		conf_file => $podist_setup->{conf_file},
		config    => $config
		)
} 'Wrote config disabling parallel';

# 7
run3 [@$podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist with randoms", $stdout, $stderr);

# 8
run3 [@$podist, 'process'], undef, \$stdout, \$stderr;
check_run("Ran audio processing", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing after processing:\n$stdout");

# 9 & 10
($res1, $res2) = $dbh->selectrow_array($pids_query, {}, 1);
is($res1, 1, 'Used one pid w/o parallel proc');
is($res2, 0, 'No null pids w/o parallel proc');

# 11
($res1) = $dbh->selectrow_array(
	q{SELECT COUNT(*) FROM enclosures WHERE playlist_no = 1});
($res2) = $dbh->selectrow_array(
	q{SELECT COUNT(*) FROM processed WHERE playlist_no = 1});
is($res2, $res1, 'All playlist entries processed (single-proc)');

# 12
$config->{processing}{parallel} = 2;
lives_ok {
	$Cfg->write_config(
		conf_file => $podist_setup->{conf_file},
		config    => $config
		)
} 'Wrote config enabling parallel=2';

# 13
run3 [@$podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist with randoms", $stdout, $stderr);

# 14
run3 [@$podist, 'process'], undef, \$stdout, \$stderr;
check_run("Ran audio processing", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing after processing:\n$stdout");

# 15 & 16
($res1, $res2) = $dbh->selectrow_array($pids_query, {}, 2);
ok($res1 > 1, 'Used multiple pids with parallel proc');
is($res2, 0, 'No null pids with parallel proc');

# 17
($res1) = $dbh->selectrow_array(
	q{SELECT COUNT(*) FROM enclosures WHERE playlist_no = 2});
($res2) = $dbh->selectrow_array(
	q{SELECT COUNT(*) FROM processed WHERE playlist_no = 2});
is($res2, $res1, 'All playlist entries processed (parallel)');

exit 0;
