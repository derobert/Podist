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
plan_dangerously_or_exit tests => 18;

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

sub is_range {
	my ($got, $want, $epsilon, $msg) = @_;
	my $low  = $want - $epsilon;
	my $high = $want + $epsilon;

	if ($got >= $low && $got <= $high) {
		pass($msg);
	} else {
		fail("$got not in [$low, $high]: $msg");
	}
}


# 1
my $podist_setup = basic_podist_setup();

my ($stdout, $stderr, $res0, $res1, $res2);
my $store_dir = $podist_setup->{store_dir};
my $podist = $podist_setup->{podist};

# 2
my $dbh = connect_to_podist_db($podist_setup->{db_file});

# 3
add_test_feeds(
	podist       => $podist,
	n_base_feeds => 4,
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
$config->{processing}{profile}{default}{tempo} = 1;
$config->{processing}{profile}{new}{tempo} = 2;
$config->{processing}{profile}{new}{basedon} = 'default';
$config->{playlist}{minimumduration} = 1; # make shorter = speed up test
$config->{playlist}{targetduration}  = 1;
lives_ok {
	$Cfg->write_config(
		conf_file => $podist_setup->{conf_file},
		config    => $config
		)
} 'Wrote config for testing redo';
long_note('New configuration file', read_text($podist_setup->{conf_file}));

# 7
run3 [@$podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist with randoms", $stdout, $stderr);

# 8
run3 [@$podist, 'process'], undef, \$stdout, \$stderr;
check_run("Ran audio processing", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing after processing:\n$stdout");

# 9, 10
my $query = <<SQL;
SELECT COUNT(*) AS N,
       SUM(p.processed_duration) AS processed,
       SUM(e.enclosure_time) AS original
  FROM processed p
  JOIN enclosures e ON (p.enclosure_no = e.enclosure_no)
 WHERE p.playlist_no = 1
SQL
($res0, $res1, $res2) = $dbh->selectrow_array($query);
note("processed = $res1, original = $res2");
is($res0, 1, 'Playlist has expected number of items');
is_range($res1, $res2, 1, 'Processed duration as expected');


# 11 .. 14
foreach my $feed (1..4) {
	run3 [@$podist, 'editfeed', '-f', $feed, '--proc-profile', 'new'], undef, \$stdout, \$stderr;
	check_run("Ran audio processing", $stdout, $stderr);
}

# 15
run3 [@$podist, 'process', '--redo'], undef, \$stdout, \$stderr;
check_run("Redo without playlists fails", $stdout, $stderr, 256);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing after redo w/o playlist:\n$stdout");

# 16
run3 [@$podist, 'process', '--redo', 'Playlist 1'], undef, \$stdout, \$stderr;
check_run("Ran REDO audio processing", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing after redo:\n$stdout");

# 17
($res0, $res1, $res2) = $dbh->selectrow_array($query);
note("processed = $res1, original = $res2");
is_range($res1, $res2/2, 1, 'Re-processed duration as expected');

# 18
run3 [@$podist, 'archive', '1'], undef, \$stdout, \$stderr;
check_run('Podist archive works on re-processed playlist', $stdout, $stderr);

exit 0;
