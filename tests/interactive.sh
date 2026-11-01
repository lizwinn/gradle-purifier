#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the interactive mode of the gradle-purifier command outside the
# sandbox, with Gradle's network cut off: every JVM gets a proxy that
# refuses. On a copy of each fixture, with an empty Gradle user home, the
# build and its tests must run from the locked downloads, the application
# must run, Gradle's own download cache must stay empty, and a change to
# the build definition must make the command fall back to ./gradlew.
#
# It needs Nix, to fetch the locked downloads.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command=$(nix build --no-link --print-out-paths "$root#gradle-purifier")/bin/gradle-purifier
work=$(mktemp -d "${TMPDIR:-/tmp}/gradle-purifier-interactive.XXXXXX")
trap 'rm -rf "$work"' EXIT

export XDG_CACHE_HOME=$work/cache
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=9 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=9 -Djava.io.tmpdir=${TMPDIR:-/tmp}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Runs the command in the copy of fixture $1 with a fresh Gradle user
# home of its own, and prints Gradle's output. A subcommand ($2, `lock` or
# `publish`) stays first. Gradle runs without a daemon, so nothing writes
# into the test's directory once the test ends.
run() {
  local fixture=$1
  shift
  local args=("$@")
  case ${args[0]} in
    publish) args=(publish --no-daemon "${args[@]:1}") ;;
    *) args=(--no-daemon "${args[@]}") ;;
  esac
  (cd "$work/$fixture" && GRADLE_USER_HOME="$work/$fixture-home" "$command" "${args[@]}" 2>&1)
}

# The module cache of Gradle holds what it downloads; a build that reads
# only the locked downloads (file: repositories) leaves it empty.
expect_no_downloads() {
  local cache=$work/$1-home/caches/modules-2/files-2.1
  if [ -d "$cache" ] && [ -n "$(ls -A "$cache")" ]; then
    fail "$1: Gradle downloaded into its cache: $(ls "$cache")"
  fi
}

# Each copy holds the files of the fixture that git tracks, as a clean
# checkout does.
for fixture in java-library kotlin-app; do
  (cd "$root/tests/fixtures/$fixture" && git ls-files -z) | while IFS= read -r -d '' file; do
    mkdir -p "$work/$fixture/$(dirname "$file")"
    cp "$root/tests/fixtures/$fixture/$file" "$work/$fixture/$file"
  done
done

echo "== java-library: build" >&2
output=$(run java-library build) || { echo "$output"; fail "java-library: build failed"; }
grep -q 'BUILD SUCCESSFUL' <<<"$output" || fail "java-library: no successful build"
expect_no_downloads java-library

echo "== java-library: publish what Nix built" >&2
rm -rf "$work/java-library/build"
output=$(run java-library publish publishMavenPublicationToLocalRepository) || { echo "$output"; fail "java-library: publish failed"; }
published=$work/java-library/build/local-repository/example/greeting/1.0.0
built=$work/java-library/.gradle/purifier/published/greeting/nix-support/artifacts/maven
for key in greeting.jar greeting-sources.jar module; do
  case $key in
    module) file=greeting-1.0.0.module ;;
    *) file=${key/greeting/greeting-1.0.0} ;;
  esac
  [ -f "$published/$file" ] || fail "java-library: publish sent no $file"
  cmp -s "$published/$file" "$built/$key" || fail "java-library: the published $file is not the one Nix built"
done
[ -f "$published/greeting-1.0.0.pom" ] || fail "java-library: publish sent no POM"
if [ -d "$work/java-library/build/classes" ]; then
  echo "$output"
  fail "java-library: publish compiled the project"
fi

echo "== kotlin-app: build and run" >&2
output=$(run kotlin-app build :app:run) || { echo "$output"; fail "kotlin-app: build failed"; }
grep -q '^Hello, Nix!$' <<<"$output" || { echo "$output"; fail "kotlin-app: the app did not greet"; }
expect_no_downloads kotlin-app

echo "== kotlin-app: a changed build definition falls back to ./gradlew" >&2
echo '// changed' >>"$work/kotlin-app/app/build.gradle.kts"
if output=$(run kotlin-app build); then
  fail "kotlin-app: the command ran with a stale lockfile"
fi
grep -q 'the build definition changed' <<<"$output" || { echo "$output"; fail "kotlin-app: no stale-lock warning"; }
grep -q 'no ./gradlew' <<<"$output" || { echo "$output"; fail "kotlin-app: no fallback to ./gradlew"; }

echo "interactive tests passed" >&2
