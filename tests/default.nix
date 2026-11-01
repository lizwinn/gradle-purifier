# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked artifacts.
{
  pkgs,
  # The flake's default package overlay, which adds buildGradleProject.
  overlay,
  gradle-purifier,
}:
let
  inherit (pkgs) lib runCommand;

  # Every fixture builds the way a consumer's package does: through
  # buildGradleProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildGradleProject;

  # A Java library in the Groovy DSL on Gradle 8, with a Maven publication
  # that carries a sources jar, and JUnit tests that run in the build.
  javaLibrary = buildGradleProject {
    src = ./fixtures/java-library;
    doCheck = true;
  };

  # A Kotlin build in the Kotlin DSL on Gradle 9: a version catalog, a
  # convention plugin in buildSrc that applies the Kotlin JVM plugin with a
  # Java 21 toolchain, a published library with kotlinx-coroutines and
  # tests, and an application that uses it.
  kotlinApp = buildGradleProject {
    src = ./fixtures/kotlin-app;
    doCheck = true;
  };

  # Fails unless every file of `files` (paths relative to `root`) exists.
  expectFiles =
    name: root: files:
    runCommand name { } ''
      ${lib.concatMapStrings (f: ''
        if [ ! -e ${root}/${f} ]; then
          echo "missing: ${f}" >&2
          exit 1
        fi
      '') files}
      touch $out
    '';

  # Fails unless the jar `jar` holds the class file `class`.
  expectClass =
    name: jar: class:
    runCommand name { nativeBuildInputs = [ pkgs.unzip ]; } ''
      unzip -l ${jar} | grep -q ' ${class}$' || { echo "${jar} holds no ${class}" >&2; exit 1; }
      touch $out
    '';
in
{
  inherit gradle-purifier;

  java-library = javaLibrary.packages.greeting;
  java-library-artifacts = expectFiles "java-library-artifacts" javaLibrary.packages.greeting [
    "nix-support/artifacts/maven/greeting.jar"
    "nix-support/artifacts/maven/greeting-sources.jar"
    "nix-support/artifacts/maven/descriptor"
    "nix-support/artifacts/maven/module"
    "example/greeting/1.0.0/greeting-1.0.0.jar"
  ];
  java-library-classes =
    expectClass "java-library-classes" javaLibrary.packages.greeting.artifacts.maven."greeting.jar"
      "example/Greeting.class";

  # The file the build fetched from an Ivy repository is in the jar.
  java-library-ivy-resource =
    expectClass "java-library-ivy-resource" javaLibrary.packages.greeting.artifacts.maven."greeting.jar"
      "node-checksums.txt";

  # The Multiplatform library publishes the JVM variant and the root
  # publication that points at it, each with its module metadata.
  kotlin-shared = kotlinApp.packages.shared;
  kotlin-shared-artifacts = expectFiles "kotlin-shared-artifacts" kotlinApp.packages.shared [
    "nix-support/artifacts/jvm/shared-jvm.jar"
    "nix-support/artifacts/jvm/module"
    "nix-support/artifacts/kotlinMultiplatform/shared-kotlin-tooling-metadata.json"
    "nix-support/artifacts/kotlinMultiplatform/module"
  ];
  kotlin-shared-classes =
    expectClass "kotlin-shared-classes" kotlinApp.packages.shared.artifacts.jvm."shared-jvm.jar"
      "example/shared/PunctuationKt.class";

  kotlin-core = kotlinApp.packages.core;
  kotlin-core-classes =
    expectClass "kotlin-core-classes" kotlinApp.packages.core.artifacts.maven."core.jar"
      "example/core/GreeterKt.class";

  kotlin-app = kotlinApp.packages.app;
  # The application runs from its package alone, on the JDK its start
  # script was wrapped with.
  kotlin-app-runs = runCommand "kotlin-app-runs" { } ''
    output=$(${lib.getExe kotlinApp.packages.app})
    if [ "$output" != "Hello, Nix!" ]; then
      echo "the app printed: $output" >&2
      exit 1
    fi
    touch $out
  '';

  # lock.nix reads only the format version it knows.
  nix-library-version =
    let
      result = builtins.tryEval (
        (import ../nix/lib/lock.nix {
          lockFile = builtins.toFile "lock.json" (
            builtins.toJSON {
              version = 0;
              projects = [ ];
              artifacts = [ ];
            }
          );
        }).version
      );
    in
    assert !result.success;
    runCommand "nix-library-version" { } "touch $out";
}
