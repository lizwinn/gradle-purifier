# Product

gradle-purifier makes Nix the dependency backend and the release builder of
Gradle builds: a build's downloads are locked by URL and hash, its
packages build in the Nix sandbox, and interactive Gradle resolves from the
same locked downloads through the store. The README describes what it
does for a user.

## What it owns

- The init script (`nix/lib/purifier.init.gradle`): the redirection of
  every remote repository, the lock run's tasks and project description,
  the sandbox build of a project, and the replacement of publication
  artifacts in publish mode.
- The recorder (`src/Recorder.java`): the HTTP server the lock run sends
  every download through.
- The command (`src/gradle-purifier.sh`, packaged by `pkgs/gradle-purifier`):
  `lock`, `publish`, and the interactive mode.
- The Nix library (`nix/lib`), whose builder the flake overlay adds to a
  package set as `buildGradleProject`, for `callPackage`. The command runs
  the same files, so the code that builds a lockfile comes from the
  revision that wrote it.
- The lockfile format (`nix/lib/lock.nix`, the `jq` program of `lock` in
  the command), versioned by its `version` field. Its download entries
  have the shapes of the shared nix-purifiers library: a file entry
  `{ path, url, mirrors, hash }` and an inline entry `{ path, contents }`.

## Principles

- **A lock is complete by construction.** It is what a fresh-cache run of
  every package build, with checks, downloaded through the recorder,
  rather than a list of what Gradle is known to fetch.
- **The init script reaches every build.** Gradle applies it to buildSrc
  and to included builds as well as to the root build, so every
  repository of the composite goes through the recorder.
- **One copy of the logic.** The build logic lives in the Nix library;
  the lock run writes only the lockfile.
- **One path per URL.** A download of `https://host/path` is at
  `https/host/path` in the tree of locked downloads, so the lock run, the
  sandbox and the interactive mode resolve through the same URLs.

## Not in scope

A repository that needs credentials works in the Nix build only through
a fetcher the caller supplies. Kotlin/Native and Kotlin/JS targets are
not supported (see the README for why).
