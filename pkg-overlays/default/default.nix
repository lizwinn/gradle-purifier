# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the builder `buildGradleProject`
# (nix/lib/build-gradle-project.nix) to the package set, beside the
# builders of nixpkgs, with the nix-purifiers library that this flake
# pins. It also adds the packages of pkgs/ under `pkgs.gradle-purifier`:
# `.gradle-purifier`, the command, which takes the source of that
# library. A consumer that lists this flake in `projects` holds the
# overlay as `gradle-purifier/default`, which its package sets apply by
# default.
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
      buildGradleProject = final.callPackage ../../nix/lib/build-gradle-project.nix {
        inherit (closure-lib) purifier;
      };
      gradle-purifier = added.gradle-purifier // {
        gradle-purifier = added.gradle-purifier.gradle-purifier.override {
          purifierSource = closure-inputs.purifier.outPath;
        };
      };
    };
}
