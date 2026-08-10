#!/usr/bin/env bash
# Drop into a shell (or run a command) inside the salva-dev container, with
# the repo bound in place and gems/bundle cached outside the image so they
# survive container rebuilds.
#
# Usage:
#   apptainer/dev-shell.sh                 # interactive shell
#   apptainer/dev-shell.sh bundle install --without production
#   apptainer/dev-shell.sh bundle exec rspec spec/lib/metadata_import_spec.rb

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SIF="$HERE/salva-dev.sif"
BUNDLE_HOME_HOST="$REPO_ROOT/apptainer/bundle"
SOCKDIR_HOST="$REPO_ROOT/apptainer/pgsock"

command -v module >/dev/null 2>&1 && module load singularity >/dev/null 2>&1 || true

mkdir -p "$BUNDLE_HOME_HOST" "$SOCKDIR_HOST"

exec apptainer exec \
    --bind "$REPO_ROOT:$REPO_ROOT" \
    --bind "$SOCKDIR_HOST:/opt/pgsock" \
    --env "BUNDLE_PATH=$BUNDLE_HOME_HOST" \
    --env "GEM_PATH=/opt/ruby-2.1.2/lib/ruby/gems/2.1.0:$BUNDLE_HOME_HOST/ruby/2.1.0" \
    --env "GIT_CONFIG_COUNT=1" \
    --env "GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf" \
    --env "GIT_CONFIG_VALUE_0=git://github.com/" \
    --env "PATH=$HERE/bin:/opt/ruby-2.1.2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --pwd "$REPO_ROOT" \
    "$SIF" "${@:-bash}"
