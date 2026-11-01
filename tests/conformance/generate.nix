# SPDX-License-Identifier: MIT
#
# The lockfiles of lockfiles.nix as files, for generate.sh.
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.linkFarm "conformance-lockfiles" (
  pkgs.lib.mapAttrsToList (name: value: {
    name = "${name}.lock.json";
    path = pkgs.writeText "${name}.lock.json" (builtins.toJSON value);
  }) (import ./lockfiles.nix { inherit (pkgs) lib; })
)
