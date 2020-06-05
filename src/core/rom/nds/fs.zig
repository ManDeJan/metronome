const std = @import("std");

const formats = @import("formats.zig");
const int = @import("../int.zig");
const nds = @import("../nds.zig");

const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const lu16 = int.lu16;
const lu32 = int.lu32;

pub const Fs = struct {
    fnt: []u8,
    fat: []nds.Range,
    data: []u8,

    pub fn lookup(fs: Fs, path: []const []const u8) ?[]u8 {
        const index = fs.lookupIndex(path) orelse return null;
        const file = fs.fat[index];
        return fs.data[file.start.value()..file.end.value()];
    }

    pub fn lookupIndex(fs: Fs, path: []const []const u8) ?usize {
        var it = fs.iterate(0);
        outer: for (path) |name, i| {
            const is_file = i == path.len - 1;

            while (it.next()) |entry| {
                switch (entry.kind) {
                    .file => {
                        if (is_file and mem.eql(u8, entry.name, name))
                            return entry.id;
                    },
                    .folder => {
                        if (is_file or !mem.eql(u8, entry.name, name))
                            continue;

                        it = fs.iterate(entry.id);
                        continue :outer; // We found the folder. Continue on to the next one
                    },
                }
            }
            return null;
        }
        return null;
    }

    pub fn iterate(fs: Fs, folder_id: u32) Iterator {
        const fnt_main_table = fs.fntMainTable();
        const fnt_entry = fnt_main_table[folder_id];
        const file_id = fnt_entry.first_file_id.value();
        const offset = fnt_entry.offset_to_subtable.value();
        debug.assert(fs.fnt.len >= offset);

        return Iterator{
            .file_id = file_id,
            .fnt_sub_table = fs.fnt[offset..],
        };
    }

    pub fn at(fs: Fs, i: usize) []u8 {
        const fat = fs.fat[i];
        return fs.data[fat.start.value()..fat.end.value()];
    }

    pub fn fntMainTable(fs: Fs) []FntMainEntry {
        const rem = fs.fnt.len % @sizeOf(FntMainEntry);
        const fnt_mains = mem.bytesAsSlice(FntMainEntry, fs.fnt[0 .. fs.fnt.len - rem]);
        const len = fnt_mains[0].parent_id.value();

        debug.assert(fnt_mains.len >= len and len <= 4096 and len != 0);
        return fnt_mains[0..len];
    }

    /// Reinterprets the file system as a slice of T. This can only be
    /// done if the file system is arranged in a certain way:
    /// * All files must have the same size of `@sizeOf(T)`
    /// * All files must be arranged sequentially in memory with no padding
    ///   and in the same order as the `fat`.
    ///
    /// This function is useful when working with roms that stores arrays
    /// of structs in narc file systems.
    pub fn toSlice(fs: Fs, comptime T: type) ![]T {
        if (fs.fat.len == 0)
            return &[0]T{};

        const start = fs.fat[0].start.value();
        var end = start;
        for (fs.fat) |fat, i| {
            const fat_start = fat.start.value();
            if (fat_start != end)
                return error.FsIsNotSequential;
            end += @sizeOf(T);
        }

        return mem.bytesAsSlice(T, fs.data[start..end]);
    }

    /// Get a file system from a narc file. This function can faile if the
    /// bytes are not a valid narc.
    pub fn fromNarc(data: []u8) !Fs {
        var fbs = io.fixedBufferStream(data);
        const stream = fbs.inStream();
        const names = formats.Chunk.names;

        const header = try stream.readStruct(formats.Header);
        if (!mem.eql(u8, &header.chunk_name, names.narc))
            return error.InvalidNarcHeader;
        if (header.byte_order.value() != 0xFFFE)
            return error.InvalidNarcHeader;
        if (header.chunk_size.value() != 0x0010)
            return error.InvalidNarcHeader;
        if (header.following_chunks.value() != 0x0003)
            return error.InvalidNarcHeader;

        const fat_header = try stream.readStruct(formats.FatChunk);
        if (!mem.eql(u8, &fat_header.header.name, names.fat))
            return error.InvalidNarcHeader;

        const fat_size = fat_header.header.size.value() - @sizeOf(formats.FatChunk);
        const fat = mem.bytesAsSlice(nds.Range, data[fbs.pos..][0..fat_size]);
        fbs.pos += fat_size;

        const fnt_header = try stream.readStruct(formats.Chunk);
        const fnt_size = fnt_header.size.value() - @sizeOf(formats.Chunk);
        if (!mem.eql(u8, &fnt_header.name, names.fnt))
            return error.InvalidNarcHeader;

        const fnt = data[fbs.pos..][0..fnt_size];
        fbs.pos += fnt_size;

        const file_data_header = try stream.readStruct(formats.Chunk);
        if (!mem.eql(u8, &file_data_header.name, names.file_data))
            return error.InvalidNarcHeader;

        return Fs{
            .fat = fat,
            .fnt = fnt,
            .data = data[fbs.pos..],
        };
    }
};

pub const Iterator = struct {
    file_id: u32,
    fnt_sub_table: []const u8,

    pub fn next(it: *Iterator) ?Entry {
        var fbs = io.fixedBufferStream(it.fnt_sub_table);

        const stream = fbs.inStream();
        const type_length = stream.readByte() catch return null;
        if (type_length == 0)
            return null;

        const length = type_length & 0x7F;
        const is_folder = (type_length & 0x80) != 0;
        const name = fbs.buffer[fbs.pos..][0..length];
        fbs.pos += length;

        const id = if (is_folder) blk: {
            const read_id = stream.readIntLittle(u16) catch return null;
            debug.assert(read_id >= 0x8001 and read_id <= 0xFFFF);
            break :blk read_id & 0x7FFF;
        } else blk: {
            defer it.file_id += 1;
            break :blk it.file_id;
        };

        it.fnt_sub_table = fbs.buffer[fbs.pos..];
        return Entry{
            .kind = if (is_folder) .folder else .file,
            .id = id,
            .name = name,
        };
    }
};

pub const Entry = struct {
    kind: Kind,
    id: u32,
    name: []const u8,

    pub const Kind = enum {
        file,
        folder,
    };
};

pub const FntMainEntry = packed struct {
    offset_to_subtable: lu32,
    first_file_id: lu16,

    // For the first entry in main-table, the parent id is actually,
    // the total number of directories (See FNT Directory Main-Table):
    // http://problemkaputt.de/gbatek.htm#dscartridgenitroromandnitroarcfilesystems
    parent_id: lu16,
};

pub const Builder = struct {
    fnt_main: std.ArrayList(FntMainEntry),
    fnt_sub: std.ArrayList(u8),
    fat: std.ArrayList(nds.Range),

    pub fn init(allocator: *mem.Allocator) !Builder {
        var fnt_main = std.ArrayList(FntMainEntry).init(allocator);
        var fnt_sub = std.ArrayList(u8).init(allocator);
        errdefer fnt_main.deinit();
        errdefer fnt_sub.deinit();

        try fnt_main.append(.{
            .offset_to_subtable = lu32.init(0),
            .first_file_id = lu16.init(0),
            .parent_id = lu16.init(1),
        });
        try fnt_sub.append(0);

        return Builder{
            .fnt_main = fnt_main,
            .fnt_sub = fnt_sub,
            .fat = std.ArrayList(nds.Range).init(allocator),
        };
    }

    pub fn add(builder: *Builder, path: []const []const u8, size: u32) !void {
        var folder_entry: usize = 0;

        const relative_path = outer: for (path) |name, i| {
            const is_file = i == path.len - 1;

            const folder = builder.fnt_main.items[folder_entry];
            const offset = folder.offset_to_subtable.value();
            var it = Iterator{
                .file_id = folder.first_file_id.value(),
                .fnt_sub_table = builder.fnt_sub.items[offset..],
            };
            while (it.next()) |entry| {
                switch (entry.kind) {
                    .file => {
                        if (is_file and mem.eql(u8, entry.name, name))
                            return error.AlreadyFileExists;
                    },
                    .folder => {
                        if (is_file or !mem.eql(u8, entry.name, name))
                            continue;

                        folder_entry = entry.id;
                        continue :outer; // We found the folder. Continue on to the next one
                    },
                }
            }
            break :outer path[i..];
        } else path;

        const file_start = if (builder.fat.items.len != 0)
            builder.fat.items[builder.fat.items.len - 1].end.value()
        else
            0;
        const relative_root = builder.fnt_main.items[folder_entry];
        const file_id = relative_root.first_file_id.value();
        try builder.fat.insert(file_id, nds.Range.init(file_start, file_start + size));

        // Correct fnt_main after their file_ids moved around
        for (builder.fnt_main.items) |*entry| {
            const no_new_folders = relative_path.len == 1;
            const old_file_id = entry.first_file_id.value();
            const new_file_id = old_file_id + 1;
            if (old_file_id > file_id)
                entry.first_file_id = lu16.init(new_file_id);
            // If we're creating new folders, then the current folder will
            // point to the new folder at the first entry. The first file
            // of this folder will then also have been moved and we will
            // need to correct this.
            if (!no_new_folders and old_file_id == file_id)
                entry.first_file_id = lu16.init(new_file_id);
        }

        var buf: [1024]u8 = undefined;
        for (relative_path) |name, i| {
            const fbs = io.fixedBufferStream(&buf).outStream();
            const is_folder = i != relative_path.len - 1;
            const len = @intCast(u7, name.len);
            const kind = @as(u8, @boolToInt(is_folder)) << 7;
            try fbs.writeByte(kind | len);
            try fbs.writeAll(name);
            if (is_folder) {
                const folder_id = @intCast(u16, 0x8000 | builder.fnt_main.items.len);
                try fbs.writeAll(&lu16.init(folder_id).bytes);
            }

            const written = fbs.context.getWritten();
            const folder = builder.fnt_main.items[folder_entry];
            const offset = folder.offset_to_subtable.value();
            try builder.fnt_sub.insertSlice(offset, written);

            for (builder.fnt_main.items) |*entry| {
                const old_offset = entry.offset_to_subtable.value();
                const new_offset = old_offset + written.len;
                if (old_offset > offset)
                    entry.offset_to_subtable = lu32.init(@intCast(u32, new_offset));
            }

            if (is_folder) {
                const fnt_len = builder.fnt_sub.items.len;
                try builder.fnt_main.append(.{
                    .offset_to_subtable = lu32.init(@intCast(u32, fnt_len)),
                    .first_file_id = lu16.init(@intCast(u16, file_id)),
                    .parent_id = lu16.init(@intCast(u16, folder_entry)),
                });

                const old_count = builder.fnt_main.items[0].parent_id.value();
                builder.fnt_main.items[0].parent_id = lu16.init(old_count + 1);

                folder_entry = builder.fnt_main.items.len - 1;
                try builder.fnt_sub.append(0);
            }
        }
        return;
    }

    // Leaves builder in a none usable state. Only `deinit` is valid
    // after `finish`
    pub fn finish(builder: *Builder) !Fs {
        const sub_table_offset = builder.fnt_main.items.len * @sizeOf(FntMainEntry);
        for (builder.fnt_main.items) |*entry| {
            const new_offset = entry.offset_to_subtable.value() + sub_table_offset;
            entry.offset_to_subtable = lu32.init(@intCast(u32, new_offset));
        }

        const fnt_main_bytes = mem.sliceAsBytes(builder.fnt_main.items);
        try builder.fnt_sub.insertSlice(0, fnt_main_bytes);
        return Fs{
            .fnt = builder.fnt_sub.toOwnedSlice(),
            .fat = builder.fat.toOwnedSlice(),
            .data = &[_]u8{},
        };
    }

    pub fn deinit(builder: Builder) void {
        builder.fnt_main.deinit();
        builder.fnt_sub.deinit();
        builder.fat.deinit();
    }
};

test "Builder" {
    const paths = [_][]const []const u8{
        &[_][]const u8{ "a", "a" },
        &[_][]const u8{ "a", "b" },
        &[_][]const u8{ "a", "c", "a" },
        &[_][]const u8{"b"},
        &[_][]const u8{ "d", "a" },
    };
    var b = try Builder.init(testing.allocator);
    defer b.deinit();

    for (paths) |path|
        try b.add(path, 0);

    const fs = try b.finish();
    defer testing.allocator.free(fs.fnt);
    defer testing.allocator.free(fs.fat);

    for (paths) |path, i|
        testing.expect(fs.lookupIndex(path) != null);
    testing.expect(fs.lookupIndex(&[_][]const u8{}) == null);
    testing.expect(fs.lookupIndex(&[_][]const u8{""}) == null);
    testing.expect(fs.lookupIndex(&[_][]const u8{ "", "" }) == null);
    testing.expect(fs.lookupIndex(&[_][]const u8{"a"}) == null);
    testing.expect(fs.lookupIndex(&[_][]const u8{ "a", "a", "a" }) == null);
}
