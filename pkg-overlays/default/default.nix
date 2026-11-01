# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.gradle-purifier`: `.gradle-purifier`, the command, which takes the
# source of the nix-purifiers library that this flake pins. A consumer
# that lists this flake in `projects` holds it as `gradle-purifier/default`,
# which its package sets apply by default.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "gradle-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      gradle-purifier = added.gradle-purifier // {
        gradle-purifier = added.gradle-purifier.gradle-purifier.override {
          purifierSource = closure-inputs.purifier.outPath;
        };
      };
    };
}
