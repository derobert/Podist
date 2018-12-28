package Podist::Test::SystemTesting;
use 5.024;
use strict;

use File::Copy qw(copy);
use File::Slurper qw(read_text write_text);
use File::Temp qw();
use IPC::Run3;
use Test::Exception;
use Test::More;

use base qw(Exporter);
our @EXPORT_OK = qw(plan_dangerously_or_exit setup_config check_run basic_podist_setup);

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

	long_note('Writing config:', $conf);
	write_text($opts{out}, $conf);

	return;
}

sub long_note {
	my ($header, $note) = @_;
	state $note_number = 0;

	my $ident = sprintf('%02X', $note_number++);
	$note =~ s/^/ <$ident>  /mg;
	chomp($note);
	note("$header\n$note\n *--*--END");
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
