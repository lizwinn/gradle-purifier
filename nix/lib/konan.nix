# The Kotlin/Native toolchain of a lockfile, as the `dependencies`
# directory of a Kotlin/Native data directory (KONAN_DATA_DIR): every
# archive of the lock's `konanDependencies` unpacked into a directory of
# its name, and `.extracted` naming them, which tells Kotlin/Native that
# they need no download.
#
# Kotlin/Native's archives hold prebuilt programs (LLVM's clang and lld,
# a GCC toolchain) that expect a conventional dynamic loader and system
# libraries. autoPatchelf points them at nixpkgs' loader and libraries, so
# they run in the sandbox. The GCC toolchain also holds the sysroot of
# the target: a glibc 2.19 that the programs Kotlin/Native links are
# linked against. autoPatchelf resolves libraries from every file it
# patches, so it patches everything but the sysroot, which stays as it is
# and is not where the toolchain's own libraries come from.
#
# It is a package for callPackage, with the lockfile among its arguments.
{
  lib,
  stdenv,
  autoPatchelfHook,
  zlib,
  ncurses,
  libxml2,
  lockFile,
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl; };
  byPath = builtins.listToAttrs (
    map (a: {
      name = a.path;
      value = a;
    }) lock.artifacts
  );
  archives = map (
    path:
    byPath.${path}
      or (throw "gradle-purifier: the lock names the Kotlin/Native archive ${path}, which it does not hold; run gradle-purifier lock --relock")
  ) (lock.konanDependencies or [ ]);
  nameOf = archive: lib.removeSuffix ".tar.gz" (builtins.baseNameOf archive.path);
in
stdenv.mkDerivation {
  name = "kotlin-native-dependencies";
  srcs = map fetch archives;
  dontUnpack = true;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
    ncurses
    libxml2
  ];
  # Some libraries of the toolchain, such as lldb's Python support, need
  # what no build uses.
  autoPatchelfIgnoreMissingDeps = true;
  # The fixup leaves the archives as they are (the target sysroot's
  # libraries and objects are link inputs); postFixup patches the
  # toolchain's own programs.
  dontAutoPatchelf = true;
  dontStrip = true;
  dontPatchELF = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    for archive in $srcs; do
      tar -xzf "$archive" -C "$out"
    done
    printf '%s\n' ${lib.escapeShellArgs (map nameOf archives)} > "$out/.extracted"
    runHook postInstall
  '';
  postFixup = ''
    mapfile -t programs < <(find "$out" -name sysroot -prune -o -type f \( -perm -u+x -o -name '*.so*' \) -print)
    autoPatchelf -- "''${programs[@]}"
  '';
  passthru.names = map nameOf archives;
}
