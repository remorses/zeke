/// Runtime CLI engine.
///
/// App() is a comptime function that takes a tuple of bound commands and returns
/// a runtime type that can parse argv and dispatch to the matched command.
///
/// Usage:
///   var app = zeke.App(.{ ServeCmd, BuildCmd }).init(allocator, "myapp");
///   app.setVersion("1.0.0");
///   try app.run();
const std = @import("std");
const builder = @import("builder.zig");

const OptionKind = builder.OptionKind;
const OptionSpec = builder.OptionSpec;
const ArgSpec = builder.ArgSpec;

// ─── ANSI helpers ───

const File = std.fs.File;
const StdWriter = File.DeprecatedWriter;

fn getStdout() StdWriter {
    return File.stdout().deprecatedWriter();
}

fn getStderr() StdWriter {
    return File.stderr().deprecatedWriter();
}

fn bold(comptime s: []const u8) []const u8 {
    return "\x1b[1m" ++ s ++ "\x1b[0m";
}

fn boldCyan(comptime s: []const u8) []const u8 {
    return "\x1b[1;36m" ++ s ++ "\x1b[0m";
}

fn boldBlue(comptime s: []const u8) []const u8 {
    return "\x1b[1;34m" ++ s ++ "\x1b[0m";
}

fn boldRed(comptime s: []const u8) []const u8 {
    return "\x1b[1;31m" ++ s ++ "\x1b[0m";
}

// ─── Runtime option matching ───

fn matchOptionToken(
    comptime opt_specs: []const OptionSpec,
    token: []const u8,
) ?struct { index: usize, is_short: bool } {
    if (token.len > 2 and token[0] == '-' and token[1] == '-') {
        const flag_name = token[2..];
        inline for (opt_specs, 0..) |spec, i| {
            if (std.mem.eql(u8, flag_name, spec.long_name)) {
                return .{ .index = i, .is_short = false };
            }
        }
        return null;
    }
    if (token.len == 2 and token[0] == '-' and token[1] != '-') {
        const short_char = token[1];
        inline for (opt_specs, 0..) |spec, i| {
            if (spec.short != 0 and spec.short == short_char) {
                return .{ .index = i, .is_short = true };
            }
        }
        return null;
    }
    return null;
}

fn setOptionField(
    allocator: std.mem.Allocator,
    comptime OptsType: type,
    comptime opt_specs: []const OptionSpec,
    opts: *OptsType,
    match_index: usize,
    tokens: []const []const u8,
    token_pos: usize,
) !usize {
    inline for (opt_specs, 0..) |spec, si| {
        if (si == match_index) {
            switch (spec.kind) {
                .flag => {
                    @field(opts, spec.field_name) = true;
                    return 1;
                },
                .required => {
                    if (token_pos + 1 < tokens.len) {
                        if (spec.multi) {
                            const current = @field(opts, spec.field_name);
                            const next = try allocator.alloc([]const u8, current.len + 1);
                            if (current.len > 0) {
                                @memcpy(next[0..current.len], current);
                                allocator.free(current);
                            }
                            next[current.len] = tokens[token_pos + 1];
                            @field(opts, spec.field_name) = next;
                        } else {
                            @field(opts, spec.field_name) = tokens[token_pos + 1];
                        }
                        return 2;
                    }
                    return 0;
                },
                .optional => {
                    if (token_pos + 1 < tokens.len and !std.mem.eql(u8, tokens[token_pos + 1], "--") and matchOptionToken(opt_specs, tokens[token_pos + 1]) == null) {
                        @field(opts, spec.field_name) = tokens[token_pos + 1];
                        return 2;
                    }
                    return 1;
                },
            }
        }
    }
    return 1;
}

const ParseError = struct {
    kind: enum { missing_value, unknown_option },
    token: []const u8,
};

fn parseOptions(
    allocator: std.mem.Allocator,
    comptime OptsType: type,
    comptime opt_specs: []const OptionSpec,
    tokens: []const []const u8,
) !struct { opts: OptsType, positional: []const []const u8, double_dash: []const []const u8, err: ?ParseError } {
    var opts: OptsType = undefined;
    inline for (opt_specs) |spec| {
        switch (spec.kind) {
            .flag => {
                @field(opts, spec.field_name) = false;
            },
            .optional => {
                @field(opts, spec.field_name) = null;
            },
            .required => {},
        }
        if (spec.multi) {
            @field(opts, spec.field_name) = &[_][]const u8{};
        }
    }

    var positional_buf: [64][]const u8 = undefined;
    var pos_count: usize = 0;
    var double_dash_start: ?usize = null;

    var i: usize = 0;
    while (i < tokens.len) {
        const token = tokens[i];

        if (std.mem.eql(u8, token, "--")) {
            double_dash_start = i + 1;
            break;
        }

        if (opt_specs.len > 0) {
            if (matchOptionToken(opt_specs, token)) |match| {
                const consumed = try setOptionField(allocator, OptsType, opt_specs, &opts, match.index, tokens, i);
                if (consumed == 0) {
                    return .{ .opts = opts, .positional = &.{}, .double_dash = &.{}, .err = .{ .kind = .missing_value, .token = token } };
                }
                i += consumed;
                continue;
            }
        }
        // Unknown option → error
        if (token.len > 1 and token[0] == '-') {
            return .{ .opts = opts, .positional = &.{}, .double_dash = &.{}, .err = .{ .kind = .unknown_option, .token = token } };
        }
        // Positional arg
        if (pos_count < positional_buf.len) {
            positional_buf[pos_count] = token;
            pos_count += 1;
        }
        i += 1;
    }

    const double_dash = if (double_dash_start) |start| tokens[start..] else &[_][]const u8{};

    return .{
        .opts = opts,
        .positional = positional_buf[0..pos_count],
        .double_dash = double_dash,
        .err = null,
    };
}

fn deinitOptions(
    comptime OptsType: type,
    comptime opt_specs: []const OptionSpec,
    allocator: std.mem.Allocator,
    opts: *OptsType,
) void {
    inline for (opt_specs) |spec| {
        if (spec.multi) {
            const values = @field(opts, spec.field_name);
            if (values.len > 0) {
                allocator.free(values);
                @field(opts, spec.field_name) = &[_][]const u8{};
            }
        }
    }
}

fn fillArgs(
    comptime ArgsType: type,
    comptime arg_specs: []const ArgSpec,
    positional: []const []const u8,
) ?ArgsType {
    var args: ArgsType = undefined;

    inline for (arg_specs) |spec| {
        if (!spec.required and !spec.variadic) {
            @field(args, spec.name) = null;
        }
        if (spec.variadic) {
            @field(args, spec.name) = &[_][]const u8{};
        }
    }

    var pos_idx: usize = 0;
    inline for (arg_specs) |spec| {
        if (spec.variadic) {
            @field(args, spec.name) = if (pos_idx < positional.len) positional[pos_idx..] else &[_][]const u8{};
        } else if (pos_idx < positional.len) {
            @field(args, spec.name) = positional[pos_idx];
            pos_idx += 1;
        } else if (spec.required) {
            return null;
        }
    }

    return args;
}

// ─── Help formatting helpers ───

fn writeSpacesAny(w: anytype, count: usize) void {
    var n: usize = 0;
    while (n < count) : (n += 1) {
        w.writeByte(' ') catch {};
    }
}

/// Compute the single shared alignment column across all commands and their
/// options. This matches goke's behavior: one column for ALL descriptions.
fn computeAlignColumn(comptime commands: anytype) usize {
    comptime {
        var max: usize = 0;
        for (commands) |Cmd| {
            // "  " + command raw name
            const cmd_width = 2 + Cmd.command_raw_name.len;
            if (cmd_width > max) max = cmd_width;

            // "    " + option raw string
            for (Cmd.command_opt_specs) |opt| {
                const opt_width = 4 + opt.raw.len;
                if (opt_width > max) max = opt_width;
            }
        }
        // Also account for global options
        const help_width = 2 + "-h, --help".len;
        if (help_width > max) max = help_width;
        const version_width = 2 + "-v, --version".len;
        if (version_width > max) max = version_width;

        // Add 2 for the gap between name column and description column
        return max + 2;
    }
}

fn containsFlag(argv: []const []const u8, long: []const u8, short: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, long) or std.mem.eql(u8, arg, short)) {
            return true;
        }
    }
    return false;
}

// ─── App type factory ───

pub fn App(comptime commands: anytype) type {
    const align_col = computeAlignColumn(commands);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        name: []const u8,
        version: ?[]const u8,
        help_enabled: bool,

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
            return .{
                .allocator = allocator,
                .name = name,
                .version = null,
                .help_enabled = true,
            };
        }

        pub fn setVersion(self: *Self, ver: []const u8) void {
            self.version = ver;
        }

        pub fn run(self: *Self) !void {
            var arg_iter = try std.process.argsWithAllocator(self.allocator);
            defer arg_iter.deinit();

            var argv_buf: [256][]const u8 = undefined;
            var argc: usize = 0;

            _ = arg_iter.next(); // skip argv[0]

            while (arg_iter.next()) |arg| {
                if (argc < argv_buf.len) {
                    argv_buf[argc] = arg;
                    argc += 1;
                }
            }

            try self.dispatch(argv_buf[0..argc]);
        }

        pub fn dispatch(self: *Self, argv: []const []const u8) !void {
            // Check for --version / -v
            if (self.version != null and containsFlag(argv, "--version", "-v")) {
                self.outputVersion();
                return;
            }

            if (containsFlag(argv, "--help", "-h") and (argv.len == 1 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h"))) {
                self.outputHelp();
                return;
            }

            // Find longest matching command name
            var best_match_len: usize = 0;
            var matched = false;
            var has_default_command = false;

            inline for (commands) |Cmd| {
                if (Cmd.command_name_parts.len == 0) {
                    has_default_command = true;
                }
                const name_parts = Cmd.command_name_parts;
                if (name_parts.len > best_match_len and name_parts.len <= argv.len) {
                    var all_match = true;
                    inline for (name_parts, 0..) |part, pi| {
                        if (pi >= argv.len or !std.mem.eql(u8, argv[pi], part)) {
                            all_match = false;
                        }
                    }
                    if (all_match) {
                        best_match_len = name_parts.len;
                    }
                }
            }

            // Dispatch the command with the longest match
            if (best_match_len > 0) {
                inline for (commands) |Cmd| {
                    const name_parts = Cmd.command_name_parts;
                    if (name_parts.len == best_match_len and !matched) {
                        var all_match = true;
                        inline for (name_parts, 0..) |part, pi| {
                            if (pi >= argv.len or !std.mem.eql(u8, argv[pi], part)) {
                                all_match = false;
                            }
                        }
                        if (all_match) {
                            matched = true;
                            const remaining = argv[name_parts.len..];
                            if (containsFlag(remaining, "--help", "-h")) {
                                self.outputCommandHelp(Cmd);
                                return;
                            }
                            try self.dispatchCommand(Cmd, remaining);
                            return;
                        }
                    }
                }
            }

            // No named command matched — try default command (empty name)
            if (!matched) {
                inline for (commands) |Cmd| {
                    if (Cmd.command_name_parts.len == 0 and !matched) {
                        matched = true;
                        if (containsFlag(argv, "--help", "-h")) {
                            self.outputCommandHelp(Cmd);
                            return;
                        }
                        try self.dispatchCommand(Cmd, argv);
                        return;
                    }
                }
            }

            // Nothing matched
            if (!matched) {
                if (argv.len == 0 or has_default_command) {
                    self.outputHelp();
                } else {
                    const stderr = getStderr();
                    stderr.print(boldRed("error:") ++ " unknown command `{s}`\n", .{argv[0]}) catch {};
                    if (self.help_enabled) {
                        stderr.print("Run \"{s} --help\" for usage information.\n", .{self.name}) catch {};
                    }
                }
            }
        }

        fn dispatchCommand(self: *Self, comptime Cmd: type, remaining: []const []const u8) !void {
            var parsed = try parseOptions(self.allocator, Cmd.Options, Cmd.command_opt_specs, remaining);
            defer deinitOptions(Cmd.Options, Cmd.command_opt_specs, self.allocator, &parsed.opts);

            if (parsed.err) |parse_err| {
                const stderr = getStderr();
                switch (parse_err.kind) {
                    .missing_value => {
                        try stderr.print(boldRed("error:") ++ " option `{s}` value is missing\n", .{parse_err.token});
                    },
                    .unknown_option => {
                        try stderr.print(boldRed("error:") ++ " Unknown option `{s}`\n", .{parse_err.token});
                    },
                }
                return error.ParseError;
            }

            const args = fillArgs(Cmd.Args, Cmd.command_arg_specs, parsed.positional);
            if (args == null) {
                const stderr = getStderr();
                try stderr.print(boldRed("error:") ++ " missing required arguments for `{s}`\n", .{Cmd.command_raw_name});
                return error.MissingRequiredArg;
            }

            try Cmd.invoke(args.?, parsed.opts);
        }

        pub fn outputVersion(self: *Self) void {
            const stdout = getStdout();
            if (self.version) |ver| {
                stdout.print("{s}/{s}\n", .{ self.name, ver }) catch {};
            }
        }

        pub fn outputHelp(self: *Self) void {
            const w = getStdout();
            self.writeHelp(w, true);
        }

        fn outputCommandHelp(self: *Self, comptime Cmd: type) void {
            const w = getStdout();
            self.writeCommandHelp(Cmd, w, true);
        }

        /// Write help text to a buffer (for testing). No ANSI codes.
        pub fn helpString(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            var managed = std.array_list.AlignedManaged(u8, null).init(allocator);
            errdefer managed.deinit();
            self.writeHelp(managed.writer(), false);
            return managed.toOwnedSlice();
        }

        pub fn commandHelpString(self: *Self, comptime Cmd: type, allocator: std.mem.Allocator) ![]const u8 {
            var managed = std.array_list.AlignedManaged(u8, null).init(allocator);
            errdefer managed.deinit();
            self.writeCommandHelp(Cmd, managed.writer(), false);
            return managed.toOwnedSlice();
        }

        fn writeHelp(self: *Self, w: anytype, comptime ansi: bool) void {
            const b = if (ansi) "\x1b[1m" else "";
            const bc = if (ansi) "\x1b[1;36m" else "";
            const bb = if (ansi) "\x1b[1;34m" else "";
            const r = if (ansi) "\x1b[0m" else "";

            // Header
            if (self.version) |ver| {
                w.print("{s}{s}{s}/{s}\n", .{ b, self.name, r, ver }) catch {};
            } else {
                w.print("{s}{s}{s}\n", .{ b, self.name, r }) catch {};
            }

            // Usage
            var has_default = false;
            inline for (commands) |Cmd| {
                if (Cmd.command_name_parts.len == 0) {
                    has_default = true;
                }
            }

            w.print("\n\n{s}Usage{s}:\n", .{ bb, r }) catch {};
            if (has_default) {
                w.print("  $ {s} [options]\n", .{self.name}) catch {};
            } else {
                w.print("  $ {s} <command> [options]\n", .{self.name}) catch {};
            }

            // Commands
            w.print("\n\n{s}Commands{s}:\n", .{ bb, r }) catch {};

            inline for (commands) |Cmd| {
                const raw_name = Cmd.command_raw_name;
                const display_name = if (raw_name.len == 0) self.name else raw_name;

                w.print("  {s}{s}{s}", .{ bc, display_name, r }) catch {};
                const used = 2 + display_name.len;
                if (used < align_col) {
                    writeSpacesAny(w, align_col - used);
                } else {
                    writeSpacesAny(w, 2);
                }
                w.print("{s}\n", .{Cmd.command_description}) catch {};

                inline for (Cmd.command_opt_specs) |opt| {
                    w.print("    {s}", .{opt.raw}) catch {};
                    const opt_used = 4 + opt.raw.len;
                    if (opt.description.len > 0) {
                        if (opt_used < align_col) {
                            writeSpacesAny(w, align_col - opt_used);
                        } else {
                            writeSpacesAny(w, 2);
                        }
                        w.print("{s}", .{opt.description}) catch {};
                    }
                    w.writeByte('\n') catch {};
                }

                w.writeByte('\n') catch {};
            }

            // Global options
            w.print("\n{s}Options{s}:\n", .{ bb, r }) catch {};

            w.print("  -h, --help", .{}) catch {};
            writeSpacesAny(w, align_col - (2 + "-h, --help".len));
            w.print("Display this message\n", .{}) catch {};

            if (self.version != null) {
                w.print("  -v, --version", .{}) catch {};
                writeSpacesAny(w, align_col - (2 + "-v, --version".len));
                w.print("Display version number\n", .{}) catch {};
            }
        }

        fn writeCommandHelp(self: *Self, comptime Cmd: type, w: anytype, comptime ansi: bool) void {
            const b = if (ansi) "\x1b[1m" else "";
            const bc = if (ansi) "\x1b[1;36m" else "";
            const bb = if (ansi) "\x1b[1;34m" else "";
            const r = if (ansi) "\x1b[0m" else "";
            var command_align_col: usize = 2 + "-h, --help".len;
            if (self.version != null) {
                command_align_col = @max(command_align_col, 2 + "-v, --version".len);
            }
            inline for (Cmd.command_opt_specs) |opt| {
                command_align_col = @max(command_align_col, 2 + opt.raw.len);
            }
            command_align_col += 2;

            if (self.version) |ver| {
                w.print("{s}{s}{s}/{s}\n", .{ b, self.name, r, ver }) catch {};
            } else {
                w.print("{s}{s}{s}\n", .{ b, self.name, r }) catch {};
            }

            w.print("\n\n{s}Usage{s}:\n", .{ bb, r }) catch {};
            if (Cmd.command_raw_name.len == 0) {
                w.print("  $ {s} [options]\n", .{self.name}) catch {};
            } else {
                w.print("  $ {s} {s} [options]\n", .{ self.name, Cmd.command_raw_name }) catch {};
            }

            w.print("\n\n{s}Description{s}:\n", .{ bb, r }) catch {};
            w.print("  {s}\n", .{Cmd.command_description}) catch {};

            w.print("\n\n{s}Options{s}:\n", .{ bb, r }) catch {};
            inline for (Cmd.command_opt_specs) |opt| {
                w.print("  {s}{s}{s}", .{ bc, opt.raw, r }) catch {};
                const used = 2 + opt.raw.len;
                if (used < command_align_col) {
                    writeSpacesAny(w, command_align_col - used);
                } else {
                    writeSpacesAny(w, 2);
                }
                w.print("{s}\n", .{opt.description}) catch {};
            }

            w.print("  -h, --help", .{}) catch {};
            writeSpacesAny(w, command_align_col - (2 + "-h, --help".len));
            w.print("Display this message\n", .{}) catch {};

            if (self.version != null) {
                w.print("  -v, --version", .{}) catch {};
                writeSpacesAny(w, command_align_col - (2 + "-v, --version".len));
                w.print("Display version number\n", .{}) catch {};
            }

            if (Cmd.command_examples.len > 0) {
                w.print("\n\n{s}Examples{s}:\n", .{ bb, r }) catch {};
                inline for (Cmd.command_examples) |example| {
                    w.print("  {s}\n", .{example}) catch {};
                }
            }
        }
    };
}

// ─── Tests ───

test "parseOptions: parses flags and values" {
    const specs = [_]OptionSpec{
        .{ .field_name = "port", .long_name = "port", .short = 'p', .kind = .required, .description = "", .raw = "" },
        .{ .field_name = "watch", .long_name = "watch", .short = 0, .kind = .flag, .description = "", .raw = "" },
        .{ .field_name = "host", .long_name = "host", .short = 0, .kind = .optional, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "--port", "3000", "--watch", "myfile.zig" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expectEqualStrings("3000", result.opts.port);
    try std.testing.expect(result.opts.watch);
    try std.testing.expectEqual(@as(?[]const u8, null), result.opts.host);
    try std.testing.expectEqual(@as(usize, 1), result.positional.len);
    try std.testing.expectEqualStrings("myfile.zig", result.positional[0]);
}

test "parseOptions: short alias" {
    const specs = [_]OptionSpec{
        .{ .field_name = "port", .long_name = "port", .short = 'p', .kind = .required, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "-p", "8080" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expectEqualStrings("8080", result.opts.port);
}

test "parseOptions: double dash separator" {
    const specs = [_]OptionSpec{
        .{ .field_name = "watch", .long_name = "watch", .short = 0, .kind = .flag, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "--watch", "--", "--extra", "stuff" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.opts.watch);
    try std.testing.expectEqual(@as(usize, 2), result.double_dash.len);
    try std.testing.expectEqualStrings("--extra", result.double_dash[0]);
}

test "parseOptions: unknown option returns error" {
    const specs = [_]OptionSpec{
        .{ .field_name = "watch", .long_name = "watch", .short = 0, .kind = .flag, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "--watch", "--unknown" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(.unknown_option, result.err.?.kind);
    try std.testing.expectEqualStrings("--unknown", result.err.?.token);
}

test "parseOptions: optionMany collects repeated values" {
    const specs = [_]OptionSpec{
        .{ .field_name = "modifier", .long_name = "modifier", .short = 0, .kind = .required, .description = "", .raw = "--modifier <key>", .multi = true },
    };
    const OptsType = builder.buildOptionsType(&specs);
    var result = try parseOptions(std.testing.allocator, OptsType, &specs, &.{ "--modifier", "cmd", "--modifier", "shift" });
    defer deinitOptions(OptsType, &specs, std.testing.allocator, &result.opts);

    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 2), result.opts.modifier.len);
    try std.testing.expectEqualStrings("cmd", result.opts.modifier[0]);
    try std.testing.expectEqualStrings("shift", result.opts.modifier[1]);
}

test "parseOptions: optional value accepts negative numbers" {
    const specs = [_]OptionSpec{
        .{ .field_name = "x", .long_name = "x", .short = 'x', .kind = .optional, .description = "", .raw = "-x [x]" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &.{ "-x", "-10" });

    try std.testing.expect(result.err == null);
    try std.testing.expectEqualStrings("-10", result.opts.x.?);
}

// ─── Help output tests ───

test "help: simple CLI with two commands" {
    const Serve = builder.cmd("serve", "Start the dev server")
        .option("--port <port>", "Port number")
        .option("--host [host]", "Hostname");
    const Build = builder.cmd("build [entry]", "Build the project")
        .option("--watch", "Watch mode")
        .option("--outdir <dir>", "Output directory");

    const noop1 = struct {
        fn f(_: Serve.Args, _: Serve.Options) !void {}
    }.f;
    const noop2 = struct {
        fn f(_: Build.Args, _: Build.Options) !void {}
    }.f;

    var app = App(.{
        Serve.bind(noop1),
        Build.bind(noop2),
    }).init(std.testing.allocator, "myapp");
    app.setVersion("1.0.0");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\myapp/1.0.0
        \\
        \\
        \\Usage:
        \\  $ myapp <command> [options]
        \\
        \\
        \\Commands:
        \\  serve             Start the dev server
        \\    --port <port>   Port number
        \\    --host [host]   Hostname
        \\
        \\  build [entry]     Build the project
        \\    --watch         Watch mode
        \\    --outdir <dir>  Output directory
        \\
        \\
        \\Options:
        \\  -h, --help        Display this message
        \\  -v, --version     Display version number
        \\
    , help);
}

test "help: space-separated subcommands align correctly" {
    const Login = builder.cmd("auth login", "Authenticate with provider");
    const Logout = builder.cmd("auth logout", "Clear credentials")
        .option("--force", "Skip confirmation");
    const List = builder.cmd("mail list", "List email threads")
        .option("--folder [folder]", "Folder to list");

    const n1 = struct {
        fn f(_: Login.Args, _: Login.Options) !void {}
    }.f;
    const n2 = struct {
        fn f(_: Logout.Args, _: Logout.Options) !void {}
    }.f;
    const n3 = struct {
        fn f(_: List.Args, _: List.Options) !void {}
    }.f;

    var app = App(.{
        Login.bind(n1),
        Logout.bind(n2),
        List.bind(n3),
    }).init(std.testing.allocator, "gtui");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\gtui
        \\
        \\
        \\Usage:
        \\  $ gtui <command> [options]
        \\
        \\
        \\Commands:
        \\  auth login           Authenticate with provider
        \\
        \\  auth logout          Clear credentials
        \\    --force            Skip confirmation
        \\
        \\  mail list            List email threads
        \\    --folder [folder]  Folder to list
        \\
        \\
        \\Options:
        \\  -h, --help           Display this message
        \\
    , help);
}

test "help: default command with subcommands" {
    const Root = builder.cmd("", "Deploy the current project")
        .option("--env <env>", "Target environment")
        .option("--dry-run", "Preview without deploying");
    const Init = builder.cmd("init", "Initialize project");
    const Status = builder.cmd("status", "Show deployment status");

    const n1 = struct {
        fn f(_: Root.Args, _: Root.Options) !void {}
    }.f;
    const n2 = struct {
        fn f(_: Init.Args, _: Init.Options) !void {}
    }.f;
    const n3 = struct {
        fn f(_: Status.Args, _: Status.Options) !void {}
    }.f;

    var app = App(.{
        Root.bind(n1),
        Init.bind(n2),
        Status.bind(n3),
    }).init(std.testing.allocator, "deploy");
    app.setVersion("2.0.0");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\deploy/2.0.0
        \\
        \\
        \\Usage:
        \\  $ deploy [options]
        \\
        \\
        \\Commands:
        \\  deploy         Deploy the current project
        \\    --env <env>  Target environment
        \\    --dry-run    Preview without deploying
        \\
        \\  init           Initialize project
        \\
        \\  status         Show deployment status
        \\
        \\
        \\Options:
        \\  -h, --help     Display this message
        \\  -v, --version  Display version number
        \\
    , help);
}

test "help: single command no options" {
    const Ping = builder.cmd("ping <host>", "Ping a host");

    const noop = struct {
        fn f(_: Ping.Args, _: Ping.Options) !void {}
    }.f;

    var app = App(.{
        Ping.bind(noop),
    }).init(std.testing.allocator, "netool");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\netool
        \\
        \\
        \\Usage:
        \\  $ netool <command> [options]
        \\
        \\
        \\Commands:
        \\  ping <host>    Ping a host
        \\
        \\
        \\Options:
        \\  -h, --help     Display this message
        \\
    , help);
}

test "help: many commands with long option names push alignment column" {
    const Screenshot = builder.cmd("screenshot [path]", "Take a screenshot")
        .option("--region [region]", "Capture specific region")
        .option("--json", "Output as JSON");
    const Click = builder.cmd("click", "Click at coordinates")
        .option("-x <x>", "X coordinate")
        .option("-y <y>", "Y coordinate")
        .option("--coord-map [map]", "Coordinate mapping: x1,y1,x2,y2,w,h");

    const n1 = struct {
        fn f(_: Screenshot.Args, _: Screenshot.Options) !void {}
    }.f;
    const n2 = struct {
        fn f(_: Click.Args, _: Click.Options) !void {}
    }.f;

    var app = App(.{
        Screenshot.bind(n1),
        Click.bind(n2),
    }).init(std.testing.allocator, "uc");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    // --coord-map [map] (4 + 17 = 21) is wider than screenshot [path] (2 + 17 = 19)
    // so alignment column is driven by the option, not the command name
    try std.testing.expectEqualStrings(
        \\uc
        \\
        \\
        \\Usage:
        \\  $ uc <command> [options]
        \\
        \\
        \\Commands:
        \\  screenshot [path]    Take a screenshot
        \\    --region [region]  Capture specific region
        \\    --json             Output as JSON
        \\
        \\  click                Click at coordinates
        \\    -x <x>             X coordinate
        \\    -y <y>             Y coordinate
        \\    --coord-map [map]  Coordinate mapping: x1,y1,x2,y2,w,h
        \\
        \\
        \\Options:
        \\  -h, --help           Display this message
        \\
    , help);
}

test "help: short aliases displayed in options" {
    const Cmd = builder.cmd("serve", "Start server")
        .option("-p, --port <port>", "Port number")
        .option("-H, --host [host]", "Hostname")
        .option("--verbose", "Verbose output");

    const noop = struct {
        fn f(_: Cmd.Args, _: Cmd.Options) !void {}
    }.f;

    var app = App(.{
        Cmd.bind(noop),
    }).init(std.testing.allocator, "srv");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\srv
        \\
        \\
        \\Usage:
        \\  $ srv <command> [options]
        \\
        \\
        \\Commands:
        \\  serve                Start server
        \\    -p, --port <port>  Port number
        \\    -H, --host [host]  Hostname
        \\    --verbose          Verbose output
        \\
        \\
        \\Options:
        \\  -h, --help           Display this message
        \\
    , help);
}

test "command help: includes examples" {
    const Click = builder.cmd("click [target]", "Click at coordinates or target")
        .optionMany("--modifier <key>", "Hold a modifier while clicking")
        .example("myapp click -x 600 -y 400 --modifier option");

    const noop = struct {
        fn f(_: Click.Args, _: Click.Options) !void {}
    }.f;

    const ClickCmd = Click.bind(noop);

    var app = App(.{ClickCmd}).init(std.testing.allocator, "myapp");
    app.setVersion("1.0.0");

    const help = try app.commandHelpString(ClickCmd, std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Examples:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--modifier <key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "myapp click -x 600 -y 400 --modifier option") != null);
}

// ─── Dispatch tests ───

test "dispatch: matches command and passes args/options" {
    const Greet = builder.cmd("greet <name>", "Greet someone")
        .option("--loud", "Shout");

    var called_name: []const u8 = "";
    var called_loud: bool = false;

    const action = struct {
        var name_ptr: *[]const u8 = undefined;
        var loud_ptr: *bool = undefined;
        fn f(args: Greet.Args, opts: Greet.Options) !void {
            name_ptr.* = args.name;
            loud_ptr.* = opts.loud;
        }
    };
    action.name_ptr = &called_name;
    action.loud_ptr = &called_loud;

    var app = App(.{Greet.bind(action.f)}).init(std.testing.allocator, "test");
    try app.dispatch(&.{ "greet", "World", "--loud" });

    try std.testing.expectEqualStrings("World", called_name);
    try std.testing.expect(called_loud);
}

test "dispatch: longest match wins for space-separated commands" {
    const Base = builder.cmd("mcp", "MCP base");
    const Login = builder.cmd("mcp login", "MCP login");

    var matched: []const u8 = "";

    const action_base = struct {
        var ptr: *[]const u8 = undefined;
        fn f(_: Base.Args, _: Base.Options) !void {
            ptr.* = "base";
        }
    };
    const action_login = struct {
        var ptr: *[]const u8 = undefined;
        fn f(_: Login.Args, _: Login.Options) !void {
            ptr.* = "login";
        }
    };
    action_base.ptr = &matched;
    action_login.ptr = &matched;

    var app = App(.{
        Base.bind(action_base.f),
        Login.bind(action_login.f),
    }).init(std.testing.allocator, "test");

    try app.dispatch(&.{ "mcp", "login" });
    try std.testing.expectEqualStrings("login", matched);

    try app.dispatch(&.{"mcp"});
    try std.testing.expectEqualStrings("base", matched);
}

test "dispatch: default command runs when no args" {
    const Root = builder.cmd("", "Default");

    var called = false;
    const action = struct {
        var ptr: *bool = undefined;
        fn f(_: Root.Args, _: Root.Options) !void {
            ptr.* = true;
        }
    };
    action.ptr = &called;

    var app = App(.{Root.bind(action.f)}).init(std.testing.allocator, "test");
    try app.dispatch(&.{});
    try std.testing.expect(called);
}

test "dispatch: default command receives options" {
    const Root = builder.cmd("", "Default")
        .option("--env <env>", "Environment");

    var env_val: []const u8 = "";
    const action = struct {
        var ptr: *[]const u8 = undefined;
        fn f(_: Root.Args, opts: Root.Options) !void {
            ptr.* = opts.env;
        }
    };
    action.ptr = &env_val;

    var app = App(.{Root.bind(action.f)}).init(std.testing.allocator, "test");
    try app.dispatch(&.{ "--env", "staging" });
    try std.testing.expectEqualStrings("staging", env_val);
}

test "dispatch: named command takes priority over default" {
    const Root = builder.cmd("", "Default");
    const Status = builder.cmd("status", "Show status");

    var matched: []const u8 = "";
    const action_root = struct {
        var ptr: *[]const u8 = undefined;
        fn f(_: Root.Args, _: Root.Options) !void {
            ptr.* = "root";
        }
    };
    const action_status = struct {
        var ptr: *[]const u8 = undefined;
        fn f(_: Status.Args, _: Status.Options) !void {
            ptr.* = "status";
        }
    };
    action_root.ptr = &matched;
    action_status.ptr = &matched;

    var app = App(.{
        Root.bind(action_root.f),
        Status.bind(action_status.f),
    }).init(std.testing.allocator, "test");

    try app.dispatch(&.{"status"});
    try std.testing.expectEqualStrings("status", matched);
}

test "dispatch: unknown option returns error" {
    const Serve = builder.cmd("serve", "Start server")
        .option("--port <port>", "Port");
    const noop = struct {
        fn f(_: Serve.Args, _: Serve.Options) !void {}
    }.f;

    var app = App(.{Serve.bind(noop)}).init(std.testing.allocator, "test");
    const result = app.dispatch(&.{ "serve", "--unknown" });
    try std.testing.expectError(error.ParseError, result);
}

test "dispatch: missing required option value returns error" {
    const Serve = builder.cmd("serve", "Start server")
        .option("--port <port>", "Port");
    const noop = struct {
        fn f(_: Serve.Args, _: Serve.Options) !void {}
    }.f;

    var app = App(.{Serve.bind(noop)}).init(std.testing.allocator, "test");
    const result = app.dispatch(&.{ "serve", "--port" });
    try std.testing.expectError(error.ParseError, result);
}

test "dispatch: missing required arg returns error" {
    const Press = builder.cmd("press <key>", "Press key");
    const noop = struct {
        fn f(_: Press.Args, _: Press.Options) !void {}
    }.f;

    var app = App(.{Press.bind(noop)}).init(std.testing.allocator, "test");
    const result = app.dispatch(&.{"press"});
    try std.testing.expectError(error.MissingRequiredArg, result);
}

// Note: --help and --version tests are omitted from unit tests because
// dispatch() writes to real stdout which can block in test runners.
// These paths are covered by the help output snapshot tests above
// (helpString) and by the example binary integration tests.

// ─── parseOptions tests (additional) ───

test "parseOptions: empty argv" {
    const specs = [_]OptionSpec{
        .{ .field_name = "watch", .long_name = "watch", .short = 0, .kind = .flag, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{};
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(!result.opts.watch);
    try std.testing.expectEqual(@as(usize, 0), result.positional.len);
    try std.testing.expect(result.err == null);
}

test "parseOptions: no specs, all positional" {
    const specs = [_]OptionSpec{};
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "foo", "bar", "baz" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expectEqual(@as(usize, 3), result.positional.len);
    try std.testing.expectEqualStrings("foo", result.positional[0]);
    try std.testing.expectEqualStrings("baz", result.positional[2]);
}

test "parseOptions: required option missing value" {
    const specs = [_]OptionSpec{
        .{ .field_name = "port", .long_name = "port", .short = 0, .kind = .required, .description = "", .raw = "--port <port>" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{"--port"};
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(.missing_value, result.err.?.kind);
}

test "parseOptions: optional flag without value stays null" {
    const specs = [_]OptionSpec{
        .{ .field_name = "format", .long_name = "format", .short = 0, .kind = .optional, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{"--format"};
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(?[]const u8, null), result.opts.format);
}

test "parseOptions: optional flag with value" {
    const specs = [_]OptionSpec{
        .{ .field_name = "format", .long_name = "format", .short = 0, .kind = .optional, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "--format", "json" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.err == null);
    try std.testing.expectEqualStrings("json", result.opts.format.?);
}

test "parseOptions: mixed positional and options" {
    const specs = [_]OptionSpec{
        .{ .field_name = "verbose", .long_name = "verbose", .short = 0, .kind = .flag, .description = "", .raw = "" },
        .{ .field_name = "out", .long_name = "out", .short = 0, .kind = .required, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "input.txt", "--verbose", "--out", "output.txt", "extra" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.err == null);
    try std.testing.expect(result.opts.verbose);
    try std.testing.expectEqualStrings("output.txt", result.opts.out);
    try std.testing.expectEqual(@as(usize, 2), result.positional.len);
    try std.testing.expectEqualStrings("input.txt", result.positional[0]);
    try std.testing.expectEqualStrings("extra", result.positional[1]);
}

test "parseOptions: unknown short option returns error" {
    const specs = [_]OptionSpec{
        .{ .field_name = "port", .long_name = "port", .short = 'p', .kind = .required, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{"-z"};
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(.unknown_option, result.err.?.kind);
    try std.testing.expectEqualStrings("-z", result.err.?.token);
}

test "parseOptions: double dash stops option parsing" {
    const specs = [_]OptionSpec{
        .{ .field_name = "verbose", .long_name = "verbose", .short = 0, .kind = .flag, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    // --verbose after -- should NOT be parsed as a flag
    const argv = [_][]const u8{ "--", "--verbose", "arg" };
    const result = try parseOptions(std.testing.allocator, OptsType, &specs, &argv);

    try std.testing.expect(!result.opts.verbose);
    try std.testing.expectEqual(@as(usize, 0), result.positional.len);
    try std.testing.expectEqual(@as(usize, 2), result.double_dash.len);
    try std.testing.expectEqualStrings("--verbose", result.double_dash[0]);
    try std.testing.expectEqualStrings("arg", result.double_dash[1]);
}

// ─── fillArgs tests (additional) ───

test "fillArgs: required and optional" {
    const specs = [_]ArgSpec{
        .{ .name = "key", .required = true, .variadic = false },
        .{ .name = "value", .required = false, .variadic = false },
    };
    const ArgsType = builder.buildArgsType(&specs);

    const positional = [_][]const u8{ "mykey", "myval" };
    const args = fillArgs(ArgsType, &specs, &positional);
    try std.testing.expect(args != null);
    try std.testing.expectEqualStrings("mykey", args.?.key);
    try std.testing.expectEqualStrings("myval", args.?.value.?);

    const positional2 = [_][]const u8{"mykey"};
    const args2 = fillArgs(ArgsType, &specs, &positional2);
    try std.testing.expect(args2 != null);
    try std.testing.expectEqualStrings("mykey", args2.?.key);
    try std.testing.expectEqual(@as(?[]const u8, null), args2.?.value);

    const positional3 = [_][]const u8{};
    const args3 = fillArgs(ArgsType, &specs, &positional3);
    try std.testing.expect(args3 == null);
}

test "fillArgs: variadic collects remaining args" {
    const specs = [_]ArgSpec{
        .{ .name = "cmd", .required = true, .variadic = false },
        .{ .name = "rest", .required = false, .variadic = true },
    };
    const ArgsType = builder.buildArgsType(&specs);

    const positional = [_][]const u8{ "run", "a", "b", "c" };
    const args = fillArgs(ArgsType, &specs, &positional);
    try std.testing.expect(args != null);
    try std.testing.expectEqualStrings("run", args.?.cmd);
    try std.testing.expectEqual(@as(usize, 3), args.?.rest.len);
    try std.testing.expectEqualStrings("a", args.?.rest[0]);
    try std.testing.expectEqualStrings("c", args.?.rest[2]);
}

test "fillArgs: variadic with no remaining args" {
    const specs = [_]ArgSpec{
        .{ .name = "files", .required = false, .variadic = true },
    };
    const ArgsType = builder.buildArgsType(&specs);

    const positional = [_][]const u8{};
    const args = fillArgs(ArgsType, &specs, &positional);
    try std.testing.expect(args != null);
    try std.testing.expectEqual(@as(usize, 0), args.?.files.len);
}

test "fillArgs: empty specs, no args needed" {
    const specs = [_]ArgSpec{};
    const ArgsType = builder.buildArgsType(&specs);

    const positional = [_][]const u8{};
    const args = fillArgs(ArgsType, &specs, &positional);
    try std.testing.expect(args != null);
}

test "fillArgs: extra positional args ignored" {
    const specs = [_]ArgSpec{
        .{ .name = "name", .required = true, .variadic = false },
    };
    const ArgsType = builder.buildArgsType(&specs);

    // Extra positional "extra" is silently ignored
    const positional = [_][]const u8{ "hello", "extra" };
    const args = fillArgs(ArgsType, &specs, &positional);
    try std.testing.expect(args != null);
    try std.testing.expectEqualStrings("hello", args.?.name);
}

// ─── Help output tests (additional) ───

test "help: no version hides --version line" {
    const Cmd = builder.cmd("run", "Run something");
    const noop = struct {
        fn f(_: Cmd.Args, _: Cmd.Options) !void {}
    }.f;

    var app = App(.{Cmd.bind(noop)}).init(std.testing.allocator, "myapp");
    // Don't call setVersion

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    // Should not contain --version
    try std.testing.expect(std.mem.indexOf(u8, help, "--version") == null);
    // Should contain --help
    try std.testing.expect(std.mem.indexOf(u8, help, "--help") != null);
}

test "help: three-level subcommand" {
    const Add = builder.cmd("git remote add <name> <url>", "Add a git remote");
    const Remove = builder.cmd("git remote remove <name>", "Remove a git remote");
    const n1 = struct {
        fn f(_: Add.Args, _: Add.Options) !void {}
    }.f;
    const n2 = struct {
        fn f(_: Remove.Args, _: Remove.Options) !void {}
    }.f;

    var app = App(.{
        Add.bind(n1),
        Remove.bind(n2),
    }).init(std.testing.allocator, "mygit");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\mygit
        \\
        \\
        \\Usage:
        \\  $ mygit <command> [options]
        \\
        \\
        \\Commands:
        \\  git remote add <name> <url>  Add a git remote
        \\
        \\  git remote remove <name>     Remove a git remote
        \\
        \\
        \\Options:
        \\  -h, --help                   Display this message
        \\
    , help);
}

test "help: only default command shows cli name and [options]" {
    const Root = builder.cmd("", "Do the thing")
        .option("--force", "Force it");
    const noop = struct {
        fn f(_: Root.Args, _: Root.Options) !void {}
    }.f;

    var app = App(.{Root.bind(noop)}).init(std.testing.allocator, "doit");
    app.setVersion("3.0.0");

    const help = try app.helpString(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expectEqualStrings(
        \\doit/3.0.0
        \\
        \\
        \\Usage:
        \\  $ doit [options]
        \\
        \\
        \\Commands:
        \\  doit           Do the thing
        \\    --force      Force it
        \\
        \\
        \\Options:
        \\  -h, --help     Display this message
        \\  -v, --version  Display version number
        \\
    , help);
}
