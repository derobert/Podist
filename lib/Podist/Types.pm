package Podist::Types;
use Moose::Util::TypeConstraints;

#<<< Perltidy destroys this...

subtype 'Podist::LUFS'
	=> as 'Num'
	=> where { $_ <= 0 }
	=> message { 'Volume above full scale not supported' };
coerce 'Podist::LUFS',
	from 'Str',
	via {
		$_ =~ /^([+-]?[0-9]+(?:\.[0-9]+)?)(?:\s+LUFS)?$/i
			or die "Unparsable volume: $_";
		0+$1
	};

subtype 'Podist::LU'
	=> as 'Maybe[Num]'
	=> where { !defined $_ || $_ <= 20 }; # bloody ffmpeg limit
coerce 'Podist::LU',
	from 'Str',
	via {
		/^(?:unlimited|infinite)$/i
			and return undef;
		/^([+-]?[0-9]+(?:\.[0-9]+)?)(?:\s+LU)?$/i
			and return 0+$1;
		die "Unparsable volume: $_";
	};

subtype 'Podist::Quality'
	=> as 'Num';

coerce 'Podist::Quality',
	from 'Str',
	via {
		/^[0-9.]+$/
			and return 0+$_;
		/^([0-9.]+)\s*k$/i
			and return 1000*$1;
		die "Unparsable quality $_";
	};
#>>>
1;
