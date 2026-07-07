#!/usr/bin/env bash
# Cross-compile repro.scala to a linux-aarch64 ELF (works from a darwin/aarch64
# host), with a selectable toolchain, to isolate the GC crash to zig's defaults.
#
# Usage: build-one.sh <compiler> <nixpkgs-flakeref> <out-elf>
#   compiler         : "zig" | "zig-nosan" | "clang"
#                      zig       = plain zig-as-clang               → CRASHES
#                      zig-nosan = zig + -fno-sanitize=undefined    → OK (the fix)
#                      clang     = pkgsCross llvmPackages.clang (control; builds
#                                  LLVM from source — slow)
#   nixpkgs-flakeref : e.g. github:NixOS/nixpkgs/nixos-26.05
#   out-elf          : output path for the aarch64 ELF
#
# The repro has NO external C deps (no openssl/zlib), so there is no -L/-I
# closure to resolve — the only variable is the C toolchain and its libc target.
#
# Requires: nix, scala-cli.
set -euo pipefail

COMPILER="${1:?compiler: zig|zig-nosan|clang}"
NIXPKGS="${2:?nixpkgs flakeref}"
OUT="${3:?out elf path}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# glibc target pin for the zig wrappers: read the chosen nixpkgs' glibc so the
# zig-bundled glibc stubs match by construction.
GLIBC_VER="$(nix eval --raw "${NIXPKGS}#glibc.version" 2>/dev/null | sed 's/-.*//')"
echo ">> [$COMPILER @ $NIXPKGS] glibc target = ${GLIBC_VER}"

case "$COMPILER" in
  zig|zig-nosan)
    # zig cc compiles C with -fsanitize=undefined by default (stock clang does
    # not); Immix's conservative marker does intentional unaligned loads, so
    # plain "zig" panics in ubsan_rt at the first GC. "zig-nosan" restores
    # stock-clang sanitizer semantics — the fix.
    NOSAN=""
    [ "$COMPILER" = "zig-nosan" ] && NOSAN="-fno-sanitize=undefined"
    # Write rev-specific zig wrappers targeting this rev's glibc.
    WRAP="$(mktemp -d)"
    cat > "$WRAP/cc"  <<EOF
#!/bin/sh
exec zig cc -target aarch64-linux-gnu.${GLIBC_VER} ${NOSAN} "\$@"
EOF
    cat > "$WRAP/cxx" <<EOF
#!/bin/sh
exec zig c++ -target aarch64-linux-gnu.${GLIBC_VER} ${NOSAN} "\$@"
EOF
    chmod +x "$WRAP/cc" "$WRAP/cxx"
    exec nix shell "${NIXPKGS}#zig" --command \
      scala-cli --power package "$HERE" -o "$OUT" -f --native \
        --native-clang   "$WRAP/cc" \
        --native-clangpp "$WRAP/cxx"
    ;;
  clang)
    # Stock cross clang from pkgsCross — the attribution control. Its
    # clang/clang++ default-target the cross triple, so no -target flag needed.
    CROSS="legacyPackages.$(nix eval --raw --impure --expr builtins.currentSystem).pkgsCross.aarch64-multiplatform"
    CC="$(nix build --no-link --print-out-paths "${NIXPKGS}#${CROSS}.llvmPackages.clang")/bin"
    exec scala-cli --power package "$HERE" -o "$OUT" -f --native \
      --native-clang   "$CC/aarch64-unknown-linux-gnu-clang" \
      --native-clangpp "$CC/aarch64-unknown-linux-gnu-clang++"
    ;;
  *)
    echo "unknown compiler: $COMPILER" >&2; exit 2 ;;
esac
