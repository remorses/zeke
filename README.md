# zeke

Type-safe CLI framework for Zig. Define commands with a builder chain — each
`.option()` call generates a new comptime type. Action functions receive typed
`Args` and `Options` structs. Accessing a field that doesn't exist is a compile
error, not a runtime crash.

Zero dependencies. Single `@import("zeke")`. Works with Zig 0.15+.

## Install

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zeke = .{
        .url = "https://github.com/remorses/zeke/archive/refs/heads/main.tar.gz",
    },
},
```

Then in `build.zig`:

```zig
const zeke_dep = b.dependency("zeke", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zeke", zeke_dep.module("zeke"));
```

## Usage

**Define commands** at comptime with the builder chain:

```zig
const zeke = @import("zeke");

const Serve = zeke.cmd("serve <entry>", "Start the dev server")
    .option("--port <port>", "Port number")
    .option("--host [host]", "Hostname")
    .option("--watch", "Watch mode")
    .optionMany("--tag <tag>", "Repeatable tag")
    .example("myapp serve src/index.ts --port 3000 --tag api --tag internal");
```

**Write typed action functions** — the compiler checks every field access:

```zig
fn serveAction(args: Serve.Args, opts: Serve.Options) !void {
    // args.entry → []const u8  (required, from <entry>)
    // opts.port  → []const u8  (required value)
    // opts.host  → ?[]const u8 (optional, null if absent)
    // opts.watch → bool        (flag)
    // opts.tag   → []const []const u8 (repeatable value option)
    // opts.bogus → COMPILE ERROR
    _ = .{ args, opts };
}
```

**Bind and register:**

```zig
const ServeCmd = Serve.bind(serveAction);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var app = zeke.App(.{ ServeCmd }).init(gpa.allocator(), "myapp");
    app.setVersion("1.0.0");
    try app.run();
}
```

## How it works

Each `.option()` call returns a **different comptime type** with one more struct
field, built via `@Type`. The chain is fully resolved at compile time — zero
runtime cost for the type machinery.

```
cmd("click [target]", "...")                    → T0  { Args={target:?str}, Options={} }
  .option("-x [x]", "X coordinate")            → T1  { Options={x:?str} }
  .option("--button [button]", "Mouse button") → T2  { Options={x:?str, button:?str} }
  .option("--count [count]", "Click count")    → T3  { Options={x:?str, button:?str, count:?str} }
```

The two-step `.bind(fn)` pattern breaks circular dependencies: define the command
first, write the action using its `.Args`/`.Options` types, then bind.

## Memory and ownership

zeke is designed to be allocation-minimal. Almost everything is **zero-copy slices
into the original argv** from the OS.

**What gets allocated at runtime:**

| What | When | Freed by |
|---|---|---|
| `argsWithAllocator` internal buffer | `app.run()` | `defer arg_iter.deinit()` inside `run()` |
| `optionMany` pointer slices | each repeated `--tag val` grows the slice | `defer deinitOptions()` after action returns |
| Combined positional slice | only when `--` separator is used | `defer allocator.free()` after action returns |

**All string values are borrowed, not copied.** The `[]const u8` fields in `Args`
and `Options` are pointers into the argv buffer owned by `argsWithAllocator`. This
means:

- **Do not store `args.*` or `opts.*` pointers beyond your action function.** They
  become dangling after `run()` returns. If you need to keep a value, copy it with
  `allocator.dupe(u8, value)`.
- For `optionMany`, the **slice of pointers** (`[]const []const u8`) is heap-allocated
  and freed automatically, but the **strings inside** are still borrowed from argv.

**Static limits:**

- Max **1024 argv tokens** (after skipping argv[0]). Extras are silently dropped.
- Max **512 positional args** per command. Extras are silently dropped.

These are stack-allocated fixed buffers — no heap allocation for typical CLI usage.

## Features

- **Comptime type generation** — `.option()` chain builds typed structs via `@Type`
- **Compile-time field checking** — wrong field access = compile error
- **Space-separated subcommands** — `mouse move`, `clipboard get` with longest-match dispatch
- **Short aliases** — `-p, --port <port>` or `-x [x]`
- **Repeatable value options** — `.optionMany("--tag <tag>", ...)` collects `--tag` values into a slice
- **Positional args** — `<required>`, `[optional]`, `[...variadic]`
- **Auto help** — `--help` / `-h` with aligned columns and ANSI colors
- **Command help** — `myapp serve --help` shows help for that command, including examples
- **Auto version** — `--version` / `-v`
- **Double-dash** — `--` separator for passthrough args
- **Zero dependencies** — pure Zig, no allocations in the comptime layer

## Option types

| Option string | Field type | Default |
|---|---|---|
| `--port <port>` | `[]const u8` | none (required) |
| `--host [host]` | `?[]const u8` | `null` |
| `--watch` | `bool` | `false` |
| `.optionMany("--tag <tag>", ...)` | `[]const []const u8` | empty slice |
| `--coord-map [map]` | `?[]const u8` | `null` (kebab → snake_case) |
| `-p, --port <port>` | `[]const u8` | none, short alias `p` |

## Arg types

| Name string | Generated field |
|---|---|
| `<key>` | `key: []const u8` |
| `[path]` | `path: ?[]const u8` |
| `[...files]` | `files: []const []const u8` |

## Full example

See [`example/main.zig`](example/main.zig) for a usecomputer-style CLI with 9
commands including space-separated subcommands (`mouse move`, `display list`,
`clipboard get/set`).

```
$ myapp --help

usecomputer/0.1.0

Usage:
  $ usecomputer <command> [options]

Commands:
  screenshot [path]            Take a screenshot
    --region [region]          Capture specific region (x,y,w,h)
    --display [id]             Target display
    --annotate                 Annotate with grid overlay
    --json                     Output as JSON
  click [target]               Click at coordinates or target
    -x [x]                     X coordinate
    -y [y]                     Y coordinate
    --button [button]          Mouse button: left, right, middle
  press <key>                  Press a key or key combination
  mouse move [x] [y]          Move to absolute coordinates
  mouse position               Print current mouse position
  display list                 List connected displays
  clipboard get                Print clipboard text
  clipboard set <text>         Set clipboard text

Options:
  -h, --help     Display this message
  -v, --version  Display version number
```

## License

MIT
