const std = @import("std");
const Allocator = std.mem.Allocator;

// FIXME: It's likely that this and LinkedArraysList should be one and the same

/// A list that is expected to be under small_size, but can expand up to
/// max_size by allocating new pages if necessary. Frees the extra pages if the
/// content no longer needs them
pub fn TypicallySmallList(comptime T: type) type {
    return struct {
        page_alloc: Allocator,
        initial_block: []T,
        // Expansions are our name for blocks that have to be allocated once
        // the initial block is full. Expansions start as 1 page, and double
        // every expansion. If our type is u8, we should see 4096, 8192, etc.
        //
        // Since the lengths are known, based off the index, we don't have to
        // store them
        //
        // Number of expansions is fixed on initialization, we do not attempt
        // to resize
        expansions: [][*]T,
        expansion_allocated: std.DynamicBitSetUnmanaged,
        capacity: usize,
        len: usize = 0,

        const elems_per_page = std.mem.page_size / @sizeOf(T);

        const Self = @This();
        const grow_factor = 2;

        pub fn init(init_alloc: Allocator, page_alloc: Allocator, small_size: usize, max_size: usize) !Self {
            const initial_block = try init_alloc.alloc(T, small_size);

            const num_expansions = idxToExpansionSlot(small_size, max_size - 1, elems_per_page);
            const expansions = try init_alloc.alloc([*]T, num_expansions);
            const expansion_allocated = try std.DynamicBitSetUnmanaged.initEmpty(init_alloc, num_expansions);

            return .{
                .page_alloc = page_alloc,
                .initial_block = initial_block,
                .expansions = expansions,
                .expansion_allocated = expansion_allocated,
                .capacity = max_size,
            };
        }

        pub fn append(self: *Self, elem: T) !void {
            if (self.len < self.initial_block.len) {
                self.initial_block[self.len] = elem;
                self.len += 1;
                return;
            }

            if (self.len >= self.capacity) {
                return error.OutOfMemory;
            }

            const block = idxToExpansionSlot(self.initial_block.len, self.len, elems_per_page);
            const block_start = expansionSlotStart(self.initial_block.len, block, elems_per_page);

            const expansion_offs = self.len - block_start;
            if (!self.expansion_allocated.isSet(block)) {
                const block_end = expansionSlotStart(self.initial_block.len, block + 1, elems_per_page);
                self.expansions[block] = (try self.page_alloc.alloc(T, block_end - block_start)).ptr;
                self.expansion_allocated.set(block);
            }

            self.expansions[block][expansion_offs] = elem;
            self.len += 1;
        }

        const IterativeExpansionCalc = struct {
            start: usize,
            idx: usize,
            size: usize,

            fn init(initial_block_len: usize) IterativeExpansionCalc {
                return .{
                    .start = initial_block_len,
                    .size = elems_per_page,
                    .idx = 0,
                };
            }

            fn step(self: *IterativeExpansionCalc) void {
                self.start += self.size;
                self.size *= grow_factor;
                self.idx += 1;
            }

            fn currentEnd(self: IterativeExpansionCalc) usize {
                return self.start + self.size;
            }
        };

        pub fn setContents(self: *Self, content: []const T) !void {
            if (content.len >= self.capacity) {
                return error.OutOfMemory;
            }

            self.len = 0; // In case of failure

            defer self.freeUnusedBlocks();

            const initial_block_len = @min(self.initial_block.len, content.len);
            @memcpy(self.initial_block[0..initial_block_len], content[0..initial_block_len]);

            if (content.len <= self.initial_block.len) {
                self.len = content.len;
                return;
            }

            var expansion_calc = IterativeExpansionCalc.init(self.initial_block.len);

            while (true) {
                const expansion_end = expansion_calc.currentEnd();

                if (content.len <= expansion_calc.start) break;

                const content_end = @min(
                    content.len,
                    expansion_end,
                );

                const expansion_copy_len = content_end - expansion_calc.start;

                if (expansion_copy_len == 0) {
                    self.len = content.len;
                    break;
                }

                // FIXME: Merge with append
                if (!self.expansion_allocated.isSet(expansion_calc.idx)) {
                    self.expansions[expansion_calc.idx] = (try self.page_alloc.alloc(T, expansion_calc.size)).ptr;
                    self.expansion_allocated.set(expansion_calc.idx);
                }

                @memcpy(self.expansions[expansion_calc.idx][0..expansion_copy_len], content[expansion_calc.start..content_end]);

                expansion_calc.step();
            }

            self.len = content.len;
        }

        pub fn contentMatches(self: Self, content: []const T) bool {
            var it = self.sliceIter();
            var content_idx: usize = 0;
            while (true) {
                const part = it.next();

                const remaining_content_len = content.len - content_idx;

                if (part.len == remaining_content_len) {
                    return std.mem.eql(T, content[content_idx..], part);
                }

                if (remaining_content_len < part.len or part.len == 0) {
                    return false;
                }

                if (!std.mem.eql(T, content[content_idx..][0..part.len], part)) {
                    return false;
                }

                content_idx += part.len;
            }
        }

        const UnusedBlocksIt = struct {
            parent: *Self,
            next_addition: usize,
            expansion_idx: usize,

            fn init(parent: *Self) UnusedBlocksIt {
                if (parent.len < parent.initial_block.len) {
                    return .{
                        .parent = parent,
                        .next_addition = elems_per_page,
                        .expansion_idx = 0,
                    };
                }

                const expansion_idx = idxToExpansionSlot(parent.initial_block.len, parent.len, elems_per_page) + 1;
                // FIXME: There's probably some way to directly calculate the block size
                const expansion_start = expansionSlotStart(parent.initial_block.len, expansion_idx, elems_per_page);
                const next_addition = expansionSlotStart(parent.initial_block.len, expansion_idx + 1, elems_per_page) - expansion_start;

                return .{
                    .parent = parent,
                    .next_addition = next_addition,
                    .expansion_idx = expansion_idx,
                };
            }

            const Output = struct {
                idx: usize,
                block: []T,
            };

            fn next(self: *UnusedBlocksIt) ?Output {
                if (!self.parent.expansion_allocated.isSet(self.expansion_idx)) {
                    return null;
                }

                defer {
                    self.next_addition *= grow_factor;
                    self.expansion_idx += 1;
                }

                return .{
                    .idx = self.expansion_idx,
                    .block = self.parent.expansions[self.expansion_idx][0..self.next_addition],
                };
            }
        };

        fn freeUnusedBlocks(self: *Self) void {
            var unused_block_it = UnusedBlocksIt.init(self);

            while (unused_block_it.next()) |block| {
                self.page_alloc.free(block.block);
                self.expansion_allocated.unset(block.idx);
            }
        }

        const SliceIter = struct {
            parent: *const Self,
            first: bool = true,
            calc: IterativeExpansionCalc,

            fn init(parent: *const Self) SliceIter {
                return .{
                    .parent = parent,
                    .calc = IterativeExpansionCalc.init(parent.initial_block.len),
                };
            }

            fn next(self: *SliceIter) []T {
                if (self.first) {
                    self.first = false;
                    const len = @min(self.parent.len, self.parent.initial_block.len);
                    return self.parent.initial_block[0..len];
                }

                if (self.calc.start >= self.parent.len) {
                    return &.{};
                }

                defer self.calc.step();

                const expansion = self.parent.expansions[self.calc.idx];
                std.debug.assert(self.parent.expansion_allocated.isSet(self.calc.idx));

                const len = @min(
                    self.parent.len - self.calc.start,
                    self.calc.size,
                );

                return expansion[0..len];
            }
        };

        pub fn sliceIter(self: *const Self) SliceIter {
            return SliceIter.init(self);
        }
    };
}

fn idxToExpansionSlot(initial_size: usize, idx: usize, elems_per_page: comptime_int) usize {
    // First expansion slot is the page size, each successive expansion
    // slot is twice as large as the previous
    //
    // first_slot_size(1 + 2 + 4 + 8)
    //
    // initial_slot + elems_per_page * (1 + 2 + 4 + 8 ... + n)
    //
    // E.g. with an initial slot of 100, elems_per_page of 500, and expansion slot 2
    // 100 + 500 + 1000 ...
    //     ^      ^      ^
    //     0      1      2
    //
    // We want to go the other way though, we want
    //   [0,100+500) -> 0,
    //   [100+500, 100+500+1000) -> 1,
    //   [100+500+1000, ...) -> 2,
    //   ...
    //
    // Plugging the sum part into wolfram alpha (sum 0..k 2^k), we get
    // pos = initial_slot + elems_per_page*(2^(n+1)) - 1)
    //
    // With some algebra
    // (pos - initial_slot) / elems_per_page = 2^(n+1) - 1
    // (pos - initial_slot) / elems_per_page + 1 = 2^(n+1)
    // log2((pos - initial_slot) / elems_per_page + 1) = n+1
    // log2((pos - initial_slot) / elems_per_page + 1) - 1 = n
    //
    // But then we're off by 1, so we drop the - 1 at the end
    const log2_arg = (idx -| initial_size) / elems_per_page + 1;
    if (log2_arg == 0) return 0;
    return std.math.log2(log2_arg);
}

fn expansionSlotStart(initial_size: usize, slot: usize, elems_per_page: usize) usize {
    // See idxToExpansionSlot
    return initial_size + elems_per_page * ((@as(usize, 1) << @intCast(slot)) - 1);
}

test "TypicallySmallList expansion idx" {
    try std.testing.expectEqual(0, idxToExpansionSlot(100, 0, 500));
    try std.testing.expectEqual(0, idxToExpansionSlot(100, 500, 500));
    try std.testing.expectEqual(0, idxToExpansionSlot(100, 100 + 500 - 1, 500));
    try std.testing.expectEqual(1, idxToExpansionSlot(100, 100 + 500, 500));
    try std.testing.expectEqual(1, idxToExpansionSlot(100, 100 + 500 + 1000 - 1, 500));
    try std.testing.expectEqual(2, idxToExpansionSlot(100, 100 + 500 + 1000, 500));
    try std.testing.expectEqual(2, idxToExpansionSlot(100, 100 + 500 + 1000 + 2000 - 1, 500));
    try std.testing.expectEqual(3, idxToExpansionSlot(100, 100 + 500 + 1000 + 2000, 500));
}

test "TypicallySmallList expansion idx slot start" {
    try std.testing.expectEqual(100, expansionSlotStart(100, 0, 500));
    try std.testing.expectEqual(600, expansionSlotStart(100, 1, 500));
    try std.testing.expectEqual(1600, expansionSlotStart(100, 2, 500));
    try std.testing.expectEqual(3600, expansionSlotStart(100, 3, 500));
}

test "TypicallySmallList append" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try TypicallySmallList(i32).init(
        arena.allocator(),
        std.heap.page_allocator,
        5,
        20000,
    );

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.append(5);

    var it = list.sliceIter();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, it.next());
    try std.testing.expectEqualSlices(i32, &.{}, it.next());

    try list.append(6);
    try list.append(7);
    try list.append(8);
    try list.append(9);

    it = list.sliceIter();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, it.next());
    try std.testing.expectEqualSlices(i32, &.{ 6, 7, 8, 9 }, it.next());
}

test "TypicallySmallList setContents" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try TypicallySmallList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    const content = "The quick brown fox jumped over the lazy dog " ** 1000;
    try list.setContents(content);

    var it = list.sliceIter();
    it = list.sliceIter();
    try std.testing.expectEqualStrings("The quick brown fox ", it.next());

    var start: usize = 20;
    var end: usize = start + 4096;
    try std.testing.expectEqualStrings(content[start..end], it.next());
    start = end;
    end = start + 8192;
    try std.testing.expectEqualStrings(content[start..end], it.next());
    start = end;
    end = start + 16384;
    try std.testing.expectEqualStrings(content[start..end], it.next());
    start = end;
    try std.testing.expectEqualStrings(content[start..], it.next());

    const content2 = "The quick brown fox jumped over the lazy dog";
    try list.setContents(content2);

    // FIXME: mock the page allocator and check free sizes

    try std.testing.expectEqual(false, list.expansion_allocated.isSet(2));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(3));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(4));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(5));

    const content3 = "The";
    try list.setContents(content3);
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(0));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(1));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(2));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(3));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(4));
    try std.testing.expectEqual(false, list.expansion_allocated.isSet(5));
}

test "TypicallySmallList UnusedBlockIter" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try TypicallySmallList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    const content = "The quick brown fox jumped over the lazy dog " ** 1000;
    try list.setContents(content);
    list.len = 20 + 4096 + 10;

    var it = TypicallySmallList(u8).UnusedBlocksIt.init(&list);

    {
        const next = it.next();
        try std.testing.expectEqual(2, next.?.idx);
        try std.testing.expectEqual(16384, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(3, next.?.idx);
        try std.testing.expectEqual(32768, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(null, next);
    }

    list.len = 3;
    it = TypicallySmallList(u8).UnusedBlocksIt.init(&list);

    {
        const next = it.next();
        try std.testing.expectEqual(0, next.?.idx);
        try std.testing.expectEqual(4096, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(1, next.?.idx);
        try std.testing.expectEqual(8192, next.?.block.len);
    }
}

test "TypicallySmallList content matches" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try TypicallySmallList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    const content = "The quick brown fox jumped over the lazy dog";
    try list.setContents(content);

    try std.testing.expectEqual(false, list.contentMatches("The"));
    try std.testing.expectEqual(true, list.contentMatches("The quick brown fox jumped over the lazy dog"));
    try std.testing.expectEqual(false, list.contentMatches("The quick brown fox jumped over the lazy dog" ** 2));
    try std.testing.expectEqual(false, list.contentMatches("asdf"));
}
