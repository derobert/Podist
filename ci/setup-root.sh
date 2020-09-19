#!/bin/sh
set -ex

is_stretch() { ( . /etc/os-release && [ 'stretch' = "$VERSION_CODENAME" ] ) }

rm -f /etc/apt/apt.conf.d/docker-clean

if [ -n "$GITLAB_CI" ]; then
	# whole thing runs as root, so don't need to worry about the
	# permissions on .cache ...
	mkdir -p .cache/apt
	printf 'Dir::Cache::Archives "%s";\n' "$(pwd)/.cache/apt" > /etc/apt/apt.conf.d/local-cachedir
fi

if is_stretch; then
	printf 'On stretch, adding backports for git-lfs.\n' >&2
	printf '%s\n' 'deb http://deb.debian.org/debian stretch-backports main' >> /etc/apt/sources.list
else
	printf 'Not stretch, backports not required.\n' >&2
fi

apt-get update
apt-get dist-upgrade -y
apt-get install -y ffmpeg normalize-audio jq lame
apt-get install -y git
apt-get install -y sqlite3

if is_stretch; then
	apt-get install -y -t stretch-backports git-lfs
else 
	apt-get install -y git-lfs
fi

apt-get install -y perl perl-doc libconfig-general-perl libdbi-perl libdbd-sqlite3-perl libfile-slurp-perl libfile-slurper-perl libipc-run3-perl liblist-moreutils-perl libscalar-list-utils-perl liblog-log4perl-perl libwww-perl libmp3-info-perl libnumber-format-perl libogg-vorbis-header-pureperl-perl libterm-size-any-perl libtext-asciitable-perl libtext-csv-perl liburi-perl libxml-feedpp-perl libdata-dump-perl libtest-exception-perl libmoose-perl libipc-run-perl libjson-maybexs-perl libnamespace-autoclean-perl libclone-perl libhash-merge-perl libtest-deep-perl libuuid-perl libtap-harness-archive-perl libdatetime-perl libfile-pushd-perl libmoosex-params-validate-perl libclone-perl libparallel-forkmanager-perl
apt-get install -y libdevel-cover-perl libpod-coverage-perl libtemplate-perl libppi-html-perl libjson-xs-perl # coverage modules
apt-get install -y festival festvox-kallpc16k sox libsox-fmt-mp3
