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
const sphutil = @import("sphutil");
const sphrender = @import("sphrender");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const Objects = sphimp.object.Objects;
const Object = sphimp.object.Object;

const level_dist: f32 = 0.1;
const widget_height = 300;

app: *App,
width: u31 = 0,
squircle_renderer: *const gui.SquircleRenderer,
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
thumbnail_shared: *const gui.thumbnail.Shared,
interactable_shared: *const gui.interactable.Shared(UiAction),

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

pub fn init(alloc: gui.GuiAlloc, app: *App, squircle_renderer: *const gui.SquircleRenderer, thumbnail_shared: *const gui.thumbnail.Shared, interactable_shared: *const gui.interactable.Shared(UiAction),) !gui.Widget(UiAction) {
    const ctx = try alloc.heap.arena().create(TreeView);
    ctx.* = .{
        .app = app,
        .per_frame = .{
            .alloc = try alloc.makeSubAlloc("tree view per frame"),
        },
        .squircle_renderer = squircle_renderer,
        .thumbnail_shared = thumbnail_shared,
        .interactable_shared = interactable_shared,
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
    .reset = null,
};

fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));

    // FIXME: self.layout.len()
    for (0..self.per_frame.layout.data.items.len) |i| {
        const bounds = self.per_frame.layout.bounds(i).offset(widget_bounds.left, widget_bounds.top);
        const widget = self.per_frame.widgets.items[i];
        widget.render(bounds, window_bounds);
    }
}

fn getSize(ctx: ?*anyopaque) PixelSize {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    return .{
        .width = self.width,
        .height = widget_height,
    };
}

fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) anyerror!void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    self.width = available_size.width;
    try self.per_frame.reset();
    // FIXME: fieldParentPtr the allocator away
    try self.per_frame.layout.update(self.per_frame.alloc.heap.arena(), self.width, &self.app.objects, self.app.selectedObjectId());

    var fr = self.app.makeFrameRenderer(self.per_frame.alloc);

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

        const interactable = try gui.interactable.interactable(
            UiAction,
            self.per_frame.alloc.heap.arena(),
            thumbnail,
            .{ .update_property_object = id },
            null,
            self.interactable_shared,
        );
        try self.per_frame.widgets.append(interactable);
    }
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(UiAction) {
    const self: *TreeView = @ptrCast(@alignCast(ctx));

    var ret = InputResponse(UiAction){};
    // FIXME: self.layout.len()
    for (0..self.per_frame.layout.data.items.len) |i| {
        const bounds = self.per_frame.layout.bounds(i).offset(widget_bounds.left, widget_bounds.top);
        const widget = self.per_frame.widgets.items[i];
        const widget_response = widget.setInputState(bounds, input_bounds.calcIntersection(bounds), input_state);
        if (widget_response.action) |a| {
            ret.action = a;
        }
    }
    return ret;
}

const Layout = struct {
    data: sphutil.RuntimeBoundedArray(Elem) = .{},
    thumbnail_height: f32 = 0,
    x_center: f32 = 0,

    const Elem = struct {
        id: ObjectId,
        location: sphmath.Vec2,
    };

    fn update(self: *Layout, arena: Allocator, width: u31, objects: *Objects, id: ObjectId) !void {
        self.x_center = @floatFromInt(width / 2);
        const preprocessed_data = preprocess(objects, id, 0, 1);

        const num_thumbnail_layers: f32 = @floatFromInt(preprocessed_data.depth + 1);
        const depth_f: f32 = @floatFromInt(preprocessed_data.depth);

        // If there were 3 layers
        // 3h + level_dist * h * 2 = opengl_height
        // h (3 + level_dist * 2) = opengl_height
        // h (num_thumbnail_layers + level_dist * depth) = opengl_height
        // h = opengl_height / (num_thumbnail_layers + level_dist * depth);
        self.thumbnail_height = @as(f32, @floatFromInt(widget_height)) / (num_thumbnail_layers + level_dist * depth_f);

        self.data = try sphutil.RuntimeBoundedArray(Elem).init(arena, preprocessed_data.num_desendents + 1);

        const padding = self.thumbnail_height * level_dist;
        const width_elems_f32: f32 = @floatFromInt(preprocessed_data.width);
        const col_width_px = self.thumbnail_height * width_elems_f32 + padding * (width_elems_f32 - 1);
        // FIXME: So many widths
        try self.layoutElems(objects, id, 0, col_width_px, @as(f32, @floatFromInt(width)) / 2.0);
    }

    const PreprocessData = struct {
        depth: usize,
        num_desendents: usize,
        // elems
        width: usize,
    };

    fn preprocess(objects: *Objects, id: ObjectId, current_depth: usize, current_width: usize) PreprocessData {
        const obj = objects.get(id);
        var dependencies = obj.dependencies();

        var depth = current_depth;
        var num_desendents: usize = 0;

        const num_direct_dependencies = countDirectDependencies(obj.*);
        const next_width = @max(num_direct_dependencies, 1) * current_width;

        var output_width = next_width;

        while (dependencies.next()) |dep| {
            const child_preprocess = preprocess(objects, dep, current_depth + 1, next_width);
            depth = @max(depth, child_preprocess.depth);
            num_desendents += 1 + child_preprocess.num_desendents;
            output_width = @max(output_width, child_preprocess.width);
        }

        return .{
            .depth = depth,
            .num_desendents = num_desendents,
            .width = output_width,
        };
    }

    fn countDirectDependencies(obj: Object) usize {
        // FIXME: Surely there's a better way?
        var it = obj.dependencies();
        var ret: usize = 0;
        while (it.next()) |_| {
            ret += 1;
        }
        return ret;
    }

    fn layoutElems(self: *Layout, objects: *Objects, id: ObjectId, current_depth: usize, current_width_px: f32, center_x_px: f32) !void {
        const obj = objects.get(id);
        var dependencies = obj.dependencies();

        const padding = self.thumbnail_height * level_dist;
        const y_center = @as(f32, @floatFromInt(current_depth)) * (self.thumbnail_height + padding) + self.thumbnail_height / 2.0;

        try self.data.append(.{
            .id = id,
            .location = .{ center_x_px, y_center },
        });

        const num_dependencies = countDirectDependencies(obj.*);
        const next_width = current_width_px / @as(f32, @floatFromInt(num_dependencies));

        const next_x_start = center_x_px - current_width_px / 2 + next_width / 2;
        var idx: usize = 0;
        while (dependencies.next()) |dep| {
            // FIXME: cast hell
            try self.layoutElems(objects, dep, current_depth + 1, next_width, @as(f32, @floatFromInt(idx)) * next_width + next_x_start);
            idx += 1;
        }
    }

    fn bounds(self: *Layout, idx: usize) PixelBBox {
        const elem: Elem = self.data.items[idx];
        const top: i32 = @intFromFloat(elem.location[1] - self.thumbnail_height / 2);
        const left: i32 = @intFromFloat(elem.location[0] - self.thumbnail_height / 2);

        // FIXME: Round
        const thumbnail_height_u: u31 = @intFromFloat(self.thumbnail_height);
        return .{
            .top = top,
            .left = left,
            .right = left + thumbnail_height_u,
            .bottom = top + thumbnail_height_u,
        };
    }
};
