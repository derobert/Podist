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

plan_dangerously_or_exit tests => 20;

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

my $podist_setup = basic_podist_setup();

my ($stdout, $stderr, $res);
my $podist = $podist_setup->{podist};

my $dbh = connect_to_podist_db($podist_setup->{db_file}, 0);

add_test_randoms(
	store_dir => $podist_setup->{store_dir}
);

add_test_feeds(
	podist       => $podist,
	n_base_feeds => 2,
	catch        => 1,
);

run3 [@$podist, qw(fsck)], undef, \$stdout, \$stderr;
check_run("fsck runs before mangling db", $stdout, $stderr);
unlike($stderr, qr/^ \[ \s+ \d+ [ ] E/max, "No errors during fsck");

$dbh->do(q{CREATE TEMPORARY TABLE tmp AS SELECT * FROM articles_enclosures WHERE enclosure_no = 1});
$dbh->do(q{DELETE FROM articles_enclosures WHERE enclosure_no = 1});

run3 [@$podist, qw(fsck)], undef, \$stdout, \$stderr;
check_run("fsck runs after mangling db", $stdout, $stderr);
like($stderr, qr/^ \[ \s+ \d+ [ ] E/max, "Found errors during fsck");
like( $stderr, qr/Enclosure number 1.+is orphaned\.$/m,
	"Found expected error"
);
like( $stderr, qr/Number of problems remaining after fsck: 1\.$/m,
	"Found expected problem count"
);
$dbh->do(q{INSERT INTO articles_enclosures SELECT * from tmp});
$dbh->do(q{DROP TABLE temp.tmp});

run3 [@$podist, qw(fsck)], undef, \$stdout, \$stderr;
check_run("fsck runs after restoring row", $stdout, $stderr);
unlike($stderr, qr/^ \[ \s+ \d+ [ ] e/max, "no errors after restoring row");

$dbh->do(q{UPDATE enclosures SET enclosure_store = NULL});
run3 [@$podist, qw(fsck)], undef, \$stdout, \$stderr;
check_run("fsck runs after wiping enclosure_store", $stdout, $stderr);
unlike($stderr, qr/^ \[ \s+ \d+ [ ] e/max, "no errors fixing enclosure_store");
is($dbh->selectrow_array(q{SELECT count(*) FROM enclosures WHERE enclosure_store IS NULL}), 0, 'fixed all enclosure_store');

# now let's do some permanent damage... delete an enclosure file
$res = $dbh->selectrow_hashref(q{SELECT * from enclosures WHERE enclosure_no=1});
long_note("Going to delete this one from the filesystem:", pp $res);
ok(unlink("$podist_setup->{store_dir}/media-pending/$res->{enclosure_file}"),
   "Deleted $res->{enclosure_file}");
run3 [@$podist, qw(fsck)], undef, \$stdout, \$stderr;
check_run("fsck runs after deleting a file", $stdout, $stderr);
like($stderr, qr/^ \[ \s+ \d+ [ ] E/max, "Found errors during fsck");
like($stderr, qr/Not found: non-archived file/, "Found expected error");
like( $stderr, qr/Number of problems remaining after fsck: 1\.$/m,
	"Found expected problem count"
);
