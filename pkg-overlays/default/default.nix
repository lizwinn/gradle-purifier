# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.gradle-purifier` (`.gradle-purifier`, the command), and the builder
# `pkgs.buildGradleProject` (nix/lib/build-gradle-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `gradle-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "gradle-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildGradleProject = final.callPackage ../../nix/lib/build-gradle-project.nix { };
    };
}
