const std = @import("std");
const sphutil = @import("sphutil");
const Allocator = std.mem.Allocator;

const Block = []align(std.mem.page_size) u8;
fn mapBlock(size: usize) !Block {
    const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
    const page = try std.posix.mmap(
        null,
        aligned_size,
        // NOTE: Maybe remap from NONE as allocated
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );

    return page[0..aligned_size];
}

fn unmapBlock(block: Block) void {
    std.posix.munmap(block);
}

/// An incredibly simple bump allocator
///
/// We have to track almost nothing. Note that this is designed to be used with
/// the tracking block allocator below. Resets are tracked at the page level.
/// All we have to do is get aligned allocations in the current block. If they
/// don't fit, we get a new block. Easy
const BumpAlloc = struct {
    block_alloc: Allocator,
    current_block: []u8 = &.{},
    cursor: usize = 0,

    const allocator_vtable = std.mem.Allocator.VTable{
        .alloc = BumpAlloc.alloc,
        .resize = BumpAlloc.resize,
        .free = BumpAlloc.free,
    };

    fn allocator(self: *BumpAlloc) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *BumpAlloc = @ptrCast(@alignCast(ctx));

        {
            const alloc_start = std.mem.alignForwardLog2(self.cursor, ptr_align);
            const alloc_end = alloc_start + len;

            if (alloc_end <= self.current_block.len) {
                self.cursor = alloc_end;
                return self.current_block[alloc_start..alloc_end].ptr;
            }
        }

        std.debug.assert(ptr_align <= comptime std.math.log2(std.mem.page_size));
        const block_len = std.mem.alignForward(usize, len, std.mem.page_size);
        const new_block = self.block_alloc.rawAlloc(block_len, ptr_align, ret_addr) orelse return null;
        self.current_block = new_block[0..block_len];
        self.cursor = len;
        return self.current_block.ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}
};

const SingleFreeListAllocator = struct {
    const Range = struct {
        start: [*]u8,
        end: [*]u8,

        fn alloc(self: *Range, parent: *SingleFreeListAllocator, len: usize, ptr_align: u8) ?[*]u8 {
            const start_u: usize = @intFromPtr(self.start);
            const aligned_start_u = std.mem.alignForwardLog2(start_u, ptr_align);
            const aligned_end_u = aligned_start_u + len;
            if (aligned_end_u <= @intFromPtr(self.end)) {
                self.start = @ptrFromInt(aligned_end_u);
                // FIXME: if range empty, remove
                const ret: [*]u8 = @ptrFromInt(aligned_start_u);
                ret[len - 1] = @intCast(aligned_start_u - start_u);

                parent.alignment_wasted += aligned_start_u - start_u;
                parent.currently_allocated += aligned_end_u - start_u;
                // NOTE: len already has the tracking segment included
                // FIXME: Ew, we shouldn't have to do this +-1 shennanigans
                parent.tracking_wasted += 1;
                parent.requested_allocated += len - 1;

                return ret;
            } else {
                return null;
            }
        }
    };

    bump: BumpAlloc = .{},
    block_list: sphutil.LinkedArraysList(Block),
    free_list: sphutil.LinkedArraysList(Range),

    currently_allocated: usize = 0,
    requested_allocated: usize = 0,
    alignment_wasted: usize = 0,
    tracking_wasted: usize = 0,

    const allocator_vtable = std.mem.Allocator.VTable{
        .alloc = SingleFreeListAllocator.alloc,
        .resize = SingleFreeListAllocator.resize,
        .free = SingleFreeListAllocator.free,
    };

    fn init() !SingleFreeListAllocator {
        const list_block_size = 4096;
        const list_capacity = list_block_size * 1000;

        var bump = BumpAlloc{};
        const block_list = try sphutil.LinkedArraysList(Block).init(bump.allocator(), list_block_size, list_capacity);
        const free_list = try sphutil.LinkedArraysList(Range).init(bump.allocator(), list_block_size, list_capacity);

        return .{
            .bump = bump,
            .block_list = block_list,
            .free_list = free_list,
        };
    }

    fn allocator(self: *SingleFreeListAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *SingleFreeListAllocator = @ptrCast(@alignCast(ctx));

        const len_with_tracking = len + 1;
        for (0..self.free_list.size()) |i| {
            const range = self.free_list.getPtr(i);
            if (range.alloc(self, len_with_tracking, ptr_align)) |ret| {
                return ret;
            }
        }

        std.debug.assert(ptr_align < comptime std.math.log2(std.mem.page_size));
        const block = mapBlock(len_with_tracking) catch return null;
        self.block_list.append(self.bump.allocator(), block) catch unreachable;
        self.free_list.append(self.bump.allocator(), .{ .start = block.ptr + len_with_tracking, .end = block.ptr + block.len }) catch unreachable;

        self.currently_allocated += len_with_tracking;
        self.tracking_wasted += 1;
        self.requested_allocated += len;

        block[len] = 0;
        return block.ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ret_addr;
        _ = buf_align;
        const self: *SingleFreeListAllocator = @ptrCast(@alignCast(ctx));
        const start_adjustment = buf.ptr[buf.len];
        const buf_end = buf.ptr + buf.len + 1;
        const buf_start = buf.ptr - start_adjustment;

        const requested_free_size = buf.len;
        const actual_free_size = buf.len + start_adjustment + 1;

        self.currently_allocated -= actual_free_size;
        self.requested_allocated -= requested_free_size;
        self.alignment_wasted -= start_adjustment;
        self.tracking_wasted -= 1;

        // Find free_list_eleme
        self.free_list.append(self.bump.allocator(), .{ .start = buf_start, .end = buf_end }) catch unreachable;

        self.mergeAdjacentFreeSegments(self.free_list.size() - 1);
    }

    fn mergeAdjacentFreeSegments(self: *SingleFreeListAllocator, idx: usize) void {
        std.debug.print("Starting merge\n", .{});
        var it = idx;
        outer: while (true) {
            std.debug.print("it: {d}\n", .{it});
            const our_elem = self.free_list.get(it);
            for (0..self.free_list.size()) |i| {
                if (i == it) continue;

                const other_elem = self.free_list.getPtr(i);

                if (other_elem.start == our_elem.end) {
                    other_elem.start = our_elem.start;
                    self.free_list.swapRemove(it);
                    if (i != self.free_list.size()) {
                        it = i;
                    }
                    continue :outer;
                } else if (other_elem.end == our_elem.start) {
                    other_elem.end = our_elem.end;
                    self.free_list.swapRemove(it);
                    if (i != self.free_list.size()) {
                        it = i;
                    }
                    continue :outer;
                }
            }
            break;
        }
    }

    const Jsonable = struct {
        const JsonRange = struct {
            start: usize,
            end: usize,
        };

        block_list: []JsonRange,
        free_list: []JsonRange,
        currently_allocated: usize,
        requested_allocated: usize,
        alignment_wasted: usize,
        tracking_wasted: usize,
    };

    fn jsonable(self: *SingleFreeListAllocator, std_alloc: std.mem.Allocator) !Jsonable {
        const block_list = try std_alloc.alloc(Jsonable.JsonRange, self.block_list.size());
        const free_list = try std_alloc.alloc(Jsonable.JsonRange, self.free_list.size());
        for (0..block_list.len) |i| {
            const item = self.block_list.get(i);
            block_list[i] = .{
                .start = @intFromPtr(item.ptr),
                .end = @intFromPtr(item.ptr + item.len),
            };
        }

        for (0..free_list.len) |i| {
            const item = self.free_list.get(i);
            free_list[i] = .{
                .start = @intFromPtr(item.start),
                .end = @intFromPtr(item.end),
            };
        }

        return .{
            .block_list = block_list,
            .free_list = free_list,
            .currently_allocated = self.currently_allocated,
            .requested_allocated = self.requested_allocated,
            .alignment_wasted = self.alignment_wasted,
            .tracking_wasted = self.tracking_wasted,
        };
    }
};

// FIXME: Double free protection
// FIXME: Release pages back to system
// FIXME: Prevent free that did not come from this allocator
// FIXME: Set freed segments to undefined and check that they're undefined when they come out
pub const BuddyListAllocator = struct {
    const allocator_vtable = std.mem.Allocator.VTable{
        .alloc = BuddyListAllocator.alloc,
        .resize = BuddyListAllocator.resize,
        .free = BuddyListAllocator.free,
    };

    const min_block_log2 = 2;
    const max_block_log2 = std.math.log2(std.mem.page_size);
    const num_free_lists = max_block_log2 - min_block_log2 + 1;

    const max_smallest_blocks = 100;

    bump: BumpAlloc,
    blocks: sphutil.LinkedArraysList(Block),
    free_lists: [num_free_lists]sphutil.RuntimeBoundedArray([*]u8),

    requested_allocated: usize,
    internal_fragmentation: usize,

    pub fn initPinned(self: *BuddyListAllocator) !void {
        self.bump = .{};
        self.blocks = try sphutil.LinkedArraysList(Block).init(self.bump.allocator(), 100, 5000);
        self.requested_allocated = 0;
        self.internal_fragmentation = 0;
        for (&self.free_lists) |*l| {
            l.* = try sphutil.RuntimeBoundedArray([*]u8).init(self.bump.allocator(), 100);
        }
    }

    pub fn allocator(self: *BuddyListAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *BuddyListAllocator = @ptrCast(@alignCast(ctx));

        if (self.requested_allocated >= 5e8) {
            return null;
        }

        const alloc_source = selectAllocSource(len, ptr_align);
        switch (alloc_source) {
            .page => {
                std.debug.assert(ptr_align < comptime std.math.log2(std.mem.page_size));
                const ret = mapBlock(len) catch return null;
                self.blocks.append(self.bump.allocator(), ret) catch unreachable;
                self.requested_allocated += len;
                self.internal_fragmentation += std.mem.alignForward(usize, len, std.mem.page_size) - len;
                return ret.ptr;
            },
            .free_list => |selected_free_list| {
                self.ensureAtLeastOneFreeElem(selected_free_list) catch return null;
                self.requested_allocated += len;
                self.internal_fragmentation += freeIdxToSize(selected_free_list) - len;
                return self.free_lists[selected_free_list].pop();
            },
        }
    }

    const AllocSource = union(enum) {
        page,
        free_list: usize,
    };

    fn selectAllocSource(len: usize, ptr_align: u8) AllocSource {
        const log2_len = std.math.log2_int_ceil(usize, len);
        if (log2_len >= max_block_log2) {
            return .page;
        }
        return .{ .free_list = @max(log2_len, ptr_align) -| min_block_log2 };
    }

    fn ensureAtLeastOneFreeElem(self: *BuddyListAllocator, free_list_idx: usize) !void {
        for (free_list_idx..self.free_lists.len) |i| {
            if (self.free_lists[i].size() > 0) {
                try self.splitFreeListItem(i, free_list_idx);
                return;
            }
        }

        const new_block = try mapBlock(std.mem.page_size);
        self.blocks.append(self.bump.allocator(), new_block) catch unreachable;
        try self.free_lists[self.free_lists.len - 1].append(self.bump.allocator(), new_block.ptr);
        try self.splitFreeListItem(max_block_log2 - min_block_log2, free_list_idx);
    }

    // FIXME: This could just return the block
    fn splitFreeListItem(self: *BuddyListAllocator, start_idx: usize, end_idx: usize) !void {
        if (start_idx == end_idx) return;

        var cur_idx = start_idx;
        std.debug.assert(start_idx > end_idx);
        var cur_list_item = self.free_lists[start_idx].pop();
        while (cur_idx > end_idx) {
            defer cur_idx -= 1;
            const item_size = freeIdxToSize(cur_idx);
            const a = cur_list_item[0 .. item_size / 2];
            const b = cur_list_item[item_size / 2 .. item_size];

            try self.free_lists[cur_idx - 1].append(self.bump.allocator(), a.ptr);
            cur_list_item = b.ptr;
        }
        try self.free_lists[cur_idx].append(self.bump.allocator(), cur_list_item);
    }

    fn freeIdxToSize(idx: usize) usize {
        const log2_size = idx + min_block_log2;
        return @as(usize, 1) << @intCast(log2_size);
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ret_addr;
        const self: *BuddyListAllocator = @ptrCast(@alignCast(ctx));

        self.requested_allocated -= buf.len;

        const alloc_source = selectAllocSource(buf.len, buf_align);
        switch (alloc_source) {
            .page => {
                const mapped = buf.ptr[0..std.mem.alignForward(usize, buf.len, std.mem.page_size)];
                const num_allocated_blocks = self.blocks.size();

                // FIXME: assert block is in blocks
                for (0..num_allocated_blocks) |i| {
                    if (self.blocks.get(i).ptr == mapped.ptr) {
                        self.blocks.swapRemove(i);
                        break;
                    }
                }

                self.internal_fragmentation -= mapped.len - buf.len;
                unmapBlock(@alignCast(mapped));
            },
            .free_list => |selected_free_list| {
                self.internal_fragmentation -= freeIdxToSize(selected_free_list) - buf.len;
                self.free_lists[selected_free_list].append(self.bump.allocator(), buf.ptr) catch unreachable;
                // FIXME: Merge adjacent
            },
        }
    }
};

fn dumpAlloc(normal: *SingleFreeListAllocator) void {
    for (0..normal.free_list.size()) |i| {
        const range = normal.free_list.get(i);
        std.debug.print("Free range eggs: {any}-{any}\n", .{ range.start, range.end });
    }

    for (0..normal.block_list.size()) |i| {
        const block = normal.block_list.get(i);
        std.debug.print("Block size: {d}\n", .{block.len});
    }

    const total_capacity: i64 = @intCast(totalCapacity(normal.block_list));
    const free_list_size: i64 = @intCast(freeListSize(normal));
    std.debug.print("Size of allocated blocks: {d}\n", .{total_capacity});
    std.debug.print("Ready to be allocated: {d}\n", .{free_list_size});
    std.debug.print("Currently allocated: {d}\n", .{normal.currently_allocated});
    std.debug.print("requested_allocated: {d}\n", .{normal.requested_allocated});
    std.debug.print("alignment_wasted: {d}\n", .{normal.alignment_wasted});
    std.debug.print("tracking_wasted: {d}\n", .{normal.tracking_wasted});

    std.debug.print("All bytes accounted for? {}\n", .{@as(i64, @intCast(normal.currently_allocated)) + free_list_size - total_capacity});
}

fn freeListSize(normal: *SingleFreeListAllocator) usize {
    var ret: usize = 0;
    for (0..normal.free_list.size()) |i| {
        const range = normal.free_list.get(i);
        const range_end_u: usize = @intFromPtr(range.end);
        const range_start_u: usize = @intFromPtr(range.start);
        ret += range_end_u - range_start_u;
    }
    return ret;
}

fn totalCapacity(block_list: sphutil.LinkedArraysList(Block)) usize {
    var ret: usize = 0;
    for (0..block_list.size()) |i| {
        ret += block_list.get(i).len;
    }
    return ret;
}

fn mappedMemory(normal: *SingleFreeListAllocator) usize {
    var ret: usize = 0;
    for (0..normal.block_list.size()) |i| {
        ret += normal.block_list.get(i).len;
    }
    return ret;
}

const AllocType = enum {
    u8,
    u16,
    u32,
    u64,

    fn toType(comptime self: AllocType) type {
        return switch (self) {
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .u64 => u64,
        };
    }
};

const Allocation = union(AllocType) {
    u8: []u8,
    u16: []u16,
    u32: []u32,
    u64: []u64,

    fn deinit(self: Allocation, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |d| {
                alloc.free(d);
            },
        }
    }
};

fn randAlloc(alloc: std.mem.Allocator, rand: std.Random) !Allocation {
    const alloc_type = rand.enumValue(AllocType);
    const alloc_size = rand.intRangeAtMost(usize, 1, 1000);
    switch (alloc_type) {
        inline else => |t| {
            const data = try alloc.alloc(t.toType(), alloc_size);
            for (0..data.len) |i| {
                data[i] = @intCast(i % std.math.maxInt(t.toType()));
            }
            return @unionInit(Allocation, @tagName(t), data);
        },
    }
}

fn RollingBuffer(comptime T: type) type {
    return struct {
        items: []T,
        idx: usize = 0,

        const Self = @This();

        fn push(self: *const Self, elem: T) T {
            const ret = self.items[self.idx];
            self.items[self.idx] = elem;
            return ret;
        }
    };
}

pub fn dumpBuddy(buddy: *BuddyListAllocator) void {
    std.debug.print("Total allocated: {d}\n", .{totalCapacity(buddy.blocks)});
    std.debug.print("Requested allocated: {d}\n", .{buddy.requested_allocated});
    std.debug.print("Internal frag: {d}\n", .{buddy.internal_fragmentation});
    var total_free: usize = 0;
    for (0..buddy.free_lists.len) |i| {
        const item_size = @as(usize, 1) << @intCast(i + BuddyListAllocator.min_block_log2);
        std.debug.print("{d}: {d}\n", .{
            item_size,
            buddy.free_lists[i].size(),
        });
        total_free += item_size * buddy.free_lists[i].size();
    }
    std.debug.print("Total free: {d}\n", .{total_free});
}

//pub fn main() !void {
//    var buddy: BuddyListAllocator = undefined;
//    try buddy.initPinned();
//
//    const alloc = buddy.allocator();
//
//    var rng = std.rand.DefaultPrng.init(0);
//    const rand = rng.random();
//
//    const allocations_buf = try alloc.alloc(Allocation, 100);
//    for (allocations_buf) |*allocation| {
//        allocation.* = try randAlloc(alloc, rand);
//    }
//
//    const allocations = RollingBuffer(Allocation){ .items = allocations_buf };
//    for (0..5000) |_| {
//        const evicted = allocations.push(try randAlloc(alloc, rand));
//        switch (evicted) {
//            inline else => |e, t| {
//                for (0..e.len) |i| {
//                    if (e[i] != i % std.math.maxInt(t.toType())) unreachable;
//                }
//            }
//        }
//        evicted.deinit(alloc);
//    }
//
//    //for (allocations.items) |a| {
//    //    a.deinit(alloc);
//    //}
//    //alloc.free(allocations_buf);
//
//    dumpBuddy(&buddy);
//
//    //var al = std.ArrayList(usize).init(alloc);
//    //for (0..4000) |i| {
//    //    try al.append(i);
//    //}
//
//    //for (al.items) |item| {
//    //    std.debug.print("{d}\n", .{item});
//    //}
//
//
//    //dumpAlloc(&normal);
//
//    //const f = try std.fs.cwd().createFile("visualizer/allocator_state.json", .{});
//    //defer f.close();
//    //var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//    //try std.json.stringify(try normal.jsonable(gpa.allocator()), .{.whitespace = .indent_2}, f.writer());
//    //
//    //al.deinit();
//    //dumpAlloc(&normal);
//    //const ints = try alloc.alloc(i32, 4);
//    //std.debug.print("ints ptr: {any}\n", .{ints.ptr});
//
//
//    //std.debug.print("{any}\n", .{bump});
//
//    //bump.reset();
//
//    //for (al.items) |item| {
//    //    std.debug.print("{d}\n", .{item});
//    //}
//}

fn PageLinkedLists(comptime T: type) type {
    const Ret = struct {
        root: *ListSegment,

        const Self = @This();

        const ListSegment = struct {
            metadata: Metadata = .{},
            storage: [capacity]T = undefined,

            const Metadata = struct {
                next: ?*ListSegment = null,
                len: usize = 0,
            };
            const capacity = (std.mem.page_size - @sizeOf(Metadata)) / @sizeOf(T);

            pub fn swapRemove(self: *ListSegment, idx: usize) void {
                if (self.metadata.len > 0) {
                    self.storage[idx] = self.storage[self.metadata.len - 1];
                    self.metadata.len -= 1;
                }
            }
        };

        pub fn init(page_alloc: Allocator) !Self {
            const root = try page_alloc.create(ListSegment);
            root.* = ListSegment{};
            return .{
                .root = root,
            };
        }

        pub fn deinit(self: *Self, page_alloc: Allocator) void {
            var segment_opt: ?*ListSegment = self.root;
            while (segment_opt) |segment| {
                const next_segment = segment.metadata.next;
                page_alloc.destroy(segment);
                segment_opt = next_segment;
            }
        }

        const Iterator = struct {
            list_segment: *ListSegment,
            idx: usize = 0,

            fn next(self: *Iterator) ?*T {
                if (self.idx == self.list_segment.metadata.len) {
                    self.list_segment = self.list_segment.metadata.next orelse return null;
                    self.idx = 0;
                }
                defer self.idx += 1;

                return &self.list_segment.storage[self.idx];
            }
        };

        pub fn iter(self: *Self) Iterator {
            return .{
                .list_segment = self.root,
            };
        }

        // May not insert at end of list :)
        pub fn insert(self: *Self, page_alloc: Allocator, val: T) !void {
            var last_segment = self.lastSegment();
            if (last_segment.metadata.len == ListSegment.capacity) {
                // FIXME: Extend list
                const new_segment = try page_alloc.create(ListSegment);
                new_segment.* = .{};
                last_segment.metadata.next = new_segment;
                last_segment = new_segment;
            }

            last_segment.storage[last_segment.metadata.len] = val;
            last_segment.metadata.len += 1;
        }

        fn lastSegment(self: *Self) *ListSegment {
            var segment = self.root;
            while (segment.metadata.next) |val| {
                segment = val;
            }
            return segment;
        }
    };

    comptime std.debug.assert(@sizeOf(Ret.ListSegment) <= std.mem.page_size);

    return Ret;
}

const BlockAllocator = struct {
    allocated_blocks: PageLinkedLists(Block),

    const allocator_vtable: Allocator.VTable = .{
        .alloc = BlockAllocator.alloc,
        .resize = BlockAllocator.resize,
        .free = BlockAllocator.free,
    };

    fn init() !BlockAllocator {
        return .{
            .allocated_blocks = try PageLinkedLists(Block).init(std.heap.page_allocator),
        };
    }

    fn deinit(self: *BlockAllocator) void {
        var it = self.allocated_blocks.iter();
        while (it.next()) |block| {
            std.heap.page_allocator.free(block.*);
        }

        self.allocated_blocks.deinit(std.heap.page_allocator);
    }

    pub fn allocator(self: *BlockAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn allocated(self: *BlockAllocator) usize {
        var it = self.allocated_blocks.iter();
        var ret: usize = 0;
        while (it.next()) |block| {
            ret += block.len;
        }

        return ret;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *BlockAllocator = @ptrCast(@alignCast(ctx));

        const ret = std.heap.page_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;

        std.debug.assert(ptr_align <= std.math.log2_int(usize, std.mem.page_size));

        const full_block_len = std.mem.alignForward(usize, len, std.mem.page_size);
        // FIXME: Free ret now on failure and return null
        self.allocated_blocks.insert(std.heap.page_allocator, @alignCast(ret[0..full_block_len])) catch unreachable;
        return ret;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *BlockAllocator = @ptrCast(@alignCast(ctx));

        if (self.findBlock(buf)) |it| {
            // FIXME: Using iterator here feels like a hack.
            // Optimization of using the list segment without re-walking the
            // list seems reasonable
            // Having to look at idx - 1 seems not so great
            it.list_segment.swapRemove(it.idx - 1);
            std.debug.assert(self.findBlock(buf) == null);
            std.heap.page_allocator.rawFree(buf, buf_align, ret_addr);
        } else {
            unreachable;
        }
    }

    fn findBlock(self: *BlockAllocator, buf: []u8) ?PageLinkedLists(Block).Iterator {
        var it = self.allocated_blocks.iter();
        while (it.next()) |elem| {
            if (buf.ptr == elem.ptr) {
                if (elem.len > std.mem.alignForward(usize, buf.len, std.mem.page_size)) {
                    unreachable;
                }
                return it;
            }
        }

        return null;
    }
};

const LockableArena = struct {
    inner: BumpAlloc,
    locked: bool = false,

    const allocator_vtable: Allocator.VTable = .{
        .alloc = LockableArena.alloc,
        .resize = LockableArena.resize,
        .free = LockableArena.free,
    };

    pub fn allocator(self: *LockableArena) Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    pub fn lock(self: *LockableArena) void {
        // FIXME: With use in Sphalloc, maybe we want to lock the whole tree..
        self.locked = true;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *LockableArena = @ptrCast(@alignCast(ctx));
        if (self.locked) return null;
        return self.inner.allocator().rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *LockableArena = @ptrCast(@alignCast(ctx));
        return self.inner.allocator().rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *LockableArena = @ptrCast(@alignCast(ctx));
        self.inner.allocator().rawFree(buf, buf_align, ret_addr);
    }
};

// FIXME: Would be nice if we used our bump alloc here instead to avoid
// over-allocating up front
pub const ScratchAlloc = struct {
    backing: std.heap.FixedBufferAllocator,

    pub fn init(buf: []u8) ScratchAlloc {
        return .{
            .backing = std.heap.FixedBufferAllocator.init(buf),
        };
    }

    pub fn allocator(self: *ScratchAlloc) Allocator {
        return self.backing.allocator();
    }

    pub fn reset(self: *ScratchAlloc) void {
        self.backing.reset();
    }

    pub const Checkpoint = usize;

    pub fn checkpoint(self: *ScratchAlloc) Checkpoint {
        return self.backing.end_index;
    }

    pub fn restore(self: *ScratchAlloc, restore_point: Checkpoint) void {
        self.backing.end_index = restore_point;
    }
};

// Currently each sphalloc has 8K of overhead because each of the child
// allocators pull in a page. Don't make these willy nilly
pub const Sphalloc = struct {
    block_alloc: BlockAllocator,
    name: []const u8,
    // Owned by our own arena
    children: Children = .{},
    parent: ?*Sphalloc = null,

    // FIXME: Can we reduce overhead?
    // Backed by block_alloc
    storage: struct {
        general: GeneralAlloc = .{},
        arena: LockableArena,
    },

    const GeneralAlloc = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = false,
        .stack_trace_frames = 0,
    });
    const Children = std.SinglyLinkedList(Sphalloc);

    // Self reference requires that sphalloc has a stable location
    pub fn initPinned(self: *Sphalloc, comptime name: []const u8) !void {
        self.* = .{
            .block_alloc = try BlockAllocator.init(),
            .name = name,
            .storage = .{
                .arena = .{
                    .inner = .{
                        .block_alloc = self.block_alloc.allocator(),
                    },
                },
                .general = .{
                    .backing_allocator = self.block_alloc.allocator(),
                    .bucket_node_pool = .{
                        .arena = .{
                            .state = .{},
                            .child_allocator = self.block_alloc.allocator(),
                        },
                    },
                },
            },
        };
    }

    pub fn deinit(self: *Sphalloc) void {
        self.removeFromParent();
        self.freeAllMemory();
    }

    fn removeFromParent(self: *Sphalloc) void {
        if (self.parent) |p| {
            var it = p.children.first;
            while (it) |node| {
                if (&node.data == self) {
                    // FIXME: Walking list an extra time
                    p.children.remove(node);
                    break;
                }
                it = node.next;
            }
        }
    }

    fn freeAllMemory(self: *Sphalloc) void {
        var it = self.children.first;
        while (it) |node| {
            node.data.freeAllMemory();
            it = node.next;
        }

        self.block_alloc.deinit();
    }

    pub fn reset(self: *Sphalloc) !void {
        self.freeAllMemory();
        self.children = .{};
        self.block_alloc = try BlockAllocator.init();
        self.storage = .{
            .arena = .{
                .inner = .{
                    .block_alloc = self.block_alloc.allocator(),
                },
            },
        };
        // Heal self references
        _ = self.arena();
        _ = self.general();
    }

    pub fn arena(self: *Sphalloc) Allocator {
        return self.storage.arena.allocator();
    }

    pub fn general(self: *Sphalloc) Allocator {
        return self.storage.general.allocator();
    }

    pub fn makeSubAlloc(self: *Sphalloc, comptime name: []const u8) !*Sphalloc {
        // FIXME: if initPinned fails, then this node leaks. We should probably checkpoint and restore our arena
        const node = try self.arena().create(Children.Node);
        node.* = .{
            .next = self.children.first,
            .data = undefined,
        };
        try node.data.initPinned(name);
        node.data.parent = self;
        self.children.prepend(node);
        return &node.data;
    }

    // FIXME: Support this as const
    pub fn totalMemoryAllocated(self: *Sphalloc) usize {
        var total_memory_allocated: usize = self.block_alloc.allocated();

        var it: ?*Children.Node = self.children.first;
        while (it) |val| {
            total_memory_allocated += val.data.totalMemoryAllocated();
            it = val.next;
        }
        return total_memory_allocated;
    }
};

test "Sphalloc sanity" {
    // Sanity test that
    // * Spawns a root alloc
    // * Makes a couple children
    // * Spams some allocations and de-allocations using both the arena and the
    //   general allocators
    // * Frees some children through the root, some directly
    // * Ensures all memory used is freed

    var initial_state_buf: [4096]u8 = undefined;
    const initial_state = try getMaps(&initial_state_buf);
    var sphalloc: Sphalloc = undefined;
    try sphalloc.initPinned("root");

    var child1 = try sphalloc.makeSubAlloc("child1");
    var child2 = try sphalloc.makeSubAlloc("child2");

    var rng = std.rand.DefaultPrng.init(0);
    const rand = rng.random();

    const child1_alloations = try child1.arena().alloc(Allocation, 100);
    for (child1_alloations) |*allocation| {
        allocation.* = try randAlloc(child1.general(), rand);
    }

    const child2_alloations = try child2.arena().alloc(Allocation, 100);
    for (child2_alloations) |*allocation| {
        allocation.* = try randAlloc(child2.general(), rand);
    }

    try cycleRandAllocations(child1.general(), child1_alloations, rand);
    try cycleRandAllocations(child2.general(), child2_alloations, rand);

    // FIXME: Add a reset

    child2.deinit();
    sphalloc.deinit();

    var end_state_buf: [4096]u8 = undefined;
    const end_state = try getMaps(&end_state_buf);
    try std.testing.expectEqualStrings(initial_state, end_state);
}

fn cycleRandAllocations(alloc: Allocator, allocations_buf: []Allocation, rand: std.Random) !void {
    const allocations = RollingBuffer(Allocation){ .items = allocations_buf };
    for (0..5000) |_| {
        const evicted = allocations.push(try randAlloc(alloc, rand));
        switch (evicted) {
            inline else => |e, t| {
                for (0..e.len) |i| {
                    if (e[i] != i % std.math.maxInt(t.toType())) unreachable;
                }
            },
        }
        evicted.deinit(alloc);
    }
}

fn dumpMaps(name: []const u8) !void {
    const f = try std.fs.cwd().createFile(name, .{});
    defer f.close();

    const maps_f = try std.fs.openFileAbsolute("/proc/self/maps", .{});
    defer maps_f.close();

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(maps_f.reader(), f.writer());
}

pub fn getMaps(buf: []u8) ![]const u8 {
    const f = try std.fs.openFileAbsolute("/proc/self/maps", .{});
    defer f.close();

    const size = try f.readAll(buf);
    return buf[0..size];
}

pub fn main() !void {

    // Block alloc with block tracking
    // Make a general purpose allocator based off that

    try dumpMaps("a.txt");
    var sphalloc = try Sphalloc.init();

    var child1 = try sphalloc.makeSubAlloc();
    var child2 = try sphalloc.makeSubAlloc();

    var rng = std.rand.DefaultPrng.init(0);
    const rand = rng.random();

    const child1_alloations = try child1.arena().alloc(Allocation, 100);
    for (child1_alloations) |*allocation| {
        allocation.* = try randAlloc(child1.general(), rand);
    }

    const child2_alloations = try child2.arena().alloc(Allocation, 100);
    for (child2_alloations) |*allocation| {
        allocation.* = try randAlloc(child2.general(), rand);
    }

    try cycleRandAllocations(child1.general(), child1_alloations, rand);
    try cycleRandAllocations(child2.general(), child2_alloations, rand);

    //for (allocations.items) |a| {
    //    a.deinit(alloc);
    //}
    //alloc.free(allocations_buf);

    std.debug.print("root allocator is using: {d}\n", .{sphalloc.totalMemoryAllocated()});
    std.debug.print("child1 allocator is using: {d}\n", .{child1.totalMemoryAllocated()});
    std.debug.print("child2 allocator is using: {d}\n", .{child2.totalMemoryAllocated()});

    try dumpMaps("b.txt");
    std.debug.print("Deiniting root allocator\n", .{});
    sphalloc.deinit();

    try dumpMaps("c.txt");

    //std.debug.print("child2 allocator is using: {d}\n", .{child2.totalMemoryAllocated()});

    //const full_app_alloc = Sphalloc.init();
    //defer full_app_alloc.deinit();

    //const sidebar_alloc = full_app_alloc.makeSubAlloc();
    //var sidebar = generateSidebar(sidebar_alloc);

    //while (true) {
    //    const event = waitForEvent();
    //    if (event.triggersChange()) {
    //        sidebar_alloc.reset();
    //        sidebar = generateSidebar(sidebar_alloc);
    //    }
    //}

}
