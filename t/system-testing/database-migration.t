use Test::More;
use Test::Exception;
use IPC::Run3;
use File::Slurper qw(read_text write_text);
use 5.024;

my @DB_VERSIONS = (    # map DB version to git commit
	{
		# note that v1 is complicated, as it evolved with the program
		# and was from before it was released. E.g.,
		# 3bcf0fd6b8b9a57203652d31e61405d60ae6a1ad changed the schema
		# w/o any migration. So this commit is from around when Podist
		# was released on GitHub.
		db_vers       => 1,
		commit        => '0ff22c10f226178ae2d479ccbc19de24c4993588',
		descr         => 'original',
		kluge_confdir => 1,
	},
	{
		# There wasn't really a branch for this, so this is the final
		# commit before the branch for v3.
		db_vers       => 2,
		commit        => '93372bbcbe6b814dad3ce2fca7f9591452544278',
		descr         => 'article info',
		kluge_confdir => 1,
	},
	{
		db_vers       => 3,
		commit        => '5a733bc44ba5cf23a9cdc8b7e0247bf87c319bc9',
		descr         => 'limits & fetch logs',
		kluge_confdir => 0,
	},
	{
		db_vers       => 4,
		commit        => '8acdb917ddc3d1d9692e0a96bfd412e952e36f1e',
		descr         => 'playlist archival',
		kluge_confdir => 0,
	},
	{
		db_vers       => 5,
		commit        => '5f89f3ba76d6684aeededea4b71a20ce1fe8e413',
		descr         => 'UUID & performance',
		kluge_confdir => 0,
	},
	{
		db_vers       => 6,
		commit        => 'dabab066b30487e14d6b7271e6e9f4502daedc36',
		descr         => 'usable_enclosures view',
		kluge_confdir => 0,
	},
	{
		db_vers       => 7,
		commit        => '5c9a3c99e149bbfe43ae1f3ed36d5c7a4db9eaa7',
		descr         => 'random music in DB',
		kluge_confdir => 0,
	},
	{
		# note: this drops support for non-archived playlists from
		# very old versions (before commit
		# 4a098bea6e9c9fa56ac056d3c2480cd6bc73901c, from October 2008).
		# That's before the commit we use for version 1, so we don't
		# have to worry.
		db_vers       => 8,
		commit        => '85f8677638db7a4c68932bf5a08a056b92304d4f',
		descr         => 'locations & processing',
		kluge_confdir => 0,
	},
);

# This test is somewhat dangerous (e.g., bugs in old versions might
# ignore the non-default directories we say to use, and instead do weird
# things to your actual Podist install). So we won't run unless
# LIVE_DANGEROUSLY=1 is set. Note the GitLab CI sets this, as its run in
# a docker container, so no existing Podist to worry about.

if (!$ENV{LIVE_DANGEROUSLY}) {
	plan skip_all => 'LIVE_DANGEROUSLY=1 not set in environment';
	exit 0;
} else {
	plan tests => @DB_VERSIONS + 2;
}

# Make Podist actually run with coverage...
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
my ($stdout, $stderr);

my $current_confdir = "$tmpdir/db-CURRENT-conf";
my $current_workdir = "$tmpdir/db-CURRENT-work";
my $current_conftmpl = "$current_confdir/podist.conf";
my $current_db = "$current_confdir/podist.db";
subtest "Creating DB & config with current worktree" => sub {
	plan tests => 6;

	my $stderr;
	run3 [qw(./Podist --conf-dir), $current_confdir], undef, undef, \$stderr;
	like($stderr, qr/set NotYetConfigured to false/, 'Podist conf init');

	-f $current_conftmpl
		or BAIL_OUT("Current Podist broken; did not create new config");
	pass("created template config file");

	# in order to create the database, we need it configured... but we
	# also want the conf template. So create a new conf dir for that.
	my $confdir2 = "$tmpdir/db-CURRENT-conf2";
	ok(mkdir($confdir2), "Created secondary conf dir for testing");

	lives_ok {
		setup_config(
			in    => $current_conftmpl,
			out   => "$confdir2/podist.conf",
			store => $current_workdir
		);
	} 'Set up current config';

	run3 [qw(./Podist --conf-dir), $confdir2, 'status'], undef, \$stdout, \$stderr;
	check_run('Podist status OK', $stdout, $stderr);

	-f $current_db
		or BAIL_OUT("Current Podist broken; did not create new database");
	pass("created current database");
};

foreach my $vinfo (@DB_VERSIONS) {
	subtest "DB version $vinfo->{db_vers}, commit $vinfo->{commit}" => sub {
		plan tests => 11;
		my $worktree = sprintf('%s/db-%02i-%s-work',
			$tmpdir, $vinfo->{db_vers}, $vinfo->{commit});
		my $confdir = sprintf('%s/db-%02i-%s-conf',
			$tmpdir, $vinfo->{db_vers}, $vinfo->{commit});
		my $storedir = sprintf('%s/db-%02i-%s-store',
			$tmpdir, $vinfo->{db_vers}, $vinfo->{commit});

		run3 [qw(git worktree add ), $worktree, $vinfo->{commit}], undef, \$stdout, \$stderr;
		check_run("worktree for $vinfo->{commit}", $stdout, $stderr);

		my $podist = "$worktree/Podist";
		my @podist_args;

	SKIP: {
			skip('Confdir kluge not required', 1) unless $vinfo->{kluge_confdir};
			lives_ok {
				my $t = read_text($podist);
				$t =~ s{notaint\("\$ENV\{HOME\}/\.podist"\)}{'$confdir'}
					or die "Could not find confdir to replace";
				write_text($podist, $t);
			}
			'Hard-coded confidr kluge applied';
		}

		push(@podist_args, '--conf-dir', $confdir)
			unless $vinfo->{kluge_confdir};

		run3 [$podist, @podist_args], undef, \$stdout, \$stderr;
		like($stderr, qr/set NotYetConfigured to false/, 'Podist conf init');
		note("stdout: $stdout");
		note("stderr: $stderr");

		my $conffile = "$confdir/podist.conf";
		ok(-f $conffile, "New config exists $conffile");

		lives_ok {
			setup_config(in => $conffile, out => $conffile, store => $storedir)
		} 'Configured Podist';

		run3 [$podist, @podist_args, 'status'], undef, \$stdout, \$stderr;
		check_run('Podist status runs', $stdout, $stderr);

		# This is a rather questionable upgrade procedure. We need a new
		# config version just to get the database migrations to run...
		# so just overwrite it with the template from the new version.

		lives_ok {
			setup_config(
				in    => $current_conftmpl,
				out   => $conffile,
				store => $storedir,
				dbdir => $confdir,
			);
		} 'Re-configured with current config template';

		run3 [qw(./Podist --conf-dir), $confdir, 'status'], undef, \$stdout, \$stderr;
		check_run('Current Podist migrates & runs status', $stdout, $stderr);

		run3 [qw(./Podist --conf-dir), $confdir, 'fsck'], undef, \$stdout, \$stderr;
		check_run('Current Podist fsck OK', $stdout, $stderr);

		run3 ['sqldiff', "$confdir/podist.db", $current_db], undef, \$stdout, \$stderr;
		check_run('sqldiff worked', $stdout, $stderr);
		$stdout =~ s/^DROP TABLE [a-z_]+_v\d+;$//agm;
		$stdout =~ s/^UPDATE podist_instance SET podist_uuid=.*$//m;
		if ($stdout =~ /^\s*$/) {
			pass('No relevant database differences');
		} else {
			fail('No relevant database differences');
			diag("Differences:\n$stdout");
			run3 ['sqldiff', $current_db, "$confdir/podist.db"], undef, \$stdout, \$stderr;
			diag("backwards diff:\n$stdout");
		}
	};
}

File::Temp::cleanup();
run3 [qw(git worktree prune)];
is($?, 0, 'pruned worktrees');
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
