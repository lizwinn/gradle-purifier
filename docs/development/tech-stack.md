# Tech stack

- **The init script is Groovy**, which every Gradle version runs without
  compiling a plugin first. It keeps to Gradle APIs that Gradle 8 and 9
  share, and reads its settings from environment variables, which the
  Gradle daemon receives from its client on every build.
- **The recorder is one Java file** on the JDK's own HTTP server
  (`com.sun.net.httpserver`) and HTTP client (`java.net.http`), compiled
  with `--release 17` and `-Werror`, so it runs on every JDK that runs
  Gradle 9.
- **The command is Bash**, packaged with `writeShellApplication`, which
  runs shellcheck on it. It uses `jq` for the lockfile, and `rsync` and
  `unzip` for the build copy and the distribution.
- **caisson** for the flake, as in sbt-purifier; nixpkgs in the package set
  builds the command and runs the checks. The Nix library needs only
  `pkgs` from its caller. The command builds the tree of locked
  downloads and the Kotlin/Native toolchain of its interactive mode with
  the nixpkgs it was built with.
