const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("sphui");
const UiAction = @import("ui_action.zig").UiAction;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;
const sphimp = @import("sphimp");
const sphmath = @import("sphmath");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphutil = @import("sphutil");
const sphrender = @import("sphrender");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const Objects = sphimp.object.Objects;
const Object = sphimp.object.Object;
const Vec2 = sphmath.Vec2;

const level_dist: f32 = 0.1;
const widget_height = 300;

app: *App,
scratch: *ScratchAlloc,
size: PixelSize = .{},
per_frame: struct {
    alloc: gui.GuiAlloc,
    layout: Layout = .{},
    texture_cache: std.AutoHashMapUnmanaged(ObjectId, TextureData) = .{},
    // FIXME: Should be long lived
    widgets: sphutil.RuntimeBoundedArray(gui.Widget(UiAction)) = .{},

    fn reset(self: *@This()) !void {
        try self.alloc.reset();
        self.layout = .{};
        self.texture_cache = .{};
        self.widgets = .{};
    }
},
// FIXME: This should be a hashmap for all object IDs that is reset when the
// selected object is changed
// ...
// or maybe it even remembers as you jump between selections
selection_stack: SelectionStack,
thumbnail_shared: *const gui.thumbnail.Shared,
main_selected: *ObjectId,
frame_shared: *const gui.frame.Shared,
sidebar_selection_request: ?ObjectId = null,
widget_state: union(enum) {
    default,
    navigating: NavigationData,
} = .default,

const NavigationData = struct {
    last_mouse_pos: gui.MousePos,
    action: enum {
        none,
        left,
        right,
        up,
        down,
    } = .none,
    num_steps: u32 = 0,
};

// FIXME: not a stack
const SelectionStack = struct {
    child_map: std.AutoHashMap(ObjectId, usize),
    focus_depth: usize = 0,

    fn init(gpa: Allocator) !SelectionStack {
        // FIXME: Maybe not the right capacity
        return .{
            .child_map = std.AutoHashMap(ObjectId, usize).init(gpa),
        };
    }

    fn selectedId(self: SelectionStack, root: ObjectId, objects: *Objects) ?ObjectId {
        var id = root;
        for (0..self.focus_depth) |_| {
            const selected_idx = self.child_map.get(id) orelse return null;
            const obj = objects.get(id);
            var it = obj.dependencies();
            var dep: ?ObjectId = null;
            for (0..selected_idx + 1) |_| {
                dep = it.next();
            }

            id = dep orelse unreachable;
        }
        return id;
    }

    fn reset(self: *SelectionStack) void {
        self.child_map.clearAndFree();
        self.focus_depth = 0;
    }

    fn getChildIdx(self: *SelectionStack, root: ObjectId, objects: *Objects) !?*usize {
        const focused_id = self.selectedId(root, objects) orelse unreachable;
        // Break here for if we have no children
        const gop = try self.child_map.getOrPut(focused_id);
        const num_children = numDependencies(objects.get(focused_id).*);
        if (!gop.found_existing) {
            if (num_children > 0) {
                gop.value_ptr.* = 0;
            } else {
                _ = self.child_map.remove(focused_id);
                return null;
            }
        }

        return gop.value_ptr;
    }
};

// FIXME: Should this live in gui.zig
const PixelOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};
const TextureData = struct {
    size: PixelSize,
    texture: sphrender.Texture,

    pub fn getSize(self: TextureData) PixelSize {
        return self.size;
    }

    pub fn getTexture(self: TextureData) sphrender.Texture {
        return self.texture;
    }
};

pub fn init(alloc: gui.GuiAlloc, scratch: *ScratchAlloc, app: *App, thumbnail_shared: *const gui.thumbnail.Shared,
    main_selected: *ObjectId,
    frame_shared: *const gui.frame.Shared,
) !gui.Widget(UiAction) {
    const ctx = try alloc.heap.arena().create(TreeView);
    ctx.* = .{
        .app = app,
        .scratch = scratch,
        .per_frame = .{
            .alloc = try alloc.makeSubAlloc("tree view per frame"),
        },
        // FIXME: Configurable depth or something?
        .selection_stack = try SelectionStack.init(alloc.heap.arena()),
        .thumbnail_shared = thumbnail_shared,
        .main_selected = main_selected,
        .frame_shared = frame_shared,
    };

    return .{
        .ctx = ctx,
        .name = "tree view",
        .vtable = &widget_vtable,
    };
}

const TreeView = @This();

const widget_vtable = gui.Widget(UiAction).VTable{
    .render = TreeView.render,
    .getSize = TreeView.getSize,
    .update = TreeView.update,
    .setInputState = TreeView.setInputState,
    .setFocused = null,
    .reset = TreeView.reset,
};

fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));

    const temp_scissor = sphrender.TemporaryScissor.init();
    defer temp_scissor.reset();

    temp_scissor.set(widget_bounds.left, window_bounds.bottom - widget_bounds.bottom, widget_bounds.calcWidth(), widget_bounds.calcHeight());

    // FIXME: self.layout.len()
    for (0..self.per_frame.layout.data.items.len) |i| {
        const widget = self.per_frame.widgets.items[i];
        const bounds = self.per_frame.layout.bounds(i, widget.getSize());
        widget.render(bounds, window_bounds);
    }
}

fn getSize(ctx: ?*anyopaque) PixelSize {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    return self.size;
}

fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) anyerror!void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    self.size.width = available_size.width;
    // FIXME: This should be handled by the layout
    self.size.height = available_size.height / 2;

    switch (self.widget_state) {
        .navigating => |*navigation_state| navigation_blk: {
            switch (navigation_state.action) {
                .none => {
                    break :navigation_blk;
                },
                .up => {
                    self.selection_stack.focus_depth -|= navigation_state.num_steps;
                },
                .down => {
                    var focused_id = self.selection_stack.selectedId(self.main_selected.*, &self.app.objects) orelse unreachable;
                    for (0..navigation_state.num_steps) |_| {
                        const child_idx = try self.selection_stack.getChildIdx(self.main_selected.*, &self.app.objects) orelse break;

                        const checkpoint = self.scratch.checkpoint();
                        defer self.scratch.restore(checkpoint);
                        // FIXME: Double extracting deps array from getChildIdx
                        const deps = try depsArray(self.scratch, self.app.objects.get(focused_id).*);
                        focused_id = deps[child_idx.*];
                        self.selection_stack.focus_depth += 1;
                    }
                },
                .left => blk: {
                    // Break here for if we have no children
                    const child_idx = try self.selection_stack.getChildIdx(self.main_selected.*, &self.app.objects) orelse break :blk;
                    child_idx.* -|= 1;
                },
                .right => blk: {
                    // FIXME: Same work happening in both selectedId and getChildIdx
                    const selected_id = self.selection_stack.selectedId(self.main_selected.*, &self.app.objects) orelse unreachable;
                    const child_idx = try self.selection_stack.getChildIdx(self.main_selected.*, &self.app.objects) orelse break :blk;
                    const num_children = numDependencies(self.app.objects.get(selected_id).*);
                    child_idx.* = @min(child_idx.* + 1, num_children - 1);
                },
            }
            self.sidebar_selection_request = self.selection_stack.selectedId(self.main_selected.*, &self.app.objects);
            navigation_state.action = .none;
            navigation_state.num_steps = 0;
        },
        else => {},
    }

    try self.per_frame.reset();
    // FIXME: fieldParentPtr the allocator away
    try self.per_frame.layout.update(self.per_frame.alloc.heap.arena(), self.scratch, getSize(ctx), &self.app.objects, self.main_selected.*, self.selection_stack);

    // FIXME: Frame renderer leaks a little
    // FIXME: Mouse position hack
    var fr = self.app.makeFrameRenderer(self.per_frame.alloc.heap.general(), self.per_frame.alloc.gl);

    self.per_frame.widgets = try sphutil.RuntimeBoundedArray(gui.Widget(UiAction)).init(
        self.per_frame.alloc.heap.arena(),
        self.per_frame.layout.data.items.len,
    );

    for (self.per_frame.layout.data.items) |item| {
        const id = item.id;
        const gop = try self.per_frame.texture_cache.getOrPut(
            self.per_frame.alloc.heap.general(),
            id,
        );

        if (!gop.found_existing) {
            const obj = self.app.objects.get(id).*;
            const texture = try fr.renderObjectToTexture(obj);
            const dims = obj.dims(&self.app.objects);

            gop.value_ptr.* = .{
                .size = .{
                    .width = @intCast(dims[0]),
                    .height = @intCast(dims[1]),
                },
                .texture = texture,
            };
        }

        const thumbnail = try gui.thumbnail.makeThumbnail(
            UiAction,
            self.per_frame.alloc.heap.arena(),
            gop.value_ptr.*,
            self.thumbnail_shared,
        );

        try thumbnail.update(.{
            .width = @intFromFloat(self.per_frame.layout.thumbnail_height * item.size_multiplier),
            .height = @intFromFloat(self.per_frame.layout.thumbnail_height * item.size_multiplier),
        }, 0);

        try self.per_frame.widgets.append(thumbnail);
    }
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(UiAction) {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    _ = widget_bounds;

    var desired_cursor_style: ?gui.CursorStyle = null;
    // HACK: Prevents stack widget from calling into other widgets
    var wants_focus: bool = false;

    switch (self.widget_state) {
        .default => {
            if (input_state.mouse_right_pressed and input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.widget_state = .{
                    .navigating = .{
                        .last_mouse_pos = input_state.mouse_pos,
                    },
                };
                desired_cursor_style = .hidden;
            }
        },
        .navigating => |*navigation_data| blk: {
            wants_focus = true;
            if (input_state.mouse_right_released) {
                self.widget_state = .default;
                desired_cursor_style = .default;
                break :blk;
            }

            const step_size_px = 50;

            const before: Vec2 = .{ navigation_data.last_mouse_pos.x, navigation_data.last_mouse_pos.y };

            const after: Vec2 = .{
                input_state.mouse_pos.x,
                input_state.mouse_pos.y,
            };

            const movement = after - before;
            const primary_movement: enum { x, y } = if (@abs(movement[0]) > @abs(movement[1])) .x else .y;

            switch (primary_movement) {
                .x => {
                    const num_steps: u32 = @intFromFloat(@abs(movement[0]) / step_size_px);
                    if (num_steps > 0) {
                        navigation_data.action = if (movement[0] > 0) .right else .left;
                        navigation_data.num_steps = num_steps;
                        navigation_data.last_mouse_pos = input_state.mouse_pos;
                    }
                },
                .y => {
                    const num_steps: u32 = @intFromFloat(@abs(movement[1]) / step_size_px);
                    if (num_steps > 0) {
                        navigation_data.action = if (movement[1] < 0) .up else .down;
                        navigation_data.num_steps = num_steps;
                        navigation_data.last_mouse_pos = input_state.mouse_pos;
                    }
                },
            }
        },
    }

    if (self.sidebar_selection_request) |id| {
        defer self.sidebar_selection_request = null;
        return .{
            .action = .{ .update_property_object = id },
            // HACK: Prevents stack widget from calling into other widgets
            .wants_focus = true,
            .cursor_style = desired_cursor_style,
        };
    }

    return .{
        .wants_focus = wants_focus,
        .cursor_style = desired_cursor_style,
    };
}

fn reset(ctx: ?*anyopaque) void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    self.selection_stack.reset();
}

const Layout = struct {
    data: sphutil.RuntimeBoundedArray(Elem) = .{},
    thumbnail_height: f32 = 0,
    x_center: f32 = 0,

    const Elem = struct {
        id: ObjectId,
        location: sphmath.Vec2,
        depth: usize,
        size_multiplier: f32,
    };

    fn update(self: *Layout, arena: Allocator, scratch: *ScratchAlloc, available: PixelSize, objects: *Objects, root_id: ObjectId, selection_stack: SelectionStack) !void {
        const checkpoint = scratch.checkpoint();
        defer scratch.restore(checkpoint);

        self.thumbnail_height = @floatFromInt(available.height / 3);
        const y_increase = self.thumbnail_height / 2;

        // FIXME: Maybe 100 is too limiting
        self.data = try sphutil.RuntimeBoundedArray(Elem).init(arena, 100);

        const x_center: f32 = @floatFromInt(available.width / 2);
        var y_offs = self.thumbnail_height / 2;
        try self.data.append(.{
            .id = root_id,
            .location = .{ x_center, y_offs },
            .depth = 0,
            .size_multiplier = 1.0,
        });

        // FIXME: Calculatable by depth
        y_offs += y_increase;

        var depth: usize = 0;
        var obj_id = root_id;
        for (0..selection_stack.focus_depth) |_| {
            const obj = objects.get(obj_id);
            const child_idx = selection_stack.child_map.get(obj_id) orelse break;
            const prepass = try layerPrepass(scratch, obj.*);

            try self.data.append(.{
                .id = prepass.dependencies[child_idx],
                .location = .{ x_center, y_offs },
                .depth = depth + 1,
                .size_multiplier = 1.0,
            });

            obj_id = prepass.dependencies[child_idx];
            depth += 1;
            y_offs += y_increase;
        }

        y_offs += self.thumbnail_height - y_increase;

        const child_idx = blk: {
            if (selection_stack.child_map.get(obj_id)) |c| break :blk c;
            var deps = objects.get(obj_id).dependencies();
            if (deps.next() == null) return;
            break :blk 0;
        };
        const obj = objects.get(obj_id);
        const x_start = x_center - @as(f32, @floatFromInt(child_idx)) * self.thumbnail_height;
        var deps = obj.dependencies();
        var dep_idx: usize = 0;
        while (deps.next()) |dep| {
            defer dep_idx += 1;

            const dep_idx_f: f32 = @floatFromInt(dep_idx);
            const dep_x = x_start + dep_idx_f * self.thumbnail_height;
            try self.data.append(.{
                .id = dep,
                .location = .{ dep_x, y_offs },
                .depth = depth + 1,
                .size_multiplier = 1.0,
            });
        }
    }

    const LayerPrepassParams = struct { num_children: usize, dependencies: []const ObjectId };

    // FIXME: ScratchAlloc should be renamed to something else
    fn layerPrepass(alloc: *ScratchAlloc, obj: Object) !LayerPrepassParams {
        var dependencies = sphutil.RuntimeBoundedArray(ObjectId).fromBuf(alloc.allocMax(ObjectId));

        var num_children: usize = 0;
        var it = obj.dependencies();
        while (it.next()) |dep| {
            try dependencies.append(dep);
            num_children += 1;
        }

        alloc.shrinkTo(dependencies.items.ptr + dependencies.items.len);

        return .{
            .num_children = num_children,
            .dependencies = dependencies.items,
        };
    }

    fn bounds(self: *Layout, idx: usize, widget_size: PixelSize) PixelBBox {
        const elem: Elem = self.data.items[idx];
        //std.debug.print("{any} {any}\n", .{container_size, elem.location});

        var top: i32 = @intFromFloat(elem.location[1]);
        top -= widget_size.height / 2;

        var left: i32 = @intFromFloat(elem.location[0]);
        left -= widget_size.width / 2;

        return PixelBBox {
            .top = top,
            .left = left,
            .right = left + widget_size.width,
            .bottom = top + widget_size.height,
        };
    }
};

// FIXME: ScratchAlloc should be renamed to something else
fn depsArray(alloc: *ScratchAlloc, obj: Object) ![]ObjectId {
    var dependencies = sphutil.RuntimeBoundedArray(ObjectId).fromBuf(alloc.allocMax(ObjectId));

    var it = obj.dependencies();
    while (it.next()) |dep| {
        try dependencies.append(dep);
    }

    alloc.shrinkTo(dependencies.items.ptr + dependencies.items.len);
    return dependencies.items;
}

fn numDependencies(obj: Object) usize {
    var ret: usize = 0;

    var it = obj.dependencies();
    while (it.next()) |_| {
        ret += 1;
    }

    return ret;
}
