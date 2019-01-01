package Podist::Test::SystemTesting;
use 5.024;
use strict;

use DBI;
use File::Copy qw(copy);
use File::pushd qw(pushd);
use File::Slurper qw(read_text write_text);
use File::Spec;
use File::Temp qw();
use IPC::Run3;
use Test::Exception;
use Test::More;
use Podist::Test::Notes qw(long_note);

use base qw(Exporter);
our @EXPORT_OK = qw(
	plan_dangerously_or_exit setup_config check_run basic_podist_setup
	long_note add_test_feeds add_test_randoms connect_to_podist_db
);

our $FEED_DIR = 't-gen/feeds/v1';

sub plan_dangerously_or_exit {
	if (!$ENV{LIVE_DANGEROUSLY}) {
		plan skip_all => 'LIVE_DANGEROUSLY=1 not set in environment';
		exit 0;
	} else {
		plan @_
	}
}

sub setup_config {
	# options: in, out - files names to read/write (may be the same file)
	#          store - where to configure to store media/playlists
	#          dbdir - where to find podist.db (optional, only change if
	#                  specified)
	my %opts = @_;

	# TODO: This works on regexp instead of Config.pm because it needs
	#       to run with old versions that don't want to use the current
	#       version's defaults. Improve this situation someday by making
	#       Config.pm able to read w/o defaults.
	my $conf = read_text($opts{in});
	long_note('Read in config:', $conf);
	$conf =~ s!\$HOME/Podist/!$opts{store}/!g or die "No storage found";
	$conf =~ s!^NotYetConfigured true$!NotYetConfigured false!m
		or die "Couldn't find NotYetConfigured";
	my $logconf = File::Spec->rel2abs('t-conf/log4perl-test.conf');
	$conf =~ s!^(\s*)Simple true\s*$!${1}Simple false\n${1}Config $logconf$2!m
		or die "Couldn't find logging config";

	if (exists $opts{dbdir}) {
		$conf =~ s!^DataDir .+ #!DataDir $opts{dbdir} #!m
			or die "Couldn't find DataDir to replace";
	}

	long_note('Writing config:', $conf);
	write_text($opts{out}, $conf);

	return;
}

sub check_run {
	my ($message, $stdout, $stderr, $expected_status) = @_;
	$expected_status //= 0;

	if ($expected_status == $?) {
		pass($message);
		long_note('stdout:', $stdout);
		long_note('stderr:', $stderr);
	} else {
		fail($message . " (wanted $expected_status, got $?)");
		diag("stdout:\n$stdout");
		diag("stderr:\n$stderr");
	}

	return;
}

sub basic_podist_setup {
	my %opts      = @_;
	my $temp_dir  = $opts{temp_dir}  // File::Temp::tempdir(CLEANUP => 1);
	my $conf_dir  = $opts{conf_dir}  // "$temp_dir/conf";
	my $store_dir = $opts{store_dir} // "$temp_dir/store";
	my $conf_file = "$conf_dir/podist.conf";
	my $conf_tmpl = "$conf_file.tmpl";
	my $db_file   = "$conf_dir/podist.db";
	my @podist    = ('./Podist', '--conf-dir', $conf_dir);

	subtest 'Basic Podist setup' => sub {
		plan tests => 7;
		my ($stdout, $stderr);

		# 1, 2
		run3 \@podist, undef, \$stdout, \$stderr;
		check_run('Run Podist to generate config template', $stdout, $stderr, 1<<8);
		like($stderr, qr/set NotYetConfigured to false/, 'Podist wants to be configured');

		# 3
		ok(-f $conf_file, "Podist created example config at $conf_file");

		# 4
		ok(copy($conf_file, $conf_tmpl), "Copied templated to $conf_tmpl");

		# 5
		lives_ok {
			setup_config(
				in    => $conf_file,
				out   => $conf_file,
				store => $store_dir
				)
		} 'Configured Podist based on example config';

		# 6
		run3 [@podist, 'status'], undef, \$stdout, \$stderr;
		check_run('Podist status runs', $stdout, $stderr);

		# 7
		ok(-f $db_file, "New DB exists $db_file");
	} or BAIL_OUT('Podist broken beyond belief');

	return {
		temp_dir      => $temp_dir,
		conf_dir      => $conf_dir,
		store_dir     => $store_dir,
		conf_file     => $conf_file,
		conf_template => $conf_tmpl,
		db_file       => $db_file,
		podist        => \@podist,
	};
}

sub add_test_feeds {
	my %opts = @_;

	my $podist  = $opts{podist} // die "Missing argument: podist";
	my $n_feeds = $opts{n_base_feeds} // 8;
	my $catch   = $opts{catch} // 1;

	die "n_base_feeds must be 0..8" if ($n_feeds < 0 || $n_feeds > 8);
	$catch = $catch ? 1 : 0;

	subtest 'Adding test feeds' => sub {
		plan tests => ($n_feeds + $catch);
		my ($stdout, $stderr);

		foreach my $feed ( 1 .. $n_feeds) {
			run3 [@$podist, 'subscribe', "Feed $feed", "file://" . File::Spec->rel2abs("$FEED_DIR/feed_$feed.xml")], undef, \$stdout, \$stderr;
			check_run("Podist subscribe Feed #$feed", $stdout, $stderr);
		}

		if ($catch) {
			run3 [@$podist, qw(catch -l 999)], undef, \$stdout, \$stderr;
			check_run("Catch without rollback", $stdout, $stderr);
		} else {
			note('Catch not requested, not run.');
		}
	};

	return;
}

sub add_test_randoms {
	my %opts = @_;

	my $num       = $opts{how_many} // 1;
	my $store_dir = $opts{store_dir} // die "missing argument: store_dir";

	$num == 1 or die "Only one random at the moment";

	subtest 'Setting up random items' => sub {
		plan tests => 2;
		my ($stdout, $stderr);

		mkdir("$store_dir/random");
		mkdir("$store_dir/random.in");
		ok(copy("t-data/MountainKing.flac", "$store_dir/random.in/"),
			'Copied MountainKing.flac to random.in');
		my $make_random = File::Spec->rel2abs('make-random');
		{
			my $dir = pushd($store_dir);
			run3 [$make_random], undef, \$stdout, \$stderr;
			check_run("Generated random items", $stdout, $stderr);
		}

	};

	return;
}

sub connect_to_podist_db {
	my ($dbfile, $readonly) = @_;
	defined $dbfile or die "Required parameter (db file) missing";
	$readonly //= 1;

	my $dbh;
	lives_ok {
		$dbh = DBI->connect(
			"dbi:SQLite:dbname=$dbfile",
			'', '',
			{
				ReadOnly         => $readonly,
				AutoCommit       => 1,
				RaiseError       => 1,
				FetchHashKeyName => 'NAME_lc'
			});
	} q{"Connected" to Podist database};

	return $dbh;
}
