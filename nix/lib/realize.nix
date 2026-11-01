# What the interactive mode of the gradle-purifier command builds.
#
# `fetches` is every locked artifact; `nix-build -A fetches` downloads them
# in parallel. `manifest` is then a store file mapping each artifact's
# path in the tree of locked downloads to its store path. The file refers
# to every artifact, so one GC root on it keeps them all alive, and the
# command builds its tree of links from it.
#
# A file made with builtins.toFile may refer to store paths but not to
# derivation outputs, so the manifest names each artifact through
# builtins.fetchurl: with the same name and hash, it is the same
# fixed-output store path a fetch derivation produces, and it is already
# valid once `fetches` is built, so nothing downloads twice.
{
  lockFile,
  libDir ? ./.,
}:
let
  lock = import (libDir + "/lock.nix") { inherit lockFile; };
  fetch = import (libDir + "/fetch.nix") { inherit lock; };
  byPath =
    f: artifacts:
    builtins.listToAttrs (
      map (artifact: {
        name = artifact.path;
        value = f artifact;
      }) artifacts
    );
  # Inline entries are store files already; only file entries download.
  files = builtins.filter (artifact: !(artifact ? contents)) lock.artifacts;
in
{
  fetches = byPath fetch files;
  manifest = builtins.toFile "gradle-purifier-repository.json" (
    builtins.toJSON (
      byPath (
        artifact:
        if artifact ? contents then
          fetch artifact
        else
          builtins.fetchurl {
            inherit (artifact) url;
            name = lock.artifactName artifact;
            sha256 = artifact.hash;
          }
      ) lock.artifacts
    )
  );
}
