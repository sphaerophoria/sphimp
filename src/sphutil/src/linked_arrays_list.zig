const std = @import("std");
const Allocator = std.mem.Allocator;

fn ceilDiv(num: usize, denom: usize) usize {
    return ((num + denom - 1) / denom);
}

test "ceilDiv" {
    try std.testing.expectEqual(4, ceilDiv(10, 3));
    try std.testing.expectEqual(0, ceilDiv(0, 1024));
    try std.testing.expectEqual(1, ceilDiv(1, 1024));
}

pub fn LinkedArraysList(comptime T: type) type {
    return struct {
        const Self = @This();

        blocks: [][]T = &.{},
        block_allocated: std.DynamicBitSetUnmanaged,
        block_capacity: usize,
        total_capacity: usize,

        pub fn init(alloc: Allocator, block_capacity: usize, max_size: usize) !Self {
            const blocks_capacity = blocksCapacity(max_size, block_capacity);
            const blocks = try alloc.alloc([]T, blocks_capacity);
            @memset(blocks, &.{});

            const block_allocated = try std.DynamicBitSetUnmanaged.initEmpty(alloc, blocks_capacity);

            return .{
                .blocks = blocks.ptr[0..0],
                .block_allocated = block_allocated,
                .block_capacity = block_capacity,
                .total_capacity = max_size,
            };
        }

        pub fn get(self: Self, idx: usize) T {
            const split_idx = self.splitIdx(idx);
            return self.blocks[split_idx.block][split_idx.offset];
        }

        pub fn getPtr(self: Self, idx: usize) *T {
            const split_idx = self.splitIdx(idx);
            return &self.blocks[split_idx.block][split_idx.offset];
        }

        pub fn size(self: Self) usize {
            if (self.blocks.len == 0) return 0;
            return (self.blocks.len - 1) * self.block_capacity + self.lastBlock().len;
        }

        pub fn append(self: *Self, alloc: Allocator, elem: T) !void {
            if (self.size() >= self.total_capacity) {
                return error.OutOfMemory;
            }

            if (self.blocks.len == 0 or self.lastBlock().len == self.block_capacity) {
                try self.appendBlock(alloc);
            }

            const last_block = self.lastBlockPtr();
            const old_len = last_block.len;
            last_block.* = last_block.ptr[0 .. old_len + 1];
            last_block.*[old_len] = elem;
        }

        pub fn swapRemove(self: *Self, idx: usize) void {
            self.getPtr(idx).* = self.pop();
        }

        pub fn pop(self: *Self) T {
            const last_block = self.lastBlockPtr();
            const last_elem = last_block.*[last_block.len - 1];

            const old_len = last_block.len;
            last_block.* = last_block.ptr[0 .. old_len - 1];

            if (last_block.len == 0) {
                self.blocks = self.blocks.ptr[0 .. self.blocks.len - 1];
            }

            return last_elem;
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.size() == 0) return null;
            return self.pop();
        }

        const SplitIdx = struct {
            block: usize,
            offset: usize,
        };

        fn splitIdx(self: Self, idx: usize) SplitIdx {
            return .{
                .block = idx / self.block_capacity,
                .offset = idx % self.block_capacity,
            };
        }

        fn blocksCapacity(total_capacity: usize, block_capacity: usize) usize {
            return ceilDiv(total_capacity, block_capacity);
        }

        fn lastBlock(self: Self) []T {
            return self.blocks[self.blocks.len - 1];
        }

        fn lastBlockPtr(self: *Self) *[]T {
            return &self.blocks[self.blocks.len - 1];
        }

        fn appendBlock(self: *Self, alloc: Allocator) !void {
            if (self.blocks.len == blocksCapacity(self.total_capacity, self.block_capacity)) {
                return error.OutOfMemory;
            }

            const old_len = self.blocks.len;
            self.blocks = self.blocks.ptr[0 .. old_len + 1];
            // FIXME: Test....
            if (!self.block_allocated.isSet(old_len)) {
                const new_block = try alloc.alloc(T, self.block_capacity);
                self.blocks[old_len] = new_block.ptr[0..0];
                self.block_allocated.set(old_len);
            }
        }
    };
}

test "LinkedArrayList" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    {
        var al = try LinkedArraysList(usize).init(alloc, 100, 4000);
        for (0..4000) |i| {
            try al.append(alloc, i);
        }

        try std.testing.expectEqual(4000, al.size());
        try std.testing.expectError(error.OutOfMemory, al.append(alloc, 0));
        for (0..al.size()) |i| {
            try std.testing.expectEqual(i, al.get(i));
        }

        for (al.blocks) |block| {
            try std.testing.expectEqual(100, block.len);
        }
    }

    {
        var al = try LinkedArraysList(usize).init(alloc, 50, 55);
        for (0..55) |i| {
            try al.append(alloc, i);
        }

        try std.testing.expectError(error.OutOfMemory, al.append(alloc, 0));
    }
}

test "LinkedArrayList removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var al = try LinkedArraysList(usize).init(alloc, 5, 10);
    for (0..2) |_| {
        for (0..10) |i| {
            try al.append(alloc, i);
        }

        al.swapRemove(5);

        {
            const seq: []const usize = &.{ 0, 1, 2, 3, 4, 9, 6, 7, 8 };
            try std.testing.expectEqual(9, al.size());
            for (0..al.size()) |i| {
                try std.testing.expectEqual(seq[i], al.get(i));
            }
        }

        al.swapRemove(2);
        //const seq: []const usize  = &.{0, 1, 8, 3, 4, 9, 6, 7};
        al.swapRemove(1);
        //const seq: []const usize  = &.{0, 7, 8, 3, 4, 9, 6};
        al.swapRemove(0);
        //const seq: []const usize  = &.{6, 7, 8, 3, 4, 9};
        al.swapRemove(0);
        {
            const seq: []const usize = &.{ 9, 7, 8, 3, 4 };
            try std.testing.expectEqual(5, al.size());
            for (0..al.size()) |i| {
                try std.testing.expectEqual(seq[i], al.get(i));
            }
        }

        al.swapRemove(0);
        {
            const seq: []const usize = &.{ 4, 7, 8, 3 };
            try std.testing.expectEqual(4, al.size());
            for (0..al.size()) |i| {
                try std.testing.expectEqual(seq[i], al.get(i));
            }
        }

        al.swapRemove(0);
        al.swapRemove(0);
        al.swapRemove(0);
        al.swapRemove(0);
        try std.testing.expectEqual(0, al.size());
    }
}

pub fn main() !void {
    var prng = std.rand.DefaultPrng.init(0);
    const rand = prng.random();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var al = try LinkedArraysList(i32).init(alloc, 100, 4000);

    for (0..4000) |_| {
        try al.append(alloc, rand.int(i32));
    }

    const context = struct {
        al: LinkedArraysList(i32),

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.al.get(a) < ctx.al.get(b);
        }

        pub fn swap(ctx: @This(), a: usize, b: usize) void {
            return std.mem.swap(i32, ctx.al.getPtr(a), ctx.al.getPtr(b));
        }
    }{ .al = al };

    std.sort.pdqContext(0, al.size(), context);

    for (0..4000) |i| {
        std.debug.print("{d}\n", .{al.get(i)});
    }
}
