#!/usr/bin/env bash
# Install every (non-git) gem from Gemfile.lock, bypassing RubyGems' AND
# Bundler's own remote-fetcher/dependency-resolution code entirely.
#
# Why: both Bundler 1.17.3 (the newest release that still supports Ruby
# 2.1.2 -- Bundler 2.x requires Ruby >= 2.3) and RubyGems 2.2.2 (the version
# bundled with this Ruby) crash with "RuntimeError: can't modify frozen
# Array/Object" when their fetchers talk to rubygems.org's current
# Marshal/compact-index/dependency-API responses. Reproduced outside both of
# them entirely (net/http + Marshal.load on today's specs.4.8.gz also
# raises it), so this is a real 2014/2018-era-code vs. modern-rubygems.org
# incompatibility (almost certainly frozen strings/arrays that old code
# assumes it can mutate in place), not network flakiness. `gem install
# bundler`/`gem install rspec` appeared to "work around" it earlier by luck
# -- some name/version lookups happen to take a lighter-weight path that
# doesn't trigger the bug, but most don't (confirmed: 78/172 gems failed
# this way on the first pass, including a batch of hard segfaults).
#
# Fix: never ask RubyGems to look anything up remotely. Download each
# locked gem's exact .gem file by its known static URL
# (https://rubygems.org/downloads/<name>-<version>.gem -- a plain HTTP GET,
# no Marshal parsing involved) and install from that local file with
# `gem install --local`, which does no network access or remote spec
# resolution at all.
#
# Strategy: every exact name+version pinned in Gemfile.lock, installed with
# --ignore-dependencies (the lockfile IS the fully resolved graph, so
# per-gem dependency resolution is redundant and would just risk picking
# different versions than what's locked). Afterward, `bundle install
# --local` can verify/link everything with zero network calls.
#
# libv8/therubyracer are deliberately skipped (see gem-list.filtered.txt) --
# they're only needed by the Gemfile's :production group (asset
# precompilation), which `--without production` already excludes, and
# libv8's bundled ancient V8 C++ source is a well-known pain to compile.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GEM_LIST="$HERE/gem-list.filtered.txt"
INSTALL_DIR="$REPO_ROOT/apptainer/bundle/ruby/2.1.0"
CACHE_DIR="$INSTALL_DIR/cache"
LOG="$HERE/gem-install.log"

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"
: > "$LOG"

# So extconf.rb scripts (nokogiri needing mini_portile, etc.) can `require`
# gems already installed earlier in this same loop.
export GEM_HOME="$INSTALL_DIR"
export GEM_PATH="$INSTALL_DIR"

total=$(wc -l < "$GEM_LIST")
n=0
fail=0

while read -r name version; do
    n=$((n + 1))
    if gem list -i "$name" -v "$version" --local --install-dir "$INSTALL_DIR" >/dev/null 2>&1; then
        echo "[$n/$total] SKIP (already installed) $name $version" | tee -a "$LOG"
        continue
    fi

    gemfile="$CACHE_DIR/${name}-${version}.gem"
    if [ ! -s "$gemfile" ]; then
        echo "[$n/$total] Downloading $name $version..." | tee -a "$LOG"
        if ! curl -fsSL -o "$gemfile" "https://rubygems.org/downloads/${name}-${version}.gem" 2>>"$LOG"; then
            echo "[$n/$total] FAILED (download) $name $version" | tee -a "$LOG"
            rm -f "$gemfile"
            fail=$((fail + 1))
            continue
        fi
    fi

    echo "[$n/$total] Installing $name $version..." | tee -a "$LOG"
    if ! gem install "$gemfile" --local \
        --install-dir "$INSTALL_DIR" \
        --ignore-dependencies --no-document >>"$LOG" 2>&1; then
        echo "[$n/$total] FAILED (install) $name $version" | tee -a "$LOG"
        fail=$((fail + 1))
    fi
done < "$GEM_LIST"

echo "Done. $fail failures out of $total gems." | tee -a "$LOG"
exit $((fail > 0 ? 1 : 0))
