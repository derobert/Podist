package Podist::Database;
use Carp;
use DBI;
use Log::Log4perl qw(:easy :no_extra_logdie_message);
use Moose;
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

sub _get_migrations {
	my ($self, $db_vers) = @_;
	my $current_vers = 2;

	$db_vers =~ /^[0-9]+$/ or confess "Silly DB version: $db_vers";
	$db_vers <= $current_vers
		or confess "Future DB version $db_vers (higher than $current_vers";

	if ($db_vers == $current_vers) {
		DEBUG("Database is already current version.");
		return undef;
	} elsif ($db_vers == 0) {
		INFO("Creating new Podist database.");
	} else {
		INFO("Migrating database from version $db_vers to $current_vers");
	}

	my @sql;
	if ($db_vers == 0) {
		push @sql, <<SQL;
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
		push @sql, <<SQL;
CREATE TABLE playlists (
  playlist_no    INTEGER   NOT NULL PRIMARY KEY,
  playlist_ctime INTEGER   NOT NULL
)
SQL
	}

	if ($db_vers == 1) {
		# 1 → 2 upgrade, need to save old enclosures table because
		# SQLite can't do ALTER TABLE well enough.
		push @sql, q{ALTER TABLE enclosures RENAME TO enclosures_v1};
		push @sql, q{DROP VIEW valids};
		push @sql, q{DROP VIEW oldest_unplayed};
	}

	if ($db_vers == 0 || $db_vers == 1) {
		push @sql, <<SQL;
CREATE TABLE enclosures (
  enclosure_no     INTEGER   NOT NULL PRIMARY KEY,
  enclosure_url    TEXT      NOT NULL UNIQUE,
  enclosure_file   TEXT      NULL UNIQUE,
  enclosure_hash   TEXT      NULL,
  enclosure_time   REAL      NULL, -- length in seconds
  enclosure_use    INTEGER   NOT NULL DEFAULT 1,
  playlist_no      INTEGER   NULL REFERENCES playlists,
  playlist_so      INTEGER   NULL,
  UNIQUE(playlist_no, playlist_so),
  CONSTRAINT use_is_bool CHECK (enclosure_use IN (0,1))
)
SQL
		push @sql, <<SQL;
CREATE INDEX enclosusures_enclosure_hash ON enclosures(enclosure_hash)
SQL
		push @sql, <<SQL;
CREATE TABLE articles (
  article_no       INTEGER   NOT NULL PRIMARY KEY,
  feed_no          INTEGER   NOT NULL REFERENCES feeds,
  article_when     INTEGER   NOT NULL, -- unix timestamp
  article_uid      TEXT      NULL,
  article_title    TEXT      NULL,
  UNIQUE(feed_no, article_uid)
)
SQL
		push @sql, <<SQL;
CREATE INDEX articles_feed_title ON articles(feed_no, article_title)
SQL
		push @sql, <<SQL;
CREATE TABLE articles_enclosures (
  article_no       INTEGER   NOT NULL REFERENCES articles,
  enclosure_no     INTEGER   NOT NULL REFERENCES enclosures,
  UNIQUE(article_no, enclosure_no)
)
SQL
	}

	if ($db_vers == 1) {
		# migrate enclosures_v1
		push @sql, <<SQL;
INSERT INTO enclosures (
    enclosure_no, enclosure_url, enclosure_file, enclosure_hash,
    enclosure_time, enclosure_use, playlist_no, playlist_so
  )
  SELECT
    enclosure_no, enclosure_url, enclosure_file, enclosure_hash,
    enclosure_time, enclosure_use, playlist_no, playlist_so
  FROM enclosures_v1
SQL
		push @sql, <<SQL;
INSERT INTO articles (article_no, feed_no, article_when, article_title)
  SELECT enclosure_no, feed_no, enclosure_when, first_title
  FROM enclosures_v1
SQL
		push @sql, <<SQL;
INSERT INTO articles_enclosures (article_no, enclosure_no)
  SELECT enclosure_no, enclosure_no
  FROM enclosures_v1
SQL
	}

	if ($db_vers == 0 || $db_vers == 1) {
		push @sql, <<SQL;
CREATE VIEW oldest_unplayed AS
  SELECT a.feed_no, min(a.article_when) AS oldest
    FROM
      enclosures e
      JOIN articles_enclosures ae ON (e.enclosure_no = ae.enclosure_no)
      JOIN articles a ON (ae.article_no = a.article_no)
    WHERE
      e.enclosure_file IS NOT NULL
      AND e.playlist_no IS NULL
      AND e.enclosure_use = 1
    GROUP BY a.feed_no
SQL
		push @sql, <<SQL;
CREATE VIEW valids AS
  SELECT
    f.feed_ordered    AS feed_ordered,
    f.feed_is_music   AS feed_is_music,
    e.enclosure_no    AS enclosure_no,
    f.feed_no         AS feed_no,
    a.article_title   AS first_title,
    a.article_when    AS article_when,
    e.enclosure_url   AS enclosure_url,
    e.enclosure_file  AS enclosure_file,
    e.enclosure_time  AS enclosure_time
  FROM
    oldest_unplayed ou
    JOIN feeds f ON (ou.feed_no = f.feed_no)
    JOIN articles a ON (ou.feed_no = a.feed_no)
    JOIN articles_enclosures ae ON (a.article_no = ae.article_no)
    JOIN enclosures e ON (ae.enclosure_no = e.enclosure_no)
  WHERE
    (NOT f.feed_ordered OR a.article_when = ou.oldest)
    AND e.enclosure_file IS NOT NULL
    AND e.enclosure_time IS NOT NULL
    AND e.playlist_no IS NULL
    AND e.enclosure_use = 1
SQL
	
		# finally, set version
		push @sql, q{PRAGMA user_version = 2};
	}

	return \@sql;
}

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

	# Migrations depend on foreign keys being off (to prevent renaming
	# tables from changing things around). That's the current SQLite
	# default, but docs warn it may change.
	$dbh->do(q{PRAGMA foreign_keys = false});

	my ($vers) = $dbh->selectrow_array('PRAGMA user_version');
	foreach my $migration (@{$self->_get_migrations($vers)}) {
		$dbh->do($migration);
	}
	
	# Migrations done; turn them on.
	$dbh->do('PRAGMA foreign_keys = ON');

	return $dbh;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
