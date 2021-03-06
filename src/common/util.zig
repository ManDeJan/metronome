const clap = @import("clap");
const std = @import("std");
const builtin = @import("builtin");

const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const os = std.os;

pub const algorithm = @import("algorithm.zig");
pub const bit = @import("bit.zig");
pub const container = @import("container.zig");
pub const exit = @import("exit.zig");
pub const escape = @import("escape.zig");
pub const parse = @import("parse.zig");
pub const testing = @import("testing.zig");
pub const unicode = @import("unicode.zig");

pub const readLine = @import("readline.zig").readLine;

test "" {
    _ = algorithm;
    _ = bit;
    _ = escape;
    _ = parse;
    _ = readLine;
    _ = testing;
    _ = unicode;
}

pub fn generateMain(
    version: []const u8,
    comptime main2: var,
    comptime params: []const clap.Param(clap.Help),
    comptime usage: var,
) fn () u8 {
    return struct {
        fn main() u8 {
            var stdio_buf = getStdIo();
            const stdio = stdio_buf.streams();
            defer stdio_buf.err.flush() catch {};

            // No need to deinit arena. The program will exit when this function
            // ends and all the memory will be freed by the os. This saves a bit
            // of shutdown time.
            var arena = heap.ArenaAllocator.init(heap.page_allocator);
            var args = clap.parse(clap.Help, params, &arena.allocator) catch |err| {
                stdio.err.print("{}\n", .{err}) catch {};
                usage(stdio.err) catch {};
                return 1;
            };

            if (args.flag("--help")) {
                usage(stdio.out) catch |err| return exit.stdoutErr(stdio.err, err);
                stdio_buf.out.flush() catch |err| return exit.stdoutErr(stdio.err, err);
                return 0;
            }

            if (args.flag("--version")) {
                stdio.out.print("{}\n", .{version}) catch |err| return exit.stdoutErr(stdio.err, err);
                stdio_buf.out.flush() catch |err| return exit.stdoutErr(stdio.err, err);
                return 0;
            }

            const res = main2(
                &arena.allocator,
                StdIo.In.InStream,
                StdIo.Out.OutStream,
                stdio,
                args,
            );

            stdio_buf.out.flush() catch |err| return exit.stdoutErr(stdio.err, err);
            return res;
        }
    }.main;
}

pub const StdIo = struct {
    pub const In = io.BufferedInStream(4096, fs.File.InStream);
    pub const Out = io.BufferedOutStream(4096, fs.File.OutStream);

    in: In,
    out: Out,
    err: Out,

    pub fn streams(stdio: *StdIo) StdIoStreams {
        return StdIoStreams{
            .in = stdio.in.inStream(),
            .out = stdio.out.outStream(),
            .err = stdio.err.outStream(),
        };
    }
};

pub const StdIoStreams = CustomStdIoStreams(StdIo.In.InStream, StdIo.Out.OutStream);
pub fn CustomStdIoStreams(comptime _InStream: type, comptime _OutStream: type) type {
    return struct {
        pub const InStream = _InStream;
        pub const OutStream = _OutStream;

        in: InStream,
        out: OutStream,
        err: OutStream,
    };
}

pub fn getStdIo() StdIo {
    return StdIo{
        .in = io.bufferedInStream(io.getStdIn().inStream()),
        .out = io.bufferedOutStream(io.getStdOut().outStream()),
        .err = io.bufferedOutStream(io.getStdErr().outStream()),
    };
}

test "getStdIo" {
    var stdio = getStdIo();
    const stdio_streams = stdio.streams();
}

/// Given a slice and a pointer, returns the pointers index into the slice.
/// ptr has to point into slice.
pub fn indexOfPtr(comptime T: type, slice: []const T, ptr: *const T) usize {
    const start = @ptrToInt(slice.ptr);
    const item = @ptrToInt(ptr);
    const dist_from_start = item - start;
    const res = @divExact(dist_from_start, @sizeOf(T));
    debug.assert(res < slice.len);
    return res;
}

test "indexOfPtr" {
    const arr = "abcde";
    for (arr) |*item, i| {
        std.testing.expectEqual(i, indexOfPtr(u8, arr, item));
    }
}

pub fn StackArrayList(comptime size: usize, comptime T: type) type {
    return struct {
        items: [size]T = undefined,
        len: usize = 0,

        pub fn fromSlice(items: []const T) !@This() {
            if (size < items.len)
                return error.SliceToBig;

            var res: @This() = undefined;
            mem.copy(T, &res.items, items);
            res.len = items.len;
            return res;
        }

        pub fn toSlice(list: *@This()) []T {
            return list.items[0..list.len];
        }

        pub fn toSliceConst(list: *const @This()) []const T {
            return list.items[0..list.len];
        }
    };
}

pub const Path = StackArrayList(fs.MAX_PATH_BYTES, u8);

pub const path = struct {
    pub fn join(paths: []const []const u8) Path {
        var res: Path = undefined;

        // FixedBufferAllocator + FailingAllocator are used here to ensure that a max
        // of MAX_PATH_BYTES is allocated, and that only one allocation occures. This
        // ensures that only a valid path has been allocated into res.
        var fba = heap.FixedBufferAllocator.init(&res.items);
        var failing = std.testing.FailingAllocator.init(&fba.allocator, 1);
        const res_slice = fs.path.join(&failing.allocator, paths) catch unreachable;
        res.len = res_slice.len;

        return res;
    }

    pub fn resolve(paths: []const []const u8) !Path {
        var res: Path = undefined;

        // FixedBufferAllocator + FailingAllocator are used here to ensure that a max
        // of MAX_PATH_BYTES is allocated, and that only one allocation occures. This
        // ensures that only a valid path has been allocated into res.
        var fba = heap.FixedBufferAllocator.init(&res.items);
        var failing = debug.FailingAllocator.init(&fba.allocator, math.maxInt(usize));
        const res_slice = try fs.path.resolve(&failing.allocator, paths);
        res.len = res_slice.len;
        debug.assert(failing.allocations == 1);

        return res;
    }
};

pub const dir = struct {
    pub fn selfExeDir() !Path {
        var res: Path = undefined;
        const res_slice = try fs.selfExeDirPath(&res.items);
        res.len = res_slice.len;
        return res;
    }

    pub fn cwd() !Path {
        var res: Path = undefined;
        const res_slice = try os.getcwd(&res.items);
        res.len = res_slice.len;
        return res;
    }

    pub const DirError = error{NotAvailable};

    pub fn home() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux, .windows => return getEnvPath("HOME"),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn cache() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return getEnvPathWithHomeFallback("XDG_CACHE_HOME", ".cache"),
            .windows => return knownFolder(&FOLDERID_LocalAppData),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn config() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return getEnvPathWithHomeFallback("XDG_CONFIG_HOME", ".config"),
            .windows => return knownFolder(&FOLDERID_RoamingAppData),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn audio() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("MUSIC"),
            .windows => return knownFolder(&FOLDERID_Music),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn desktop() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("DESKTOP"),
            .windows => return knownFolder(&FOLDERID_Desktop),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn documents() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("DOCUMENTS"),
            .windows => return knownFolder(&FOLDERID_Documents),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn download() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("DOWNLOAD"),
            .windows => return knownFolder(&FOLDERID_Downloads),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn pictures() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("PICTURES"),
            .windows => return knownFolder(&FOLDERID_Pictures),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn public() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("PUBLICSHARE"),
            .windows => return knownFolder(&FOLDERID_Public),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn templates() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("TEMPLATES"),
            .windows => return knownFolder(&FOLDERID_Templates),
            else => @compileError("Unsupported os"),
        }
    }

    pub fn videos() DirError!Path {
        switch (std.Target.current.os.tag) {
            .linux => return runXdgUserDirCommand("VIDEOS"),
            .windows => return knownFolder(&FOLDERID_Videos),
            else => @compileError("Unsupported os"),
        }
    }

    fn getEnvPathWithHomeFallback(key: []const u8, home_fallback: []const u8) DirError!Path {
        return getEnvPath(key) catch {
            const home_dir = try getEnvPath("HOME");
            return path.join(&[_][]const u8{ home_dir.toSliceConst(), home_fallback, "" });
        };
    }

    fn getEnvPath(key: []const u8) DirError!Path {
        const env = os.getenv(key) orelse return DirError.NotAvailable;
        if (!fs.path.isAbsolute(env))
            return DirError.NotAvailable;

        return path.join(&[_][]const u8{ env, "" });
    }

    fn runXdgUserDirCommand(key: []const u8) DirError!Path {
        var process_buf: [1024 * 1024]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&process_buf);
        comptime debug.assert(@sizeOf(std.ChildProcess) <= process_buf.len);

        // std.ChildProcess.init current impl allocates ChildProcess and nothing else.
        // Therefore it should never fail, as long as the above assert doesn't trigger.
        // Remember to make sure that this assumetion is up to date with zigs std lib.
        const process = std.ChildProcess.init(&[_][]const u8{ "xdg-user-dir", key }, &fba.allocator) catch unreachable;
        defer process.deinit();
        process.stdin_behavior = .Ignore;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Ignore;

        process.spawn() catch return DirError.NotAvailable;
        errdefer _ = process.kill() catch undefined;

        const stdout_stream = &process.stdout.?.inStream().stream;
        var res: Path = undefined;
        res.len = stdout_stream.readFull(&res.items) catch return DirError.NotAvailable;

        const term = process.wait() catch return DirError.NotAvailable;
        if (term == .Exited and term.Exited != 0)
            return DirError.NotAvailable;
        if (term != .Exited)
            return DirError.NotAvailable;

        res.len -= 1; // Remove newline. Assumes that if xdg-user-dir succeeds. It'll always return something

        // Join result with nothing, so that we always get an ending seperator
        res = path.join(&[_][]const u8{ res.toSliceConst(), "" }) catch return DirError.NotAvailable;

        // It's not very useful if xdg-user-dir returns the home dir, so let's assume that
        // the dir is not available if that happends.
        const home_dir = home() catch Path{};
        if (mem.eql(u8, res.toSliceConst(), home_dir.toSliceConst()))
            return DirError.NotAvailable;

        return res;
    }

    const FOLDERID_LocalAppData = os.windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}");
    const FOLDERID_RoamingAppData = os.windows.GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}");
    const FOLDERID_Music = os.windows.GUID.parse("{4BD8D571-6D19-48D3-BE97-422220080E43}");
    const FOLDERID_Desktop = os.windows.GUID.parse("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}");
    const FOLDERID_Documents = os.windows.GUID.parse("{FDD39AD0-238F-46AF-ADB4-6C85480369C7}");
    const FOLDERID_Downloads = os.windows.GUID.parse("{374DE290-123F-4565-9164-39C4925E467B}");
    const FOLDERID_Pictures = os.windows.GUID.parse("{33E28130-4E1E-4676-835A-98395C3BC3BB}");
    const FOLDERID_Public = os.windows.GUID.parse("{DFDF76A2-C82A-4D63-906A-5644AC457385}");
    const FOLDERID_Templates = os.windows.GUID.parse("{A63293E8-664E-48DB-A079-DF759E0509F7}");
    const FOLDERID_Videos = os.windows.GUID.parse("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}");

    fn knownFolder(id: *const os.windows.KNOWNFOLDERID) DirError!Path {
        var res_path: [*:0]os.windows.WCHAR = undefined;
        const err = os.windows.shell32.SHGetKnownFolderPath(id, 0, null, &res_path);
        if (err != os.windows.S_OK)
            return DirError.NotAvailable;

        defer os.windows.ole32.CoTaskMemFree(@ptrCast(*c_void, res_path));

        var buf: [fs.MAX_PATH_BYTES * 2]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buf);
        const utf8_path = std.unicode.utf16leToUtf8Alloc(&fba.allocator, mem.span(res_path)) catch return DirError.NotAvailable;

        // Join result with nothing, so that we always get an ending seperator
        return path.join(&[_][]const u8{ utf8_path, "" });
    }
};
