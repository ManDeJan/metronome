const clap = @import("clap");
const std = @import("std");
const util = @import("util");

const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const os = std.os;
const rand = std.rand;
const testing = std.testing;

const exit = util.exit;
const parse = util.parse;

const Clap = clap.ComptimeClap(clap.Help, &params);
const Param = clap.Param(clap.Help);

pub const main = util.generateMain("0.0.0", main2, &params, usage);

const params = blk: {
    @setEvalBranchQuota(100000);
    break :blk [_]Param{
        clap.parseParam("-h, --help        Display this help text and exit.                                                                ") catch unreachable,
        clap.parseParam("    --hms         Also randomize hms (this may break your game).") catch unreachable,
        clap.parseParam("-s, --seed <NUM>  The seed to use for random numbers. A random seed will be picked if this is not specified.      ") catch unreachable,
        clap.parseParam("-v, --version     Output version information and exit.                                                            ") catch unreachable,
    };
};

fn usage(stream: var) !void {
    try stream.writeAll("Usage: tm35-rand-machines ");
    try clap.usage(stream, &params);
    try stream.writeAll("\nRandomizes the moves of tms.\n" ++
        "\n" ++
        "Options:\n");
    try clap.help(stream, &params);
}

const Preference = enum {
    random,
    stab,
};

/// TODO: This function actually expects an allocator that owns all the memory allocated, such
///       as ArenaAllocator or FixedBufferAllocator. Can we either make this requirement explicit
///       or move the Arena into this function?
pub fn main2(
    allocator: *mem.Allocator,
    comptime InStream: type,
    comptime OutStream: type,
    stdio: util.CustomStdIoStreams(InStream, OutStream),
    args: var,
) u8 {
    const hms = args.flag("--hms");
    const seed = if (args.option("--seed")) |seed|
        fmt.parseUnsigned(u64, seed, 10) catch |err| {
            stdio.err.print("'{}' could not be parsed as a number to --seed: {}\n", .{ seed, err }) catch {};
            usage(stdio.err) catch {};
            return 1;
        }
    else blk: {
        var buf: [8]u8 = undefined;
        os.getrandom(buf[0..]) catch break :blk @as(u64, 0);
        break :blk mem.readInt(u64, &buf, .Little);
    };

    var stdin = io.bufferedInStream(stdio.in);
    var line_buf = std.ArrayList(u8).init(allocator);
    var data = Data{};

    while (util.readLine(&stdin, &line_buf) catch |err| return exit.stdinErr(stdio.err, err)) |line| {
        const str = mem.trimRight(u8, line, "\r\n");
        const print_line = parseLine(allocator, &data, hms, str) catch |err| switch (err) {
            error.OutOfMemory => return exit.allocErr(stdio.err),
            error.ParseError => true,
        };
        if (print_line)
            stdio.out.print("{}\n", .{str}) catch |err| return exit.stdoutErr(stdio.err, err);

        line_buf.resize(0) catch unreachable;
    }

    randomize(data, seed);

    for (data.tms.values()) |tm, i| {
        stdio.out.print(".tms[{}]={}\n", .{
            data.tms.at(i).key,
            tm,
        }) catch |err| return exit.stdoutErr(stdio.err, err);
    }
    for (data.hms.values()) |hm, i| {
        stdio.out.print(".hms[{}]={}\n", .{
            data.hms.at(i).key,
            hm,
        }) catch |err| return exit.stdoutErr(stdio.err, err);
    }

    return 0;
}

fn parseLine(allocator: *mem.Allocator, data: *Data, hms: bool, str: []const u8) !bool {
    const sw = util.parse.Swhash(8);
    const m = sw.match;
    const c = sw.case;

    var p = parse.MutParser{ .str = str };
    switch (m(try p.parse(parse.anyField))) {
        c("tms") => {
            _ = try data.tms.put(
                allocator,
                try p.parse(parse.index),
                try p.parse(parse.usizev),
            );
            return false;
        },
        c("hms") => if (hms) {
            _ = try data.hms.put(
                allocator,
                try p.parse(parse.index),
                try p.parse(parse.usizev),
            );
            return false;
        },
        c("moves") => {
            const index = try p.parse(parse.index);
            _ = try data.moves.put(allocator, index);
        },
        else => return true,
    }
    return true;
}

fn randomize(data: Data, seed: u64) void {
    var random = &rand.DefaultPrng.init(seed).random;

    for (data.tms.values()) |*tm|
        tm.* = data.moves.at(random.intRangeLessThan(usize, 0, data.moves.count()));
    for (data.hms.values()) |*hm|
        hm.* = data.moves.at(random.intRangeLessThan(usize, 0, data.moves.count()));
}

const Machines = util.container.IntMap.Unmanaged(usize, usize);
const Moves = util.container.IntSet.Unmanaged(usize);

const Data = struct {
    moves: Moves = Moves{},
    tms: Machines = Machines{},
    hms: Machines = Machines{},
};

test "tm35-rand-machines" {
    const result_prefix =
        \\.moves[0].power=10
        \\.moves[1].power=30
        \\.moves[2].power=30
        \\.moves[3].power=30
        \\.moves[4].power=50
        \\.moves[5].power=70
        \\
    ;
    const test_string = result_prefix ++
        \\.tms[0]=0
        \\.tms[1]=2
        \\.tms[2]=4
        \\.hms[0]=1
        \\.hms[1]=3
        \\.hms[2]=5
        \\
    ;
    util.testing.testProgram(main2, &params, &[_][]const u8{"--seed=0"}, test_string, result_prefix ++
        \\.hms[0]=1
        \\.hms[1]=3
        \\.hms[2]=5
        \\.tms[0]=1
        \\.tms[1]=0
        \\.tms[2]=0
        \\
    );
    util.testing.testProgram(main2, &params, &[_][]const u8{ "--seed=0", "--hms" }, test_string, result_prefix ++
        \\.tms[0]=1
        \\.tms[1]=0
        \\.tms[2]=0
        \\.hms[0]=1
        \\.hms[1]=2
        \\.hms[2]=5
        \\
    );
}