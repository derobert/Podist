package Podist::Misc;
use strict;

use parent qw(Exporter);
our @EXPORT_OK = qw(inherit_proc_profiles);

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

1;
