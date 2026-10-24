#!/bin/sh
# Project-local adaptation of the official Elixir install script's macOS URLs.
set -eu

lab_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir="$lab_root/.runtime"
otp_version=28.4
elixir_version=1.20.4

case "$(uname -sm)" in
  'Darwin arm64') runtime_target=aarch64-apple-darwin ;;
  'Darwin x86_64') runtime_target=x86_64-apple-darwin ;;
  *)
    echo 'This optional bootstrap supports macOS. Install the pinned versions with your version manager on other platforms.' >&2
    exit 1
    ;;
esac

otp_dir="$runtime_dir/otp/$otp_version"
elixir_dir="$runtime_dir/elixir/$elixir_version-otp-28"
mkdir -p "$runtime_dir/downloads"

if [ ! -x "$otp_dir/bin/erl" ]; then
  otp_archive="$runtime_dir/downloads/otp-$runtime_target.tar.gz"
  curl --fail --location --retry 2 --connect-timeout 20 --max-time 1200 \
    "https://github.com/erlef/otp_builds/releases/download/OTP-$otp_version/otp-$runtime_target.tar.gz" \
    --output "$otp_archive"
  mkdir -p "$otp_dir"
  tar xzf "$otp_archive" -C "$otp_dir"
fi

if [ ! -x "$elixir_dir/bin/elixir" ]; then
  elixir_archive="$runtime_dir/downloads/elixir-$elixir_version-otp-28.zip"
  curl --fail --location --retry 2 --connect-timeout 20 --max-time 1200 \
    "https://builds.hex.pm/builds/elixir/v$elixir_version-otp-28.zip" \
    --output "$elixir_archive"
  mkdir -p "$elixir_dir"
  unzip -q -o "$elixir_archive" -d "$elixir_dir"
fi

PATH="$elixir_dir/bin:$otp_dir/bin:$PATH"
export PATH
elixir --version
echo 'Ready. Run: ./scripts/mix check'
