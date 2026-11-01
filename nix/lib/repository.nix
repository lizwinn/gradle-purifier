# The locked downloads of a lockfile as one tree: every locked file at its
# path, as a link into the store. The path of a file is the URL it was
# downloaded from without the "://", so https://repo.maven.apache.org/maven2/x
# is at https/repo.maven.apache.org/maven2/x. The init script points each
# remote repository of the build at its directory in this tree.
#
# It is a package for callPackage, with the lockfile among its arguments.
# buildGradleProject's `repository` is this.
{
  lib,
  runCommand,
  lockFile,
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl; };
in
# The manifest goes to the builder as a file, since a large build locks
# thousands of artifacts and the list would not fit in an environment
# variable.
runCommand "gradle-purifier-repository"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${fetch a}\n") lock.artifacts;
    passAsFile = [ "manifest" ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock; };
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$manifestPath"
  ''
