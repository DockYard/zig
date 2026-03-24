# Zap — Zig Compiler Fork

This is a fork of the [Zig compiler](https://github.com/ziglang/zig) (v0.15.x)
maintained by [DockYard](https://dockyard.com) for the **Zap** programming
language.

Zap compiles to [ZIR](https://ziglang.org/documentation/master/#Zig-Intermediate-Representation)
(Zig Intermediate Representation), reusing Zig's semantic analysis, code
generation, and linking pipeline rather than implementing a full toolchain from
scratch.

## What This Fork Adds

A **ZIR Library API** (`src/zir_api.zig` and `src/zir_builder.zig`) that
exposes Zig's compilation pipeline through a C ABI, allowing external compilers
like Zap to:

- **Build ZIR programmatically** — 50+ builder functions for emitting
  instructions (values, operators, control flow, function calls, struct/array
  init, imports, etc.)
- **Inject ZIR directly** — bypass Zig's parser and AstGen stages by feeding
  pre-built ZIR bytecode into the compiler
- **Drive compilation** — create compilation contexts, register modules, link
  system libraries, and run the full compilation pipeline
- **Configure output** — select output mode (executable, library, object),
  optimization level, and linking options

The fork also adds a `lib` build target in `build.zig` that produces
`libzig_compiler.a` for linking into external projects.

## How Zap Uses This

```
Zap source → Zap parser/AST → ZIR (via zir_builder C API)
                                  ↓
                          zir_compilation_create()
                          zir_compilation_add_zir()
                          zir_compilation_add_module()
                          zir_compilation_update()
                                  ↓
                          Native binary (via Zig backend)
```

## Building

### As a Library (for Zap)

```
zig build lib
```

This produces `libzig_compiler.a` which Zap links against.

### As a Standalone Compiler

The standard Zig build process still works:

```
mkdir build
cd build
cmake ..
make install
```

**Dependencies:** CMake >= 3.15, system C/C++ toolchain, LLVM/Clang/LLD == 20.x

See the upstream [Building Zig From Source](https://github.com/ziglang/zig/wiki/Building-Zig-From-Source)
wiki page for details.

## Upstream Zig

For Zig language documentation, downloads, and community resources, see
[ziglang.org](https://ziglang.org/).

## License

Same license as upstream Zig — see [LICENSE](LICENSE).
