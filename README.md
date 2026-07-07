# Scala Native + `zig cc`: Immix GC "misaligned address" panic on aarch64

A ~50-line dependency-free Scala Native program that **panics at the first
Immix GC collection** when cross-compiled with zig-as-clang
(`zig cc -target aarch64-linux-gnu.<glibc>`), and the one-flag fix.

**TL;DR:** the panic is **not** a hardware alignment fault and not a zig
codegen/ABI bug. `zig cc` compiles C with `-fsanitize=undefined` **by default**
(stock clang doesn't), and Scala Native's `NO_SANITIZE` guard in the GC doesn't
cover UBSan — so UBSan's alignment check fires on the conservative marker's
*intentional* unaligned loads. Fix: add **`-fno-sanitize=undefined`** to the
zig `cc`/`c++` wrappers.

## The crash

```
thread 1 panic: load of misaligned address 0x… for type 'word_t *'
    (aka 'unsigned long *'), which requires 8 byte alignment
  scala-native/gc/immix/Marker.c:149  Marker_markRange
  scala-native/gc/immix/Marker.c:197  Marker_markProgramStack
  scala-native/gc/immix/Marker.c:227  Marker_MarkRoots
  scala-native/gc/immix/Heap.c:176    Heap_Collect
  scala-native/gc/immix/Allocator.c   Allocator_allocSlow → Allocator_Alloc
  scala-native/gc/immix/ImmixGC.c:52  scalanative_GC_alloc
```

Deterministic on the first collection. Runs fine on real aarch64 hardware and
under `--platform linux/arm64` Docker emulation alike — when built with stock
clang, or with zig + the fix.

## Environment

- Host: macOS, Apple Silicon (aarch64-darwin) — but nothing here is
  darwin-specific
- Target: linux/aarch64 (real hardware **and** `--platform linux/arm64` Docker
  — not an emulation artifact)
- Scala 3.8.4, Scala Native 0.5.12
- zig 0.16.0 (as the C/C++ cross compiler)

## Root cause

`thread 1 panic:` is the format of **zig's bundled UBSan runtime**
(`ubsan_rt.zig` — visible via `strings` on the crashing binary). aarch64 Linux
permits unaligned loads on normal memory; nothing traps on hardware. The chain:

1. **`zig cc` compiles C with `-fsanitize=undefined` by default**, unlike stock
   clang. Every Scala Native GC `.c` file gets UBSan-instrumented, with zig's
   panic runtime linked in.
2. Scala Native anticipates sanitizers on the conservative marker —
   `Marker_markRange` is annotated `NO_SANITIZE` — but the guard doesn't
   activate: [`gc/shared/GCTypes.h`][gctypes] only defines a real `NO_SANITIZE`
   under `__has_feature(address_sanitizer)` or
   `__has_feature(thread_sanitizer)`. **UBSan sets neither feature**, so under
   `-fsanitize=undefined` the macro expands to nothing and the marker is
   instrumented after all.
3. The UB site UBSan trips on is the **registers-buffer scan**, not the main
   stack walk (`Marker_markRange` alignment-masks its start address, and the
   program-stack call at Marker.c:187 strides by `sizeof(word_t)` — those loads
   are all 8-aligned). On every non-x86 target, `RegistersCapture.h` takes the
   `CAPTURE_SETJMP` branch (registers captured via `setjmp` into a `jmp_buf`),
   and `Marker_markProgramStack` — Marker.c:197, the exact frame in the trace —
   deliberately scans that buffer with `stride = sizeof(uint32_t)` ("Pointers
   in jmp_buf might be non word-size aligned"). Every other 8-byte load is
   4-aligned: benign on hardware, a guaranteed UBSan alignment panic. The
   faulting addresses observed (e.g. `…2c4`) are 4-but-not-8-aligned, matching.

This also explains why x86_64 doesn't crash even under zig: x86/x86_64 take the
hand-rolled `CAPTURE_X86` / `CAPTURE_X86_64` branch (a struct of aligned
`void *`s, scanned at word stride) — the UB path simply doesn't exist there.
It's not that x86 "tolerates" the unaligned load; the load never happens.

[gctypes]: https://github.com/scala-native/scala-native/blob/v0.5.12/nativelib/src/main/resources/scala-native/gc/shared/GCTypes.h

## Result matrix

| # | C toolchain | GC | Outcome |
|---|-------------|-----|---------|
| 1 | zig 0.16.0 | immix (default) | **CRASH** — ubsan_rt panic in `Marker_markRange` |
| 2 | zig 0.16.0 | none | OK — `ok: -66560` (no marker → the UB never executes) |
| 3 | zig 0.16.0 **+ `-fno-sanitize=undefined`** | immix (default) | **OK** — `ok: -66560` (the fix) |
| 4 | stock clang (native or `pkgsCross`) | immix (default) | OK — no UBSan by default |

## The fix

Add `-fno-sanitize=undefined` wherever you wrap `zig cc` as a Scala Native
toolchain:

```sh
exec zig cc -target aarch64-linux-gnu.2.42 -fno-sanitize=undefined "$@"
```

This restores stock-clang sanitizer semantics — i.e. exactly what every
non-zig Scala Native build gets. `-fno-sanitize=alignment` alone silences this
particular site, but conservative-GC code has other benign UB, so disabling the
whole `undefined` group is the safer, parity-preserving choice.

**Upstream:** the tighter fix is in Scala Native itself — `GCTypes.h` should
also gate on `__has_feature(undefined_behavior_sanitizer)` (and apply
`no_sanitize("undefined")` / `disable_sanitizer_instrumentation`) so
`NO_SANITIZE` covers UBSan builds too. Then zig's defaults would work out of
the box.

## Reproduce

Requires nix, scala-cli, and docker (or real aarch64-linux hardware to run on).

```bash
# 1. zig, default flags → crash
./build-one.sh zig github:NixOS/nixpkgs/nixos-26.05 ./repro-zig
docker run --rm --platform linux/arm64 -v "$PWD/repro-zig:/repro:ro" debian:stable-slim /repro

# 2. zig + -fno-sanitize=undefined → clean (THE FIX)
./build-one.sh zig-nosan github:NixOS/nixpkgs/nixos-26.05 ./repro-zig-nosan
docker run --rm --platform linux/arm64 -v "$PWD/repro-zig-nosan:/repro:ro" debian:stable-slim /repro
# → ok: -66560

# Confirm the mechanism: zig's UBSan runtime is only in the crashing binary
strings ./repro-zig       | grep -c ubsan_rt   # > 0
strings ./repro-zig-nosan | grep -c ubsan_rt   # 0
```

`repro.scala` is the whole program; `build-one.sh <zig|zig-nosan|clang> <nixpkgs> <out>`
is the cross-build harness (no external C deps — no `-L`/`-I` closure).

## Reproducing without zig

zig is incidental — it merely enables UBSan by default. The same diagnostic
reproduces with **stock clang, natively, no cross-compilation**, on any AArch64
machine (e.g. an Apple Silicon Mac — darwin/aarch64 takes the same
`CAPTURE_SETJMP` path):

```bash
scala-cli --power package . -o ./repro-ubsan -f --native \
  --native-compile -fsanitize=undefined --native-linking -fsanitize=undefined
./repro-ubsan
# Marker.c:149:24: runtime error: load of misaligned address 0x… for type
#   'word_t *' (aka 'unsigned long *'), which requires 8 byte alignment
# SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior … Marker.c:149:24
```

Stock clang's UBSan defaults to recover mode (prints and continues — the run
still ends in `ok: -66560`); zig's runtime is trap-mode, which is why the same
check aborts there. Note that Scala Native 0.5 officially supports UBSan via
`NativeConfig.sanitizer` (`scala.scalanative.build.Sanitizer.UndefinedBehaviourSanitizer`),
so this is reachable through first-party configuration alone.
