package Podist::Misc;
use strict;

use parent qw(Exporter);
our @EXPORT_OK = qw(inherit_proc_profiles normalize_time);

use Hash::Merge qw();
#use Log::Log4perl qw(:easy :no_extra_logdie_message);
use Log::Log4perl qw(:no_extra_logdie_message);

# this is stuff that was moved out of the main Podist file so we can
# test it more easily. It'll likely move again someday (Podist needs
# more refactoring).

sub inherit_proc_profiles {
	my $profiles = shift;
	my $log = Log::Log4perl->get_logger(__PACKAGE__);

	my %done;
	my $hm = Hash::Merge->new('RIGHT_PRECEDENT');
	foreach my $leaf (keys %$profiles) {
		next if $done{$leaf};

		my %working = ( $leaf => 1);
		my @stack = ($leaf);
		while (@stack) {
			if (@stack >= 100) {
				$log->fatal("Stack limit hit in profile processing");
				die "BasedOn chain too long";
			}

			my $prof = $stack[-1];
			my $base = $profiles->{$prof}{basedon};
			if (defined $base && !$done{$base}) {
				if ($working{$base}) {
					$log->fatal("Error in configuration: profile $prof BasedOn $base leads to infinite recursion");
					die "Problem with config file";
				}
				$log->trace("Recursing for profile $prof -> $base");
				if (!exists $profiles->{$base}) {
					$log->fatal("Error in configuration: Profile $prof is BasedOn $base, but $base was never defined");
					die "Base profile does not exist";
				}
				$working{$base} = 1;
				push @stack, $base;
				next;
			} elsif (defined $base && $done{$base}) {
				$log->trace("Merging profile $base into $prof");
				$profiles->{$prof}
					= $hm->merge($profiles->{$base}, $profiles->{$prof});
			} elsif (!defined $base) {
				$log->trace("Profile $prof has no base; done");
				# no work needed
			} else {
				$log->fatal("inherit_prof_profiles is confused; profile=$prof base=$base, stack=(@{[ join(q{, }, @stack) ]})");
				die "bug";
			}
			$done{$prof} = 1;
			$working{$prof} = 0;
			pop @stack;
		}
	}

	return;
}

sub normalize_time {
	my $time = shift;
	my $log = Log::Log4perl->get_logger(__PACKAGE__);

	$time =~ /^ (\d+) \s* w $/ixa  and return $1 * 604_800;
	$time =~ /^ (\d+) \s* d $/ixa  and return $1 * 86_400;
	$time =~ /^ (\d+) \s* h $/ixa  and return $1 * 3600;
	$time =~ /^ (\d+) \s* m $/ixa  and return $1 * 60;
	$time =~ /^ (\d+) \s* s? $/ixa and return $1 * 1;
	
	$log->logconfess(
		"Unparsable duration: $time. Expected number with optional H, M, or S suffix.");
}

1;
