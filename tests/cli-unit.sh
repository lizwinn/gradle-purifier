#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Unit tests of the gradle-purifier command's parsing: the wrapper's
# distribution URL, the path of a URL in the tree of locked downloads,
# Kotlin/Native's download URLs in a build log, and the lockfile entries
# made from the recorder's records. The `cli-unit` flake check runs it
# with the path of the command as its argument; it sources the command
# for its functions.
set -euo pipefail

# shellcheck disable=SC1090 # the command is a build output
source "$1"
set +e

failures=0
expect() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $name: expected [$expected], got [$actual]" >&2
    failures=$((failures + 1))
  fi
}

work=$(mktemp -d)
cd "$work" || exit 1

mkdir -p gradle/wrapper
printf '%s\n' 'distributionBase=GRADLE_USER_HOME' \
  'distributionUrl=https\://services.gradle.org/distributions/gradle-9.1.0-bin.zip' \
  'zipStorePath=wrapper/dists' >gradle/wrapper/gradle-wrapper.properties
expect "distribution URL without escapes" \
  "https://services.gradle.org/distributions/gradle-9.1.0-bin.zip" "$(distribution_url)"

printf 'distributionUrl = https\\://example.org/gradle-8.14.3-all.zip\r\n' >gradle/wrapper/gradle-wrapper.properties
expect "distribution URL with spaces and CRLF" \
  "https://example.org/gradle-8.14.3-all.zip" "$(distribution_url)"

expect "tree path of an https URL" \
  "https/repo.maven.apache.org/maven2/a/b.jar" "$(tree_path https://repo.maven.apache.org/maven2/a/b.jar)"
expect "tree path keeps a port" \
  "http/localhost:8081/r/a.pom" "$(tree_path http://localhost:8081/r/a.pom)"

cat >build.log <<'EOF'
> Task :compileKotlinLinuxX64
Downloading dependency https://download.jetbrains.com/kotlin/native/lldb-4-linux.tar.gz to /k/dependencies/cache/lldb-4-linux.tar.gz
Done.
Downloading dependency https://download.jetbrains.com/kotlin/native/resources/llvm/19-x86_64-linux/llvm-19.tar.gz to /k/cache/llvm-19.tar.gz
Downloading dependency https://download.jetbrains.com/kotlin/native/lldb-4-linux.tar.gz to /k/dependencies/cache/lldb-4-linux.tar.gz
Cannot download a dependency https://download.jetbrains.com/kotlin/native/other.tar.gz: refused
EOF
expect "Kotlin/Native download URLs, each once" \
  "https://download.jetbrains.com/kotlin/native/lldb-4-linux.tar.gz
https://download.jetbrains.com/kotlin/native/resources/llvm/19-x86_64-linux/llvm-19.tar.gz" \
  "$(konan_download_urls build.log)"

printf '%s\t%s\t%s\t%s\n' \
  "https/h/b.jar" "https://h/b.jar" "sha256-B" "https://m/b.jar" \
  "https/h/a.jar" "https://h/a.jar" "sha256-A" "" \
  "https/h/a.jar" "https://h/a.jar" "sha256-A" "" \
  "https/h/org/x/maven-metadata.xml" "inline" "$(printf '<metadata/>\n' | base64 -w0)" "" >records.tsv
printf '%s\t%s\t%s\n' "https/d/gradle.zip" "https://d/gradle.zip" "sha256-D" >>records.tsv
expect "lockfile entries from records" \
  '[{"path":"https/d/gradle.zip","url":"https://d/gradle.zip","mirrors":[],"hash":"sha256-D"},{"path":"https/h/a.jar","url":"https://h/a.jar","mirrors":[],"hash":"sha256-A"},{"path":"https/h/b.jar","url":"https://h/b.jar","mirrors":["https://m/b.jar"],"hash":"sha256-B"},{"path":"https/h/org/x/maven-metadata.xml","contents":"<metadata/>\n"}]' \
  "$(artifacts_json records.tsv | jq -c .)"

: >empty.tsv
expect "no records, no entries" "[]" "$(artifacts_json empty.tsv | jq -c .)"

cd / && rm -rf "$work"
if [ "$failures" -gt 0 ]; then
  echo "$failures command tests failed" >&2
  exit 1
fi
echo "command tests passed"
