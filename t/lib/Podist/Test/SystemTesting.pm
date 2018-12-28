use 5.024;

package Podist::Test::SystemTesting;
use Test::More;
use File::Slurper qw(read_text write_text);

use base qw(Exporter);
our @EXPORT_OK = qw(plan_dangerously_or_exit setup_config check_run);

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

	note("Writing config: $conf");
	write_text($opts{out}, $conf);

	return;
}

sub check_run {
	my ($message, $stdout, $stderr) = @_;

	if (0 == $?) {
		pass($message);
		note("stdout:\n$stdout");
		note("stderr:\n$stderr");
	} else {
		fail($message);
		diag("stdout:\n$stdout");
		diag("stderr:\n$stderr");
	}

	return;
}
