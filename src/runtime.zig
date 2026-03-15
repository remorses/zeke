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

fn cyan(comptime s: []const u8) []const u8 {
    return "\x1b[36m" ++ s ++ "\x1b[0m";
}

fn boldCyan(comptime s: []const u8) []const u8 {
    return "\x1b[1;36m" ++ s ++ "\x1b[0m";
}

fn blue(comptime s: []const u8) []const u8 {
    return "\x1b[34m" ++ s ++ "\x1b[0m";
}

fn boldBlue(comptime s: []const u8) []const u8 {
    return "\x1b[1;34m" ++ s ++ "\x1b[0m";
}

fn dim(s: []const u8) ![]const u8 {
    _ = s;
    return "";
}

fn red(comptime s: []const u8) []const u8 {
    return "\x1b[31m" ++ s ++ "\x1b[0m";
}

fn boldRed(comptime s: []const u8) []const u8 {
    return "\x1b[1;31m" ++ s ++ "\x1b[0m";
}

// ─── Runtime option matching ───

/// Match a single argv token against an option spec.
/// Returns the field name if matched, null otherwise.
fn matchOptionToken(
    comptime opt_specs: []const OptionSpec,
    token: []const u8,
) ?struct { index: usize, is_short: bool } {
    // Check --long-name
    if (token.len > 2 and token[0] == '-' and token[1] == '-') {
        const flag_name = token[2..];
        inline for (opt_specs, 0..) |spec, i| {
            if (std.mem.eql(u8, flag_name, spec.long_name)) {
                return .{ .index = i, .is_short = false };
            }
        }
        return null;
    }
    // Check -x (short alias)
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

/// Set a single option field by runtime index. Uses inline for + comptime index
/// comparison so each branch sees the correct field type.
/// Returns number of tokens consumed (1 for flag, 2 for value, 0 for error).
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
                    return 0; // Missing required value
                },
                .optional => {
                    if (token_pos + 1 < tokens.len and (tokens[token_pos + 1].len == 0 or tokens[token_pos + 1][0] != '-')) {
                        @field(opts, spec.field_name) = tokens[token_pos + 1];
                        return 2;
                    }
                    return 1; // Optional with no value — stays null
                },
            }
        }
    }
    return 1; // unreachable if index is valid
}

/// Parse argv tokens into an Options struct for a given command.
/// Returns the populated options struct and the remaining positional args.
fn parseOptions(
    comptime OptsType: type,
    comptime opt_specs: []const OptionSpec,
    tokens: []const []const u8,
) struct { opts: OptsType, positional: []const []const u8, double_dash: []const []const u8, err: ?[]const u8 } {
    // Initialize opts with defaults: flags→false, optionals→null, required→undefined
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

        // Check for -- separator
        if (std.mem.eql(u8, token, "--")) {
            double_dash_start = i + 1;
            break;
        }

        if (opt_specs.len > 0) {
            if (matchOptionToken(opt_specs, token)) |match| {
                const consumed = setOptionField(OptsType, opt_specs, &opts, match.index, tokens, i);
                if (consumed == 0) {
                    return .{ .opts = opts, .positional = &.{}, .double_dash = &.{}, .err = opt_specs[match.index].long_name };
                }
                i += consumed;
                continue;
            }
        }
        if (token.len > 0 and token[0] == '-') {
            // Unknown option — skip for now
            i += 1;
        } else {
            // Positional arg
            if (pos_count < positional_buf.len) {
                positional_buf[pos_count] = token;
                pos_count += 1;
            }
            i += 1;
        }
    }

    const double_dash = if (double_dash_start) |start| tokens[start..] else &[_][]const u8{};

    return .{
        .opts = opts,
        .positional = positional_buf[0..pos_count],
        .double_dash = double_dash,
        .err = null,
    };
}

/// Fill an Args struct from positional tokens.
fn fillArgs(
    comptime ArgsType: type,
    comptime arg_specs: []const ArgSpec,
    positional: []const []const u8,
) ?ArgsType {
    var args: ArgsType = undefined;

    // Initialize optional fields to their defaults
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
            // Consume all remaining positional args
            @field(args, spec.name) = if (pos_idx < positional.len) positional[pos_idx..] else &[_][]const u8{};
        } else if (pos_idx < positional.len) {
            @field(args, spec.name) = positional[pos_idx];
            pos_idx += 1;
        } else if (spec.required) {
            return null; // Missing required arg
        }
    }

    return args;
}

// ─── App type factory ───

/// Create a CLI application type from a tuple of bound commands.
///
///   var app = App(.{ ServeCmd, BuildCmd }).init(allocator, "myapp");
///   try app.run();
pub fn App(comptime commands: anytype) type {
    return struct {
        const Self = @This();
        const Commands = commands;

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

        /// Parse process argv and dispatch to the matched command.
        pub fn run(self: *Self) !void {
            var arg_iter = try std.process.argsWithAllocator(self.allocator);
            defer arg_iter.deinit();

            // Collect args into a slice
            var argv_buf: [256][]const u8 = undefined;
            var argc: usize = 0;

            // Skip argv[0] (program name)
            _ = arg_iter.next();

            while (arg_iter.next()) |arg| {
                if (argc < argv_buf.len) {
                    argv_buf[argc] = arg;
                    argc += 1;
                }
            }

            const argv = argv_buf[0..argc];
            try self.dispatch(argv);
        }

        /// Dispatch with an explicit argv slice (useful for testing).
        pub fn dispatch(self: *Self, argv: []const []const u8) !void {
            // Check for --help
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    // Check if there's a command prefix match for scoped help
                    if (argv.len > 0 and !std.mem.startsWith(u8, argv[0], "-")) {
                        if (self.findCommandHelp(argv)) |help_text| {
                            const stdout = getStdout();
                            try stdout.writeAll(help_text);
                            try stdout.writeByte('\n');
                            return;
                        }
                    }
                    self.outputHelp();
                    return;
                }
            }

            // Check for --version
            if (self.version != null) {
                for (argv) |arg| {
                    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
                        self.outputVersion();
                        return;
                    }
                }
            }

            // Try matching each command (longest match first — inline for
            // iterates the tuple which we order by name_parts length desc)
            var best_match_len: usize = 0;
            var matched = false;

            // First pass: find the longest matching command
            inline for (commands) |Cmd| {
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

            // Second pass: dispatch the command with the longest match
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
                        const parsed = parseOptions(Cmd.Options, Cmd.command_opt_specs, remaining);

                        if (parsed.err) |opt_name| {
                            const stderr = getStderr();
                            try stderr.print(boldRed("error:") ++ " option --{s} requires a value\n", .{opt_name});
                            return error.MissingOptionValue;
                        }

                        const args = fillArgs(Cmd.Args, Cmd.command_arg_specs, parsed.positional);
                        if (args == null) {
                            const stderr = getStderr();
                            try stderr.print(boldRed("error:") ++ " missing required arguments for `{s}`\n", .{Cmd.command_raw_name});
                            return error.MissingRequiredArg;
                        }

                        try Cmd.invoke(args.?, parsed.opts);
                        return;
                    }
                }
            }

            // No match — check for default command (empty name)
            inline for (commands) |Cmd| {
                if (Cmd.command_name_parts.len == 0 and !matched) {
                    matched = true;
                    const parsed = parseOptions(Cmd.Options, Cmd.command_opt_specs, argv);
                    if (parsed.err) |opt_name| {
                        const stderr = getStderr();
                        try stderr.print(boldRed("error:") ++ " option --{s} requires a value\n", .{opt_name});
                        return error.MissingOptionValue;
                    }
                    const args = fillArgs(Cmd.Args, Cmd.command_arg_specs, parsed.positional);
                    if (args == null) {
                        const stderr = getStderr();
                        try stderr.print(boldRed("error:") ++ " missing required arguments for `{s}`\n", .{Cmd.command_raw_name});
                        return error.MissingRequiredArg;
                    }
                    try Cmd.invoke(args.?, parsed.opts);
                    return;
                }
            }

            // Nothing matched — show help
            if (self.help_enabled) {
                self.outputHelp();
            }
        }

        fn findCommandHelp(self: *Self, argv: []const []const u8) ?[]const u8 {
            _ = self;
            _ = argv;
            // TODO: scoped help for subcommand groups
            return null;
        }

        pub fn outputVersion(self: *Self) void {
            const stdout = getStdout();
            if (self.version) |ver| {
                stdout.print("{s}/{s}\n", .{ self.name, ver }) catch {};
            }
        }

        pub fn outputHelp(self: *Self) void {
            const stdout = getStdout();

            // Header
            if (self.version) |ver| {
                stdout.print(bold("{s}") ++ "/{s}\n\n", .{ self.name, ver }) catch {};
            } else {
                stdout.print(bold("{s}") ++ "\n\n", .{self.name}) catch {};
            }

            // Usage
            stdout.print(boldBlue("Usage") ++ ":\n  $ {s} <command> [options]\n\n", .{self.name}) catch {};

            // Commands
            stdout.print(boldBlue("Commands") ++ ":\n", .{}) catch {};

            // Calculate padding
            var max_name_len: usize = 0;
            inline for (commands) |Cmd| {
                const name_len = Cmd.command_raw_name.len;
                if (name_len > max_name_len) max_name_len = name_len;
            }

            inline for (commands) |Cmd| {
                const raw = Cmd.command_raw_name;
                const desc = Cmd.command_description;
                const padding = max_name_len - raw.len + 2;
                stdout.print("  " ++ boldCyan("{s}"), .{raw}) catch {};
                var p: usize = 0;
                while (p < padding) : (p += 1) {
                    stdout.writeByte(' ') catch {};
                }
                stdout.print("{s}\n", .{desc}) catch {};

                // Print command-specific options indented
                inline for (Cmd.command_opt_specs) |opt| {
                    stdout.print("    {s}", .{opt.raw}) catch {};
                    if (opt.description.len > 0) {
                        // Pad to align descriptions
                        const opt_padding = if (opt.raw.len < max_name_len - 2)
                            max_name_len - 2 - opt.raw.len
                        else
                            2;
                        var op: usize = 0;
                        while (op < opt_padding) : (op += 1) {
                            stdout.writeByte(' ') catch {};
                        }
                        stdout.print("{s}", .{opt.description}) catch {};
                    }
                    stdout.writeByte('\n') catch {};
                }
            }

            // Global options
            stdout.print("\n" ++ boldBlue("Options") ++ ":\n", .{}) catch {};
            stdout.print("  -h, --help     Display this message\n", .{}) catch {};
            if (self.version != null) {
                stdout.print("  -v, --version  Display version number\n", .{}) catch {};
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

test "fillArgs: required and optional" {
    const specs = [_]ArgSpec{
        .{ .name = "key", .required = true, .variadic = false },
        .{ .name = "value", .required = false, .variadic = false },
    };
    const ArgsType = builder.buildArgsType(&specs);

    // Both provided
    const positional = [_][]const u8{ "mykey", "myval" };
    const args = fillArgs(ArgsType, &specs, &positional);
    try std.testing.expect(args != null);
    try std.testing.expectEqualStrings("mykey", args.?.key);
    try std.testing.expectEqualStrings("myval", args.?.value.?);

    // Only required
    const positional2 = [_][]const u8{"mykey"};
    const args2 = fillArgs(ArgsType, &specs, &positional2);
    try std.testing.expect(args2 != null);
    try std.testing.expectEqualStrings("mykey", args2.?.key);
    try std.testing.expectEqual(@as(?[]const u8, null), args2.?.value);

    // Missing required
    const positional3 = [_][]const u8{};
    const args3 = fillArgs(ArgsType, &specs, &positional3);
    try std.testing.expect(args3 == null);
}
