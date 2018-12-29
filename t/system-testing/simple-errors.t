use 5.024;
use IPC::Run3;
use Test::More;
use Podist::Test::SystemTesting qw(basic_podist_setup check_run plan_dangerously_or_exit);

plan_dangerously_or_exit tests => 7;

# coverage for exec'd Podist
$ENV{PERL5OPT} = $ENV{HARNESS_PERL_SWITCHES};

my ($stdout, $stderr);

my $setup = basic_podist_setup();

run3 $setup->{podist}, undef, \$stdout, \$stderr;
check_run("Errors out w/o command", $stdout, $stderr, 1<<8);

run3 [@{$setup->{podist}}, qw(extraterritoriality)], undef, \$stdout, \$stderr;
check_run("Errors out w/ invalid command", $stdout, $stderr, 1<<8);

run3 [@{$setup->{podist}}, qw(subscribe http://where-is-my-name.com/)], undef, \$stdout, \$stderr;
check_run("Errors out: subscribe w/o name", $stdout, $stderr, 1<<8);

run3 [@{$setup->{podist}}, 'subscribe', '', 'A URL Would Be Nice'], undef, \$stdout, \$stderr;
check_run("Errors out: subscribe w/o URL", $stdout, $stderr, 1<<8);

run3 [@{$setup->{podist}}, qw(fetch --silly-option-does-not-exist)], undef, \$stdout, \$stderr;
check_run("Errors out: invalid option", $stdout, $stderr, 2<<8);

run3 [@{$setup->{podist}}, qw(list)], undef, \$stdout, \$stderr;
check_run("Errors out: nothing to list", $stdout, $stderr, 2<<8);
