package Podist::Config;
use 5.024; # let's have new sane Unicode regex behavior
use Moose;
use namespace::autoclean;
use Carp qw(confess);
use Clone qw(clone);
use Config::General;
use File::Slurper qw(write_text);
use MooseX::Params::Validate;
use Podist::Types;
use Podist::Misc qw(normalize_time);

# Probably if we were doing this from scratch, Podist wouldn't treat
# config as just a giant hash. But it's hard to change, and also it'd
# require centralizaing and/or probing a lot of knowledge to e.g., find
# out what attributes each module needs; Storage and Processor
# essentially handle their own config, for example.
#
# So this is currently a class without much state. Might be refactored
# more in the future.
#
# So, this is just a fairly minimal object to turn a config into a hash.
# There are also methods for writing config — Podist does not use these,
# but the tests do. Note that they lose comments.

has config_version => (
	is       => 'ro',
	isa      => 'Int',
	default  => 2,
	init_arg => undef,    # maybe someday, if we need it, but doubt it.
);

has _parse_opts_common => (
	is       => 'ro',
	isa      => 'HashRef',
	default  => sub {
		+{
			-AllowMultiOptions    => 0,
			-LowerCaseNames       => 1,
			-UseApacheInclude     => 1,
			-IncludeRelative      => 1,
			-IncludeDirectories   => 1,
			-IncludeGlob          => 1,
			-IncludeAgain         => 1,
			-MergeDuplicateBlocks => 1,
			-AutoLaunder          => 1,
			-AutoTrue             => 1,
			-InterPolateVars      => 1,
			-InterPolateEnv       => 1,
			-StrictVars           => 1,
			-SplitPolicy          => 'whitespace',
			-UTF8                 => 1,
		}
	},
	init_arg => undef,
);

sub read_config {
	my ($self, $conffile, $confdir) = validated_list(
		\@_,
		conf_file => { isa => 'Podist::FilePath' },
		conf_dir => { isa => 'Podist::AbsoluteDirPath', coerce => 1 },
	);

	my $cg = Config::General->new(
		-String => $self->_default_config_text(conf_dir => $confdir),
		%{$self->_parse_opts_common},
	);
	my %defs = $cg->getall;

	# V1 did not have a ConfigVersion specified, so we set it as
	# default. A V2 config will override it, but a V1 config will let
	# the default through.
	$defs{configversion} = 1;

	$cg = Config::General->new(
		%{$self->_parse_opts_common},
		-MergeDuplicateOptions => 1,
		-DefaultConfig         => \%defs,
		-ConfigFile            => $conffile,
	);

	my $config = { $cg->getall };
	$self->_normalize_config($config);

	return $config;
}

sub write_config {
	my ($self, $conffile, $config) = validated_list(
		\@_,
		conf_file => { isa => 'Str' }, # may not exist, so not FilePath
		config => { isa => 'HashRef' },
	);

	# stringifying the regexp in TitleIgnoreRE results in adding more
	# and more (?^u: ... ) to it, each time its saved. Work around it by
	# pre-stringifying it. Of course, that means we need to copy the
	# hash first.
	if (exists $config->{article}{titleignorere}) {
		$config = clone($config);
		my ($re, $flags) = re::regexp_pattern($config->{article}{titleignorere});
		$flags eq 'u' or confess "Unexpected TitleIgnoreRE flags: $flags";
		$config->{article}{titleignorere} = $re;
	}

	my $cg = Config::General->new( $self->_parse_opts_common );
	$cg->save_file($conffile, $config);

	return;
}

sub read_or_create_config {
	my ($self, $confdir) = validated_list(
		\@_,
		conf_dir => { isa => 'Podist::AbsoluteDirPath', coerce => 1 },
	);
	my $conffile = "$confdir/podist.conf";

	# not the most efficient, but allows more DRY. And only happens
	# once when first setting up Podist.
	-e $conffile
		or write_text($conffile,
		              $self->_default_config_text(conf_dir => $confdir));

	return $self->read_config(conf_dir => $confdir,
		conf_file => $conffile);
}

sub _normalize_config {
	# NOTE: modifies passed config!
	local $_;
	my $self = shift;
	my ($config) = pos_validated_list(
		\@_,
		{ isa => 'HashRef' },
	);
	
	my $p = $config->{playlist};
	$p->{$_} = normalize_time($p->{$_})
		foreach (qw(minimumduration targetduration maximumduration));
	$p->{$_} = $self->_normalize_fraction($p->{$_})
		foreach (qw(randomchancem randomchanceb randomfeedratio));

	$config->{article}{titleignorere}
		= $self->_compile_regex($config->{article}{titleignorere});

	return;
}

sub _normalize_fraction {
	my ($self, $fract) = @_;

	my $D = qr/
		(?: \d+ (?: \. \d* )? ) |
	  	(?: \. \d+ )
	/xa;

	$fract =~ m!^ ($D) \s* / \s* ($D) $!xa and return $1/$2;
	$fract =~ m!^ ($D) $!xa and return 0+$1;
	confess "Unparsable decimal/fraction: $fract. Expected decimal or two decimal numbers separated by a forward slash (e.g., 1/2)";
}

sub _compile_regex {
	my ($self, $re_text) = @_;

	my $res = eval { qr/$re_text/ };
	if ($@) {
		# can't use ERROR yet. Log4perl isn't set up.
		(my $err = $@) =~ s/ at \S+ line \d+\.\n$//;
		die <<ERR;
Invalid configuration file found. Expected a valid regular expression
for the TitleIgnoreRE option in the <article> block. Attempting to
compile:

   $re_text

gave the following Perl error:

   $err
ERR
	}

	return $res;
}

sub _default_config_text {
	my ($self, $confdir) = validated_list(
		\@_,
		conf_dir => { isa => 'Podist::AbsoluteDirPath', coerce => 1 },
	);

	return <<CONF;
# Once you've reviewed this file, change this to false.
NotYetConfigured true
ConfigVersion ${\ $self->config_version }
DataDir $confdir # e.g., \$HOME/.podist

<storage>
	PendingMedia      \$HOME/Podist/media-pending
	UnusableMedia     \$HOME/Podist/media-unusable
	OriginalMedia     \$HOME/Podist/playlists/original
	ProcessedMedia    \$HOME/Podist/playlists/processed
	ArchivedMedia     \$HOME/Podist/archived/original
	ArchivedProcessed \$HOME/Podist/archived/processed

	Playlists         \$HOME/Podist/playlists
	ArchivedPlaylists \$HOME/Podist/archived

	RandomMedia       \$HOME/Podist/random
</storage>

<archival>
	# media is always yes
	Processed   no
	Speech      yes
</archival>

<feed>
	BaseURL      http://yourserver/podist/
	FudgeDates   no
	<include>
		Speeches        no
		Intermissions   yes
		Leadout         no
	</include>
</feed>

<article>
	# Note this is after basic title whitespace normalization.
	TitleIgnoreRE   "(?i:[\\[(]rebroadcast[\\])])\$"
</article>

<playlist>
	# These are constraints for playlist generation. They are followed
	# as:
	#   1. If there are less than MinimumFiles, add any valid file (defined
	#      below)
	#   2. If there are MaximumFiles, stop. This playlist is done.
	#   3. If the playlist duration is less than TargetDuration, add any
	#      valid file such that the duration does not exceed
	#      MaximumDuration. If there are no files to add, stop, this
	#      playlist is done.
	#   4. If the playlist duration is at least TargetDuration, stop.
	#      This playlist is done.
	# Those are repeated until hitting a "stop", of course.
	#
	# As a final check, before comitting the playlist, if the total
	# length is less than MinimumDuration, abort.
	#
	# A valid file is any file that is:
	#   - the oldest unplaylisted file in its feed, if the feed is ordered
	#   - any unplaylisted file in an unordered feed
	# and does not put more than MaxConsecutive files from the same feed
	# in a row and does not exceed MaximumPerFeed files from that feed
	# in the current playlist.
	MinimumDuration    1800
	TargetDuration     3600
	MaximumDuration    7200
	MinimumFiles       1
	MaximumFiles       5
	MaximumConsecutive 2
	MaximumPerFeed     4

	# How do we pick between multiple valid options, all of which follow
	# the rules?
	#   - Random: pick completely at random
	#   - RandomFeed: pick at random, but make sure each feed has an
	#                 equal chance even if feed A has 10 eps, and feed B
	#                 has 300.
	#   - Longest: Pick the longest (duration) 
	#   - Oldest: Pick the oldest
	ChoiceMethod       RandomFeed
	
	# What should the chance be of throwing in a random item after each
	# played item?
	#   - Mode: Count, Time
	#   - M: Slope
	#   - B: Y-intercept, aka constan in constant func
	# That is, f(x) = mx + b
	#
	# NOTE: Random items are ignored in length/duration constraints
	#       (above).
	RandomChanceMode   Time
	RandomChanceM      1/7200
	RandomChanceB      0.2
	
	# How often should we use \$RandomMedia vs. feeds marked as music in
	# the database? 0 is always \$RandomMedia, 1 is always music feeds.
	# Note that if there aren't any unplayed items in music feeds, will
	# fall back to \$RandomMedia. (Note: music feeds always use
	# ChoiceMethod random)
	RandomFeedRatio    1/3

	# If we insert a random item, does this reset the consecutive same
	# podcast counter?
	ResetConsecutive   yes

	# Specify how many random items to play after the end of podcasts on
	# a playlist (so you don't have to switch while driving)
	LeadoutLength 5

	# Shall we put an announcement at the beginning and/or end of the
	# playlists we generate using a TTS (see the speech section below)
	AnnounceBegin Yes
	AnnounceLeadout Yes
	AnnounceEnd   Yes
</playlist>

<processing>
	Parallel 0
    <profile base>
        Loudness       -23 LUFS
        LoudnessRange  unlimited
        Encoder        lame-vbr   # lame-vbr, lame-cbr, vorbis, opus
        EncodeQuality  4          # meaning depends on Encoder
    </profile>
    <profile default>
        BasedOn        base
		# If you want all your podcasts to be sped up (time stretching),
		# uncomment this:
		# Tempo          1.3x
		# Optionally, override default rubberband filter options
		# RubberbandOptions :pitchq=quality:window=short
    </profile>
    <profile compress>
        BasedOn        default
        LoudnessRange  5 LU
    </profile>
    <profile music>
    	BasedOn        base
    	Tempo          1x
    	EncodeQuality  2
    </profile>
</processing>

<speech>
	# Which TTS engine shall we use? Currently, only Festival is
	# supported.
	Engine Festival

	# The voice to use
	Voice kal_diphone

	# How loud to make the audio
	Volume 12dbFS

	# Which format to get the audio in enventually. Options are:
	#   wav, mp3-cbr, mp3, ogg (listed largest -> smallest)
	Format ogg

	# What to say
	<message>
		Begin   Start of playlist __CURRENT__.
		Leadout End of podcasts in playlist __CURRENT__.
		End     End of playlist __CURRENT__.
	</message>
</speech>

<database>
	DSN dbi:SQLite:dbname=\$DataDir/podist.db
	Username   # fill in if DB requires
	Password   # fill in if DB requires
</database>

<logging>
	Simple true
	Level info   # fatal | error | warn | info | debug | trace

	### Alternatively, for more control,
	# Simple false
	# Config \$DataDir/log4perl.conf
</logging>
CONF
}

1;

=encoding utf8

=head1 NAME

Podist::Config - configuration handling for Podist

=head1 SYNOPSIS

 my $Cfg = Podist::Config->new;
 my $config = $Cfg->read_config(conf_dir => "$ENV{HOME}/.podist");

=head1 DESCRIPTION

Contains functions for handling the Podist configuration file, including
generating the default (template) configuration. Also contains functions
for editing configuration, used by the Podist tests.

Podist configuration is based on L<Config::General>, with most of the
convenience features allowed.

Note that this class is, for historical reasons, not really very OO. It
contains basically no state (and no user modifiable state). It mainly
works by returning configuration hashrefs.

=head2 PUBLIC METHODS

=over

=item read_config()

Reads a Podist configuration file and returns a Podist configuration
hash. Default values will be returned for things not present in the
configuration file.

Arguments:

=over

=item I<conf_dir>

Required. Directory holding the Podist configuration file. This must
already exist (and will be coerced to a absolute path, just in case).
This is only used to compute some of the default values.

=item I<conf_file>

Required. Path of the configuration file. Must already exist.

=back

=item write_config()

Writes a Podist configuration file. Note that there is no way to include
comments with this method; ths method is intended only for the Podist
tests (which need it for testing to make sure various configuration
options work).

Arguments:

=over

=item I<conf_file>

File to write the configuration to. If it already exists, its
overwritten.

=item I<config>

Podist configuration hashref. Note one special requirement: the
TitleIgnoreRE regexp must be compiled with C<qr/WHATEVER/u>; this is the
default for any half-recent version of Perl, when running with a C<use
5.024> or similar in effect. Non-half-recent versions of Perl can't run
Podist anyway. 

=back

=item read_or_create_config()

Reads a Podist configuration from the given directory or, if it doesn't
exist, creates a new default one. The new one will have
C<$config->{notyetconfigured}> set to a true value, so you can test that
to see if the user has configured Podist.

The configuration file will be named F<podist.conf> inside the
configuration directory.

Arguments:

=over

=item I<conf_dir>

Directory to find or create the Podist configuration in.

=back

=back

=head1 AUTHOR

L<Anthony DeRobertis|mailto:anthony@derobert.net>. This module is part of
Podist; for details see L<https://gitlab.com/derobert/Podist>.

=head1 COPYRIGHT

Podist Copyright ©2008–2018 Anthony DeRobertis. Licensed under GPLv3 or
later; see F<COPYING> for the complete text of the license.
