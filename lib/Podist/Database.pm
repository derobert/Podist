package Podist::Database;
use feature 'state';
use Carp;
use DBI;
use File::Spec qw();
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
			selectcol_arrayref last_insert_id prepare_cached quote_identifier
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
	$opts{when}  =~ /^\d+$/       or croak "Bad when: $opts{when}";
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

sub add_enclosure_storage {
	my ($self, $e_no, $store, $name) = @_;

	my $sth = $self->prepare_cached(q{
		UPDATE enclosures
		  SET enclosure_store = ?, enclosure_file = ?
		  WHERE enclosure_no = ?
	});
	$sth->execute($store, $name, $e_no);

	return;
}

sub update_enclosure_storage {
	my ($self, $e_no, $store) = @_;

	my $sth = $self->prepare_cached(q{
		UPDATE enclosures
		  SET enclosure_store = ?
		  WHERE enclosure_no = ?
	});
	$sth->execute($store, $e_no);

	return;
}

sub get_enclosure_storage {
	my ($self, $e_no) = @_;
	wantarray or croak "get_enclosure_storage returns a list";

	my $sth = $self->prepare_cached(q{
		SELECT enclosure_store, playlist_no, enclosure_file
		  FROM enclosures WHERE enclosure_no = ?
	});
	$sth->execute($e_no);
	my ($store, $p_no, $name) = $sth->fetchrow_array
		or confess "enclosure $e_no not found";
	$sth->finish;

	return ($store, $p_no, $name);
}

sub get_playlist_enclosures {
	my ($self, $p_no) = @_;

	$self->selectcol_arrayref(q{
		SELECT enclosure_no FROM enclosures WHERE playlist_no = ?
	}, {}, $p_no);
}

sub get_playlist_speeches {
	my ($self, $p_no) = @_;

	$self->selectcol_arrayref(q{
		SELECT speech_no FROM speeches WHERE playlist_no = ?
	}, {}, $p_no);
}

sub add_playlist { 
	my ($self, $template) = @_;

	# we can't use last_insert_id since we need a name for the playlist
	# based on the playlist number. Instead, use the max() + 1 trick.
	
	my ($p_no) = $self->selectrow_array(q{
		SELECT 1+COALESCE(max(playlist_no),0) FROM playlists
	});
	my $name = sprintf($template, $p_no);

	TRACE("Adding playlist $p_no name $name");
	$self->do(q{
		INSERT INTO playlists(playlist_no, playlist_ctime, playlist_file)
		  VALUES (?, ?, ?)
	}, {}, $p_no, time(), $name);

	return $p_no;
}

sub get_playlist_storage {
	my ($self, $p_no) = @_;
	wantarray or croak "get_playlist_storage returns a list";

	my $sth = $self->prepare_cached(q{
		SELECT playlist_archived, playlist_file
		  FROM playlists WHERE playlist_no = ?
	});
	$sth->execute($p_no);
	my ($archived, $file) = $sth->fetchrow_array
		or confess "playlist $p_no not found";
	$sth->finish;

	return ($archived, $file);
}

sub add_speech {
	my ($self, %opts) = @_;

	# confess since this will be called from Storage, which isn't the
	# original source.
	defined(my $event = $opts{event}) or confess "event param required";
	defined(my $text  = $opts{text})  or confess "text param required";
	defined(my $file  = $opts{file})  or confess "file param required";
	defined(my $store = $opts{store}) or confess "store param required";
	defined(my $p_no = $opts{playlist_no})
		or confess "playlist_no param required";
	defined(my $p_so = $opts{playlist_so})
		or confess "playlist_so param required";

	my $sth = $self->prepare_cached(q{
		INSERT INTO speeches(
		  playlist_no, playlist_so,
		  speech_event, speech_text,
		  speech_file, speech_store
		) VALUES (
		  ?, ?,
		  ?, ?,
		  ?, ?
		)
	});
	$sth->execute(
		$p_no, $p_so,
		$event, $text,
		$file, $store
	);

	my $s_no = $self->last_insert_id('', '', 'speeches', 'speech_no');
	return $s_no;
}

sub get_speech_storage {
	# FIXME: ridiculously close to other get_*_storage... need a real
	# ORM.
	my ($self, $s_no) = @_;
	wantarray or croak "get_speech_storage returns a list";

	my $sth = $self->prepare_cached(q{
		SELECT speech_store, playlist_no, speech_file
		  FROM speeches WHERE speech_no = ?
	});
	$sth->execute($s_no);
	my ($store, $p_no, $name) = $sth->fetchrow_array
		or confess "speech $s_no not found";
	$sth->finish;

	return ($store, $p_no, $name);
}

sub update_speech_storage {
	# FIXME: damn same as update_*_storage
	my ($self, $s_no, $store) = @_;

	my $sth = $self->prepare_cached(q{
		UPDATE speeches
		  SET speech_store = ?
		  WHERE speech_no = ?
	});
	$sth->execute($store, $s_no);

	return;
}

sub drop_podcast {
	my ($self, $feed_no) = @_;

	my $sth_victims = $self->prepare(<<QUERY);
SELECT e.enclosure_no, e.enclosure_time
  FROM articles a
  JOIN articles_enclosures ae ON (a.article_no = ae.article_no)
  JOIN enclosures e ON (ae.enclosure_no = e.enclosure_no)
  WHERE a.feed_no = ? AND e.playlist_no IS NULL AND e.enclosure_use = 1
  ORDER BY e.enclosure_no
QUERY
	my $sth_dontuse = $self->prepare(<<QUERY);
UPDATE enclosures SET enclosure_use = 0 WHERE enclosure_no = ?
QUERY

	my ($N, $t_time) = (0, 0);
	$sth_victims->execute($feed_no);
	while (my ($e_no, $e_time) = $sth_victims->fetchrow_array) {
		++$N; $t_time += $e_time;
		$sth_dontuse->execute($e_no);
		INFO("Dropping feed #$feed_no, will not use enclosure #$e_no.");
	}
	WARN("Dropped feed #$feed_no, not using $N enclosures (${ \int(0.5+($t_time/60)) } minutes total).");

	$sth_victims->finish;
	$sth_dontuse->finish;

	$self->update_feed($feed_no, { feed_enabled => 0 });

	return;
}

sub update_feed {
	my ($self, $feed_no, $updates) = @_;

	$self->_update_table_generic(
		table => 'feeds', 
		pkey => { feed_no => $feed_no }, 
		updates => $updates
	);
}

sub update_random {
	my ($self, $random_no, $updates) = @_;

	$self->_update_table_generic(
		table => 'randoms', 
		pkey => { random_no => $random_no }, 
		updates => $updates
	);
}

sub _update_table_generic {
	my ($self, %opts) = @_;
	local $_;
	# TODO: switch to an ORM like DBIC somday. Which would already
	# provide this.
	
	my @cols = map($self->quote_identifier($_), keys %{$opts{updates}});
	my @vals = values %{$opts{updates}};

	my @keys = map($self->quote_identifier($_), keys %{$opts{pkey}});
	push @vals, values %{$opts{pkey}};

	my $table = $self->quote_identifier($opts{table});

	my $query = <<QUERY;
UPDATE $table
  SET
    ${ \join(",\n    ",    map("$_ = ?", @cols)) }
  WHERE
    ${ \join(" AND\n    ", map("$_ = ?", @keys)) }
QUERY

	TRACE("_update_table_generic generated query:\n$query");
	my $rows = $self->do($query, {}, @vals);
	1 == $rows or die "Expected to affect 1 row, instead got $rows";

	return;
}

sub add_processed {
	my ($self, %opts) = @_;

	defined(my $e_no = $opts{enclosure_no})
		or croak "enclosure_no required";
	defined(my $p_no = $opts{playlist_no})  or croak "playlist_no required";
	defined(my $prof = $opts{profile})      or croak "profile required";
	defined(my $duration = $opts{duration}) or croak "duration required";
	defined(my $cputime = $opts{cputime})   or croak "cputime required";
	defined(my $store = $opts{store})       or croak "store required";
	defined(my $pid = $opts{pid})           or croak "pid required";
	defined(my $parallel = $opts{parallel}) or croak "parallel required";

	my $sth = $self->prepare_cached(q{
		INSERT INTO processed(
		  enclosure_no, playlist_no, processed_profile,
		  processed_duration, processed_cputime, processed_store,
		  processed_pid, processed_parallel
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	});
	$sth->execute($e_no, $p_no, $prof, $duration, $cputime, $store, $pid,
		$parallel);

	my $proc_no = $self->last_insert_id('', '', 'processed', 'processed_no');
	return $proc_no;
}

sub add_processed_part {
	my ($self, %opts) = @_;

	defined(my $proc_no = $opts{processed_no})
		or confess "processed_no param required";
	defined(my $pp_so = $opts{proc_part_so})
		or confess "proc_part_so param required";
	defined(my $pp_file = $opts{proc_part_file})
		or confess "proc_part_file param required";

	my $sth = $self->prepare_cached(q{
		INSERT INTO processed_parts(
		  processed_no, proc_part_so, proc_part_file
		) VALUES (?, ?, ?)
	});
	$sth->execute($proc_no, $pp_so, $pp_file);

	return;
}

sub get_processed_parts {
	my ($self, $e_no) = @_;

	my $sth = $self->prepare_cached(q{
		SELECT
		    p.processed_no, p.playlist_no, p.processed_store,
		    pp.proc_part_file
		  FROM
		    processed p JOIN processed_parts pp ON (
		      p.processed_no = pp.processed_no
		    )
		  WHERE p.enclosure_no = ?
	});
	$sth->execute($e_no);

	my $res = $sth->fetchall_arrayref({});
	$sth->finish;

	return $res;
}

sub update_processed_storage {
	my ($self, $e_no, $store) = @_;

	my $sth = $self->prepare_cached(q{
		UPDATE processed
		  SET processed_store = ?
		  WHERE enclosure_no = ?
	});
	$sth->execute($store, $e_no);

	return;
}

sub find_or_add_random {
	my ($self, $file) = @_;

	my $sth = $self->prepare_cached(q{
		SELECT random_no, random_weight, random_name FROM randoms
		 WHERE random_file = ?
	});

	my ($number, $weight, $name);
	$sth->execute($file);
	if (($number, $weight, $name) = $sth->fetchrow_array) {
		$sth->finish; # should only be one row, but just in case
	} else {
		# not found, add it. Rare, so no need to cache sth here. Build
		# user presentable name from file name (should do tags someday).

		(undef, undef, $name) = File::Spec->splitpath($file);
		$name =~ s/\..{1,4}$//;

		INFO("Adding new random item $file to DB with name $name");
		my $sth = $self->prepare(q{
			INSERT INTO randoms(random_file, random_name) VALUES (?, ?)
		});
		$sth->execute($file, $name);
		$number = $self->last_insert_id('', '', 'randoms', 'random_no')
			or confess "Failed to get a random_no back from DB";
		DEBUG("New random is number $number");

		($weight) = $self->selectrow_array(
			q{SELECT random_weight FROM randoms WHERE random_no = ?},
			{}, $number
		) or confess "Could not find freshly-inserted random $number";
	}

	return {
		random_no     => $number,
		random_file   => $file,
		random_name   => $name,
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

sub mark_playlist_archived {
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

sub get_playlist_list {
	my ($self, $omit_archived) = @_;

	my $query = q{SELECT playlist_no FROM playlists};
	$query .= q{ WHERE playlist_archived IS NULL} if $omit_archived;

	$self->selectcol_arrayref($query);
}

sub get_processing_info {
	my ($self, $playlist) = @_;

	# we use min(article_no) instead of article_when (or a combination
	# of the two) because we want this to be stable. Hypothetically, a
	# new fetch could add a new, lower article_when. But article_no
	# always increases, it's the order they were added to the DB.
	#
	# TODO: Consider what to do about a.article_use
	my $query = <<SQL;
SELECT
    e.playlist_so, e.enclosure_no, e.enclosure_file, e.enclosure_time,
    e.enclosure_store,
    p.processed_no, p.processed_profile, p.processed_duration,
    p.processed_store, pp.proc_part_so, pp.proc_part_file,
    f.feed_no, f.feed_name, f.feed_proc_profile
  FROM
    enclosures e
    LEFT JOIN processed p ON (e.enclosure_no = p.enclosure_no)
    LEFT JOIN processed_parts pp ON (p.processed_no = pp.processed_no)
    JOIN (
      SELECT enclosure_no, MIN(article_no) AS min_article_no
        FROM articles_enclosures
       GROUP BY enclosure_no ) AS fa ON (e.enclosure_no = fa.enclosure_no)
    JOIN articles a ON (fa.min_article_no = a.article_no)
    JOIN feeds f ON (a.feed_no = f.feed_no)
  WHERE e.playlist_no = ?
  ORDER BY e.playlist_so, p.processed_no, pp.proc_part_so
SQL

	my $sth = $self->prepare($query);
	$sth->execute($playlist);

	my @res;
	while (my $row = $sth->fetchrow_hashref) {
		# this mess so wants for DBIC... it's on the todo list.
		if (@res && $res[-1]{enclosure_no} == $row->{enclosure_no}) {
			push @{$row->{processed_parts}}, {
				proc_part_so   => $row->{proc_part_sp},
				proc_part_file => $row->{proc_part_file},
			};
		} else {
			my ($pp_so, $pp_file)
				= delete @{$row}{qw(proc_part_so proc_part_file)};
			if (defined $pp_so) {
				$row->{processed_parts}
					= [{proc_part_so => $pp_so, proc_part_file => $pp_file}];
			} else {
				$row->{processed_parts} = [ ];
			}
			push @res, $row;
		}
	}

	$sth->finish;
	return \@res
}

sub unarchived_playlist_info {
	my ($self) = @_;

	my $sth = $self->prepare_cached(<<SQL);
       SELECT 'enclosure' AS type
            , 'podcast' AS role
            , info.*
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
UNION ALL
       SELECT 'randommedia' AS type
            , ru.random_use_reason AS role
            , ru.random_no
            , r.random_file
            , NULL AS random_time -- do not have or need...
            , ru.playlist_no
            , ru.playlist_so
            , p.playlist_archived
            , NULL AS first_article_no -- makes no sense
            , r.random_name
            , NULL AS article_when -- maybe someday read tags to get date
            , 'Random Media' AS feed_name
            , NULL AS feed_url
         FROM random_uses ru
         JOIN playlists p ON (ru.playlist_no = p.playlist_no)
         JOIN randoms r ON (ru.random_no = r.random_no)
         WHERE p.playlist_archived IS NULL
 ORDER BY playlist_no, playlist_so
SQL
	$sth->execute;
	my $res = $sth->fetchall_arrayref({});
	$sth->finish;

	return $res;
}

sub _get_migrations {
	my ($self, $db_vers) = @_;
	my $current_vers = 9;

	# Versions:
	# 0 - no db yet
	# 1 - original
	# 2 - store article info, not just enclosures
	# 3 - per-fed, per-time limit; db logs fetches
	# 4 - adds playlist archival
	# 5 - podist_instance (UUID); add some indexes (performance)
	# 6 - usable enclosure view
	# 7 - store random music selections in db
	# 8 - more explicit storage location in db (enclosures & playlists),
	#     support for processed versions
	# 9 - store parallel processing info in db

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
	}

	if ($db_vers > 0 && $db_vers < 4) {    
		push @sql, q{ALTER TABLE playlists ADD playlist_archived INTEGER NULL};
	}

	if ($db_vers > 0 && $db_vers < 8) {
		push @sql, q{ALTER TABLE playlists RENAME TO playlists_v7};
	}

	if ($db_vers < 8) {
		push @sql, <<SQL;
CREATE TABLE playlists (
  playlist_no       INTEGER   NOT NULL PRIMARY KEY,
  playlist_ctime    INTEGER   NOT NULL,
  playlist_archived INTEGER   NULL,
  playlist_file     TEXT      NOT NULL UNIQUE
)
SQL
	}

	if ($db_vers > 0 && $db_vers < 8) {
		push @sql, <<SQL;
INSERT INTO playlists (
    playlist_no, playlist_ctime, playlist_archived,
    playlist_file
  ) SELECT
    playlist_no, playlist_ctime, playlist_archived,
    printf('Playlist %03i.m3u', playlist_no)
  FROM playlists_v7
SQL
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
		push @sql, q{DROP INDEX enclosusures_enclosure_hash};
	}

	if ($db_vers == 1 || $db_vers == 2) {
		push @sql,
			q{ALTER TABLE feeds ADD feed_limit_amount INTEGER NOT NULL DEFAULT 3},
			q{ALTER TABLE feeds ADD feed_limit_period INTEGER NOT NULL DEFAULT 604800};

		push @sql, q{DROP VIEW valids};
		push @sql, q{DROP VIEW oldest_unplayed};
	}

	if ($db_vers < 8) {
		push @sql,
			q{ALTER TABLE feeds ADD feed_proc_profile TEXT NOT NULL DEFAULT 'default'};
	}

	if ($db_vers > 1 && $db_vers < 8) {
		# grumble, can't add a constraint to an existing table... We
		# only need to do this if between 2 and 7, because 1->2 already
		# recreates enclosures.
		push @sql, q{ALTER TABLE enclosures RENAME TO enclosures_v7};
		push @sql, q{DROP INDEX enclosusures_enclosure_hash};
	}

	if ($db_vers < 8) {
		push @sql, <<SQL;
CREATE TABLE enclosures (
  enclosure_no     INTEGER   NOT NULL PRIMARY KEY,
  enclosure_url    TEXT      NOT NULL UNIQUE,
  enclosure_file   TEXT      NULL UNIQUE,
  enclosure_store  TEXT      NULL,
  enclosure_hash   TEXT      NULL,
  enclosure_time   REAL      NULL, -- length in seconds
  enclosure_use    INTEGER   NOT NULL DEFAULT 1,
  playlist_no      INTEGER   NULL REFERENCES playlists,
  playlist_so      INTEGER   NULL,
  UNIQUE(playlist_no, playlist_so),
  CONSTRAINT use_is_bool CHECK (enclosure_use IN (0,1)),
  CONSTRAINT valid_enclusre_store CHECK (
    enclosure_store IN ('pending', 'unusable', 'original', 'archived',
                        'archived-legacy')
  )
)
SQL
	}

	if ($db_vers == 2) {
		# can't add columns in middle in SQLite, and adding to the end
		# confuses tests (because sqldiff shows differences). Podist
		# doesn't care, though.
		push @sql, q{ALTER TABLE articles RENAME TO articles_v2};
		push @sql, q{DROP INDEX articles_feed_title};
	}

	if ($db_vers < 3) {
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
	}

	if ($db_vers == 2) {
		push @sql, <<SQL;
INSERT INTO articles (
    article_no, feed_no, article_when, article_uid, article_title
  ) SELECT
    article_no, feed_no, article_when, article_uid, article_title
  FROM articles_v2
SQL
	}

	if ($db_vers < 2) {
		push @sql, <<SQL;
CREATE TABLE articles_enclosures (
  article_no       INTEGER   NOT NULL REFERENCES articles,
  enclosure_no     INTEGER   NOT NULL REFERENCES enclosures,
  UNIQUE(article_no, enclosure_no)
)
SQL
	}

	if ($db_vers == 0) {
		# no migration needed for new db
	} elsif ($db_vers == 1) {
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
	} elsif ($db_vers < 8) {
		# migrate enclosures_v7
		push @sql, <<SQL;
INSERT INTO enclosures (
	enclosure_no, enclosure_url, enclosure_file, enclosure_hash,
	enclosure_time, enclosure_use, playlist_no, playlist_so
  ) SELECT 
    enclosure_no, enclosure_url, enclosure_file, enclosure_hash,
    enclosure_time, enclosure_use, playlist_no, playlist_so
  FROM enclosures_v7
SQL
	}

	if ($db_vers < 8) {
		push @sql, <<SQL;
CREATE INDEX enclosusures_enclosure_hash ON enclosures(enclosure_hash)
SQL
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
  random_name      TEXT      NOT NULL,
  random_weight    INTEGER   NOT NULL DEFAULT 1000, -- set to 0 to disable
  CONSTRAINT random_weight_is_non_negative CHECK (random_weight >= 0)
)
SQL
	}

	# random_uses was created in v7, changed in v8
	if ($db_vers == 7) {
		push @sql, q{ALTER TABLE random_uses RENAME TO random_uses_v7};
	}
	if ($db_vers < 8) {
		push @sql, <<SQL;
CREATE TABLE random_uses (
  random_no          INTEGER   NOT NULL REFERENCES randoms,
  random_use_reason  TEXT      NOT NULL,
  playlist_no        INTEGER   NOT NULL REFERENCES playlists,
  playlist_so        INTEGER   NOT NULL,
  UNIQUE(playlist_no, playlist_so),
  CONSTRAINT random_uses_valid_reason CHECK(
    random_use_reason IN ('intermission', 'lead-out')
  )
)
SQL
	}
	if ($db_vers == 7) {
		push @sql, <<SQL;
INSERT INTO random_uses
  SELECT random_no, 'intermission', playlist_no, playlist_so
    FROM random_uses_v7
SQL
	}


	if ($db_vers < 8) {
		push @sql, <<SQL;
CREATE TABLE speeches (
  speech_no      INTEGER   NOT NULL PRIMARY KEY,
  playlist_no    INTEGER   NOT NULL REFERENCES playlists,
  playlist_so    INTEGER   NOT NULL,
  speech_event   TEXT      NOT NULL,
  speech_text    TEXT      NOT NULL,
  speech_file    TEXT      NULL,
  speech_store   TEXT      NULL,
  CONSTRAINT valid_speech_store CHECK (
    speech_store IN ('processed', 'archived-processed', 'deleted')
  ),
  UNIQUE(playlist_no, playlist_so)
)
SQL
		push @sql, <<SQL;
CREATE TABLE processed (
  processed_no       INTEGER   NOT NULL PRIMARY KEY,
  enclosure_no       INTEGER   NOT NULL UNIQUE,
  playlist_no        INTEGER   NOT NULL,
  processed_profile  TEXT      NOT NULL,
  processed_duration REAL      NOT NULL,
  processed_parallel INTEGER   NOT NULL DEFAULT 0,
  processed_pid      INTEGER   NULL,
  processed_cputime  REAL      NOT NULL,
  processed_store    TEXT      NOT NULL,
  
  CONSTRAINT process_playlisted_enclosures
    FOREIGN KEY(enclosure_no, playlist_no)
    REFERENCES enclosures(enclosure_no, playlist_no),
  CONSTRAINT processed_valid_store CHECK (
    processed_store IN ('processed', 'archived-processed', 'deleted')
  )
)
SQL
		push @sql, <<SQL;
CREATE TABLE processed_parts (
  processed_no       INTEGER   NOT NULL REFERENCES processed,
  proc_part_so       INTEGER   NOT NULL,
  proc_part_file     TEXT      NOT NULL,

  PRIMARY KEY(processed_no, proc_part_so)
)
SQL
	}

	if ($db_vers == 8) {
		push @sql,
			q{ALTER TABLE processed ADD COLUMN processed_parallel INTEGER NOT NULL DEFAULT 0},
			q{ALTER TABLE processed ADD COLUMN processed_pid INTEGER NULL};
	}


	# finally, set version
	push @sql, q{PRAGMA user_version = 9};

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
