A `ld -lazy_framework` for macOS. Designed to build Deno.

## Usage

Build the static lib (`make`), then drive the final link through `lzld` and
link `liblzld_arm64.a`:

```toml
[target.aarch64-apple-darwin]
rustflags = [
  "-C",
  "link-args=-fuse-ld=/path/to/lzld/lzld -L/path/to/lzld -llzld_arm64",
]
```

On Nix-based toolchains, set the linker driver to the system clang so the macOS
SDK (with `libiconv.tbd`) is used:

```
CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=/usr/bin/cc
```

### Usage without `lzld` wrapper

1. `rustc -Z link-native-libraries=no -L/path/to/lzld -llzld`:
Requires nightly but doesn't need a wrapper linker.

2. Manaully source modification: Remove `#[link]` attributes
from all dependencies and link to `liblzld.a`.

## Design

It's pretty simple. Drop in `lzld` as the linker. It strips `-framework` and
`-weak_framework` arguments and links a static library (`liblzld.a`) that lazy
loads each framework via `dlopen` on first use. Rest of the arguments are
passed as-is to `ld64.lld`.

Each symbol Deno imports from a stripped framework is provided as a thin shim:
on first call it `dlopen`s the framework and caches the resolved function
pointer. Data constants (which have no call to intercept) are handled per
symbol — `kCFAllocatorDefault` is `NULL` (the documented default-allocator
sentinel); `kCFTypeArrayCallBacks` / `kCFRunLoopDefaultMode` are substituted by
the wrapper shims at the use site once their framework is loaded.

### Measured effect (Deno, aarch64, warm)

Same tree and flags, lzld vs. stock link:

| invocation        | stock   | lzld    | delta              |
|-------------------|---------|---------|--------------------|
| `deno --version`  | 6.29 ms | 5.32 ms | **-0.97 ms (-15%)**|
| `deno run hello`  | 12.49 ms| 12.14 ms| -0.35 ms           |

The minimal path never touches the frameworks, so deferral is a clean win. A
full `deno run` pulls part of the framework graph back via dyld initializers, so
the gain is smaller there.

### Covered symbols

Generated from the live import set (`dyld_info -imports <deno>`):
CoreFoundation (CFArray / CFString / CFURL / CFRunLoop + data constants),
CoreServices (FSEvents), Security (Keychain), Foundation
(`NSKeyValueChangeNewKey`), Metal (`MTLCopyAllDevices`). QuartzCore,
CoreGraphics, MetalPerformanceShaders and AVFoundation are linked but import no
symbols, so they are simply dropped.

Regenerate the shim set when Deno's imports change:

```
dyld_info -imports <deno> | grep -E '\(from (CoreFoundation|CoreServices|Security|Foundation|Metal)\)'
```

Set `LZLD_TRACE=1` at runtime to print a backtrace the first time each framework
is forced to load — useful for finding startup call sites that defeat laziness.

