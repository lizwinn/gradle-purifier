# SPDX-License-Identifier: MIT
#
# The `gradle-purifier` package scope, which the default package overlay
# adds to the package set as `pkgs.gradle-purifier`. Its packages take the
# nix-purifiers library that this flake pins.
{
  callPackage,
  inputs,
  lib,
}:
{
  # The builder: a package whose value builds a Gradle build from its
  # lockfile (nix/lib/build-gradle-project.nix).
  buildGradleProject = callPackage ../nix/lib/build-gradle-project.nix {
    inherit (lib) purifier;
  };

  # The command: `gradle-purifier lock`, `update`, `prefetch` and
  # `publish`.
  gradle-purifier = callPackage ./gradle-purifier {
    purifierSource = inputs.purifier.outPath;
  };
}
