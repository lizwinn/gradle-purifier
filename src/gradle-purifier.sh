# SPDX-License-Identifier: MIT
#
# The gradle-purifier command. pkgs/gradle-purifier substitutes the @…@
# names and runs it as a writeShellApplication, which sets errexit,
# nounset and pipefail.
#
#   gradle-purifier lock [--relock] [-- <gradle arguments>]
#       writes gradle-purifier.lock.json at the root of the build in the
#       current directory
#   gradle-purifier publish [<gradle arguments>]
#       publishes what Nix built from the lockfile, through the build's
#       own publish tasks
#   gradle-purifier <gradle arguments>
#       runs Gradle on the locked downloads, offline, when the lockfile is
#       current; otherwise it runs ./gradlew
#
# The command runs the Gradle distribution that
# gradle/wrapper/gradle-wrapper.properties names, as ./gradlew would.

# A failure inside $(…) stops the command too.
shopt -s inherit_errexit

lib=@lib@
recorder=@recorder@
default_java=@java@
lock_version=@lockVersion@
# The nixpkgs whose package set `publish` builds the packages with, and
# the Kotlin/Native toolchain of the interactive mode.
nixpkgs=@nixpkgs@
# What Kotlin/Native's JNI libraries need, and the dynamic linker the
# programs it links name, from that package set.
konan_library_path=@konanLibraryPath@
dynamic_linker=@dynamicLinker@

lockfile=gradle-purifier.lock.json
portal=https/plugins.gradle.org/m2
# The hosts Kotlin/Native downloads its toolchain from: its
# dependenciesUrl, and the CDN that redirects to.
konan_hosts=(download.jetbrains.com download-cdn.jetbrains.com)

die() {
  echo "gradle-purifier: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  gradle-purifier lock [--relock] [--java <major>] [-- <gradle arguments>]
      Writes gradle-purifier.lock.json: every file the build downloads,
      by URL and hash, and the projects the Nix builder makes packages of.
      The lock is renewed only when the build definition changed, unless
      --relock is given. Gradle runs on JAVA_HOME, on nixpkgs' JDK of the
      major version --java names, or on the command's JDK 21. The gradle
      arguments are recorded in the lock and passed to every Gradle run of
      the lock.
  gradle-purifier publish [<gradle arguments>]
      Builds every publishing project with Nix from the lockfile, then
      runs the build's publish tasks (publish, unless gradle arguments
      name others) with the files Nix built in place of the ones Gradle
      would make. The build's repositories and credentials apply.
  gradle-purifier ide
      Makes the builds an IDE runs through the Gradle tooling API read the
      locked downloads: realizes the lockfile and installs an init script
      in the init.d of the Gradle user home. Run it again after each lock.
  gradle-purifier <gradle arguments>
      Runs Gradle offline on the locked downloads when the lockfile is
      current, and ./gradlew otherwise.

publish and the runs on the locked downloads use nixpkgs' JDK of the
Java major version the lock was made with, or the JDK that
GRADLE_PURIFIER_JAVA_HOME names.
EOF
}

# The home of nixpkgs' headless JDK of the major version $1, built with
# Nix (GC root in .gradle/purifier).
nixpkgs_jdk() {
  local out
  out=$(nix-build --quiet --out-link "$PWD/.gradle/purifier/jdk-$1" "$nixpkgs" \
    -A "javaPackages.compiler.openjdk$1.headless") || die "nixpkgs has no headless OpenJDK $1"
  printf '%s/lib/openjdk' "$out"
}

# The JDK to run Gradle on: JAVA_HOME when it is set; otherwise nixpkgs'
# JDK of the major version $1 when it is given, and the command's own JDK
# when it is not.
java_home() {
  if [ -n "${JAVA_HOME:-}" ]; then
    echo "$JAVA_HOME"
  elif [ -n "${1:-}" ]; then
    nixpkgs_jdk "$1"
  else
    echo "$default_java"
  fi
}

# The major version of the Java the lockfile was made with.
locked_java_major() {
  jq -r '.javaVersion | split(".") | .[0]' "$lockfile"
}

require_build_root() {
  if [ ! -f settings.gradle ] && [ ! -f settings.gradle.kts ]; then
    die "run this at the root of a Gradle build (the directory with settings.gradle or settings.gradle.kts)"
  fi
}

# The distribution URL of the wrapper properties, with the escapes of the
# properties format removed.
distribution_url() {
  local properties=gradle/wrapper/gradle-wrapper.properties
  [ -f "$properties" ] || die "the build has no $properties; add a wrapper with 'gradle wrapper'"
  local url
  url=$(sed -n 's/^[[:space:]]*distributionUrl[[:space:]]*[=:][[:space:]]*//p' "$properties" | tail -n 1 | tr -d '\r')
  [ -n "$url" ] || die "$properties sets no distributionUrl"
  printf '%s' "${url//\\/}"
}

# The path of a URL in the tree of locked downloads.
tree_path() {
  local url=$1
  local scheme=${url%%://*}
  printf '%s/%s' "$scheme" "${url#*://}"
}

# The build definition: the files whose change means that the lock must
# be made again. They are every settings and build script,
# gradle.properties, the version catalogs and the wrapper properties, and
# every file of buildSrc and of each included build (a directory below the
# root with a settings script).
definition_files() {
  {
    find . \( -name .git -o -name .gradle -o -name .kotlin -o -name .idea -o -name build -o -name node_modules \) -prune -o \
      -type f \( -name 'settings.gradle' -o -name 'settings.gradle.kts' -o -name 'build.gradle' -o -name 'build.gradle.kts' \
      -o -name 'gradle.properties' -o -name '*.versions.toml' -o -name 'gradle-wrapper.properties' -o -name '*.init.gradle' \) -print
    local dir
    for dir in ./buildSrc $(find . -mindepth 2 \( -name .git -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
      -type f \( -name settings.gradle -o -name settings.gradle.kts \) -printf '%h\n'); do
      [ -d "$dir" ] || continue
      find "$dir" \( -name .gradle -o -name .kotlin -o -name build \) -prune -o -type f -print
    done
  } | sort -u
}

inputs_hash() {
  local files
  files=$(definition_files)
  {
    printf '%s\n' "$*"
    [ -z "$files" ] || printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 sha256sum
  } | sha256sum | cut -d ' ' -f 1
}

# Unpacks the Gradle distribution zip $1 into the user's cache, once, and
# prints its Gradle home.
unpack_distribution() {
  local zip=$1
  local cache=${XDG_CACHE_HOME:-$HOME/.cache}/gradle-purifier/distributions
  local name
  name=$(basename "$(readlink -f "$zip")")
  local dir=$cache/$name
  if [ ! -d "$dir" ]; then
    mkdir -p "$cache"
    local tmp
    tmp=$(mktemp -d "$cache/.unpack.XXXXXX")
    unzip -q "$zip" -d "$tmp"
    mv "$tmp" "$dir"
  fi
  local home
  home=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -x "$home/bin/gradle" ] || die "$zip holds no bin/gradle"
  printf '%s' "$home"
}

# Copies the build at the current directory to $1, leaving out version
# control, Gradle's state, IDE files and the build directory of every
# project.
copy_build() {
  local target=$1
  local excludes=(--exclude=/.git --exclude=.gradle --exclude=.kotlin --exclude=.idea --exclude=/result*)
  local script dir
  while IFS= read -r script; do
    dir=$(dirname "${script#./}")
    if [ "$dir" = . ]; then excludes+=(--exclude=/build/); else excludes+=(--exclude="/$dir/build/"); fi
  done < <(find . \( -name .git -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
    -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' -o -name 'settings.gradle' -o -name 'settings.gradle.kts' \) -print)
  mkdir -p "$target"
  rsync -a --delete "${excludes[@]}" ./ "$target/"
}

# Kotlin/Native downloads its toolchain (LLVM, a GCC toolchain with a
# sysroot, and more) with its own downloader, and deletes each archive
# once it has extracted it. The downloader names every download in the
# build's output, as "Downloading dependency <url> to <file>". Records
# each such URL from the Gradle output $1 as a download into the records
# file $2, fetching it into the store for its hash, and writes the
# archives' paths in the tree of locked downloads to the file $3, one per
# line, for the lockfile's konanDependencies.
record_konan_dependencies() {
  local log=$1 records=$2 list=$3
  : >"$list"
  local url path hash
  while IFS= read -r url; do
    echo "gradle-purifier: fetching $url" >&2
    hash=$(nix --extra-experimental-features nix-command store prefetch-file --json --hash-type sha256 "$url" | jq -r '.hash')
    path=$(tree_path "$url")
    printf '%s\t%s\t%s\n' "$path" "$url" "$hash" >>"$records"
    echo "$path" >>"$list"
  done < <(konan_download_urls "$log")
}

# The URLs Kotlin/Native's downloader names in the Gradle output $1, each
# once.
konan_download_urls() {
  sed -n 's/^Downloading dependency \(https\?:\/\/[^ ]*\) to .*/\1/p' "$1" | sort -u
}

# The lockfile's artifacts, as JSON, from the recorder's records file $1:
# a file entry for each line with a URL (its optional fourth field is a
# mirror), an inline entry for each line the recorder marked "inline" (its
# third field is the contents in Base64), and one entry per path.
artifacts_json() {
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
    | if .[1] == "inline" then {path: .[0], contents: (.[2] | @base64d)}
      else {path: .[0], url: .[1], mirrors: ([.[3] // empty] | map(select(length > 0))), hash: .[2]} end)
    | unique_by(.path)' "$1"
}

# The Kotlin/Native name of this machine. A Kotlin/Native toolchain runs
# on the machine it was made for, so the lock records it.
konan_host() {
  case $(uname -m) in
    x86_64) echo linux_x64 ;;
    aarch64 | arm64) echo linux_arm64 ;;
    *) uname -m ;;
  esac
}

lock_command() {
  local relock='' java_major=''
  while [ $# -gt 0 ]; do
    case $1 in
      --relock) relock=1; shift ;;
      --java)
        [ $# -ge 2 ] || die "--java takes a Java major version, such as 17"
        java_major=$2
        shift 2
        ;;
      --) shift; break ;;
      -h | --help) usage; exit 0 ;;
      *) die "lock takes --relock, --java <major> and, after --, gradle arguments; got $1" ;;
    esac
  done
  local gradle_args=("$@")
  require_build_root

  local root=$PWD
  local hash
  hash=$(inputs_hash "${gradle_args[@]}")
  if [ -z "$relock" ] && [ -f "$lockfile" ] && [ "$(jq -r '.inputsHash' "$lockfile")" = "$hash" ] \
    && [ "$(jq -r '.version' "$lockfile")" = "$lock_version" ]; then
    echo "gradle-purifier: $lockfile is current" >&2
    return 0
  fi

  local url
  url=$(distribution_url)
  echo "gradle-purifier: fetching $url" >&2
  local prefetch dist_hash dist_zip
  prefetch=$(nix --extra-experimental-features nix-command store prefetch-file --json --hash-type sha256 "$url")
  dist_hash=$(jq -r '.hash' <<<"$prefetch")
  dist_zip=$(jq -r '.storePath' <<<"$prefetch")
  local gradle_home
  gradle_home=$(unpack_distribution "$dist_zip")

  local work=$root/.gradle/purifier/lock-run
  rm -rf "$work"
  mkdir -p "$work"
  copy_build "$work/build"

  local records=$work/records.tsv
  printf '%s\t%s\t%s\n' "$(tree_path "$url")" "$url" "$dist_hash" >"$records"
  local java
  java=$(java_home "$java_major")
  # Empty jdk.http.auth.*.disabledSchemes let the recorder send the Basic
  # credentials of an https_proxy URL to the proxy, for HTTPS tunnels and
  # for plain HTTP alike.
  "$java/bin/java" -Djdk.http.auth.tunneling.disabledSchemes= -Djdk.http.auth.proxying.disabledSchemes= \
    -cp "$recorder" Recorder "$records" "$work/port" "${konan_hosts[@]}" &
  local recorder_pid=$!
  # shellcheck disable=SC2064 # the PID is known now
  trap "kill $recorder_pid 2>/dev/null || true" EXIT
  local waited=0
  while [ ! -f "$work/port" ]; do
    kill -0 "$recorder_pid" 2>/dev/null || die "the recorder did not start"
    [ $waited -lt 300 ] || die "the recorder did not start within 30 seconds"
    sleep 0.1
    waited=$((waited + 1))
  done
  local ports base tunnel_port
  read -r -a ports <"$work/port" || true
  base=http://127.0.0.1:${ports[0]}
  tunnel_port=${ports[1]}

  echo "gradle-purifier: running the lock build in $work/build" >&2
  (
    cd "$work/build" || exit 1
    # Gradle's own HTTP client reaches only the recorder: a remote it
    # contacts directly goes to a proxy that refuses, so a download the
    # lock would miss fails here rather than in the sandbox. The HTTPS
    # proxy is the recorder's tunnel, which reaches Kotlin/Native's
    # download host and refuses every other.
    KONAN_DATA_DIR=$work/konan \
      GRADLE_USER_HOME=$work/gradle-home \
      GRADLE_PURIFIER_MODE=lock \
      GRADLE_PURIFIER_REPOSITORY=$base \
      GRADLE_PURIFIER_OUTPUT=$work/output \
      JAVA_HOME=$java \
      "$gradle_home/bin/gradle" \
      --init-script "$lib/purifier.init.gradle" \
      --no-daemon --no-configuration-cache --no-build-cache --console=plain \
      "-Dorg.gradle.internal.plugins.portal.url.override=$base/$portal" \
      "-Djava.io.tmpdir=${TMPDIR:-/tmp}" \
      -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=9 \
      -Dhttps.proxyHost=127.0.0.1 "-Dhttps.proxyPort=$tunnel_port" \
      '-Dhttp.nonProxyHosts=localhost|127.0.0.1' \
      -Porg.gradle.java.installations.auto-download=false \
      -Pkotlin.compiler.execution.strategy=in-process \
      "${gradle_args[@]}" \
      purifierLock </dev/null 2>&1 | tee "$work/gradle.log"
  )
  kill "$recorder_pid" 2>/dev/null || true
  wait "$recorder_pid" 2>/dev/null || true
  trap - EXIT
  record_konan_dependencies "$work/gradle.log" "$records" "$work/konan-dependencies"

  [ -f "$work/output/projects.json" ] || die "the lock build wrote no projects.json"
  local args_json
  args_json=$(jq -n '$ARGS.positional' --args -- "${gradle_args[@]}")
  jq -n \
    --argjson version "$lock_version" \
    --slurpfile described "$work/output/projects.json" \
    --argjson artifacts "$(artifacts_json "$records")" \
    --rawfile konanDependencies "$work/konan-dependencies" \
    --arg konanHost "$(konan_host)" \
    --arg distribution "$(tree_path "$url")" \
    --arg inputsHash "$hash" \
    --argjson gradleArguments "$args_json" \
    '{
      version: $version,
      gradleVersion: $described[0].gradleVersion,
      javaVersion: $described[0].javaVersion,
      distribution: $distribution,
      gradleArguments: $gradleArguments,
      inputsHash: $inputsHash,
      projects: $described[0].projects,
      konanDependencies: ($konanDependencies | split("\n") | map(select(length > 0)) | unique),
      konanHost: $konanHost,
      artifacts: $artifacts
    }' >"$root/$lockfile.tmp"
  mv "$root/$lockfile.tmp" "$root/$lockfile"
  echo "gradle-purifier: wrote $lockfile ($(jq '.artifacts | length' "$root/$lockfile") downloads)" >&2
}

# Fetches the locked downloads through Nix and prints the store path of
# their tree (repository.nix, as the Nix builder makes it), with a GC root
# in .gradle/purifier.
realize() {
  local state=$PWD/.gradle/purifier
  mkdir -p "$state"
  local tree
  if ! tree=$(nix-build --quiet --out-link "$state/repository" \
    --expr "{ lockFile }: (import $nixpkgs { }).callPackage $lib/repository.nix { inherit lockFile; }" \
    --arg lockFile "$PWD/$lockfile"); then
    die "the locked downloads did not fetch (see Nix's error above). A hash mismatch means $lockfile does not match what its URL serves: restore the lockfile from version control, or run 'gradle-purifier lock --relock' if the remote changed the file."
  fi
  printf '%s' "$tree"
}

# Succeeds when the lockfile exists, has this command's format, and was
# made from the current build definition. Otherwise it says why on stderr,
# followed by $1, and fails.
lock_is_current() {
  local consequence=$1
  if [ ! -f "$lockfile" ]; then
    echo "gradle-purifier: the build has no $lockfile; run 'gradle-purifier lock'. $consequence" >&2
    return 1
  fi
  if ! jq -e 'type == "object" and (.artifacts | type == "array") and (.projects | type == "array")' "$lockfile" >/dev/null 2>&1; then
    die "$lockfile is not a gradle-purifier lockfile (it is not valid JSON, or it lacks artifacts or projects); restore it from version control or run 'gradle-purifier lock --relock'"
  fi
  local locked_args=()
  mapfile -t locked_args < <(jq -r '.gradleArguments[]' "$lockfile")
  if [ "$(jq -r '.version' "$lockfile")" != "$lock_version" ]; then
    echo "gradle-purifier: $lockfile has another lock format; run 'gradle-purifier lock --relock'. $consequence" >&2
    return 1
  fi
  if [ "$(jq -r '.inputsHash' "$lockfile")" != "$(inputs_hash "${locked_args[@]}")" ]; then
    echo "gradle-purifier: the build definition changed since $lockfile was made; run 'gradle-purifier lock'. $consequence" >&2
    return 1
  fi
}

# When the lock holds a Kotlin/Native toolchain, builds it with Nix,
# unpacked and patched (konan.nix), as the dependencies of the
# Kotlin/Native data directory .gradle/purifier/konan, and sets the
# environment Kotlin/Native runs with, as the Nix builder does.
setup_konan() {
  [ "$(jq '.konanDependencies // [] | length' "$lockfile")" -gt 0 ] || return 0
  local state=$PWD/.gradle/purifier
  local toolchain
  toolchain=$(nix-build --quiet --out-link "$state/konan-gcroot" \
    --expr "{ lockFile }: (import $nixpkgs { }).callPackage $lib/konan.nix { inherit lockFile; }" \
    --arg lockFile "$PWD/$lockfile")
  export KONAN_DATA_DIR=$state/konan
  rm -rf "$KONAN_DATA_DIR/dependencies"
  mkdir -p "$KONAN_DATA_DIR/dependencies"
  local dependency
  for dependency in "$toolchain"/*; do
    ln -s "$dependency" "$KONAN_DATA_DIR/dependencies/"
  done
  cp "$toolchain/.extracted" "$KONAN_DATA_DIR/dependencies/.extracted"
  export LD_LIBRARY_PATH=$konan_library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  local host
  host=$(konan_host)
  export GRADLE_PURIFIER_KONAN_PROPERTIES="dynamicLinker.$host=$dynamic_linker"
}

# Runs the Gradle of the lock on the locked downloads, in the init
# script's mode $1, with the gradle arguments that follow. The variables
# of the environment pass on to Gradle.
run_locked_gradle() {
  local mode=$1
  shift
  setup_konan
  local tree
  tree=$(realize)
  local gradle_home
  gradle_home=$(unpack_distribution "$tree/$(jq -r '.distribution' "$lockfile")")
  local locked_args=()
  mapfile -t locked_args < <(jq -r '.gradleArguments[]' "$lockfile")
  # A run on the lock takes the Java major version the lock was made with,
  # whatever JAVA_HOME names, unless GRADLE_PURIFIER_JAVA_HOME names a JDK.
  local java
  if [ -n "${GRADLE_PURIFIER_JAVA_HOME:-}" ]; then
    java=$GRADLE_PURIFIER_JAVA_HOME
  else
    java=$(nixpkgs_jdk "$(locked_java_major)")
  fi
  # Gradle's errors go to the terminal and to a log as well, so that a
  # failure to find a locked file can be explained after Gradle exits.
  local errors status=0
  errors=$(mktemp "${TMPDIR:-/tmp}/gradle-purifier-errors.XXXXXX")
  JAVA_HOME=$java \
    GRADLE_PURIFIER_MODE=$mode \
    GRADLE_PURIFIER_REPOSITORY=file://$tree \
    "$gradle_home/bin/gradle" \
    --offline \
    --init-script "$lib/purifier.init.gradle" \
    "-Dorg.gradle.internal.plugins.portal.url.override=file://$tree/$portal" \
    "${locked_args[@]}" \
    "$@" 2> >(tee "$errors" >&2) || status=$?
  wait "$!" 2>/dev/null || true
  if [ "$status" -ne 0 ] && grep -q -e 'Could not find' -e 'Could not resolve' "$errors" \
    && grep -q -F "$tree" "$errors"; then
    echo "gradle-purifier: the build needs a file that $lockfile does not hold (Gradle names it above). Run 'gradle-purifier lock --relock' to lock it, or restore the lockfile if it was edited." >&2
  fi
  rm -f "$errors"
  exit "$status"
}

run_command() {
  require_build_root
  if [ -f "$lockfile" ] || [ ! -x ./gradlew ]; then
    if lock_is_current "Gradle runs the usual way."; then
      run_locked_gradle interactive "$@"
    fi
  fi
  [ -x ./gradlew ] || die "the build has no current $lockfile and no ./gradlew"
  exec ./gradlew "$@"
}

# Builds the package of every publishing project with Nix, and runs the
# build's publish tasks (`publish`, or the gradle arguments given) with
# those packages' files in place of the ones Gradle would make.
publish_command() {
  require_build_root
  lock_is_current "Nothing is published." || exit 1
  local state=$PWD/.gradle/purifier/published
  mkdir -p "$state"
  local artifacts='{}' id out
  while IFS= read -r id; do
    echo "gradle-purifier: building $id with Nix" >&2
    out=$(nix-build "$lib/publish.nix" --argstr nixpkgs "$nixpkgs" --argstr src "$PWD" -A "$id" --out-link "$state/$id")
    artifacts=$(jq --arg id "$id" --arg out "$out" '. + {($id): $out}' <<<"$artifacts")
  done < <(jq -r '.projects[] | select(.publications != []) | .id' "$lockfile")
  [ $# -gt 0 ] || set -- publish
  # The init script disables the task that generates each publication's
  # Gradle module metadata, so Gradle does not publish its output, and
  # publishes the module metadata Nix built instead. Gradle still runs the
  # dependencies of a disabled task, which compile and package the
  # project; excluding the task with -x leaves them out.
  local excluded=()
  mapfile -t excluded < <(jq -r '.projects[] | (if .path == ":" then "" else .path end) as $p
    | .publications[] | "-x", "\($p):generateMetadataFileFor\(.name[0:1] | ascii_upcase)\(.name[1:])Publication"' "$lockfile")
  GRADLE_PURIFIER_ARTIFACTS=$artifacts run_locked_gradle publish "${excluded[@]}" "$@"
}

# Prepares the build for an IDE, which imports it with its own Gradle
# through the tooling API: realizes the lockfile, records in
# .gradle/purifier/ide.properties what the IDE init script needs, and
# installs that script (ide.init.gradle) in the init.d of the Gradle user
# home, where every Gradle build applies it.
ide_command() {
  require_build_root
  lock_is_current "The IDE resolves the usual way." || exit 1
  local state=$PWD/.gradle/purifier
  local tree
  tree=$(realize)
  # The IDE's builds apply the init script from the store; this root keeps
  # it there.
  nix-store --add-root "$state/lib" --realise "$lib" >/dev/null
  local sha256
  sha256=$(sha256sum "$lockfile" | cut -d ' ' -f 1)
  {
    echo "# Written by gradle-purifier ide, for the IDE init script."
    echo "repository=file://$tree"
    echo "portal=file://$tree/$portal"
    echo "initScript=$lib/purifier.init.gradle"
    echo "lockSha256=$sha256"
  } >"$state/ide.properties"
  local init_d=${GRADLE_USER_HOME:-$HOME/.gradle}/init.d
  mkdir -p "$init_d"
  install -m 0644 "$lib/ide.init.gradle" "$init_d/gradle-purifier.gradle"
  # An IDE set to this local Gradle distribution needs no download of the
  # wrapper's distribution either.
  local gradle_home
  gradle_home=$(unpack_distribution "$tree/$(jq -r '.distribution' "$lockfile")")
  ln -sfn "$gradle_home" "$state/gradle"
  echo "gradle-purifier: the IDE's Gradle builds of $PWD read the locked downloads now ($init_d/gradle-purifier.gradle). For no download at all, set the IDE's Gradle distribution to $state/gradle. Run 'gradle-purifier ide' again after each lock." >&2
}

# The unit tests (tests/cli-unit.sh) source the command for its functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    lock) shift; lock_command "$@" ;;
    publish) shift; publish_command "$@" ;;
    ide) shift; ide_command "$@" ;;
    -h | --help) usage ;;
    *) run_command "$@" ;;
  esac
fi
