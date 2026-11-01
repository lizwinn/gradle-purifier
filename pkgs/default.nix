# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The gradle-purifier command: `gradle-purifier lock`, and Gradle runs on
  # the locked downloads.
  gradle-purifier = callPackage ./gradle-purifier { };
}
