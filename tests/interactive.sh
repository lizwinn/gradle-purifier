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
fixtures=(java-library kotlin-app)
# The Kotlin/Native fixture's lock holds the toolchain of x86_64-linux.
[ "$(uname -m)" = x86_64 ] && fixtures+=(kotlin-native)
for fixture in "${fixtures[@]}"; do
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
# nix-build names the link to the package's `maven` output greeting-maven.
built=$work/java-library/.gradle/purifier/published/greeting-maven/nix-support/artifacts/maven
for key in greeting.jar greeting-sources.jar module; do
  case $key in
    module) file=greeting-1.0.0.module ;;
    *) file=${key/greeting/greeting-1.0.0} ;;
  esac
  [ -f "$published/$file" ] || fail "java-library: publish sent no $file"
  [ -f "$built/$key" ] || fail "java-library: the Nix package holds no $key"
  cmp -s "$published/$file" "$built/$key" || fail "java-library: the published $file is not the one Nix built"
done
[ -f "$published/greeting-1.0.0.pom" ] || fail "java-library: publish sent no POM"
if [ -d "$work/java-library/build/classes" ]; then
  echo "$output"
  fail "java-library: publish compiled the project"
fi

echo "== java-library: an IDE imports the build offline through the tooling API" >&2
# `gradle-purifier ide` sets up the Gradle user home the IDE uses. The
# import then runs the way Buildship and jdtls import a build, with the
# distribution that `ide` links.
output=$(cd "$work/java-library" && GRADLE_USER_HOME="$work/ide-home" "$command" ide 2>&1) || { echo "$output"; fail "java-library: gradle-purifier ide failed"; }
prefetch() {
  nix --extra-experimental-features nix-command store prefetch-file --json "$1" | jq -r '.storePath'
}
tooling=$(prefetch https://repo.gradle.org/gradle/libs-releases/org/gradle/gradle-tooling-api/9.1.0/gradle-tooling-api-9.1.0.jar)
slf4j=$(prefetch https://maven-central.storage-download.googleapis.com/maven2/org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar)
jdk=$work/java-library/.gradle/purifier/jdk-21/lib/openjdk
"$jdk/bin/javac" -cp "$tooling" -d "$work/tooling" "$root/tests/ToolingImport.java"
output=$("$jdk/bin/java" -cp "$work/tooling:$tooling:$slf4j" ToolingImport \
  "$work/java-library" "$work/java-library/.gradle/purifier/gradle" "$work/ide-home" 2>&1) || { echo "$output"; fail "java-library: the IDE import failed"; }
grep -q "$(printf '^commons-lang3-3.17.0.jar\tcommons-lang3-3.17.0-sources.jar$')" <<<"$output" \
  || { echo "$output"; fail "java-library: the IDE import has no commons-lang3 with its sources"; }
cache=$work/ide-home/caches/modules-2/files-2.1
if [ -d "$cache" ] && [ -n "$(ls -A "$cache")" ]; then
  fail "java-library: the IDE import downloaded into the Gradle cache: $(ls "$cache")"
fi

echo "== kotlin-app: build and run" >&2
output=$(run kotlin-app build :app:run) || { echo "$output"; fail "kotlin-app: build failed"; }
# The JVM's notice of JAVA_TOOL_OPTIONS on stderr may share a line with
# the greeting.
grep -q 'Hello, Nix!$' <<<"$output" || { echo "$output"; fail "kotlin-app: the app did not greet"; }
expect_no_downloads kotlin-app

if [ "$(uname -m)" = x86_64 ]; then
  echo "== kotlin-native: build, test and run on the locked toolchain" >&2
  output=$(run kotlin-native build runReleaseExecutableLinuxX64) || { echo "$output"; fail "kotlin-native: build failed"; }
  grep -q 'Hello, Nix!$' <<<"$output" || { echo "$output"; fail "kotlin-native: the executable did not greet"; }
  expect_no_downloads kotlin-native
fi

# Each mistake below makes the command fail with a message that says what
# is wrong and what to run. Each works on a fresh copy of java-library.
mistake() {
  rm -rf "$work/mistake"
  cp -r "$work/java-library" "$work/mistake"
  rm -rf "$work/mistake/.gradle" "$work/mistake/build"
}

echo "== a malformed lockfile" >&2
mistake
echo '{ "version": 1, ' >"$work/mistake/gradle-purifier.lock.json"
if output=$(run mistake build); then fail "a malformed lockfile ran"; fi
grep -q 'is not a gradle-purifier lockfile.*lock --relock' <<<"$output" || { echo "$output"; fail "no message for a malformed lockfile"; }

echo "== a tampered hash" >&2
mistake
# The tampered entry downloads again, so it is the small file from
# nodejs.org, which serves the test without a rate limit.
jq '(.artifacts[] | select(.path | endswith("SHASUMS256.txt")) | .hash) = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
  "$work/java-library/gradle-purifier.lock.json" >"$work/mistake/gradle-purifier.lock.json"
if output=$(run mistake build); then fail "a tampered hash ran"; fi
grep -q 'hash mismatch' <<<"$output" || { echo "$output"; fail "Nix reported no hash mismatch"; }
grep -q 'restore the lockfile.*lock --relock' <<<"$output" || { echo "$output"; fail "no message for a tampered hash"; }

echo "== an entry missing from the lockfile" >&2
mistake
jq 'del(.artifacts[] | select(.path | endswith("commons-text-1.13.0.jar")))' \
  "$work/java-library/gradle-purifier.lock.json" >"$work/mistake/gradle-purifier.lock.json"
if output=$(run mistake build); then fail "a lockfile without an entry the build needs ran"; fi
grep -q 'commons-text' <<<"$output" || { echo "$output"; fail "Gradle did not name the missing file"; }
grep -q 'gradle-purifier lock --relock' <<<"$output" || { echo "$output"; fail "no message for a missing entry"; }

echo "== kotlin-app: a changed build definition falls back to ./gradlew" >&2
echo '// changed' >>"$work/kotlin-app/app/build.gradle.kts"
if output=$(run kotlin-app build); then
  fail "kotlin-app: the command ran with a stale lockfile"
fi
grep -q 'the build definition changed' <<<"$output" || { echo "$output"; fail "kotlin-app: no stale-lock warning"; }
grep -q 'no ./gradlew' <<<"$output" || { echo "$output"; fail "kotlin-app: no fallback to ./gradlew"; }

echo "interactive tests passed" >&2
