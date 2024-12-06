const std = @import("std");
const Allocator = std.mem.Allocator;
const obj_mod = @import("object.zig");
const Renderer = @import("Renderer.zig");
const sphmath = @import("sphmath");
const coords = @import("coords.zig");
const gl = @import("sphrender").gl;

const DrawerRenderer = @This();

// FIXME: Maybe PlaneRenderProgram should live somewhere common
thumbnail_background_program: Renderer.PlaneRenderProgram,
thumbnail_buffer: Renderer.PlaneRenderProgram.Buffer,

const thumbnail_height_ratio = 0.95;
const thumbnail_aspect_ratio = 1.0;
const thumbnail_pad = 0.1;
const thumbnail_width_rel_drawer_height = thumbnail_height_ratio * thumbnail_aspect_ratio * 2;

// FIXME: Maybe we render the image as part of the thumbnail program
pub const thumbnail_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\// FIXME: hack, should find based off program inputs etc.
    \\uniform int selected = 0;
    \\void main()
    \\{
    \\
    \\    vec2 center_offs = abs(vec2(0.5, 0.5) - uv);
    \\    bool in_outline = center_offs.x > 0.475 || center_offs.y > 0.475;
    \\    if (!in_outline) discard;
    \\    fragment = (selected != 0) ? vec4(0.0, 1.0, 1.0, 1.0) : vec4(1.0, 1.0, 1.0, 1.0);
    \\}
;

pub fn init(alloc: Allocator) !DrawerRenderer {
    const program = try Renderer.PlaneRenderProgram.init(alloc, Renderer.plane_vertex_shader, thumbnail_frag, null);
    return .{
        .thumbnail_background_program = program,
        .thumbnail_buffer = program.makeDefaultBuffer(),
    };
}

pub fn deinit(self: *DrawerRenderer, alloc: Allocator) void {
    self.thumbnail_background_program.deinit(alloc);
}

fn firstThumbnailToDrawerTransform(drawer_width: usize, drawer_height: usize) sphmath.Transform {
    // -1 + Thumbnail width / 2 + offs
    const drawer_aspect = sphmath.calcAspect(drawer_width, drawer_height);
    return coords.aspectsToCorrectedTransform(
        thumbnail_aspect_ratio,
        drawer_aspect,
    )
        .then(sphmath.Transform.scale(
        thumbnail_height_ratio,
        thumbnail_height_ratio,
    ))
        .then(sphmath.Transform.translate(
        -1 + (thumbnail_pad + thumbnail_width_rel_drawer_height / 2.0) / drawer_aspect,
        0,
    ));
}

fn thumbnailXOffset(drawer_width: usize, drawer_height: usize) f32 {
    const drawer_aspect = sphmath.calcAspect(drawer_width, drawer_height);
    return (thumbnail_width_rel_drawer_height + thumbnail_pad) / drawer_aspect;
}

fn drawerPosToThumbnailIdx(pos: sphmath.Vec2, drawer_width: usize, drawer_height: usize) ?usize {
    const first_thumbnail_to_drawer_transform = firstThumbnailToDrawerTransform(drawer_width, drawer_height);
    const single_x_offs = thumbnailXOffset(drawer_width, drawer_height);

    const bl = sphmath.applyHomogenous(first_thumbnail_to_drawer_transform.apply(sphmath.Vec3{ -1.0, -1.0, 1.0 }));
    const tr = sphmath.applyHomogenous(first_thumbnail_to_drawer_transform.apply(sphmath.Vec3{ 1.0, 1.0, 1.0 }));

    if (pos[1] < bl[1] or pos[1] > tr[1]) {
        return null;
    }

    // [    ]  [    ]  [  .  ]
    // ^ bl[0]            ^ pos[0]
    //      |--| thumbnail_pad
    // |-------| single_x_offs
    //
    // bl[0] + i * single_x_offs = pos
    // solve for i
    const i_f = (pos[0] - bl[0]) / single_x_offs;

    if (i_f < 0) {
        return null;
    }

    // Pad is always at the end, if we are in pad, we are not on an object
    const i: usize = @intFromFloat(i_f);
    const decimal = i_f - @as(f32, @floatFromInt(i));
    if (decimal > 1.0 - thumbnail_pad) return null;

    return i;
}

pub fn render(self: DrawerRenderer, left: usize, bottom: usize, right: usize, top: usize, frame_renderer: *Renderer.FrameRenderer, selected_id: obj_mod.ObjectId, objects: *obj_mod.Objects, mouse_window_x: f32, mouse_window_y: f32) !?obj_mod.ObjectId {
    gl.glEnable(gl.GL_SCISSOR_TEST);

    const drawer_width = right - left;
    const drawer_height = top - bottom;
    gl.glScissor(@intCast(left), @intCast(bottom), @intCast(right), @intCast(top));
    gl.glViewport(@intCast(left), @intCast(bottom), @intCast(right), @intCast(top));
    gl.glClearColor(0.3, 0.3, 0.3, 1.0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    // FIXME: Restore initial scissor state
    gl.glDisable(gl.GL_SCISSOR_TEST);

    const drawer_height_f: f32 = @floatFromInt(drawer_height);
    const drawer_width_f: f32 = @floatFromInt(drawer_width);
    const thumbnail_height_f = drawer_height_f * thumbnail_height_ratio;
    const thumbnail_height: usize = @intFromFloat(thumbnail_height_f);
    const thumbnail_width: usize = @intFromFloat(thumbnail_height_f * thumbnail_aspect_ratio);

    const mouse_drawer_x = ((mouse_window_x - @as(f32, @floatFromInt(left))) / drawer_width_f) * 2 - 1;
    const mouse_drawer_y = ((mouse_window_y - @as(f32, @floatFromInt(bottom))) / drawer_height_f) * 2 - 1;
    _ = selected_id;

    // -1 + Thumbnail width / 2 + offs
    const first_thumbnail_to_drawer_transform = firstThumbnailToDrawerTransform(drawer_width, drawer_height);

    var obj_ids = objects.idIter();
    var i: usize = 0;
    var ret: ?obj_mod.ObjectId = null;
    while (obj_ids.next()) |id| {
        defer i += 1;

        const obj = objects.get(id);
        const object_dims = obj.dims(objects);

        const obj_to_thumbnail_transform = coords.aspectRatioCorrectedFill(
            object_dims[0],
            object_dims[1],
            thumbnail_width,
            thumbnail_height,
        ).then(sphmath.Transform.scale(0.95, 0.95));
        //const thumbnail_height_f: f32 = @floatFromInt(thumbnail_height);
        //const drawer_height_f: f32 = @floatFromInt(drawer_height);
        //

        var x_offs: f32 = thumbnailXOffset(drawer_width, drawer_height);
        x_offs *= @floatFromInt(i);
        const thumbnail_to_drawer_transform = first_thumbnail_to_drawer_transform
            .then(sphmath.Transform.translate(x_offs, 0));

        //const selected: i32 = if (selected_id.value == id.value) 1 else 0;
        const selected: i32 = if (drawerPosToThumbnailIdx(.{ mouse_drawer_x, mouse_drawer_y }, drawer_width, drawer_height) == i) 1 else 0;
        if (selected == 1) {
            ret = id;
        }
        self.thumbnail_background_program.render(self.thumbnail_buffer, &.{.{ .int = selected }}, &.{}, thumbnail_to_drawer_transform);

        try frame_renderer.renderObjectWithTransform(obj.*, obj_to_thumbnail_transform.then(thumbnail_to_drawer_transform));
    }

    return ret;
}
