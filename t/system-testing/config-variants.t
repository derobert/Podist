use 5.024;
use strict;
use warnings qw(all);

use Data::Dump qw(pp);
use File::Slurper qw(read_text write_text read_lines);
use IPC::Run3 qw(run3);
use Test::Exception;
use Test::More;
use XML::FeedPP;

use Podist::Config;
use Podist::Test::SystemTesting qw(
	setup_config check_run plan_dangerously_or_exit basic_podist_setup
	add_test_feeds add_test_randoms
);
use Podist::Test::Notes qw(long_note);

plan_dangerously_or_exit tests => 6;
my ($stdout, $stderr);

# Podist generates "fudged" dates by playlist_no * 1000 + item number, and
# then taking that as a Unix timestamp (seconds after epoch). So this
# would cover 9999 playlists, aka Sun Apr 26 17:46:40 UTC 1970. 
our $MAX_FUDGE_DATE = 10_000_000;

my $setup = basic_podist_setup();
add_test_feeds(podist => $setup->{podist});
add_test_randoms(store_dir => $setup->{store_dir});

run3 [@{$setup->{podist}}, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist", $stdout, $stderr);

my $Cfg = Podist::Config->new;
my $config = $Cfg->read_config(
	conf_dir  => $setup->{conf_dir},
	conf_file => $setup->{conf_file});
long_note('Initial parsed config:', pp($config));

subtest 'Four options off' => sub {
	local $config->{feed}{fudgedates} = 0;
	local $config->{feed}{include}{intermissions} = 0;
	local $config->{feed}{include}{leadout} = 0;
	local $config->{feed}{include}{speeches} = 0;

	lives_ok {
		$Cfg->write_config(
			conf_file => $setup->{conf_file},
			config    => $config
			)
	} 'wrote new config';

	run3 [@{$setup->{podist}}, 'feed'], undef, \$stdout, \$stderr;
	check_run("Generated feed", $stdout, $stderr);

	my $feed_xml = read_text("$config->{storage}{playlists}/feed.xml");
	long_note('Generated RSS:', $feed_xml);
	my $feed;
	lives_ok { $feed = XML::FeedPP->new($feed_xml, type => 'string') } 'Parsed generated feed';
	long_note('Parsed RSS:', pp $feed);

	my $i = 0;
	foreach my $item ($feed->get_item()) {
		++$i;
		ok(defined $item->get_pubDate_epoch, "[$i] has publication date");
		ok($item->get_pubDate_epoch >= $MAX_FUDGE_DATE, "[$i] is not fudged");
		ok($item->guid =~ /-enclosure-\d+$/a, "[$i] is an enclosure");
	}

	done_testing();
};

subtest 'Four options on' => sub {
	local $config->{feed}{fudgedates} = 1;
	local $config->{feed}{include}{intermissions} = 1;
	local $config->{feed}{include}{leadout} = 1;
	local $config->{feed}{include}{speeches} = 1;

	lives_ok {
		$Cfg->write_config(
			conf_file => $setup->{conf_file},
			config    => $config
			)
	} 'wrote new config';

	run3 [@{$setup->{podist}}, 'feed'], undef, \$stdout, \$stderr;
	check_run("Generated feed", $stdout, $stderr);

	my $feed_xml = read_text("$config->{storage}{playlists}/feed.xml");
	long_note('Generated RSS:', $feed_xml);
	my $feed;
	lives_ok { $feed = XML::FeedPP->new($feed_xml, type => 'string') } 'Parsed generated feed';
	long_note('Parsed RSS:', pp $feed);

	my $i = 0;
	my $rands = 0;
	my $speeches = 0;
	my $last = undef;
	foreach my $item ($feed->get_item()) {
		++$i;
		ok(defined $item->get_pubDate_epoch, "[$i] has publication date");
		ok($item->get_pubDate_epoch < $MAX_FUDGE_DATE, "[$i] is fudged");
		my $guid = $item->guid;
		if ($guid =~ /-enclosure-\d+$/a) {
			$last = 'enclosure';
			pass("[$i] is an enclosure");
		} elsif ($guid =~ /-randommedia-\d+-\d+-\d+$/a) {
			++$rands;
			$last = 'random';
			pass("[$i] is random media");
		} else {
			# speech TODO
			fail("[$i] has unrecongnized guid: $guid");
		}
	}
	ok($rands > 0, "Has random media ($rands)");
	is($last, 'random', 'Last is random, lead-out maybe working');

	TODO: {
		local $TODO = "Speeches not yet added to feeds";
		ok($speeches > 0, "Has speeches ($speeches)");
	}

	done_testing();
};
