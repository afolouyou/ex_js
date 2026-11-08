pub const std = @import("std");

const build_options = @import("build-options");
const execution = @import("../../../execution.zig");
const gc = @import("../../../gc.zig");
const types = @import("../../../types.zig");

const Agent = execution.Agent;
const String = types.String;

const Cache = @This();

pub const Entries = std.array_hash_map.Custom(*Entry.Link, void, struct {
    cache: *Cache,
    pub fn hash(ctx: @This(), link: *Entry.Link) u32 {
        if (link.entry == null) {
            ctx.cache.tombstone_encounters +|= 1;
        }
        return link.hash;
    }
    pub fn eql(ctx: @This(), a: *Entry.Link, b: *Entry.Link, _: usize) bool {
        if (a.entry == null or b.entry == null) {
            ctx.cache.tombstone_encounters +|= 1;
            return false;
        }
        return a.entry.?.key.eql(b.entry.?.key);
    }
}, false);

pub const Entry = struct {
    key: Key,
    value: String,

    pub const Link = struct {
        entry: ?*Entry,
        hash: u32,
    };

    pub const Key = union(enum) {
        utf8: []const u8,
        utf16: []const u16,

        pub fn eql(self: Key, other: Key) bool {
            if (self == .utf8 and other == .utf8) {
                return std.mem.eql(u8, self.utf8, other.utf8);
            } else if (self == .utf16 and other == .utf16) {
                return std.mem.eql(u16, self.utf16, other.utf16);
            }
            return false;
        }

        pub fn hash(self: Key) u32 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&std.meta.activeTag(self)));
            switch (self) {
                .utf8 => |utf8| hasher.update(utf8),
                .utf16 => |utf16| hasher.update(std.mem.sliceAsBytes(utf16)),
            }
            const bits = hasher.final();
            return @truncate(bits ^ (bits << 32));
        }
    };
};

entries: Entries,
tombstone_encounters: usize,

pub const empty: Cache = .{
    .entries = .empty,
    .tombstone_encounters = 0,
};

pub const GetOrPutResult = struct {
    found_existing: bool,
    string: *String,
};

pub fn getOrPut(cache: *Cache, agent: *Agent, key: Entry.Key) std.mem.Allocator.Error!GetOrPutResult {
    var temp_entry: Entry = .{ .key = key, .value = undefined };
    var temp_entry_link: Entry.Link = .{
        .entry = &temp_entry,
        .hash = key.hash(),
    };
    const gop = try cache.entries.getOrPutContext(agent.gc_allocator, &temp_entry_link, .{
        .cache = cache,
    });
    if (gop.found_existing and gop.key_ptr.*.entry != null) {
        return .{ .found_existing = true, .string = &gop.key_ptr.*.entry.?.value };
    }
    const entry_link = try agent.gc_allocator_atomic.create(Entry.Link);
    const entry = try agent.gc_allocator.create(Entry);
    entry_link.* = .{
        .entry = entry,
        .hash = temp_entry_link.hash,
    };
    entry.* = .{ .key = key, .value = undefined };
    gop.key_ptr.* = entry_link;
    if (build_options.enable_libgc) {
        try gc.registerDisappearingLink(@ptrCast(&entry_link.entry), @ptrCast(entry));
    }
    if (cache.tombstone_encounters > cache.entries.count() / 2) {
        var i: usize = 0;
        while (i < cache.entries.count()) {
            if (cache.entries.keys()[i].entry == null) {
                cache.entries.swapRemoveAtContext(i, .{ .cache = cache });
            } else {
                i += 1;
            }
        }
        cache.tombstone_encounters = 0;
    }
    return .{ .found_existing = false, .string = &entry.value };
}
