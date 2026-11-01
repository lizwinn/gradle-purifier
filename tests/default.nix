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

  # A Kotlin/Native build with a linuxX64 library, its tests, and an
  # executable. Its lock holds the Kotlin/Native toolchain of x86_64-linux.
  kotlinNative = buildGradleProject {
    src = ./fixtures/kotlin-native;
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
  # The archives of `assemble` are in `out`, under their version-free keys.
  java-library-archives = expectFiles "java-library-archives" javaLibrary.packages.greeting [
    "share/archives/greeting.jar"
    "share/archives/greeting-sources.jar"
  ];
  java-library-artifacts = expectFiles "java-library-artifacts" javaLibrary.packages.greeting.maven [
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
  kotlin-shared-artifacts = expectFiles "kotlin-shared-artifacts" kotlinApp.packages.shared.maven [
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

  # The recorder's mapping between request paths, remote URLs and paths in
  # the tree of locked downloads (tests/RecorderTest.java).
  recorder-unit =
    runCommand "recorder-unit"
      {
        nativeBuildInputs = [ pkgs.jdk21_headless ];
      }
      ''
        cp ${../src/Recorder.java} Recorder.java
        cp ${./RecorderTest.java} RecorderTest.java
        javac -d classes Recorder.java RecorderTest.java
        java -cp classes RecorderTest
        touch $out
      '';

  # The command's parsing (tests/cli-unit.sh).
  cli-unit = runCommand "cli-unit" { nativeBuildInputs = [ pkgs.jq ]; } ''
    bash ${./cli-unit.sh} ${lib.getExe gradle-purifier}
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
# The Kotlin/Native fixture's lock holds the toolchain of x86_64-linux,
# so its checks build there.
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
  kotlin-native = kotlinNative.packages.kotlin-native;
  # The executable runs from its package, and its tests ran in the build.
  kotlin-native-runs = runCommand "kotlin-native-runs" { } ''
    output=$(${lib.getExe kotlinNative.packages.kotlin-native})
    if [ "$output" != "Hello, Nix!" ]; then
      echo "the executable printed: $output" >&2
      exit 1
    fi
    touch $out
  '';
  kotlin-native-artifacts =
    expectFiles "kotlin-native-artifacts" kotlinNative.packages.kotlin-native.maven
      [
        "nix-support/artifacts/linuxX64/kotlin-native-linuxx64.klib"
        "nix-support/artifacts/linuxX64/module"
        "nix-support/artifacts/kotlinMultiplatform/module"
      ];
}
