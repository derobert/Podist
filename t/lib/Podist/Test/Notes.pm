package Podist::Test::Notes;
use 5.024;
use strict;

use Test::More;
use base qw(Exporter);
our @EXPORT_OK = qw(long_note);

sub long_note {
	my ($header, $note) = @_;
	state $note_number = 0;

	my $ident = sprintf('%02X', $note_number++);
	$note =~ s/^/ <$ident>  /mg;
	chomp($note);
	note("$header\n$note\n *--*--END");
}

1;
