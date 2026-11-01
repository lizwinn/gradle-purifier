# SPDX-License-Identifier: MIT
#
# The `gradle-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildGradleProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    gradle-purifier = prev.gradle-purifier or { };
  };

}
