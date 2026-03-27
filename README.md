# Zap Zig Fork

This is a fork of the [Zig compiler](https://codeberg.org/ziglang/zig) (v0.15.2) maintained by [DockYard](https://dockyard.com) for the [Zap](https://github.com/DockYard/zap) programming language.

## Why This Fork Exists

Zap is a functional programming language that compiles to native binaries. Rather than implementing its own code generation and linking, Zap lowers directly to ZIR (Zig Intermediate Representation) and feeds it into Zig's compilation pipeline — getting LLVM optimization, native code generation, and cross-platform linking for free.

Upstream Zig doesn't expose its compilation pipeline as a library. This fork adds a C-ABI surface that lets external compilers drive Zig's internals programmatically.

## What This Fork Adds

**ZIR Library API** (`src/zir_api.zig` and `src/zir_builder.zig`) — a C-ABI interface to Zig's compilation pipeline:

- **Build ZIR programmatically** — 50+ builder functions for emitting instructions (values, operators, control flow, function calls, struct/array init, imports, etc.)
- **Inject ZIR directly** — bypass Zig's parser and AstGen, feeding pre-built ZIR bytecode into the compiler
- **Drive compilation** — create compilation contexts, register modules, link system libraries, run sema + codegen + link
- **Configure output** — executable/library/object output, optimization level, strip, static LLVM linking

**`lib` build target** in `build.zig` — produces `libzap_compiler.a`, a static library that Zap links against.

## How Zap Uses This

```
Zap source -> Lexer -> Parser -> Type Checker -> HIR -> IR
                                                         |
                                                         v
                                              ZIR (via C-ABI builder)
                                                         |
                                                         v
                                              zir_compilation_create()
                                              zir_compilation_add_zir()
                                              zir_compilation_update()
                                                         |
                                                         v
                                              Native binary (LLVM backend)
```

## Pre-built Libraries

Pre-built `libzap_compiler.a` and LLVM static libraries for each platform are available on the [Releases](https://github.com/DockYard/zig/releases) page. These are what you need to build Zap from source without compiling the entire Zig toolchain.

| Platform | File |
|---|---|
| macOS Apple Silicon | `zap-deps-aarch64-macos-none.tar.xz` |
| Linux arm64 | `zap-deps-aarch64-linux-gnu.tar.xz` |
| Linux x86_64 | `zap-deps-x86_64-linux-gnu.tar.xz` |

Each tarball contains `libzap_compiler.a` and `llvm-libs/` with all LLVM/Clang/LLD static libraries.

## Building From Source

If you want to build `libzap_compiler.a` yourself, the process follows the official [zig-bootstrap](https://codeberg.org/ziglang/zig-bootstrap) methodology. See the [Zap README](https://github.com/DockYard/zap#building-the-zig-fork) for step-by-step instructions.

The short version:

```sh
# 1. Clone zig-bootstrap 0.15.2 (bundles LLVM 20 source)
git clone --depth 1 --branch 0.15.2 https://codeberg.org/ziglang/zig-bootstrap.git

# 2. Build LLVM + host Zig (phases 1-3 of zig-bootstrap)
cd zig-bootstrap && ./build aarch64-macos-none baseline

# 3. Build libzap_compiler.a using the host Zig
cd /path/to/this/repo
zig-bootstrap/out/host/bin/zig build lib \
  --search-prefix zig-bootstrap/out/aarch64-macos-none-baseline \
  -Dstatic-llvm -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none -Dcpu=baseline
```

## Upstream Zig

This fork tracks Zig v0.15.2. For Zig language documentation, downloads, and community resources, see [ziglang.org](https://ziglang.org/) and [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig).

## License

Same license as upstream Zig — see [LICENSE](LICENSE).
