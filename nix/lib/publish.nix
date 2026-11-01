# What `gradle-purifier publish` builds: the Maven output of the package of
# every publishing project of a build, by buildGradleProject
# (build-gradle-project.nix, called with a nixpkgs package set), from
# arguments the command passes as strings.
#
#   nixpkgs  a nixpkgs source directory
#   src      the build root
{
  nixpkgs,
  src,
}:
let
  pkgs = import nixpkgs { };
  build = pkgs.callPackage ./build-gradle-project.nix { } { src = /. + src; };
in
builtins.mapAttrs (_: package: package.maven or package.out) (
  pkgs.lib.filterAttrs (_: package: package.gradleProject.publications != [ ]) build.packages
)
