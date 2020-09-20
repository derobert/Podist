use 5.024;
use strict;
use warnings qw(all);

use Data::Dump qw(pp);
use File::Slurper qw(read_text write_text read_lines);
use IPC::Run3 qw(run3);
use Test::Exception;
use Test::More;
use XML::FeedPP;
use version 0.77;

use Podist::Config;
use Podist::Test::SystemTesting qw(
	setup_config check_run plan_dangerously_or_exit basic_podist_setup
	add_test_feeds add_test_randoms connect_to_podist_db
);
use Podist::Test::Notes qw(long_note);

plan_dangerously_or_exit tests => 11;
my ($stdout, $stderr);

# These fourc count as tests
my $setup = basic_podist_setup();
add_test_feeds(podist => $setup->{podist}, n_base_feeds => 2);
add_test_randoms(store_dir => $setup->{store_dir});
my $dbh = connect_to_podist_db($setup->{db_file}, 0);

my $Cfg = Podist::Config->new;
my $config = $Cfg->read_config(
	conf_dir  => $setup->{conf_dir},
	conf_file => $setup->{conf_file});
long_note('Initial parsed config:', pp($config));

$config->{playlist}{targetduration}
	= $config->{playlist}{maximumduration} = 3600 * 4;
$config->{playlist}{maximumfiles} = 999;
$config->{playlist}{maximumconsecutive} = 999;
$config->{playlist}{maximumperfeed} = 999;

lives_ok { # 5
	$Cfg->write_config(
		conf_file => $setup->{conf_file},
		config    => $config
		)
} 'wrote new config';

# 6
run3 [@{$setup->{podist}}, qw(editfeed -f 1 --pause)], undef, \$stdout, \$stderr;
check_run("Paused feed 1", $stdout, $stderr);

# 7 - Playlist 1, with feed 1 paused
undef $stdout; undef $stderr;
run3 [@{$setup->{podist}}, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist", $stdout, $stderr);

# 8
run3 [@{$setup->{podist}}, qw(editfeed -f 1 --play)], undef, \$stdout, \$stderr;
check_run("Unpaused feed 1", $stdout, $stderr);

# 9 - Playlist 1, with feed 1 unpaused
undef $stdout; undef $stderr;
run3 [@{$setup->{podist}}, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist", $stdout, $stderr);


my $query = <<QUERY;
SELECT count(*)
  FROM enclosures e
  JOIN articles_enclosures ae ON (e.enclosure_no = ae.enclosure_no)
  JOIN articles a ON (ae.article_no = a.article_no)
 WHERE e.playlist_no = ? AND a.feed_no = ?
QUERY
my $count;

# 10
($count) = $dbh->selectrow_array($query, {}, 1, 1);
is($count, 0, "Playlist 1 has expected 0 items from feed 1");

# 11
($count) = $dbh->selectrow_array($query, {}, 2, 1);
ok($count > 0, "Playlist 2 has items from feed 1");
