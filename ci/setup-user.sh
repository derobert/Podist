#!/bin/sh
set -ex

mkdir -p .cache/lfs
git config --global --add 'lfs.storage' "$(pwd)/.cache/lfs"
git-lfs install
git submodule init
git submodule update
mkdir -p artifacts/tap
t/make-test-feeds
