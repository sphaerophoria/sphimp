const std = @import("std");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const gl = @import("gl.zig");
const Renderer = @import("Renderer.zig");
const obj_mod = @import("object.zig");
const StbImage = @import("StbImage.zig");
const coords = @import("coords.zig");

const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Objects = obj_mod.Objects;

const Vec2 = lin.Vec2;
const Vec3 = lin.Vec3;
const Transform = lin.Transform;
const PixelDims = obj_mod.PixelDims;

const App = @This();

alloc: Allocator,
objects: Objects = .{},
renderer: Renderer,
view_state: ViewState,
input_state: InputState = .{},

pub fn init(alloc: Allocator, window_width: usize, window_height: usize) !App {
    var objects = Objects{};
    errdefer objects.deinit(alloc);

    const renderer = try Renderer.init(alloc);

    return .{
        .alloc = alloc,
        .objects = objects,
        .renderer = renderer,
        .view_state = .{
            .window_width = window_width,
            .window_height = window_height,
        },
    };
}

pub fn deinit(self: *App) void {
    self.objects.deinit(self.alloc);
    self.renderer.deinit(self.alloc);
}

pub fn save(self: *App, path: []const u8) !void {
    const object_saves = try self.objects.save(self.alloc);
    defer self.alloc.free(object_saves);

    const out_f = try std.fs.cwd().createFile(path, .{});
    defer out_f.close();

    try std.json.stringify(
        obj_mod.SaveData{
            .objects = object_saves,
        },
        .{ .whitespace = .indent_2 },
        out_f.writer(),
    );
}

pub fn load(self: *App, path: []const u8) !void {
    const in_f = try std.fs.cwd().openFile(path, .{});
    defer in_f.close();

    var json_reader = std.json.reader(self.alloc, in_f.reader());
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(obj_mod.SaveData, self.alloc, &json_reader, .{});
    defer parsed.deinit();

    var new_objects = try Objects.initCapacity(self.alloc, parsed.value.objects.len);
    // Note that objects gets swapped in and is freed by this defer
    defer new_objects.deinit(self.alloc);

    for (parsed.value.objects) |saved_object| {
        var object = try Object.load(self.alloc, saved_object, self.renderer.path_program.vpos_location);
        errdefer object.deinit(self.alloc);

        try new_objects.append(self.alloc, object);
    }

    // Swap objects so the old ones get deinited
    std.mem.swap(Objects, &new_objects, &self.objects);

    // Loaded masks do not generate textures
    try self.regenerateAllMasks();

    var id_it = self.objects.idIter();
    if (id_it.next()) |id| {
        self.input_state.selectObject(id, &self.objects);
    }
}

pub fn render(self: *App) !void {
    try self.renderer.render(self.alloc, &self.objects, self.input_state.selected_object, self.view_state.objectToWindowTransform(self.selectedDims()), self.view_state.window_width, self.view_state.window_height);
}

pub fn setKeyDown(self: *App, key: u8, ctrl: bool) !void {
    const action = self.input_state.setKeyDown(key, ctrl);
    try self.handleInputAction(action);
}

pub fn setMouseDown(self: *App) void {
    self.input_state.setMouseDown(&self.objects);
}

pub fn setMouseUp(self: *App) void {
    self.input_state.setMouseUp();
}

pub fn setMiddleDown(self: *App) void {
    self.input_state.setMiddleDown();
}

pub fn setMiddleUp(self: *App) void {
    self.input_state.setMiddleUp();
}

pub fn clickRightMouse(self: *App) !void {
    const input_action = self.input_state.clickRightMouse();
    try self.handleInputAction(input_action);
}

pub fn setSelectedObject(self: *App, id: ObjectId) void {
    self.input_state.selectObject(id, &self.objects);
    self.view_state.reset();
}

pub fn scroll(self: *App, amount: f32) void {
    self.view_state.zoom(amount);
}

pub fn setMousePos(self: *App, xpos: f32, ypos: f32) !void {
    const new_x = self.view_state.windowToClipX(xpos);
    const new_y = self.view_state.windowToClipY(ypos);
    const new_pos = self.view_state.clipToObject(Vec2{ new_x, new_y }, self.selectedDims());
    const input_action = self.input_state.setMousePos(new_pos);

    try self.handleInputAction(input_action);
}

pub fn createPath(self: *App) !void {
    const initial_positions: []const Vec2 = &.{
        Vec2{ -0.5, -0.5 },
        Vec2{ 0.5, 0.5 },
    };

    const path_id = self.objects.nextId();
    const path_obj = try obj_mod.PathObject.init(
        self.alloc,
        initial_positions,
        self.input_state.selected_object,
        self.renderer.path_program.vpos_location,
    );
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new path"),
        .data = .{
            .path = path_obj,
        },
    });

    const selected_dims = self.objects.get(self.input_state.selected_object).dims(&self.objects);
    const mask_id = self.objects.nextId();
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new mask"),
        .data = .{
            .generated_mask = try obj_mod.GeneratedMaskObject.generate(self.alloc, path_id, selected_dims[0], selected_dims[1], path_obj.points.items),
        },
    });

    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "masked obj"),
        .data = .{
            .shader = try obj_mod.ShaderObject.init(self.alloc, &.{ self.input_state.selected_object, mask_id }, Renderer.mul_fragment_shader, &.{ "u_texture", "u_texture_2" }, selected_dims[0], selected_dims[1]),
        },
    });
}

pub fn addToComposition(self: *App, id: obj_mod.ObjectId) !void {
    const selected_object = self.objects.get(self.input_state.selected_object);

    if (selected_object.data != .composition) {
        return error.SelectedItemNotComposition;
    }

    try selected_object.data.composition.addObj(self.alloc, id);
}

pub fn deleteFromComposition(self: *App, id: obj_mod.CompositionIdx) !void {
    const selected_object = self.objects.get(self.input_state.selected_object);

    if (selected_object.data != .composition) {
        return error.SelectedItemNotComposition;
    }

    selected_object.data.composition.removeObj(id);
    // Force input state to release any references to a composition object
    self.input_state.setMouseUp();
}

pub fn addComposition(self: *App) !ObjectId {
    const id = self.objects.nextId();

    const name = try self.alloc.dupe(u8, "composition");
    errdefer self.alloc.free(name);

    try self.objects.append(self.alloc, .{
        .name = name,
        .data = .{ .composition = obj_mod.CompositionObject{} },
    });

    return id;
}

pub fn loadImage(self: *App, path: [:0]const u8) !ObjectId {
    const id = self.objects.nextId();

    const obj = try obj_mod.FilesystemObject.load(self.alloc, path);
    errdefer obj.deinit(self.alloc);

    const name = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(name);

    try self.objects.append(self.alloc, .{
        .name = name,
        .data = .{
            .filesystem = obj,
        },
    });

    return id;
}

pub fn addShaderObject(self: *App, name: []const u8, input_images: []const ObjectId, shader_source: [:0]const u8, texture_names: []const [:0]const u8, width: usize, height: usize) !ObjectId {
    const shader_id = self.objects.nextId();

    const duped_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(duped_name);

    var obj = try obj_mod.ShaderObject.init(
        self.alloc,
        input_images,
        shader_source,
        texture_names,
        width,
        height,
    );
    errdefer obj.deinit(self.alloc);

    try self.objects.append(self.alloc, .{
        .name = duped_name,
        .data = .{
            .shader = obj,
        },
    });

    return shader_id;
}

fn selectedObject(self: *App) *Object {
    return self.objects.get(self.input_state.selected_object);
}

fn selectedDims(self: *App) PixelDims {
    return self.objects.get(self.input_state.selected_object).dims(&self.objects);
}

const ViewState = struct {
    window_width: usize,
    window_height: usize,
    viewport_center: Vec2 = .{ 0.0, 0.0 },
    zoom_level: f32 = 1.0,

    fn reset(self: *ViewState) void {
        self.viewport_center = .{ 0.0, 0.0 };
        self.zoom_level = 1.0;
    }

    fn pan(self: *ViewState, movement_obj: Vec2) void {
        self.viewport_center -= movement_obj;
    }

    fn zoom(self: *ViewState, amount: f32) void {
        // Note that amount is in range [-N,N]
        // If we want the zoom adjustment to feel consistent, we need the
        // change from 4-8x to feel the same as the change from 1-2x
        // This means that a multiplicative level feels better than an additive one
        // So we need a function that goes from [-N,N] -> [lower than 1, greater than 1]
        // If we take this to the extreme, we want -inf -> 0, inf -> inf, 1 ->
        // 0. x^y provides this.
        // x^y also has the nice property that x^y*x^z == x^(y+z), which
        // results in merged scroll events acting the same as multiple split
        // events
        // Constant tuned until whatever scroll value we were getting felt ok
        //
        //
        // 1.1^(x+y) == 1.1^x * 1.1^y
        self.zoom_level *= std.math.pow(f32, 1.1, amount);
    }

    fn windowToClipX(self: ViewState, xpos: f32) f32 {
        const window_width_f: f32 = @floatFromInt(self.window_width);
        return ((xpos / window_width_f) - 0.5) * 2;
    }

    fn windowToClipY(self: ViewState, ypos: f32) f32 {
        const window_height_f: f32 = @floatFromInt(self.window_height);
        return (1.0 - (ypos / window_height_f) - 0.5) * 2;
    }

    fn clipToObject(self: *ViewState, val: Vec2, object_dims: PixelDims) Vec2 {
        const obj_aspect = coords.calcAspect(object_dims[0], object_dims[1]);
        const window_aspect = coords.calcAspect(self.window_width, self.window_height);

        var aspect_aspect_v: Vec2 = undefined;

        if (window_aspect > obj_aspect) {
            aspect_aspect_v = Vec2{ obj_aspect / window_aspect, 1.0 };
        } else {
            aspect_aspect_v = Vec2{ 1.0, window_aspect / obj_aspect };
        }

        return (self.viewport_center + val / Vec2{ self.zoom_level, self.zoom_level }) / aspect_aspect_v;
    }

    fn objectToWindowTransform(self: ViewState, object_dims: PixelDims) Transform {
        const aspect_transform = coords.aspectRatioCorrectedFill(
            object_dims[0],
            object_dims[1],
            self.window_width,
            self.window_height,
        );

        return aspect_transform
            .then(Transform.translate(-self.viewport_center[0], -self.viewport_center[1]))
            .then(Transform.scale(self.zoom_level, self.zoom_level));
    }

    test "test aspect no zoom/pan" {
        const view_state = ViewState{
            .window_width = 100,
            .window_height = 50,
            .viewport_center = .{ 0.0, 0.0 },
            .zoom_level = 1.0,
        };

        const transform = view_state.objectToWindowTransform(.{ 50, 100 });
        // Given an object that's 50x100, in a window 100x50
        //
        //  ______________________
        // |       |      |       |
        // |       | o  o |       |
        // |       | ____ |       |
        // |       |      |       |
        // |       |      |       |
        // |_______|______|_______|
        //
        // The object has coordinates of [-1, 1] in both dimensions, as does
        // the window
        //
        // This means that in window space, the object coordinates have be
        // squished, such that the aspect ratio of the object is preserved, and
        // the height stays the same

        const tl_obj = Vec3{ -1.0, 1.0, 1.0 };
        const br_obj = Vec3{ 1.0, -1.0, 1.0 };

        const tl_obj_win = lin.applyHomogenous(transform.apply(tl_obj));
        const br_obj_win = lin.applyHomogenous(transform.apply(br_obj));

        // Height is essentially preserved
        try std.testing.expectApproxEqAbs(1.0, tl_obj_win[1], 0.01);
        try std.testing.expectApproxEqAbs(-1.0, br_obj_win[1], 0.01);

        // Width needs to be scaled in such a way that the aspect ratio 50/100
        // is preserved in _pixel_ space. The window is stretched so that the
        // aspect is 2:1. In a non stretched window, we would expect that
        // 50/100 maps to N/2, so the width of 1/2 needs to be halfed _again_
        // to stay correct in the stretched window
        //
        // New width is then 0.5
        try std.testing.expectApproxEqAbs(-0.25, tl_obj_win[0], 0.01);
        try std.testing.expectApproxEqAbs(0.25, br_obj_win[0], 0.01);
    }

    test "test aspect with zoom/pan" {
        // Similar to the above test case, but with the viewport moved
        const view_state = ViewState{
            .window_width = 100,
            .window_height = 50,
            .viewport_center = .{ 0.5, 0.5 },
            .zoom_level = 2.0,
        };

        const transform = view_state.objectToWindowTransform(.{ 50, 100 });

        const tl_obj = Vec3{ -1.0, 1.0, 1.0 };
        const br_obj = Vec3{ 1.0, -1.0, 1.0 };

        const tl_obj_win = lin.applyHomogenous(transform.apply(tl_obj));
        const br_obj_win = lin.applyHomogenous(transform.apply(br_obj));

        // Height should essentially be doubled in window space, because the
        // zoom is doubled. We are centered 0.5,0.5 up to the right, so a 2.0
        // height object should be 1.0 above us, and 3.0 below us
        try std.testing.expectApproxEqAbs(1.0, tl_obj_win[1], 0.01);
        try std.testing.expectApproxEqAbs(-3.0, br_obj_win[1], 0.01);

        // In unzoomed space, the answer was [-0.25, 0.25]. We are centered at
        // 0.5, with a 2x zoom. This means that the right side is 0.25 to our
        // left (un zoomed), and the left side is 0.5 farther than that. Double
        // the distances for 2x zoom, and we get -0.5, -1.5
        try std.testing.expectApproxEqAbs(-1.5, tl_obj_win[0], 0.01);
        try std.testing.expectApproxEqAbs(-0.5, br_obj_win[0], 0.01);
    }
};

const InputState = struct {
    selected_object: ObjectId = .{ .value = 0 },
    // object coords
    mouse_pos: lin.Vec2 = .{ 0.0, 0.0 },
    panning: bool = false,
    data: union(enum) {
        composition: union(enum) {
            move: obj_mod.CompositionIdx,
            none,
        },
        path: ?obj_mod.PathIdx,
        none,
    } = .none,

    const InputAction = union(enum) {
        add_path_elem: Vec2,
        move_composition_obj: struct {
            idx: obj_mod.CompositionIdx,
            amount: Vec2,
        },
        move_path_point: struct {
            idx: obj_mod.PathIdx,
            amount: Vec2,
        },
        save,
        pan: Vec2,
    };

    fn selectObject(self: *InputState, id: ObjectId, objects: *Objects) void {
        const obj = objects.get(id);
        switch (obj.data) {
            .composition => self.data = .{ .composition = .none },
            .path => self.data = .{ .path = null },
            else => self.data = .none,
        }
        self.selected_object = id;
    }

    // FIXME: Objects should be const
    fn setMouseDown(self: *InputState, objects: *obj_mod.Objects) void {
        switch (self.data) {
            .composition => |*action| {
                const composition_obj = &objects.get(self.selected_object).data.composition;
                var closest_idx: usize = 0;
                var current_dist = std.math.inf(f32);

                for (0..composition_obj.objects.items.len) |idx| {
                    const transform = composition_obj.objects.items[idx].transform;
                    const center = lin.applyHomogenous(transform.apply(Vec3{ 0, 0, 1 }));
                    const dist = lin.length2(center - self.mouse_pos);
                    if (dist < current_dist) {
                        closest_idx = idx;
                        current_dist = dist;
                    }
                }

                if (current_dist == std.math.inf(f32)) {
                    action.* = .none;
                } else {
                    action.* = .{
                        .move = .{ .value = closest_idx },
                    };
                }
            },
            .path => |*selected_obj| {
                const path = objects.get(self.selected_object).asPath() orelse return; // FIXME assert?
                var closest_point: usize = 0;
                var min_dist = std.math.inf(f32);

                for (path.points.items, 0..) |point, idx| {
                    const dist = lin.length2(self.mouse_pos - point);
                    if (dist < min_dist) {
                        closest_point = idx;
                        min_dist = dist;
                    }
                }

                if (min_dist != std.math.inf(f32)) {
                    selected_obj.* = .{ .value = closest_point };
                }
            },
            .none => {},
        }
    }

    fn setMouseUp(self: *InputState) void {
        switch (self.data) {
            .composition => |*action| action.* = .none,
            .path => |*selected_path_item| selected_path_item.* = null,
            .none => {},
        }
    }

    fn setMousePos(self: *InputState, new_pos: Vec2) ?InputAction {
        var apply_mouse_pos = true;
        defer if (apply_mouse_pos) {
            self.mouse_pos = new_pos;
        };

        switch (self.data) {
            .composition => |*composition_state| {
                switch (composition_state.*) {
                    .move => |idx| return InputAction{
                        .move_composition_obj = .{
                            .idx = idx,
                            .amount = new_pos - self.mouse_pos,
                        },
                    },
                    .none => {},
                }
            },
            .path => |path_idx| {
                if (path_idx) |idx| {
                    return InputAction{ .move_path_point = .{
                        .idx = idx,
                        .amount = new_pos - self.mouse_pos,
                    } };
                }
            },
            else => {},
        }

        if (self.panning) {
            // A little odd, the camera movement is applied in object space,
            // because that's the coordinate space we store our mouse in. If we
            // apply a pan, the mouse SHOULD NOT MOVE in object space. Because
            // of this we ask that the viewport moves us around, but do not
            // update our internal cached position
            apply_mouse_pos = false;
            return .{
                .pan = new_pos - self.mouse_pos,
            };
        }

        return null;
    }

    fn clickRightMouse(self: *InputState) ?InputAction {
        switch (self.data) {
            .path => {
                return .{ .add_path_elem = self.mouse_pos };
            },
            else => return null,
        }
    }

    fn setMiddleDown(self: *InputState) void {
        self.panning = true;
    }

    fn setMiddleUp(self: *InputState) void {
        self.panning = false;
    }

    fn setKeyDown(_: *InputState, key: u8, ctrl: bool) ?InputAction {
        switch (key) {
            'S' => {
                if (ctrl) {
                    return .save;
                }
            },
            else => {},
        }
        return null;
    }
};

const MaskIterator = struct {
    it: Objects.IdIter,
    objects: *Objects,

    fn next(self: *MaskIterator) ?*obj_mod.GeneratedMaskObject {
        while (self.it.next()) |obj_id| {
            const obj = self.objects.get(obj_id);
            switch (obj.data) {
                .generated_mask => |*m| return m,
                else => continue,
            }
        }

        return null;
    }
};

fn handleInputAction(self: *App, action: ?InputState.InputAction) !void {
    switch (action orelse return) {
        .add_path_elem => |obj_loc| {
            const selected_object = self.selectedObject();
            if (selected_object.asPath()) |p| {
                try p.addPoint(self.alloc, obj_loc);
                try self.regeneratePathMasks(self.input_state.selected_object);
            }
        },
        .move_composition_obj => |movement| {
            const selected_object = self.selectedObject();
            if (selected_object.asComposition()) |composition| {
                composition.moveObject(movement.idx, movement.amount);
            }
        },
        .move_path_point => |movement| {
            const selected_object = self.selectedObject();
            if (selected_object.asPath()) |path| {
                path.movePoint(
                    movement.idx,
                    movement.amount,
                );
                try self.regeneratePathMasks(self.input_state.selected_object);
            }
        },
        .save => {
            try self.save("save.json");
        },
        .pan => |amount| {
            self.view_state.pan(amount);
        },
    }
}

fn regenerateMask(self: *App, mask: *obj_mod.GeneratedMaskObject) !void {
    const path_obj = self.objects.get(mask.source);
    const path = switch (path_obj.data) {
        .path => |*p| p,
        else => return error.InvalidMaskObj,
    };

    const width, const height = path_obj.dims(&self.objects);
    var tmp = try obj_mod.GeneratedMaskObject.generate(self.alloc, mask.source, width, height, path.points.items);
    defer tmp.deinit();

    std.mem.swap(obj_mod.GeneratedMaskObject, mask, &tmp);
}

fn regeneratePathMasks(self: *App, path_id: ObjectId) !void {
    var it = MaskIterator{ .it = self.objects.idIter(), .objects = &self.objects };
    while (it.next()) |mask| {
        if (mask.source.value != path_id.value) continue;
        try self.regenerateMask(mask);
    }
}

fn regenerateAllMasks(self: *App) !void {
    var it = MaskIterator{ .it = self.objects.idIter(), .objects = &self.objects };
    while (it.next()) |mask| {
        try self.regenerateMask(mask);
    }
}

fn getCompositionObj(self: *App) ?*obj_mod.CompositionObject {
    switch (self.objects.get(self.input_state.selected_object).data) {
        .composition => |*c| return c,
        else => return null,
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
