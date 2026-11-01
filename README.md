# gradle-purifier

gradle-purifier locks the downloads of a Gradle build and builds it in the
Nix sandbox. It works with Java and Kotlin builds, in the Groovy and the
Kotlin DSL, on Gradle 8 and 9, including Kotlin Multiplatform with JVM
and Kotlin/Native targets. Gradle still plans and runs the build. The
purifier records every file Gradle downloads in a lockfile, by URL and
SHA-256, and Nix fetches those files and runs the build offline. The
lockfile also names the projects and their outputs, so a flake knows
every package without generated Nix files.

It is one of the [nix-purifiers](https://nix-purifiers.github.io), and it
meets their shared contract: the same builder, commands, checks and
README sections as every other purifier.

## Quickstart

The build needs a Gradle wrapper (`gradle/wrapper/gradle-wrapper.properties`);
the purifier runs the distribution that the wrapper names. Lock the build
from its root, and commit `gradle-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/gradle-purifier -- lock
```

The flake's `overlays.default` adds the builder `buildGradleProject` to
the package set, beside the builders of nixpkgs. A package written for
`callPackage` takes it by name:

```nix
# package.nix
{ buildGradleProject }:
(buildGradleProject { src = ./.; }).packages.app
```

```nix
# flake.nix
{
  inputs.gradle-purifier.url = "github:nix-purifiers/gradle-purifier";
  inputs.nixpkgs.follows = "gradle-purifier/nixpkgs";

  outputs = { nixpkgs, gradle-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ gradle-purifier.overlays.default ];
      };
    in
    {
      packages.${system}.app = pkgs.callPackage ./package.nix { };
    };
}
```

`buildGradleProject` takes what it needs from the package set by name,
such as `javaPackages` and `stdenvNoCC`, and `buildGradleProject.override`
replaces any of them. Its result has these attributes:

- `packages.<id>` holds a package per project, named after the project:
  the name of the root project for the root project, and the project path
  with `-` for `:` otherwise (`:libs:core` is `libs-core`). Programs go
  to `bin/` of `out`: the distribution of the `application` plugin, with
  its start script set to run on the JDK of the build, and the release
  executables of Kotlin/Native. The archives that `assemble` makes go to
  `share/archives/` of `out`, named without the version of the project,
  and `packages.<id>.archives."<key>"` is the path of one. Maven
  publications go to the `maven` output, in Maven layout, with each
  artifact linked without the version at
  `nix-support/artifacts/<publication>/<artifactId>[-<classifier>].<ext>`,
  and `packages.<id>.artifacts.<publication>."<key>"` is the path of one.
- `tests` runs the `check` task of every project in the sandbox.
- `release` holds the Maven output of every project with publications,
  which `gradle-purifier publish` uploads.
- `fetches` lists the downloads of the build as entries of the
  nix-purifiers library, for SBOM, license and vulnerability tools.

The builder takes these arguments besides `src`, the root of the build:

- `lockFile` is the lockfile; the default is `gradle-purifier.lock.json`
  in `src`. A build kept external passes a lockfile from outside `src`,
  and `src` then needs only the files of Gradle.
- `fetchers` replaces the fetchers of the nix-purifiers library, such as
  a `fetchurl` that sends credentials to a company repository.
- `jdk` is the JDK that runs Gradle and the applications. The default is
  the headless JDK of nixpkgs of the Java major version the lock was made
  with.
- `toolchainJdks` lists the JDKs for Java toolchains that ask for another
  Java version. Gradle provisions no toolchain in the sandbox.
- `doCheck` runs the `check` task of each project in its package build.
- `srcFilter` filters the build root before it is copied into the store.

`lib.gradle-purifier.readLock { src, lockFile }` reads the lock into the
shape that every purifier shares: `entries`, `outputs` and `problems`.

## Development loop

After each lock, run `prefetch` at the build root:

```zsh
nix run github:nix-purifiers/gradle-purifier -- prefetch
```

It realizes in the Nix store the locked downloads, the JDK, the Gradle
distribution of the wrapper and, for a Kotlin/Native build, the patched
toolchain. Their garbage-collector roots go in `.gradle-purifier/` beside
the lockfile. It also installs an init script in the `init.d` directory
of the Gradle user home, which Gradle applies to every build. For the
builds of this root, the script points every repository at the locked
downloads. It leaves every other build alone. After that, the build tool
works as usual:

```zsh
./gradlew build
```

`prefetch` links the distribution where `./gradlew` looks for it, so the
wrapper downloads nothing. Gradle reads the locked files where they are,
so its own download cache stays empty. A build that needs a download the
lockfile does not hold fails, and the init script names
`gradle-purifier lock`. When the lockfile changed since the last
prefetch, the init script says so and the build resolves the usual way
until `prefetch` runs again. `prefetch` warns when `JAVA_HOME` names
another Java major version than the lock, and prints the JDK to use.

Gradle keeps a lockfile of its own only in a build that turns on its
dependency locking. Without one, `gradle-purifier.lock.json` records the
resolution as well as the downloads: it holds the version listings
(`maven-metadata.xml`) that dynamic versions resolve through, and `lock`
resolves from them again. In a build with dependency locking, `lock`
keeps the resolution of Gradle's lockfiles as they are.

These are the commands:

- `gradle-purifier lock` runs Gradle and records the downloads. It makes
  the lock again only when the build definition changed: the settings and
  build scripts, `gradle.properties`, the version catalogs, the wrapper
  properties, Gradle's own lockfiles, and the files of `buildSrc` and of
  included builds. `--relock` makes it again regardless. A dynamic
  version, such as `3.17.+`, resolves as it did in the last lock, from
  the version listings that the lockfile holds. A relock of an unchanged
  build reproduces the lockfile byte for byte. The lock runs Gradle on
  nixpkgs' JDK of a major version with `--java 17`, or of the Java the
  existing lockfile was made with. A first lock runs on `JAVA_HOME`, or
  else on the JDK 21 of the command. Gradle arguments after `--` go into
  the lockfile and into every Gradle run of the lock.
- `gradle-purifier update [<group>:<artifact>...]` locks again with the
  newest versions that the dynamic versions allow, for every package or
  for the packages named (`group:*` names a whole group). In a build that
  uses Gradle's dependency locking, it runs Gradle with `--write-locks`,
  or `--update-locks` for the packages named, and writes Gradle's
  lockfiles back into the build.
- `gradle-purifier prefetch` prepares the development loop, as above.
- `gradle-purifier publish` uploads the `release` that Nix built (see
  below).

For a build kept external, each command takes `--lockfile <path>`, or the
environment variable `GRADLE_PURIFIER_LOCKFILE`. The dev shell of the
flake that passes `lockFile` to the builder can set the variable to the
same path.

### Publishing

```zsh
nix run github:nix-purifiers/gradle-purifier -- publish
```

The command builds the `release` with Nix, from the lockfile, then runs
the `publish` task of Gradle (or the tasks given after `publish`) with the
artifacts and the Gradle module metadata of every Maven publication
replaced by the files Nix built. The publishing repositories and
credentials of the build apply, and nothing is compiled outside the
sandbox. Gradle generates the POM from the build, as it does for any
publish.

## Working offline

After `prefetch`, `./gradlew`, a Gradle on the `PATH` and an IDE build
with the network cut off. Gradle reads the locked files from the Nix
store, so its own download cache stays empty.

## Editor

An IDE imports a Gradle build with its own Gradle run, through the Gradle
tooling API: IntelliJ IDEA, and Eclipse and VS Code through Buildship and
jdtls. The init script that `prefetch` installs applies to those runs too,
so the import reads the locked downloads. The lock run resolves the
sources and the javadoc of every library, so an IDE that attaches them
finds them in the lock. An IDE set to use the Gradle wrapper finds the
distribution that `prefetch` linked. One set to a local distribution can
use `.gradle-purifier/distribution` beside the lockfile.

## Troubleshooting

Every problem with a lockfile fails in the command and at Nix evaluation,
with a message that names the fix.

| Problem | Message | Fix |
| --- | --- | --- |
| The build definition changed since the lock | "the build definition … changed since … was made" | `gradle-purifier lock` |
| The lockfile was edited by hand | "does not match its contentHash, so it was edited" | `gradle-purifier lock --relock`, or restore it from version control |
| The lockfile is not JSON, has another format version or lacks a field | "not valid JSON", "has lock format version …", "lacks a field" | `gradle-purifier lock --relock` |
| A download does not match its hash | Nix reports a hash mismatch | restore the lockfile, or `gradle-purifier lock --relock` if the remote changed the file |
| The build needs a file the lockfile does not hold | "the build needs a file that … does not hold" | `gradle-purifier lock --relock` |
| A dynamic version asks for a version the lock never saw | "a dynamic version asks for a version that the version listings of the lockfile do not have" | `gradle-purifier update <group>:<artifact>` |
| The lockfile changed since the last prefetch | "changed since 'gradle-purifier prefetch' ran" | `gradle-purifier prefetch` |

## Supported language repositories

The lock records every download through Gradle's repositories: Maven and
Ivy repositories of settings scripts, of `pluginManagement`, of
`dependencyResolutionManagement`, of buildscripts and of projects, in the
root build, in `buildSrc` and in included builds, and the Gradle plugin
portal. To do that, the lock run copies the build to
`.gradle-purifier/lock-run` and runs it through an init script that points
every repository at a recorder on the loopback address, which fetches
each file and records its URL and hash. The lock run builds, tests and
publishes (into a scratch directory) every project, and resolves every
resolvable configuration with sources and javadoc, so the lockfile holds
what any package build or editor needs.

Some files are recorded in a particular way:

- When Gradle compares a file it holds from one repository with the
  checksum another repository serves, the recorder fetches the whole
  file, so every repository's copy is in the lockfile.
- A `maven-metadata.xml`, which Gradle reads for dynamic versions and
  snapshots, changes whenever a new version is published, so the
  lockfile holds its contents.
- A file of Maven Central gets Google's mirror of Maven Central as a
  mirror, which Nix tries when Maven Central fails. With
  `GRADLE_PURIFIER_CENTRAL_MIRROR=1`, the lock run downloads from the
  mirror. The lockfile names Maven Central either way.
- Kotlin/Native downloads its toolchain (LLVM, a GCC toolchain with a
  glibc sysroot, libffi) from download.jetbrains.com with its own
  downloader. The recorder gives that downloader an HTTPS tunnel to the
  download hosts of JetBrains only, and the command records each archive
  the downloader names. In the sandbox, the builder unpacks the archives,
  patches their programs with `autoPatchelf`, and links programs with the
  dynamic linker of nixpkgs. A toolchain runs on the machine it was made
  for, so the lockfile records the host, and a build with Kotlin/Native
  targets builds on the system its lock was made on, x86_64-linux or
  aarch64-linux. Lock it on each system that builds it, with a lockfile
  per system kept outside the tree. Kotlin/Native 2.2 crashes the JVM on JDK 21, so lock
  such a build with `--java 17`. On NixOS, the lock run needs a
  conventional dynamic loader, such as
  [nix-ld](https://github.com/nix-community/nix-ld) provides, because it
  runs the toolchain before anything can patch it.

The lock refuses these:

- **Downloads outside the repositories.** Gradle's own HTTP client gets a
  proxy that refuses every connection, so a plugin that downloads with
  its own client fails in the lock run rather than later in the sandbox.
  The file needs a repository that the build declares.
- **Kotlin/JS targets.** Yarn installs npm packages from the npm registry
  outside Gradle, so a Kotlin/JS target fails at its first download.
- **The configuration cache** is off in the lock run and in the sandbox,
  because the tasks of the init script read the project model.

A lock run sends the `Authorization` header of a repository on to it, so
a lock can be made from a repository that needs credentials. The Nix
build then needs a `fetchers.fetchurl` that supplies them.

## Examples

[Spring PetClinic](https://github.com/spring-projects/spring-petclinic)
is a Spring Boot application with a Gradle wrapper and a Java 17
toolchain. In a clone of it, lock it on Java 17:

```zsh
nix run github:nix-purifiers/gradle-purifier -- lock --java 17
git add gradle-purifier.lock.json
```

A `package.nix` and a `flake.nix` at the root of the clone build it:

```nix
# package.nix
{ buildGradleProject }:
(buildGradleProject { src = ./.; }).packages.spring-petclinic
```

```nix
# flake.nix
{
  inputs.gradle-purifier.url = "github:nix-purifiers/gradle-purifier";
  inputs.nixpkgs.follows = "gradle-purifier/nixpkgs";

  outputs = { nixpkgs, gradle-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ gradle-purifier.overlays.default ];
      };
    in
    {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
    };
}
```

`nix build` then makes the Spring Boot jar, which runs on Java 17:

```zsh
nix build
java -jar result/share/archives/spring-petclinic.jar
```

For the development loop, `prefetch` sets up the wrapper, and the usual
commands work offline:

```zsh
nix run github:nix-purifiers/gradle-purifier -- prefetch
./gradlew bootRun
```

## Credits

The design follows
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), which took
its model from nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo):
the build tool resolves, a lockfile records each download by URL and
hash, and Nix builds from the lockfile in the sandbox.
`docs/development/` holds the design, the tests and the commands.
