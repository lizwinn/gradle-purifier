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
# The lockfile keeps a file entry's URL and hash only; Nix derives its path
# and its mirrors.
expect "lockfile entries from records" \
  '[{"url":"https://d/gradle.zip","hash":"sha256-D"},{"url":"https://h/a.jar","hash":"sha256-A"},{"url":"https://h/b.jar","hash":"sha256-B"},{"path":"https/h/org/x/maven-metadata.xml","contents":"<metadata/>\n"}]' \
  "$(artifacts_json records.tsv | jq -c .)"

printf '{"b":1,"a":[2,"x\\n"],"contentHash":"old"}' >lock.json
expect "the content hash is SHA-256 of the sorted JSON without contentHash" \
  "sha256:$(printf '{"a":[2,"x\\n"],"b":1}' | sha256sum | cut -d ' ' -f 1)" \
  "$(content_hash lock.json)"

: >empty.tsv
expect "no records, no entries" "[]" "$(artifacts_json empty.tsv | jq -c .)"

# The lock pins the version listings of its lockfile, except those of the
# packages an update names.
lockfile=$work/pinned.lock.json
# shellcheck disable=SC2154 # the command sets lock_version
jq -n --argjson version "$lock_version" '{version: $version, artifacts: [
  {path: "https/h/org/a/lib/maven-metadata.xml", contents: "A"},
  {path: "https/h/org/a/other/maven-metadata.xml", contents: "B"},
  {path: "https/h/com/c/tool/maven-metadata.xml", contents: "C"},
  {url: "https://h/org/a/lib/1/lib-1.jar", hash: "sha256-J"}]}' >"$lockfile"
expect "every listing is pinned" \
  "https/h/org/a/lib/maven-metadata.xml QQ== https/h/org/a/other/maven-metadata.xml Qg== https/h/com/c/tool/maven-metadata.xml Qw==" \
  "$(pinned_listings | tr '\t\n' '  ' | sed 's/ $//')"
expect "an update of one package leaves its listing out" \
  "https/h/org/a/other/maven-metadata.xml https/h/com/c/tool/maven-metadata.xml" \
  "$(pinned_listings org.a:lib | cut -f 1 | tr '\n' ' ' | sed 's/ $//')"
expect "an update of a group leaves out the listings of the group" \
  "https/h/com/c/tool/maven-metadata.xml" \
  "$(pinned_listings 'org.a:*' | cut -f 1)"
jq '.version = 0' "$lockfile" >old.lock.json
lockfile=$work/old.lock.json
expect "a lockfile of another format version pins nothing" "" "$(pinned_listings)"

cd / && rm -rf "$work"
if [ "$failures" -gt 0 ]; then
  echo "$failures command tests failed" >&2
  exit 1
fi
echo "command tests passed"
