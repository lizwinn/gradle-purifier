#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Renews the lockfiles of the test fixtures with the gradle-purifier
# command of this checkout. It needs the network.
#
#   tests/relock-fixtures.sh            locks the fixtures whose build
#                                       definition changed
#   tests/relock-fixtures.sh --relock   locks every fixture
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command=$(nix build --no-link --print-out-paths "$root#gradle-purifier")/bin/gradle-purifier

for fixture in "$root"/tests/fixtures/*/; do
  echo "== ${fixture#"$root"/}" >&2
  (cd "$fixture" && "$command" lock "$@")
done
