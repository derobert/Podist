use 5.024;
use IPC::Run3;
use Test::More;
use Podist::Test::SystemTesting qw(basic_podist_setup check_run plan_dangerously_or_exit);

plan_dangerously_or_exit tests => 5;

# coverage for exec'd Podist
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

my ($stdout, $stderr);

# 1
my $setup = basic_podist_setup();

# 2..3
run3 [@{$setup->{podist}}, '--help'], undef, \$stdout, \$stderr;
check_run("Podist --help exit code is 0", $stdout, $stderr);
ok($stdout =~ /^Usage:/i, 'Help starts with usage');

# 4..5
# This check is a little funny as we can get terminal escapes thrown
# back at us.
run3 [@{$setup->{podist}}, '--manual'], undef, \$stdout, \$stderr;
check_run("Podist --manual exit code is 0", $stdout, $stderr);
ok($stdout =~ /^\N*NAME[\n\e]/i, 'Looks like a manual');

