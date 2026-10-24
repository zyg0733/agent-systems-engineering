#!/bin/sh
# Build a project-local server from the official, checksum-verified source.
set -eu
lab_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pg_version=18.6
pg_prefix="$lab_root/.runtime/postgres/$pg_version"
pg_downloads="$lab_root/.runtime/downloads"
pg_source_root="$lab_root/.runtime/sources"
pg_archive="postgresql-$pg_version.tar.bz2"
mkdir -p "$pg_downloads" "$pg_source_root"

if [ ! -x "$pg_prefix/bin/postgres" ]; then
  curl --fail --location --retry 2 --connect-timeout 20 --max-time 600 \
    "https://ftp.postgresql.org/pub/source/v$pg_version/$pg_archive" -o "$pg_downloads/$pg_archive"
  curl --fail --location --retry 2 --connect-timeout 20 --max-time 60 \
    "https://ftp.postgresql.org/pub/source/v$pg_version/$pg_archive.sha256" -o "$pg_downloads/$pg_archive.sha256"
  (cd "$pg_downloads" && shasum -a 256 -c "$pg_archive.sha256")
  tar xjf "$pg_downloads/$pg_archive" -C "$pg_source_root"
  cd "$pg_source_root/postgresql-$pg_version"
  ./configure --prefix="$pg_prefix" --without-icu --without-readline --without-zlib > "$pg_downloads/postgres-configure.log" 2>&1
  make -j4 > "$pg_downloads/postgres-build.log" 2>&1
  make install > "$pg_downloads/postgres-install.log" 2>&1
fi

"$pg_prefix/bin/postgres" --version
echo 'Ready. Run: ./scripts/postgres start'
