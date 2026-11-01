# SPDX-License-Identifier: MIT
#
# The lockfiles of the conformance checks: the lockfile of the Java
# library fixture with one change each. `sealed` computes the contentHash
# again, as `gradle-purifier lock` does, so the change passes as the work
# of the command; `edited` keeps the old one.
#
# tests/default.nix reads the copies committed beside this file, and fails
# when one of them differs from this file's value; tests/conformance/
# generate.sh writes them again.
{ lib }:
let
  lock = lib.importJSON ../fixtures/java-library/gradle-purifier.lock.json;
  contentHashOf =
    l: "sha256:" + builtins.hashString "sha256" (builtins.toJSON (removeAttrs l [ "contentHash" ]));
  sealed = l: l // { contentHash = contentHashOf l; };
in
{
  # Made for another build definition.
  stale = sealed (
    lock // { inputsHash = "0000000000000000000000000000000000000000000000000000000000000000"; }
  );

  # A download hash changed by hand.
  tampered = lock // {
    artifacts = map (
      a: if a ? hash then a // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; } else a
    ) lock.artifacts;
  };

  # Another format version.
  version = sealed (lock // { version = 0; });

  # No projects field.
  field = sealed (removeAttrs lock [ "projects" ]);

  # Without the jar of commons-lang3, which the build needs.
  missing = sealed (
    lock
    // {
      artifacts = lib.filter (
        a: builtins.match ".*/commons-lang3-[^/]*\\.jar" (a.url or "") == null
      ) lock.artifacts;
    }
  );
}
