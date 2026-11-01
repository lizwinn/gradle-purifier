# The fetcher for locked artifacts.
#
# An artifact is a file entry `{ path, url, mirrors, hash }`, where
# `mirrors` lists further URLs that serve the same bytes, or an inline entry
# `{ path, contents }`. The lock holds a file whose remote contents change
# over time, such as Maven's maven-metadata.xml, as an inline entry, which
# becomes a store file with builtins.toFile.
#
# By default each file entry is a fixed-output derivation on Nix's built-in
# fetcher (the same derivation <nix/fetchurl.nix> makes), so neither the
# interactive mode nor a sandboxed build needs nixpkgs to download. A
# fixed-output store path depends only on its name and hash, so the
# default fetcher and nixpkgs' fetchurl produce the same paths.
#
# `fetchurl`, when given, replaces the built-in fetcher. It is called with
# { name, url, hash } and is the place for credentials (nixpkgs' fetchurl
# takes `netrcPhase`) or mirrors.
{
  lock,
  fetchurl ? null,
}:
artifact:
let
  name = lock.artifactName artifact;
  urls = [ artifact.url ] ++ artifact.mirrors;
in
if artifact ? contents then
  builtins.toFile name artifact.contents
else if fetchurl != null then
  fetchurl {
    inherit name urls;
    inherit (artifact) hash;
  }
else
  derivation {
    inherit name;
    builder = "builtin:fetchurl";
    system = "builtin";
    inherit (artifact) url;
    inherit urls;
    outputHash = artifact.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
