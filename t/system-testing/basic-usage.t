use 5.024;

use File::Copy qw(copy);
use File::pushd qw(pushd);
use File::Slurper qw(read_text write_text);
use File::Spec;
use IPC::Run3;
use Test::Exception;
use Test::More;

# This test is somewhat dangerous (e.g., might ignore the non-default
# directories we say to use, and instead do weird things to your actual
# Podist install). So we won't run unless LIVE_DANGEROUSLY=1 is set.
# Note the GitLab CI sets this, as its run in a docker container, so no
# existing Podist to worry about.

if (!$ENV{LIVE_DANGEROUSLY}) {
	plan skip_all => 'LIVE_DANGEROUSLY=1 not set in environment';
	exit 0;
} else {
	plan tests => 19;
}

my $FEED_DIR = 't-gen/feeds/v1';

my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
my ($stdout, $stderr);

my $conf_dir  = "$tmpdir/conf";
my $store_dir = "$tmpdir/store";

my @podist = ('./Podist', '--conf-dir', $conf_dir);

# 1
run3 \@podist, undef, \$stdout, \$stderr;
like($stderr, qr/set NotYetConfigured to false/, 'Podist conf init');
note("stdout: $stdout");
note("stderr: $stderr");

# 2
my $conf_file = "$conf_dir/podist.conf";
ok(-f $conf_file, "New config exists $conf_file");

# 3
lives_ok {
	setup_config(in => $conf_file, out => $conf_file, store => $store_dir)
} 'Configured Podist';

# 4
run3 [@podist, 'status'], undef, \$stdout, \$stderr;
check_run('Podist status runs', $stdout, $stderr);

# 5 .. 12
foreach my $feed ( 1 .. 8) {
	run3 [@podist, 'subscribe', "Feed $feed", "file://" . File::Spec->rel2abs("$FEED_DIR/feed_$feed.xml")], undef, \$stdout, \$stderr;
	check_run("Podist subscribe Feed #$feed", $stdout, $stderr);
}

# 13
run3 [@podist, qw(catch -l 1)], undef, \$stdout, \$stderr;
check_run("Catch with rollback", $stdout, $stderr);

# TODO: confirm no enclosures in DB

# 14
run3 [@podist, qw(catch -l 999)], undef, \$stdout, \$stderr;
check_run("Catch without rollback", $stdout, $stderr);

# TODO: confirm 32 enclosures in DB

# 15
run3 [@podist, 'status'], undef, \$stdout, \$stderr;
check_run("Status after catch", $stdout, $stderr);

# 16
TODO: {
	local $TODO = 'Podist bug, currently fails w/o random items';
	run3 [@podist, 'playlist'], undef, \$stdout, \$stderr;
	check_run("Generated playlist w/o randoms", $stdout, $stderr);
};

# 17
mkdir("$store_dir/random");
mkdir("$store_dir/random.in");
copy("t-data/MountainKing.flac", "$store_dir/random.in/");
my $make_random = File::Spec->rel2abs('make-random');
{
	my $dir = pushd($store_dir);
	run3 [$make_random], undef, \$stdout, \$stderr;
	check_run("Generated random items", $stdout, $stderr);
}

# 18
run3 [@podist, 'playlist'], undef, \$stdout, \$stderr;
check_run("Generated playlist with randoms", $stdout, $stderr);

# TODO: Confirm playlist OK.
# TODO: Check status in DB.

# 19
run3 [@podist, 'feed'], undef, \$stdout, \$stderr;
check_run("Generated feed", $stdout, $stderr);

exit 0;

## subs from here on out
sub check_run {
	my ($message, $stdout, $stderr) = @_;

	if (0 == $?) {
		pass($message);
		note("stdout: $stdout");
		note("stderr: $stderr");
	} else {
		fail($message);
		diag("stdout: $stdout");
		diag("stderr: $stderr");
	}

	return;
}

sub setup_config {
	# options: in, out - files names to read/write (may be the same file)
	#          store - where to configure to store media/playlists
	#          dbdir - where to find podist.db (optional, only change if
	#                  specified)
	my %opts = @_;

	my $conf = read_text($opts{in});
	$conf =~ s!\$HOME/Podist/!$opts{store}/!g or die "No storage found";
	$conf =~ s!^NotYetConfigured true$!NotYetConfigured false!m
		or die "Couldn't find NotYetConfigured";
	$conf =~ s!^(\s*)Level info(\s+)!${1}Level trace$2!m
		or die "Couldn't find logging Level";

	if (exists $opts{dbdir}) {
		$conf =~ s!^DataDir .+ #!DataDir $opts{dbdir} #!m
			or die "Couldn't find DataDir to replace";
	}

	note("Writing config: $conf");
	write_text($opts{out}, $conf);

	return;
}
