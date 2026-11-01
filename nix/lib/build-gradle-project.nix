# buildGradleProject: the sandboxed builds of a Gradle build, from the
# lockfile `gradle-purifier lock` writes at the build root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# gradle-purifier overlay (`overlays.default`) adds it to the package set
# as `buildGradleProject`, so a package written for callPackage takes it
# like any other dependency:
#
#   { buildGradleProject }: (buildGradleProject { src = ./.; }).packages.app
#
# and `buildGradleProject.override` replaces what it takes from the set.
# The builder returns
#
#   repository       the tree of every locked download
#   distribution     the Gradle distribution of the lock, unpacked
#   packages.<id>    a package per project the lock names: one with an
#                    application holds the installed application (bin/ and
#                    lib/); one with Maven publications holds them in Maven
#                    layout, in the `maven` output when the project has an
#                    application and in `out` otherwise
{
  lib,
  stdenvNoCC,
  callPackage,
  makeWrapper,
  unzip,
  # The JDKs a build can run on; the default JDK of a build is the headless
  # one of the major version its lock was made with.
  javaPackages,
}:
{
  # The root of the Gradle build.
  src,
  # The lockfile; the default is the one `gradle-purifier lock` writes at
  # the build root.
  lockFile ? src + "/gradle-purifier.lock.json",
  # The JDK that runs Gradle and the applications.
  jdk ? null,
  # Further JDKs for the build's Java toolchains, when a toolchain asks for
  # another Java version than `jdk`. Gradle downloads no toolchain in the
  # sandbox.
  toolchainJdks ? [ ],
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
  # Runs the checks of each project (`check`) in its package build.
  doCheck ? false,
  # Filters the build root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out Gradle's state,
  # build outputs and editor state.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # A directory named build is a build output when a build script or a
  # settings script sits beside it.
  isBuildOutput =
    path:
    let
      parent = dirOf path;
    in
    lib.any (script: builtins.pathExists (parent + "/${script}")) [
      "build.gradle"
      "build.gradle.kts"
      "settings.gradle"
      "settings.gradle.kts"
    ];

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (
        type == "directory"
        && (lib.elem name [
          ".gradle"
          ".kotlin"
          ".idea"
        ])
      )
      || (type == "directory" && name == "build" && isBuildOutput path)
      || name == ".git"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "gradle-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  javaMajor = builtins.head (lib.splitString "." lock.javaVersion);
  defaultJdk =
    javaPackages.compiler."openjdk${javaMajor}".headless
      or (throw "gradle-purifier: javaPackages has no openjdk${javaMajor} for the Java ${lock.javaVersion} the lock was made with; pass `jdk`.");
  jdk' = if jdk != null then jdk else defaultJdk;
  javaHome = j: j.home or "${j}/lib/openjdk";

  repository = callPackage ./repository.nix { inherit lockFile fetchurl; };

  distribution = stdenvNoCC.mkDerivation {
    name = "gradle-${lock.gradleVersion}";
    src = "${repository}/${lock.distribution}";
    nativeBuildInputs = [ unzip ];
    dontConfigure = true;
    dontBuild = true;
    unpackPhase = ''
      runHook preUnpack
      unzip -q "$src"
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      mv gradle-* "$out"
      runHook postInstall
    '';
    # The distribution is jars and two start scripts; fixup only rewrites
    # the start scripts' shebangs.
    dontStrip = true;
  };

  initScript = ./purifier.init.gradle;
  portal = "https/plugins.gradle.org/m2";

  # The Gradle invocation shared by every package build; the lock run
  # (`gradle-purifier lock`) runs Gradle the same way, so a lock made with
  # it holds what this needs.
  runGradle = tasks: ''
    export HOME="$TMPDIR/home"
    export GRADLE_USER_HOME="$TMPDIR/gradle-home"
    export GRADLE_PURIFIER_MODE=sandbox
    export GRADLE_PURIFIER_REPOSITORY=file://${repository}
    export GRADLE_PURIFIER_OUTPUT="$TMPDIR/purifier-output"
    export GRADLE_PURIFIER_CHECK=${if doCheck then "1" else "0"}
    export JAVA_HOME=${javaHome jdk'}
    mkdir -p "$HOME" "$GRADLE_USER_HOME"
    ${distribution}/bin/gradle \
      --offline --no-daemon --no-configuration-cache --no-build-cache --no-watch-fs \
      --console=plain --stacktrace \
      --init-script ${initScript} \
      -Dorg.gradle.internal.plugins.portal.url.override=file://${repository}/${portal} \
      -Dorg.gradle.native=false \
      -Djava.io.tmpdir="$TMPDIR" \
      -Porg.gradle.java.installations.auto-download=false \
      -Porg.gradle.java.installations.auto-detect=false \
      -Porg.gradle.java.installations.paths=${
        lib.concatMapStringsSep "," javaHome ([ jdk' ] ++ toolchainJdks)
      } \
      -Pkotlin.compiler.execution.strategy=in-process \
      ${lib.escapeShellArgs lock.gradleArguments} \
      ${lib.escapeShellArgs tasks} </dev/null
  '';

  # The build links each artifact of a publication, its POM and its Gradle
  # module metadata at names without the version of the project:
  # <linkDirectory>/<publication>/<key>, …/descriptor and …/module.
  linkDirectory = "nix-support/artifacts";

  mkPackage =
    project:
    let
      hasApplication = project.application != null;
      hasPublications = project.publications != [ ];
      mavenOutput = if hasApplication then "maven" else "out";
      artifactFile =
        package: publication: key:
        "${package.${mavenOutput}}/${linkDirectory}/${publication}/${key}";
      taskPath = if project.path == ":" then ":purifierBuild" else "${project.path}:purifierBuild";
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      name = project.id;
      src = filteredSrc;
      outputs = [ "out" ] ++ lib.optional (hasApplication && hasPublications) "maven";
      nativeBuildInputs = [ makeWrapper ];
      dontConfigure = true;
      # The outputs are jars, POMs and start scripts; fixup has nothing to
      # patch, and it must not rewrite the jars.
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${runGradle [ taskPath ]}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        built="$GRADLE_PURIFIER_OUTPUT/${project.id}"
        ${lib.optionalString hasApplication ''
          cp -r "$built/application" "$out"
          rm -f "$out"/bin/*.bat
          wrapProgram "$out/bin/${project.application.name}" --set-default JAVA_HOME ${javaHome jdk'}
        ''}
        ${lib.optionalString hasPublications ''
          maven=''$${mavenOutput}
          cp -r "$built/maven" "$maven"
          link() {
            # $1 publication, $2 key, $3 the artifact's directory, $4 its
            # file name after "<artifactId>-<version>", and $5 "optional"
            # for a file the build may leave out.
            local dir=$3 version
            version=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
            local file="$dir/$version/$(basename "$dir")-$version$4"
            if [ ! -f "$file" ] && [ "''${5:-}" = optional ]; then
              return 0
            fi
            if [ ! -f "$file" ]; then
              echo "gradle-purifier: the lock names $1/$2, which this build of ${project.id} did not publish; run gradle-purifier lock" >&2
              exit 1
            fi
            mkdir -p "$maven/${linkDirectory}/$1"
            ln -s "$file" "$maven/${linkDirectory}/$1/$2"
          }
          ${lib.concatMapStrings (
            publication:
            let
              dir = "$maven/${lib.replaceStrings [ "." ] [ "/" ] publication.groupId}/${publication.artifactId}";
              suffix = a: (if a.classifier != null then "-${a.classifier}" else "") + ".${a.extension}";
            in
            ''
              link ${publication.name} descriptor "${dir}" .pom
              link ${publication.name} module "${dir}" .module optional
            ''
            + lib.concatMapStrings (a: ''
              link ${publication.name} ${lib.escapeShellArg a.key} "${dir}" ${lib.escapeShellArg (suffix a)}
            '') publication.artifacts
          ) project.publications}
        ''}
        runHook postInstall
      '';
      passthru = {
        inherit repository distribution lock;
        gradleProject = project;
        # The artifact files of the package by publication and key, such
        # as artifacts.maven."core-sources.jar". They are known from the
        # lock alone, before the package is built.
        artifacts = builtins.listToAttrs (
          map (publication: {
            inherit (publication) name;
            value = builtins.listToAttrs (
              map (a: {
                name = a.key;
                value = artifactFile finalAttrs.finalPackage publication.name a.key;
              }) publication.artifacts
            );
          }) project.publications
        );
      };
      meta = {
        description = "${project.path} of a Gradle build, built by gradle-purifier";
      }
      // lib.optionalAttrs hasApplication { mainProgram = project.application.name; };
    });

  packages = builtins.mapAttrs (_: mkPackage) lock.projectsById;
in
{
  inherit
    lock
    repository
    distribution
    packages
    ;
  jdk = jdk';
}
