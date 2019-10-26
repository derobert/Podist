package Podist::Types;
use Moose::Util::TypeConstraints;
use File::Spec;

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

subtype 'Podist::Tempo'
	=> as 'Num'
	=> where { $_ > 0 }
	=> message { 'Tempo must be positive, non-zero' };

coerce 'Podist::Tempo',
	from 'Str',
	via {
		/^([0-9.]+)(?: \s* x)?$/ix and return 0 + $1;
		/^([0-9.]+) \s* %$/x       and return 0.01 * $1;
		die "Unparseable tempo: $_";
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

subtype 'Podist::FilePath'
	=> as 'Str'
	=> where { -f $_ }
	=> message { 'File must exist and be a file' };

subtype 'Podist::AbsoluteDirPath'
	=> as 'Str'
	=> where { File::Spec->file_name_is_absolute($_) && -d $_ }
	=> message { 'Directory must exist and be absolute' };

coerce 'Podist::AbsoluteDirPath',
	from 'Str',
	via { File::Spec->rel2abs($_) };

#>>>
1;
