package Podist::Database;
use feature 'state';
use Carp;
use DBI;
use Log::Log4perl qw(:easy :no_extra_logdie_message);
use UUID;
use Moose;
use namespace::autoclean;

has dsn      => (required => 1, is => 'ro', isa => 'Str');
has username => (required => 0, is => 'ro', isa => 'Str|Undef');
has password => (required => 0, is => 'ro', isa => 'Str|Undef');
has uuid     => (required => 0, is => 'ro', isa => 'Str', lazy => 1, builder => '_build_uuid');

has _dbh => (
	is       => 'ro',
	isa      => 'Object',
	init_arg => undef,
	lazy     => 1,
	builder  => '_build_dbh',
	handles  => [qw(
			commit rollback do prepare selectall_arrayref selectrow_array
			last_insert_id prepare_cached
			)
	],
);

sub find_enclosure {
	my ($self, $url) = @_;

	my $sth = $self->prepare_cached(
		q{SELECT enclosure_no FROM enclosures WHERE enclosure_url = ?}
	);

	$sth->execute($url);
	my ($res) = $sth->fetchrow_array;
	$sth->finish;

	return $res;
}

sub find_article {
	my ($self, %search) = @_;

	my $sth;
	if (exists $search{uid}
		&& !exists $search{when}
		&& !exists $search{title})
	{
		$sth = $self->prepare_cached(
			q{SELECT article_no FROM articles WHERE article_uid = ?});
		$sth->execute($search{uid});
	} elsif (exists $search{when} && exists $search{title}) {
		$sth = $self->prepare_cached(
			q{SELECT article_no FROM articles
			  WHERE article_title = ? AND article_when = ? LIMIT 1}
		);
		$sth->execute($search{title}, $search{when});
	} else {
		confess "Expected search by uid or by title/when";
	}

	my ($res) = $sth->fetchrow_array;
	$sth->finish;

	return $res;
}

sub add_article {
	my ($self, %opts) = @_;
	$opts{feed}  =~ /^\d+$/       or croak "Bad feed number";
	$opts{when}  =~ /^\d+$/       or croak "Bad when";
	$opts{fetch} =~ /^\d+$/       or croak "Bad fetch number";

	# default to true, convert perl truth to strict 0/1 truth.
	$opts{use} = ($opts{use} // 1) ? 1 : 0;

	my $sth = $self->prepare_cached(q{
		INSERT INTO articles(
		  feed_no, fetch_no, article_title, article_when, article_uid,
		  article_use
		) VALUEs (?, ?, ?, ?, ?, ?)
	});
	$sth->execute(
		$opts{feed}, $opts{fetch}, $opts{title},
		$opts{when}, $opts{uid},   $opts{use});

	my $e_no = $self->last_insert_id('', '', 'articles', 'article_no');
	$e_no or confess "Failed to get an article number back from DB";

	return $e_no;
}

sub add_enclosure {
	my ($self, $url) = @_;

	my $sth = $self->prepare_cached(
		q{INSERT INTO enclosures(enclosure_url) VALUES (?)});
	$sth->execute($url);

	my $e_no = $self->last_insert_id('', '', 'enclosures', 'enclosure_no');
	$e_no or confess "Failed to get an enclosure number back from DB";

	return $e_no;
}

sub link_article_enclosure {
	my ($self, $article, $enclosure) = @_;

	my $sth = $self->prepare_cached(q{
		INSERT INTO articles_enclosures(article_no, enclosure_no)
		  VALUES (?, ?)
	});
	$sth->execute($article, $enclosure);

	return;
}

sub find_or_add_random {
	my ($self, $file) = @_;

	my $sth = $self->prepare_cached(q{
		SELECT random_no, random_weight FROM randoms
		 WHERE random_file = ?
	});

	my ($number, $weight);
	$sth->execute($file);
	if (($number, $weight) = $sth->fetchrow_array) {
		$sth->finish; # should only be one row, but just in case
	} else {
		# not found, add it. Rare, so no need to cache sth.
		INFO("Adding new random item $file to database");
		my $sth = $self->prepare(q{
			INSERT INTO randoms(random_file) VALUES (?)
		});
		$sth->execute($file);
		$number = $self->last_insert_id('', '', 'randoms', 'random_no')
			or confess "Failed to get a random_no back from DB";
		DEBUG("New random is number $number");

		# load weight from DB. Again rare (exactly same as add, hopefully).
		($weight) = $self->selectrow_array(
			q{SELECT random_weight FROM randoms WHERE random_no = ?},
			{}, $number
		) or confess "Could not find freshly-inserted random $number";
	}

	return {
		random_no => $number,
		random_file => $file,
		random_weight => $weight,
	};

}

sub add_fetch {
	my ($self, $feed_no) = @_;

	my $sth = $self->prepare_cached(
		q{INSERT INTO fetches(feed_no, fetch_when) VALUES (?, ?)});
	$sth->execute($feed_no, time);

	my $f_no = $self->last_insert_id('', '', 'fetches', 'fetch_no');
	$f_no or confess "Failed to get a fetch number back from DB";

	return $f_no;
}

sub finish_fetch {
	state $CODES = {
		ok          => 0,
		limit       => 1,
		http_error  => 2,
		parse_error => 3,
	};
	my ($self, $fetch_no, $status_txt) = @_;
	defined(my $status = $CODES->{lc $status_txt})
		or croak "Invalid status '$status_txt'";

	my $sth = $self->prepare_cached(
		q{UPDATE fetches SET fetch_status = ? WHERE fetch_no = ?}
	);
	$sth->execute($status, $fetch_no);
}

sub archive_playlist {
	my ($self, $p_no) = @_;
	my $sth = $self->prepare_cached(
		q{UPDATE playlists SET playlist_archived = ? WHERE playlist_no = ?}
	);

	$sth->execute(time, $p_no);
	return;
}

sub vacuum {
	my ($self) = @_;

	$self->commit;
	local $self->_dbh->{AutoCommit} = 1;
	$self->do('VACUUM');
}

sub _build_uuid {
	my ($self) = @_;
	
	my @row = $self->selectrow_array(
		q{SELECT podist_uuid FROM podist_instance}
	) or die "No rows in podist_instance?";

	return $row[0];
}

sub unarchived_playlist_info {
	my ($self) = @_;

	my $sth = $self->prepare_cached(<<SQL);
   SELECT info.*
        , a.article_title AS article_title
        , a.article_when AS article_when
        , f.feed_name AS feed_name
        , f.feed_url AS feed_url
     FROM ( SELECT e.enclosure_no
                 , e.enclosure_file
                 , e.enclosure_time
                 , e.playlist_no
                 , e.playlist_so
                 , p.playlist_archived
                 , (   SELECT a.article_no
                         FROM articles_enclosures ae
                         JOIN articles a ON (ae.article_no = a.article_no)
                        WHERE ae.enclosure_no = e.enclosure_no
                          AND a.article_use = 1
                     ORDER BY CASE WHEN a.article_title IS NULL THEN 1 ELSE 0 END, a.article_no
                        LIMIT 1
                   ) AS first_article_no
              FROM enclosures e
              JOIN playlists p ON (e.playlist_no = p.playlist_no)
             WHERE p.playlist_archived IS NULL
          ) AS info
LEFT JOIN articles a ON (info.first_article_no = a.article_no)
LEFT JOIN feeds f ON (a.feed_no = f.feed_no)
 ORDER BY playlist_no, playlist_so
SQL
	$sth->execute;
	my $res = $sth->fetchall_arrayref({});
	$sth->finish;

	return $res;
}

sub _get_migrations {
	my ($self, $db_vers) = @_;
	my $current_vers = 7;

	# Versions:
	# 0 - no db yet
	# 1 - original
	# 2 - store article info, not just enclosures
	# 3 - per-fed, per-time limit; db logs fetches
	# 4 - adds playlist archival
	# 5 - podist_instance (UUID); add some indexes (performance)
	# 6 - usable enclosure view
	# 7 - store random music selections in db

	$db_vers =~ /^[0-9]+$/ or confess "Silly DB version: $db_vers";
	$db_vers <= $current_vers
		or confess "Future DB version $db_vers (higher than $current_vers";

	if ($db_vers == $current_vers) {
		DEBUG("Database is already current version.");
		return [];
	} elsif ($db_vers == 0) {
		INFO("Creating new Podist database.");
	} else {
		INFO("Migrating database from version $db_vers to $current_vers");
	}

	my @sql;
	if ($db_vers == 0) {
		push @sql, <<SQL;
CREATE TABLE feeds (
  feed_no             INTEGER   NOT NULL PRIMARY KEY,
  feed_url            TEXT      NOT NULL UNIQUE,
  feed_name           TEXT      NOT NULL UNIQUE,
  feed_enabled        INTEGER   NOT NULL DEFAULT 1,
  feed_ordered        INTEGER   NOT NULL DEFAULT 1,
  feed_all_audio      INTEGER   NOT NULL DEFAULT 1,
  feed_is_music       INTEGER   NOT NULL DEFAULT 0,
  feed_limit_amount   INTEGER   NOT NULL DEFAULT 3,
  feed_limit_period   INTEGER   NOT NULL DEFAULT 604800, -- 1 week in seconds
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

	if ($db_vers < 4) {    # including 0
		push @sql, q{ALTER TABLE playlists ADD playlist_archived INTEGER NULL};
	}

	if ($db_vers < 5) {
		my $uuid = UUID::uuid();
		push @sql, <<SQL;
CREATE TABLE podist_instance (
	podist_uuid   TEXT   NOT NULL
)
SQL
		push @sql, qq{INSERT INTO podist_instance(podist_uuid) VALUES ('$uuid')}; # UUID is safe chars
	}

	if ($db_vers < 3) {
		push @sql, <<SQL;
CREATE TABLE status_codes (
  status_code   INTEGER   NOT NULL PRIMARY KEY,
  status_descr  TEXT      NOT NULL
)
SQL
		push @sql, q{INSERT INTO status_codes VALUES(0, 'OK')};
		push @sql, q{INSERT INTO status_codes VALUES(1, 'Limit Exceeded')};
		push @sql, q{INSERT INTO status_codes VALUES(2, 'HTTP Error (download failed)')};
		push @sql, q{INSERT INTO status_codes VALUES(3, 'Feed parse failed')};
		push @sql, <<SQL;
CREATE TABLE fetches (
  fetch_no       INTEGER   NOT NULL PRIMARY KEY,
  feed_no        INTEGER   NOT NULL REFERENCES feeds,
  fetch_status   INTEGER   NULL REFERENCES status_codes,
  fetch_when     INTEGER   NOT NULL -- unix timestamp
)
SQL
	}

	if ($db_vers == 1) {
		# 1 → 2 upgrade, need to save old enclosures table because
		# SQLite can't do ALTER TABLE well enough.
		push @sql, q{ALTER TABLE enclosures RENAME TO enclosures_v1};
	}

	if ($db_vers == 1 || $db_vers == 2) {
		push @sql,
			q{ALTER TABLE feeds ADD feed_limit_amount INTEGER NOT NULL DEFAULT 3},
			q{ALTER TABLE feeds ADD feed_limit_period INTEGER NOT NULL DEFAULT 604800};

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
  fetch_no         INTEGER   NULL REFERENCES fetches,
  article_when     INTEGER   NOT NULL, -- unix timestamp
  article_use      INTEGER   NOT NULL DEFAULT 1,
  article_uid      TEXT      NULL,
  article_title    TEXT      NULL,
  UNIQUE(feed_no, article_uid),
  CONSTRAINT use_is_bool CHECK (article_use IN (0,1))
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

	if ($db_vers == 2) {
		push @sql,
			"ALTER TABLE articles ADD fetch_no INTEGER NULL REFERENCES fetches";

		push @sql,
			q{ALTER TABLE articles ADD article_use INTEGER NOT NULL DEFAULT 1 CONSTRAINT use_is_bool CHECK (article_use IN (0,1))};
	}

	if ($db_vers < 5) {
		push @sql, <<SQL;
CREATE INDEX articles_enclosures_enclosure_no ON articles_enclosures(enclosure_no);
SQL
	}

	if ($db_vers == 0 || $db_vers == 1 || $db_vers == 2) {
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
      AND a.article_use = 1
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
    AND a.article_use = 1
SQL
	
	}

	if ($db_vers < 6) {
		push @sql, <<SQL;
CREATE VIEW usable_enclosures AS
  SELECT e.*,
         MIN(a.article_no) AS min_article_no,
         MIN(a.article_when) AS earliest_article_when
    FROM enclosures e
    JOIN articles_enclosures ae ON (e.enclosure_no = ae.enclosure_no)
    JOIN articles a ON (ae.article_no = a.article_no)
   WHERE e.enclosure_use = 1
   GROUP BY e.enclosure_no
  HAVING MAX(a.article_use) >= 1
SQL
	}

	if ($db_vers < 7) {
		push @sql, <<SQL;
CREATE TABLE randoms (
  random_no        INTEGER   NOT NULL PRIMARY KEY,
  random_file      TEXT      NOT NULL UNIQUE,
  random_weight    INTEGER   NOT NULL DEFAULT 1000, -- set to 0 to disable
  CONSTRAINT random_weight_is_non_negative CHECK (random_weight >= 0)
)
SQL
		push @sql, <<SQL;
CREATE TABLE random_uses (
  random_no        INTEGER   NOT NULL REFERENCES randoms,
  playlist_no      INTEGER   NOT NULL REFERENCES playlists,
  playlist_so      INTEGER   NOT NULL,
  UNIQUE(playlist_no, playlist_so)
)
SQL
	}

	# finally, set version
	push @sql, q{PRAGMA user_version = 7};

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

	local $dbh->{ShowErrorStatement} = 1; # useful if migration fails
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
