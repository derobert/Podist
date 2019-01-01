use 5.024;

use Data::Dump qw(pp);
use File::Find qw(find);
use File::Slurper qw(read_text read_lines);
use IPC::Run3;
use Test::Deep;
use Test::Exception;
use Test::More;
use Text::CSV;
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
plan_dangerously_or_exit tests => 33;

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
	n_base_feeds => 8,
	catch        => 0,
);

# 4
run3 [@$podist, qw(catch -l 1)], undef, \$stdout, \$stderr;
check_run("Catch with rollback", $stdout, $stderr);

# 5
($res) = $dbh->selectrow_array(q{SELECT count(*) FROM enclosures});
is($res, 0, 'No enclosures in DB after rollback');

# 6
run3 [@$podist, qw(catch -l 999)], undef, \$stdout, \$stderr;
check_run("Catch without rollback", $stdout, $stderr);

# 7
($res) = $dbh->selectrow_array(q{SELECT count(*) FROM enclosures});
is($res, 32, '32 enclosures after catch');

# 8
run3 [@$podist, 'status'], undef, \$stdout, \$stderr;
check_run("Status after catch", $stdout, $stderr);

# 9
TODO: {
	local $TODO = 'Podist bug, currently fails w/o random items';
	# Subtest to work around Test::More bug(?) where it fails to notice
	# the tests run by check_run() are inside a TODO block.
	subtest 'Playlist w/o random items' => sub {
		run3 [@$podist, 'playlist'], undef, \$stdout, \$stderr;
		check_run("Generated playlist w/o randoms", $stdout, $stderr);
	};
};

# 10
TODO: {
	local $TODO = 'Podist bug, does not clean up speech on playlist fail';
	my $files = 0;
	find(sub { ++$files if -f }, "$store_dir/playlists");
	is ($files, 0, 'No files in playlist dir after failed generation');
	note("Working around non-cleanup by emptying processed dir");
	find(sub { -f and unlink }, "$store_dir/playlists/processed");
}

# 11
add_test_randoms(store_dir => $store_dir, how_many => 1);

# 12
subtest 'Podist list -r OK' => sub {
	plan tests => 2;
	local $ENV{COLUMNS} = 500; # avoid wrapping
	run3 [@$podist, qw(list -r)], undef, \$stdout, \$stderr;
	check_run("List feeds runs", $stdout, $stderr);
	$stdout =~ y/ .|+'-/ /sd;    # remove formatting
	$stdout =~ s/^\s+//gm;
	$stdout =~ s/\s+$//gm;
	long_note("Randoms without formatting:", $stdout);
	foreach (split("\n", $stdout)) {
		/^Random Items$/     and next;    # header
		/^$/                 and next;    # header or footer (line);
		/^DB File Name/      and next;    # header;
		if (/^1 MountainKingopus MountainKing 1000 100000$/) {
			pass("Found random item MountainKing");
		} else {
			fail("Unexpected line: $_");
		}
	}
};

# 13
run3 [@$podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist with randoms", $stdout, $stderr);

# 14
$res = $dbh->selectrow_arrayref(<<QUERY);
	SELECT playlist_no, playlist_archived, playlist_file FROM playlists
QUERY
is_deeply($res, [ 1, undef, 'Playlist 001.m3u' ], 'Playlist DB entry OK');

# count items that should be on playlist according to db.
my $db_item_count = 0;

# 15
($res) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM random_uses});
ok($res > 0, 'Random music uses recorded in DB');
note("DB random music count: $res");
$db_item_count += $res;

# 16
($res) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM speeches});
ok($res > 0, 'Speeches recorded in DB');
note("DB speeches count: $res");
$db_item_count += $res;

# 17
($res) = $dbh->selectrow_array(<<QUERY);
	SELECT COUNT(*) FROM enclosures WHERE playlist_no IS NOT NULL
QUERY
ok($res > 0, 'Used enclosures recorded in DB');
note("DB playlisted enclosure count: $res");
$db_item_count += $res;

note("Database says to expect $db_item_count items on the playlist");

# 18
my @playlist;
lives_ok {
	@playlist = read_lines("$store_dir/playlists/Playlist 001.m3u")
} 'Read generated playlist';
note("Generated playlist:\n".pp(@playlist));

# 19
is(scalar(@playlist), $db_item_count,
	"Found expected number of items in playlist");

# 20
subtest 'Playlist items exist' => sub {
	plan tests => scalar(@playlist);

	foreach my $item (@playlist) {
		ok(-e "$store_dir/playlists/$item", "Entry exists: $item");
	}
};

# 21
run3 [@$podist, 'feed'], undef, \$stdout, \$stderr;
check_run("Generated feed", $stdout, $stderr);
note("Feed:\n", read_text("$store_dir/playlists/feed.xml"));

# 22
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing BEFORE archive:\n$stdout");
run3 [@$podist, qw(archive 001)], undef, \$stdout, \$stderr;
check_run("Archived playlist", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing AFTER archive:\n$stdout");

# 23
($res) = $dbh->selectrow_array(<<QUERY);
	SELECT COUNT(*) FROM enclosures WHERE enclosure_store = 'original'
QUERY
is($res, 0, 'No remaining "original" enclosures after archive');

# 24, 25
$res = $dbh->selectrow_hashref(q{SELECT * FROM playlists});
is($res->{playlist_no}, 1, 'Still playlist 1');
ok(defined($res->{playlist_archived}), 'Has archival time');

# 26
run3 [@$podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated second playlist", $stdout, $stderr);

# 27
run3 [@$podist, 'process'], undef, \$stdout, \$stderr;
check_run("Ran audio processing", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing after processing:\n$stdout");

# 28
run3 [@$podist, 'archive', 'Playlist 002.m3u'], undef, \$stdout, \$stderr;
check_run("Archived second playlist", $stdout, $stderr);
run3 ['find', $store_dir, '-ls'], undef, \$stdout;
note("Store directory listing AFTER archive:\n$stdout");

# 29
subtest 'Podist list -f OK' => sub {
	plan tests => 9;
	run3 [@$podist, qw(list -f)], undef, \$stdout, \$stderr;
	check_run("List feeds runs", $stdout, $stderr);
	$stdout =~ y/ .|+'-/ /sd;    # remove formatting
	$stdout =~ s/^\s+//gm;
	$stdout =~ s/\s+$//gm;
	note("Formatting removed to:\n$stdout");
	foreach (split("\n", $stdout)) {
		/^Feeds$/            and next;    # header
		/^$/                 and next;    # header or footer (line);
		/^Enabled Feed Name/ and next;    # header;
		if (/^Yes Feed ([0-8]) \1 default$/) {
			pass("Found Feed $1");
		} else {
			fail("Unexpected line: $_");
		}
	}
};

# 30
subtest 'Podist history OK' => sub {
	plan tests => 4;
	run3 [@$podist, qw(history)], undef, \$stdout, \$stderr;
	check_run("History runs", $stdout, $stderr);

	open my $fh, '<', \$stdout;
	my $csv = Text::CSV->new;
	while (my $row = $csv->getline($fh)) {
		if ($row->[0] eq 'When_UTC') {
			pass("Found header row");
		} else {
			cmp_deeply(
				$row,
				[
					re(qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/a),
					32,
					code(sub {
						$_[0] < 32
							? (1)
							: (0, "should be fewer than 32 unplayed")
					}),
					num(74267.16734693888, 60*32),    # ±60s/episode
					ignore(), # unplayed time
				], "History row OK");
		}
	}
};

# 31
run3 [@$podist, qw(fetch -f 1)], undef, \$stdout, \$stderr;
check_run("Fetches specific feed", $stdout, $stderr);

# 32
run3 [@$podist, qw(fetch -l 10)], undef, \$stdout, \$stderr;
check_run("Fetches with limit override", $stdout, $stderr);

# 33
run3 [@$podist, qw(cleanup)], undef, \$stdout, \$stderr;
check_run("Cleanup runs", $stdout, $stderr);

# TODO: Actually add some enclosures to clean up.


exit 0;
