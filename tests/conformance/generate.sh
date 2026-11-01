#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the lockfiles of the conformance checks (lockfiles.nix) beside
# this script. Run it after relocking the Java library fixture.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(nix-build --no-out-link "$here/generate.nix")
for file in "$out"/*.lock.json; do
  install -m 0644 "$file" "$here/$(basename "$file")"
done
