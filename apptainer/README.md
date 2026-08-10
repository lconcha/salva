# SALVA dev/test container (apptainer)

A full-stack local dev/test environment for SALVA: Ruby 2.1.2, Rails 3.2.21,
and PostgreSQL, matching the production stack described in the repo's
`CLAUDE.md`. Lets you run the offline normaliser specs *and* smoke-test real
Rails code (controllers, models, migrations) without touching the production
server.

Nothing app-specific is baked into the image — gems are installed at dev
time into a bind-mounted path (`apptainer/bundle/`) so they survive image
rebuilds, and the Postgres data directory (`apptainer/pgdata/`) is likewise
outside the image.

## Prerequisites

- `apptainer`/`singularity` on `PATH`. On this machine that requires
  `module load singularity` first (not on `PATH` by default).
- Outbound HTTPS to: `deb.debian.org`, `cache.ruby-lang.org`,
  `www.openssl.org`, `rubygems.org`, `github.com`. **Plain `git://` is
  blocked on this network** — see gotcha #4 below.

## One-time setup

```bash
module load singularity

# 1. Build the image (~15-20 min: compiles OpenSSL 1.0.2 + Ruby 2.1.2 from source)
apptainer build --fakeroot apptainer/salva-dev.sif apptainer/salva-dev.def

# 2. Install every gem pinned in Gemfile.lock (~5-10 min)
apptainer/dev-shell.sh apptainer/install-gems.sh
apptainer/dev-shell.sh bundle install --local --without production

# 3. Local-only config (gitignored, copy from the tracked .example files)
cp config/database.yml.example config/database.yml   # then edit: user "salva", no password, host 127.0.0.1
cp config/site.yml.example config/site.yml
cp config/mail.yml.example config/mail.yml

# 4. Postgres
apptainer/dev-db.sh init
apptainer/dev-db.sh start
apptainer/dev-db.sh createdb salva_dev
apptainer/dev-db.sh createdb salva_test

# 5. Schema
apptainer/dev-shell.sh bundle exec rake db:migrate
```

## Day to day

```bash
apptainer/dev-shell.sh                                              # interactive shell in the container
apptainer/dev-shell.sh bundle exec rspec spec/lib/metadata_import_spec.rb
apptainer/dev-shell.sh bundle exec rails console
apptainer/dev-shell.sh bundle exec rails runner "puts Article.count"

apptainer/dev-db.sh status
apptainer/dev-db.sh psql
apptainer/dev-db.sh stop
```

`apptainer/dev-shell.sh` binds the repo, sets `PATH`/`GEM_PATH`/`BUNDLE_PATH`
correctly, and rewrites `git://` to `https://`. Always use it (or
`dev-db.sh`) rather than calling `apptainer exec` directly.

## Known gotchas (why the setup looks the way it does)

1. **Base OS is Debian 12, not a period-accurate old Debian.** This host's
   `apptainer build --fakeroot` needs glibc >= 2.34 for the injected `faked`
   binary to run inside the build sandbox, which rules out anything older.
2. **Ruby 2.1.2 and OpenSSL 1.0.2u are compiled from source** in
   `salva-dev.def`. Ruby 2.1's `net/https` predates the OpenSSL 1.1/3.x API
   and won't build against Debian 12's stock OpenSSL 3.
3. **`SSL_CERT_FILE`** is set explicitly (build time and `%environment`) to
   Debian's CA bundle — the custom-built OpenSSL doesn't know about it by
   default, which broke `gem install bundler` until fixed.
4. **`git://` is blocked outbound on this network.** `dev-shell.sh` rewrites
   it to `https://` via `GIT_CONFIG_*` env vars. The two git-sourced gems
   (`scope_by_fuzzy`, `lazy_high_charts`) are additionally pinned with an
   explicit `:ref` in the `Gemfile`, matching the revision already recorded
   in `Gemfile.lock` — without it, a fresh clone floats to current `master`,
   which can violate the Gemfile's version constraint.
5. **Postgres must run as a persistent `apptainer instance`, never a
   one-shot `apptainer exec`.** `pg_ctl` daemonizes (double-forks) the real
   `postgres` process, which then outlives whatever launched it; if that was
   a one-shot exec, the SIF's squashfs mount backing the postgres
   binary/libs disappears once the exec's process exits, and the server
   SIGBUSes a few seconds later. `dev-db.sh start` uses `apptainer instance
   start` for exactly this reason. Also needed `dynamic_shared_memory_type =
   sysv` and `shared_memory_type = sysv` in `postgresql.conf` — POSIX shm
   segments in `/dev/shm` were *also* SIGBUS-y in this container.
6. **Bundler 1.17.3 (the newest release still supporting Ruby 2.1.2) and
   RubyGems 2.2.2 (bundled with it) both crash** with `RuntimeError: can't
   modify frozen Array` / `frozen Object` on essentially any live lookup
   against today's rubygems.org — confirmed with a standalone
   `net/http` + `Marshal.load` reproduction outside both tools entirely, so
   it's a real 2014/2018-era-code vs. modern-service incompatibility, not
   network flakiness, and not fixable by upgrading Bundler (2.x drops Ruby
   2.1 support). Worked around by never letting either tool do a remote
   lookup: `install-gems.sh` downloads every locked gem's raw `.gem` file by
   its static URL (`https://rubygems.org/downloads/<name>-<version>.gem`,
   a plain HTTP GET, no Marshal parsing) and installs each with `gem install
   --local`. `bundle install --local` afterward only verifies/links what's
   already there, using `bundle config cache_path` pointed at the same
   download cache — zero network calls, no crash.
7. **`rmagick` needs the old `Magick-config` tool**, which Debian 12 no
   longer ships (ImageMagick moved to pkg-config-only). Shimmed at
   `apptainer/bin/Magick-config`, delegating to `pkg-config MagickWand`; put
   on `PATH` by `dev-shell.sh`.
8. **`rake` is pinned to `10.4.2`** explicitly in the `Gemfile`. Left
   unconstrained, Bundler's resolver picks the newest rake (13.x), which
   requires Ruby >= 2.3.
9. **`Gemfile.lock`'s `rtf_rails` entry was missing its spec stanza** in the
   version this fork inherited — pre-existing corruption, unrelated to this
   container work (`rtf_rails (= 0.0.1)` was listed in `DEPENDENCIES` with
   no matching `GEM/specs` entry). Repaired directly (added the missing
   stanza, using `rtf_rails`'s real dependencies from rubygems.org) rather
   than deleting and regenerating the whole lockfile, which would route
   through the broken fetcher in gotcha #6 anyway.
10. **ActiveRecord 3.2's `postgresql_adapter.rb`** temporarily sets
    `client_min_messages` to `'panic'` while enabling standard-conforming
    strings — a value modern Postgres (9.6+) no longer accepts for that
    parameter. Patched to `'error'` directly in the installed gem under
    `apptainer/bundle/gems/activerecord-3.2.21/...` (an ephemeral,
    gitignored build artifact — this does not touch the tracked app code or
    any gem source that ships to production).
11. **`libv8`, `therubyracer`, and `SystemTimer` are deliberately skipped**
    in `install-gems.sh`. The first two are only needed by the Gemfile's
    `:production` group (asset-pipeline JS runtime), already excluded via
    `--without production`, and `libv8`'s bundled ancient V8 C++ source is a
    well-known pain to compile on a modern toolchain. `SystemTimer` is
    `:platforms => :ruby_18` only and irrelevant (and won't compile) on
    Ruby 2.1.2.
12. **`config/database.yml`, `config/site.yml`, `config/mail.yml`** are
    gitignored local config, not part of the handoff package — copy from
    the tracked `.example` files.
13. **The `log` symlink is intentionally tracked** and points at a
    Capistrano production path (`/home/deployer/apps/salva/shared/log`)
    that doesn't exist here. Don't "fix" it — Rails falls back to logging
    on STDERR, which is fine for dev/test.

## A note on background work

Building this involved a lot of long-running commands. Apptainer instances
(like the Postgres instance `dev-db.sh` manages) survive session/SSH
disconnects fine. Plain background shell commands do not always — they can
get killed when the driving agent/session process is torn down, even though
the machine itself never went anywhere. If you're resuming interrupted work,
check whatever log file the command was writing to rather than assuming it
finished.
