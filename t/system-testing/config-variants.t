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
	add_test_feeds add_test_randoms connect_to_podist_db
);
use Podist::Test::Notes qw(long_note);

plan_dangerously_or_exit tests => 9;
my ($stdout, $stderr, $res);

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

# Podist generates "fudged" dates by playlist_no * 1000 + item number, and
# then taking that as a Unix timestamp (seconds after epoch). So this
# would cover 9999 playlists, aka Sun Apr 26 17:46:40 UTC 1970. 
our $MAX_FUDGE_DATE = 10_000_000;

my $setup = basic_podist_setup();
add_test_feeds(podist => $setup->{podist});
add_test_randoms(store_dir => $setup->{store_dir});

my $Cfg = Podist::Config->new;
my $config = $Cfg->read_config(
	conf_dir  => $setup->{conf_dir},
	conf_file => $setup->{conf_file});
long_note('Initial parsed config:', pp($config));

my $dbh = connect_to_podist_db($setup->{db_file}, 0);

subtest 'Five playlist things off' => sub {
	plan tests => 4;
	local $config->{playlist}{announcebegin} = 0;
	local $config->{playlist}{announceend} = 0;
	local $config->{playlist}{announceleadout} = 0;
	local $config->{playlist}{leadoutlength} = 0;
	local $config->{playlist}{randomchanceb} = 0;
	local $config->{playlist}{randomchancem} = 0;

	lives_ok {
		$Cfg->write_config(
			conf_file => $setup->{conf_file},
			config    => $config
			)
	} 'wrote new config';

	run3 [@{$setup->{podist}}, 'playlist'], undef, \$stdout, \$stderr;
	check_run("Generated playlist", $stdout, $stderr);

	($res) = $dbh->selectrow_array(
		q{SELECT COUNT(*) FROM speeches WHERE playlist_no = 1}
	);
	is($res, 0, 'No speech on playlist 1');
	($res) = $dbh->selectrow_array(
		q{SELECT COUNT(*) FROM random_uses WHERE playlist_no = 1}
	);
	is($res, 0, 'No randoms on playlist 1');
};

subtest 'Five playlist things on' => sub {
	plan tests => 5;
	local $config->{playlist}{announcebegin} = 1;
	local $config->{playlist}{announceend} = 1;
	local $config->{playlist}{announceleadout} = 1;
	local $config->{playlist}{leadoutlength} = 50;
	local $config->{playlist}{randomchanceb} = 1;
	local $config->{playlist}{randomchancem} = 0;

	lives_ok {
		$Cfg->write_config(
			conf_file => $setup->{conf_file},
			config    => $config
			)
	} 'wrote new config';

	run3 [@{$setup->{podist}}, 'playlist'], undef, \$stdout, \$stderr;
	check_run("Generated playlist", $stdout, $stderr);

	($res) = $dbh->selectrow_array(
		q{SELECT COUNT(*) FROM speeches WHERE playlist_no = 2}
	);
	is($res, 3, 'Three speeches on playlist 2');

	($res) = $dbh->selectrow_array(
		q{SELECT COUNT(*) FROM random_uses WHERE playlist_no = 2 AND random_use_reason = 'lead-out'}
	);
	is($res, 50, 'Twenty-item leadout on playlist 2');

	($res) = $dbh->selectrow_array(
		q{SELECT COUNT(*) FROM random_uses WHERE playlist_no = 2 AND random_use_reason = 'intermission'}
	);
	ok($res > 0, 'Intermissions exist on playlist 2');
};

subtest 'Fiddle feed options' => sub {
	plan tests => 4;

	local $config->{playlist}{randomchanceb} = 1;
	local $config->{playlist}{randomchancem} = 0;
	local $config->{playlist}{randomfeedratio} = 1;

	lives_ok {
		$Cfg->write_config(
			conf_file => $setup->{conf_file},
			config    => $config
			)
	} 'wrote new config';

	# set two of the feeds to be music.
	$dbh->do(q{UPDATE feeds SET feed_is_music = 1 WHERE feed_no IN (1,2)});

	run3 [@{$setup->{podist}}, 'playlist'], undef, \$stdout, \$stderr;
	check_run("Generated playlist", $stdout, $stderr);

	ok($stderr =~ m!Adding random item .+/original/!,
		'Added a random item from downloaded media');

	($res) = $dbh->selectrow_array(<<QUERY);
SELECT COUNT(*)
  FROM articles a
  JOIN articles_enclosures ae ON (a.article_no = ae.article_no)
  JOIN enclosures e ON (ae.enclosure_no = e.enclosure_no)
 WHERE a.feed_no IN (1,2) AND e.playlist_no = 3
QUERY
	ok($res > 0, "Used feed 1/2 ($res times)");
};

subtest 'Four feed options off' => sub {
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

subtest 'Four feed options on' => sub {
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
	ok($rands >= 50, "More than 50 random media, lead-out must be working");

	TODO: {
		local $TODO = "Speeches not yet added to feeds";
		ok($speeches > 0, "Has speeches ($speeches)");
	}

	done_testing();
};
