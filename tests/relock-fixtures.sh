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
  # Kotlin/Native's compiler 2.2 crashes on JDK 21, so its fixture locks
  # on JDK 17.
  java=()
  case $(basename "$fixture") in
    kotlin-native) java=(--java 17) ;;
  esac
  (cd "$fixture" && "$command" lock "${java[@]}" "$@")
done
