# SPDX-License-Identifier: MIT
#
# The `gradle-purifier` library namespace: the builder
# lib.gradle-purifier.buildGradleProject (nix/lib/build-gradle-project.nix),
# with the nix-purifiers library that this flake pins, and
# lib.gradle-purifier.readLock (nix/lib/read-lock.nix), the lock in memory
# that the nix-purifiers contract describes.
{ closure-lib, ... }:
{

  overlay = final: prev: {
    gradle-purifier = (prev.gradle-purifier or { }) // {
      buildGradleProject = import ../../nix/lib/build-gradle-project.nix {
        lib = closure-lib;
        inherit (closure-lib) purifier;
      };
      readLock = import ../../nix/lib/read-lock.nix { lib = closure-lib; };
    };
  };

}
