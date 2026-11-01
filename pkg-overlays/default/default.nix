# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.gradle-purifier` of pkgs/, which holds the builder
# `buildGradleProject` and the command `gradle-purifier`.
# `pkgs.gradle-purifier.overrideScope` replaces what the scope shares. A
# consumer that lists this flake in `projects` holds the overlay as
# `gradle-purifier/default`, which its package sets apply by default.
{ closure-lib, closure-inputs, ... }:
{
  overlay = final: prev: {
    gradle-purifier = closure-lib.caisson.nixpkgs.mkScope final (
      callPackage:
      import ../../pkgs {
        inherit callPackage;
        lib = closure-lib;
        inputs = closure-inputs;
      }
    );
  };
}
