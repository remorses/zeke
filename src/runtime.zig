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
    comptime OptsType: type,
    comptime opt_specs: []const OptionSpec,
    opts: *OptsType,
    match_index: usize,
    tokens: []const []const u8,
    token_pos: usize,
) usize {
    inline for (opt_specs, 0..) |spec, si| {
        if (si == match_index) {
            switch (spec.kind) {
                .flag => {
                    @field(opts, spec.field_name) = true;
                    return 1;
                },
                .required => {
                    if (token_pos + 1 < tokens.len and (tokens[token_pos + 1].len == 0 or tokens[token_pos + 1][0] != '-')) {
                        @field(opts, spec.field_name) = tokens[token_pos + 1];
                        return 2;
                    }
                    return 0;
                },
                .optional => {
                    if (token_pos + 1 < tokens.len and (tokens[token_pos + 1].len == 0 or tokens[token_pos + 1][0] != '-')) {
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
    comptime OptsType: type,
    comptime opt_specs: []const OptionSpec,
    tokens: []const []const u8,
) struct { opts: OptsType, positional: []const []const u8, double_dash: []const []const u8, err: ?ParseError } {
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
                const consumed = setOptionField(OptsType, opt_specs, &opts, match.index, tokens, i);
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

/// Write `count` spaces to writer.
fn writeSpaces(w: StdWriter, count: usize) void {
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
            // Check for --help / -h
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    self.outputHelp();
                    return;
                }
            }

            // Check for --version / -v
            if (self.version != null) {
                for (argv) |arg| {
                    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
                        self.outputVersion();
                        return;
                    }
                }
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
                            try dispatchCommand(Cmd, remaining);
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
                        try dispatchCommand(Cmd, argv);
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

        fn dispatchCommand(comptime Cmd: type, remaining: []const []const u8) !void {
            const parsed = parseOptions(Cmd.Options, Cmd.command_opt_specs, remaining);

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

            // Header
            if (self.version) |ver| {
                w.print(bold("{s}") ++ "/{s}\n", .{ self.name, ver }) catch {};
            } else {
                w.print(bold("{s}") ++ "\n", .{self.name}) catch {};
            }

            // Usage line — adapt based on whether there's a default command
            var has_default = false;
            inline for (commands) |Cmd| {
                if (Cmd.command_name_parts.len == 0) {
                    has_default = true;
                }
            }

            w.print("\n\n" ++ boldBlue("Usage") ++ ":\n", .{}) catch {};
            if (has_default) {
                w.print("  $ {s} [options]\n", .{self.name}) catch {};
            } else {
                w.print("  $ {s} <command> [options]\n", .{self.name}) catch {};
            }

            // Commands section
            w.print("\n\n" ++ boldBlue("Commands") ++ ":\n", .{}) catch {};

            inline for (commands) |Cmd| {
                const raw_name = Cmd.command_raw_name;
                // Default command shows as the CLI name
                const display_name = if (raw_name.len == 0) self.name else raw_name;
                const display_prefix: usize = if (raw_name.len == 0) 0 else 0;
                _ = display_prefix;

                // Command line: "  <name>  <padded description>"
                w.print("  ", .{}) catch {};
                w.print(boldCyan("{s}"), .{display_name}) catch {};
                const used = 2 + display_name.len;
                if (used < align_col) {
                    writeSpaces(w, align_col - used);
                } else {
                    writeSpaces(w, 2);
                }
                w.print("{s}\n", .{Cmd.command_description}) catch {};

                // Command options, indented with same alignment column
                inline for (Cmd.command_opt_specs) |opt| {
                    w.print("    {s}", .{opt.raw}) catch {};
                    const opt_used = 4 + opt.raw.len;
                    if (opt.description.len > 0) {
                        if (opt_used < align_col) {
                            writeSpaces(w, align_col - opt_used);
                        } else {
                            writeSpaces(w, 2);
                        }
                        w.print("{s}", .{opt.description}) catch {};
                    }
                    w.writeByte('\n') catch {};
                }

                // Blank line between command blocks
                w.writeByte('\n') catch {};
            }

            // Global options section
            w.print("\n" ++ boldBlue("Options") ++ ":\n", .{}) catch {};

            w.print("  -h, --help", .{}) catch {};
            const help_used = 2 + "-h, --help".len;
            writeSpaces(w, align_col - help_used);
            w.print("Display this message\n", .{}) catch {};

            if (self.version != null) {
                w.print("  -v, --version", .{}) catch {};
                const ver_used = 2 + "-v, --version".len;
                writeSpaces(w, align_col - ver_used);
                w.print("Display version number\n", .{}) catch {};
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
    const result = parseOptions(OptsType, &specs, &argv);

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
    const result = parseOptions(OptsType, &specs, &argv);

    try std.testing.expectEqualStrings("8080", result.opts.port);
}

test "parseOptions: double dash separator" {
    const specs = [_]OptionSpec{
        .{ .field_name = "watch", .long_name = "watch", .short = 0, .kind = .flag, .description = "", .raw = "" },
    };
    const OptsType = builder.buildOptionsType(&specs);
    const argv = [_][]const u8{ "--watch", "--", "--extra", "stuff" };
    const result = parseOptions(OptsType, &specs, &argv);

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
    const result = parseOptions(OptsType, &specs, &argv);

    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(.unknown_option, result.err.?.kind);
    try std.testing.expectEqualStrings("--unknown", result.err.?.token);
}

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
