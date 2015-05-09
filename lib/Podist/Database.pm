package Podist::Database;
use DBI;
use Moose;
use Log::Log4perl qw(:easy :no_extra_logdie_message);
use namespace::autoclean;

has dsn      => (required => 1, is => 'ro', isa => 'Str');
has username => (required => 0, is => 'ro', isa => 'Str|Undef');
has password => (required => 0, is => 'ro', isa => 'Str|Undef');

has _dbh => (
	is       => 'ro',
	isa      => 'Object',
	init_arg => undef,
	lazy     => 1,
	builder  => '_build_dbh',
	handles  => [qw(
			commit rollback do prepare selectall_arrayref selectrow_array
			last_insert_id
			)
	],
);

use constant DB_VERSION => 1;

sub _build_dbh {
	my ($self) = @_;

	TRACE("Connecting to the database.");
	my $dbh = DBI->connect(
		$self->dsn, $self->username, $self->password,
		{
			AutoCommit       => 0,
			RaiseError       => 1,
			PrintError       => 0,
			FetchHashKeyName => 'NAME_lc',
		});

	my ($vers) = $dbh->selectrow_array('PRAGMA user_version');
	$vers > DB_VERSION
		and die "Database is from newer version of this program";

	if (0 == $vers) {
		INFO("Creating Podist database.");
		# need to create db.
		$dbh->do(<<SQL);
CREATE TABLE feeds (
  feed_no        INTEGER   NOT NULL PRIMARY KEY,
  feed_url       TEXT      NOT NULL UNIQUE,
  feed_name      TEXT      NOT NULL UNIQUE,
  feed_enabled   INTEGER   NOT NULL DEFAULT 1,
  feed_ordered   INTEGER   NOT NULL DEFAULT 1,
  feed_all_audio INTEGER   NOT NULL DEFAULT 1,
  feed_is_music  INTEGER   NOT NULL DEFAULT 0,
  CONSTRAINT enabled_is_bool CHECK (feed_enabled IN (0,1)),
  CONSTRAINT ordered_is_bool CHECK (feed_ordered IN (0,1)),
  CONSTRAINT all_audio_is_bool CHECK (feed_all_audio IN (0,1)),
  CONSTRAINT is_music_is_bool CHECK (feed_is_music IN (0,1))
)
SQL
		$dbh->do(<<SQL);
CREATE TABLE playlists (
  playlist_no    INTEGER   NOT NULL PRIMARY KEY,
  playlist_ctime INTEGER   NOT NULL
)
SQL
		$dbh->do(<<SQL);
CREATE TABLE enclosures (
  enclosure_no     INTEGER   NOT NULL PRIMARY KEY,
  feed_no          INTEGER   NOT NULL REFERENCES feeds,
  first_title      TEXT      NULL,
  enclosure_url    TEXT      NOT NULL UNIQUE,
  enclosure_file   TEXT      NULL UNIQUE,
  enclosure_hash   TEXT      NULL,
  enclosure_when   INTEGER   NOT NULL, -- unix timestamp
  enclosure_time   REAL      NULL, -- length in seconds
  enclosure_use    INTEGER   NOT NULL DEFAULT 1,
  playlist_no      INTEGER   NULL REFERENCES playlists,
  playlist_so      INTEGER   NULL,
  UNIQUE(playlist_no, playlist_so),
  CONSTRAINT use_is_bool CHECK (enclosure_use IN (0,1))
)
SQL
		$dbh->do(<<SQL);
CREATE INDEX enclosusures_enclosure_hash ON enclosures(enclosure_hash)
SQL
		$dbh->do(<<SQL);
CREATE VIEW oldest_unplayed AS
  SELECT feed_no, min(enclosure_when) AS oldest
    FROM enclosures
    WHERE
      enclosure_file IS NOT NULL
      AND playlist_no IS NULL
      AND enclosure_use = 1
    GROUP BY feed_no
SQL
		$dbh->do(<<SQL);
CREATE VIEW valids AS
  SELECT
    f.feed_ordered    AS feed_ordered,
    f.feed_is_music   AS feed_is_music,
    e.enclosure_no    AS enclosure_no,
    e.feed_no         AS feed_no,
    e.first_title     AS first_title,
    e.enclosure_url   AS enclosure_url,
    e.enclosure_file  AS enclosure_file,
    e.enclosure_when  AS enclosure_when,
    e.enclosure_time  AS enclosure_time
  FROM
    feeds f
    JOIN enclosures e ON (f.feed_no = e.feed_no)
    LEFT JOIN oldest_unplayed ou ON (e.feed_no = ou.feed_no)
  WHERE
    (NOT f.feed_ordered OR e.enclosure_when = ou.oldest)
    AND e.enclosure_file IS NOT NULL
    AND e.enclosure_time IS NOT NULL
    AND e.playlist_no IS NULL
    AND e.enclosure_use = 1
SQL
		$dbh->selectrow_array('PRAGMA user_version = 1');
		$dbh->commit;
		TRACE("Database creation done.");
	} elsif (1 == $vers) {
		DEBUG("Version 1 database found");
		# current, do nothing.
	} else {
		LOGDIE "BUG: Unknown (but not future!) database version";
	}

	# Enable foreign keys
	$dbh->do('PRAGMA foreign_keys = ON');

	return $dbh;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
