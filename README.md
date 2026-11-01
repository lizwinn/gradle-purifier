# gradle-purifier

gradle-purifier locks the downloads of a Gradle build and builds it in the
Nix sandbox. It works with Java and Kotlin builds, in the Groovy and the
Kotlin DSL, on Gradle 8 and 9. Gradle still plans and runs the build. The
purifier records every file Gradle downloads in a lockfile, by URL and
SHA-256, and Nix fetches those files and runs the build offline. The
repository needs no generated Nix files: the lockfile names the projects
and their artifacts, so a flake reads the packages from the lockfile alone.

It is one of the [nix-purifiers](https://nix-purifiers.github.io), and its
design follows
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier) (formerly
sbt-nix-backend), which took its model from nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

- **A lockfile.** `gradle-purifier lock` writes
  `gradle-purifier.lock.json` at the build root: the Gradle distribution of
  the wrapper, every file the build downloads, and the projects to build.
- **Sandboxed builds.** `buildGradleProject`, which the flake's overlay
  adds to a package set, turns a build and its lockfile into packages: one
  per project with an application or a Maven publication.
- **Interactive Gradle on the locked downloads.** `gradle-purifier <tasks>`
  runs the build's Gradle offline, with every repository read from the
  locked downloads through the store.
- **Publishing what Nix built.** `gradle-purifier publish` runs the build's
  own publish tasks with the files Nix built in place of the ones Gradle
  would make.

## How the lock is made

`gradle-purifier lock` copies the build to `.gradle/purifier/lock-run`
and runs Gradle there with an empty Gradle user home, through an init
script. The init script points every remote repository of every build of
the composite at a recorder on the loopback address: the URL
`https://host/path` becomes `http://127.0.0.1:<port>/https/host/path`. That
covers the repositories of settings scripts, of `pluginManagement`, of
`dependencyResolutionManagement`, of buildscripts and of projects, in the
root build, in `buildSrc` and in included builds, and the plugin portal.
The recorder fetches each file from its remote and records its URL and
hash.

The lock run builds, tests and publishes (into a scratch directory) every
project, and resolves every resolvable configuration, so the lockfile
holds what any package build needs. A lockfile is what a fresh run
downloaded, rather than a list of what Gradle is known to fetch. Gradle's
own HTTP client gets a proxy that refuses every connection, so a download
that bypasses the repositories fails in the lock run, rather than later
in the sandbox.

Some files are recorded in a particular way:

- Gradle compares a file it already holds from one repository with the
  checksum another repository serves, and then reuses its copy without
  downloading. The recorder fetches the whole file for such a request, so
  every repository's copy is in the lockfile.
- `maven-metadata.xml`, which Gradle reads for dynamic versions and
  snapshots, changes whenever a new version is published. The lockfile
  holds its contents rather than its hash, so the build sees the versions
  the lock run saw.

`gradle-purifier lock` makes the lock again only when the build
definition changed: the settings and build scripts, `gradle.properties`,
the version catalogs, the wrapper properties, and the files of `buildSrc`
and of included builds. `gradle-purifier lock --relock` makes it again
regardless.

## Use

Lock the build from its root. The build needs a Gradle wrapper
(`gradle/wrapper/gradle-wrapper.properties`); the purifier runs the
distribution the wrapper names.

```zsh
nix run github:nix-purifiers/gradle-purifier -- lock
```

The lock run uses `JAVA_HOME`, or nixpkgs' JDK of a major version with
`--java 17`, or else the command's JDK 21. The builds of a lockfile use
the Java major version it was made with. Commit
`gradle-purifier.lock.json`. Gradle arguments after `--` go into the
lockfile and into every Gradle run of the lock:

```zsh
nix run github:nix-purifiers/gradle-purifier -- lock -- -Pflavor=release
```

The flake's `overlays.default` adds `buildGradleProject` to a package set.
A package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildGradleProject }:
(buildGradleProject { src = ./.; }).packages.app
```

```nix
{
  inputs.gradle-purifier.url = "github:nix-purifiers/gradle-purifier";
  inputs.nixpkgs.follows = "gradle-purifier/nixpkgs";

  outputs = { nixpkgs, gradle-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          gradle-purifier.overlays.default
          (final: prev: { app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.app = pkgs.app;
    };
}
```

`packages.<id>` is named after the project: the root project's name for
the root project, and the project path with `-` for `:` otherwise
(`:libs:core` is `libs-core`).

- A project with the `application` plugin builds its installed
  distribution (`bin/` and `lib/`), with the start script set to run on
  the build's JDK, so `nix run` runs it.
- A project with Maven publications builds them in Maven layout, in `out`,
  or in the `maven` output when the project also has an application. The
  package links each artifact, without the project's version, at
  `nix-support/artifacts/<publication>/<artifactId>[-<classifier>].<ext>`,
  with the POM at `…/descriptor` and the Gradle module metadata at
  `…/module`. `packages.<id>.artifacts.<publication>."<key>"` is the path
  of an artifact, known from the lockfile before the package is built.

`nix/lib/build-gradle-project.nix` documents the builder's arguments:

- `jdk` is the JDK that runs Gradle and the applications. The default is
  the headless JDK of the major version the lock was made with.
- `toolchainJdks` lists the JDKs for Java toolchains that ask for another
  Java version. Gradle provisions no toolchain in the sandbox.
- `doCheck` runs each project's `check`.
- `fetchurl` replaces the fetcher, for credentials or mirrors.
- `srcFilter` filters the build root before it is copied into the store.

### Interactive mode

```zsh
nix run github:nix-purifiers/gradle-purifier -- build
```

With a current lockfile, the command fetches the locked downloads through
Nix (one GC root, in `.gradle/purifier`), links them into
`.gradle/purifier/repository`, and runs the lock's Gradle with `--offline`,
every repository pointing into that tree. It runs on nixpkgs' JDK of the
Java major version of the lock, whatever `JAVA_HOME` names;
`GRADLE_PURIFIER_JAVA_HOME` names another. Gradle reads the files where
they are, so its own download cache stays empty. When the lockfile is
missing, has another format, or was made from another build definition,
the command says so and runs `./gradlew` instead.

### Publishing

```zsh
nix run github:nix-purifiers/gradle-purifier -- publish
```

The command builds the package of every publishing project with Nix, from
the lockfile, then runs Gradle's `publish` (or the tasks given after
`publish`) with every Maven publication's artifacts and module metadata
replaced by the files Nix built. The build's own publishing repositories
and credentials apply, and nothing is compiled outside the sandbox. Gradle
generates the POM from the build, as it does for any publish.

## Kotlin

Kotlin JVM projects and Kotlin Multiplatform projects with JVM targets
build like Java projects: the Kotlin Gradle plugin, the compiler and the
standard library resolve through the build's repositories, and the lock
records them. The lock run and the sandbox compile in-process
(`kotlin.compiler.execution.strategy=in-process`), and `java.io.tmpdir`
points at the temporary directory of the build, where the compiler writes
its session files. A `jvmToolchain(…)` for the JDK the build runs on
needs nothing more; another version needs that JDK in `toolchainJdks`.

### Kotlin/Native

Kotlin/Native targets build too, with tests and executables. Kotlin/Native
downloads its toolchain (LLVM, a GCC toolchain with a glibc sysroot,
libffi) from download.jetbrains.com with its own downloader rather than
through Gradle's repositories. In the lock run, the recorder gives that
downloader an HTTPS tunnel to JetBrains' download hosts only, and the
command records each archive the downloader names in the build's output.
The lockfile lists them as `konanDependencies`.

In the sandbox, `buildGradleProject` unpacks those archives and patches
their programs with `autoPatchelf`, so they run on nixpkgs' loader and
libraries, and gives them to Kotlin/Native as already extracted. The
programs Kotlin/Native links name nixpkgs' dynamic linker
(`-Xoverride-konan-properties=dynamicLinker…`), so native tests run in
the sandbox and a release executable of a project is in its package's
`bin/`, without its `.kexe` suffix. The interactive mode uses the same
patched toolchain.

Three things to know:

- **Lock on JDK 17.** Kotlin/Native's compiler 2.2 crashes the JVM on JDK
  21. Lock with `gradle-purifier lock --java 17`; the builds of the lock
  then run on JDK 17 too.
- **One host.** A Kotlin/Native toolchain runs on the machine it was made
  for, so the lockfile records the host (`konanHost`), and the builder
  refuses a lock made for another.
- **NixOS.** The lock run executes the toolchain as downloaded, before
  anything can patch it, so on NixOS it needs a conventional dynamic
  loader, such as [nix-ld](https://github.com/nix-community/nix-ld)
  provides.

## Limitations

- **Kotlin/JS targets are not supported yet.** Kotlin/JS fetches Node.js
  and Yarn through Ivy repositories, which the lock records, but Yarn then
  installs npm packages from the npm registry itself, outside Gradle, and
  the prebuilt Node.js binary expects a conventional `/lib64` dynamic
  loader, which the Nix sandbox does not have. In a lock run a Kotlin/JS
  target fails at Yarn's first download.
- **Credentials.** The lock run sends a repository's `Authorization`
  header on to it, so a lock can be made from a repository that needs
  credentials. The Nix build downloads with the built-in fetcher, which
  has none; such a build needs a `fetchurl` that supplies them.
- **IDEs.** An IDE that imports the build runs Gradle itself, through the
  wrapper, and resolves the usual way.
- **The configuration cache** is off in the lock run and in the sandbox,
  because the init script's tasks read the project model.
- **Downloads in tasks.** A plugin that downloads with its own HTTP
  client, outside Gradle's repositories, fails in the lock run (the proxy
  refuses it). The file needs a repository the build declares.

## Development

`docs/development/` holds the design, the tests and the commands.
