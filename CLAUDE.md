# Zap Zig Fork

This is a fork of Zig 0.15.2 that adds a C-ABI surface (`src/zir_api.zig`, `src/zir_builder.zig`) so the Zap compiler can drive Zig's compilation pipeline programmatically. The `lib` build target in `build.zig` produces `libzap_compiler.a`.

## Repository layout

- `src/zir_api.zig` / `src/zir_builder.zig` — C-ABI interface (the Zap-specific additions)
- `build.zig` — the `lib` step builds `libzap_compiler.a`
- `ci/` — upstream Zig CI scripts (not used for release tarballs)

## Branches

- `zap-zir-library` — active development branch, rebased on top of the `0.15.2` tag
- `master` — separate upstream-tracking history; the previous release tag (`v0.15.2-zap.1`) was pointed here but future releases should target `zap-zir-library`

## Creating a new release

When asked to "add a new release" or "push a release", follow these steps exactly. Every release MUST include all three platform tarballs: macOS ARM, Linux ARM, and Linux x86_64.

### 1. Determine the new version tag

The naming convention is `v0.15.2-zap.N` where N increments from the last release. Check:

```sh
gh release list --repo DockYard/zig --limit 5
```

### 2. Verify bootstrap LLVM libs exist for all targets (one-time)

The zig-bootstrap at `~/projects/zig-bootstrap/` cross-compiles LLVM (+ zlib + zstd) for each target. This only needs to happen once — not per release. All three targets are currently built.

```sh
ls ~/projects/zig-bootstrap/out/ | grep baseline
# Expected: aarch64-linux-gnu-baseline, aarch64-macos-none-baseline, x86_64-linux-gnu-baseline
```

If a target is missing, run the full bootstrap sequence for it. The `build` script in zig-bootstrap handles the complete process (zlib, zstd, then LLVM cross-compile):

```sh
cd ~/projects/zig-bootstrap && ./build <target> baseline
# e.g.: ./build x86_64-linux-gnu baseline
```

This uses the host Zig to cross-compile everything — no Linux machine needed.

### 3. Build `libzap_compiler.a` for all three targets

The bootstrap does NOT need to be re-run for releases — only `libzap_compiler.a` needs rebuilding when ZIR API code changes. Run from this repo's root:

```sh
ZIG=~/projects/zig-bootstrap/out/host/bin/zig
BOOTSTRAP=~/projects/zig-bootstrap/out

# macOS Apple Silicon
$ZIG build lib \
  --search-prefix $BOOTSTRAP/aarch64-macos-none-baseline \
  -Dstatic-llvm -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none -Dcpu=baseline
cp zig-out/lib/libzap_compiler.a /tmp/libzap_compiler-aarch64-macos-none.a

# Linux ARM
$ZIG build lib \
  --search-prefix $BOOTSTRAP/aarch64-linux-gnu-baseline \
  -Dstatic-llvm -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-linux-gnu -Dcpu=baseline
cp zig-out/lib/libzap_compiler.a /tmp/libzap_compiler-aarch64-linux-gnu.a

# Linux x86_64
$ZIG build lib \
  --search-prefix $BOOTSTRAP/x86_64-linux-gnu-baseline \
  -Dstatic-llvm -Doptimize=ReleaseSafe \
  -Dtarget=x86_64-linux-gnu -Dcpu=baseline
cp zig-out/lib/libzap_compiler.a /tmp/libzap_compiler-x86_64-linux-gnu.a
```

Each `zig build lib` overwrites `zig-out/lib/libzap_compiler.a`, so copy after each build.

### 4. Package all three tarballs

Each tarball structure is `<target>/libzap_compiler.a` + `<target>/llvm-libs/*.a`:

```sh
BOOTSTRAP=~/projects/zig-bootstrap/out

for TARGET in aarch64-macos-none aarch64-linux-gnu x86_64-linux-gnu; do
  STAGING=$(mktemp -d)
  mkdir -p "$STAGING/$TARGET/llvm-libs"
  cp "/tmp/libzap_compiler-$TARGET.a" "$STAGING/$TARGET/libzap_compiler.a"
  cp "$BOOTSTRAP/$TARGET-baseline/lib/"*.a "$STAGING/$TARGET/llvm-libs/"
  tar cJf "zap-deps-$TARGET.tar.xz" -C "$STAGING" "$TARGET"
  rm -rf "$STAGING"
done
```

### 5. Create the GitHub release

```sh
VERSION=v0.15.2-zap.N  # replace N

gh release create "$VERSION" \
  --repo DockYard/zig \
  --target zap-zir-library \
  --title "Zap Compiler Dependencies $VERSION" \
  --notes "$(cat <<'EOF'
Pre-built `libzap_compiler.a` and LLVM 20 static libraries for building Zap from source.

Based on Zig 0.15.2 with ZIR API extensions for Zap.

## Usage

Download the tarball for your platform, extract it, then build Zap:

```sh
tar xJf zap-deps-aarch64-macos-none.tar.xz
cd ~/projects/zap
zig build \
  -Dzap-compiler-lib=aarch64-macos-none/libzap_compiler.a \
  -Dllvm-lib-path=aarch64-macos-none/llvm-libs
```

## Platforms

| File | Platform |
|---|---|
| `zap-deps-aarch64-macos-none.tar.xz` | macOS Apple Silicon |
| `zap-deps-aarch64-linux-gnu.tar.xz` | Linux arm64 |
| `zap-deps-x86_64-linux-gnu.tar.xz` | Linux x86_64 |

Built with zig-bootstrap 0.15.2 process (LLVM 20, no LTO, native objects).
EOF
)" \
  zap-deps-aarch64-macos-none.tar.xz \
  zap-deps-aarch64-linux-gnu.tar.xz \
  zap-deps-x86_64-linux-gnu.tar.xz
```

### 6. Verify

```sh
gh release view "$VERSION" --repo DockYard/zig
```

### 7. Clean up

```sh
rm -f /tmp/libzap_compiler-*.a
rm -f zap-deps-*.tar.xz
```

## Key paths

| What | Where |
|---|---|
| zig-bootstrap root | `~/projects/zig-bootstrap/` |
| Bootstrap build script | `~/projects/zig-bootstrap/build` |
| Host zig binary | `~/projects/zig-bootstrap/out/host/bin/zig` |
| LLVM libs (macOS ARM) | `~/projects/zig-bootstrap/out/aarch64-macos-none-baseline/lib/*.a` |
| LLVM libs (Linux ARM) | `~/projects/zig-bootstrap/out/aarch64-linux-gnu-baseline/lib/*.a` |
| LLVM libs (Linux x86_64) | `~/projects/zig-bootstrap/out/x86_64-linux-gnu-baseline/lib/*.a` |
| Built libzap_compiler.a | `zig-out/lib/libzap_compiler.a` (overwritten per target) |
