# Testing

The tests come in two layers.

1. **Flake checks** (`tests/default.nix`) run in the sandbox under
   `nix flake check`:
   - `gradle-purifier` builds the command, which compiles the recorder
     with warnings as errors and runs shellcheck on the script.
   - `nix-library-version` checks that `lock.nix` rejects another lock
     format.
   - The `java-library*` checks build `tests/fixtures/java-library` and
     run its tests. The fixture is a Groovy-DSL build on Gradle 8 with a
     Maven publication and a sources jar, a dynamic version (resolved
     through an inline `maven-metadata.xml`), a library from an included
     build, and a file from an Ivy repository that serves plain files by
     pattern. The checks look for the artifact links, the classes and the
     Ivy file in the package.
   - The `kotlin-*` checks build `tests/fixtures/kotlin-app` and run its
     tests. The fixture is a Kotlin-DSL build on Gradle 9 with a version
     catalog, a convention plugin in buildSrc that applies the Kotlin JVM
     plugin with a Java 21 toolchain, plugins from the plugin portal, a
     published Kotlin library, a Kotlin Multiplatform library with a JVM
     target, and an application. `kotlin-app-runs` runs the application
     from its package.
2. **Interactive tests** (`tests/interactive.sh`) run outside the sandbox
   with Gradle's network cut off (every JVM gets a proxy that refuses). On
   copies of both fixtures, each with an empty Gradle user home, the
   builds and their tests must run from the locked downloads, the
   application must run, and Gradle's download cache must stay empty.
   `gradle-purifier publish` must publish the artifacts and module
   metadata Nix built, byte for byte, without compiling the project. A
   changed build script must make the command fall back to `./gradlew`.

The lockfiles of the fixtures are test data. `tests/relock-fixtures.sh`
renews them; it needs the network.
