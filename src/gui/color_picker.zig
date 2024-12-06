const std = @import("std");
const gui = @import("gui.zig");
const sphmath = @import("sphmath");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const util = @import("util.zig");
const Widget = gui.Widget;
const MousePos = gui.MousePos;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Color = gui.Color;
const PlaneRenderProgram = sphrender.PlaneRenderProgram;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const ColorUniformIndex = enum {
    lightness,

    pub fn asIndex(self: ColorUniformIndex) usize {
        return @intFromEnum(self);
    }
};

const ColorPickerAction = f32;
const ActionGenerator = struct {
    pub fn generate(_: ActionGenerator, val: f32) ColorPickerAction {
        return val;
    }
};

pub fn ColorPicker(comptime ActionType: type) type {
    return struct {
        const Self = @This();
        size: PixelSize,
        // FIXME: Shared state
        renderer: PlaneRenderProgram,
        vertex_buffer: PlaneRenderProgram.Buffer,
        lightness: f32 = 1.0,
        drag_widget: Widget(f32),

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = Self.update,
        };

        pub fn init(alloc: Allocator, width: u31, height: u31, drag_float_style: gui.drag_float.DragFloatStyle, label_state: *const gui.label.SharedLabelState, squircle_renderer: *const SquircleRenderer) !Widget(ActionType) {
            const color_picker = try alloc.create(Self);
            errdefer alloc.destroy(color_picker);

            const renderer = try PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, color_picker_frag, ColorUniformIndex);
            errdefer renderer.deinit(alloc);

            const buffer = renderer.makeDefaultBuffer();

            color_picker.* = .{
                .size = .{
                    .width = width,
                    .height = height,
                },
                .renderer = renderer,
                .vertex_buffer = buffer,
                .drag_widget = undefined,
            };
            color_picker.drag_widget = try gui.drag_float.makeWidget(alloc, &color_picker.lightness, ActionGenerator{}, drag_float_style, label_state, squircle_renderer);

            return .{
                .vtable = &widget_vtable,
                .ctx = color_picker,
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .width = self.size.width,
                .height = self.size.height + self.drag_widget.getSize().height,
            };
        }

        fn update(ctx: ?*anyopaque, window_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.drag_widget.update(window_size);
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_state: InputState) ?ActionType {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const drag_bounds = getDragBounds(self.drag_widget, bounds);
            if (self.drag_widget.setInputState(drag_bounds, input_state)) |val| {
                self.lightness = val;
            }

            var color_bounds = bounds;
            color_bounds.top += drag_bounds.calcHeight();
            if (input_state.mouse_down_location) |loc| {
                if (pixelToRgb(self.lightness, loc, color_bounds)) |color| {
                    std.debug.print("color: {any}\n", .{color});
                }
            }

            return null;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const drag_bounds = getDragBounds(self.drag_widget, bounds);
            self.drag_widget.render(drag_bounds, window_bounds);

            var remaining = bounds;
            remaining.top += drag_bounds.calcHeight();
            const transform = util.widgetToClipTransform(remaining, window_bounds);
            self.renderer.render(self.vertex_buffer, &.{}, &.{.{
                .idx = ColorUniformIndex.lightness.asIndex(),
                .val = .{ .float = self.lightness },
            }}, transform);
        }
    };
}

const hsv_rgb_axis = ColorAxis.calcHsvFacing();

// Mirror of glsl code
fn bestAxis(center_offs: sphmath.Vec2) sphmath.Vec3 {
    const b2 = sphmath.Vec2{ hsv_rgb_axis.b[0], hsv_rgb_axis.b[1] };
    const g2 = sphmath.Vec2{ hsv_rgb_axis.g[0], hsv_rgb_axis.g[1] };
    const r2 = sphmath.Vec2{ hsv_rgb_axis.r[0], hsv_rgb_axis.r[1] };

    const db = sphmath.dot(center_offs, b2);
    const dr = sphmath.dot(center_offs, r2);
    const dg = sphmath.dot(center_offs, g2);

    if (db > dg and db > dr) return hsv_rgb_axis.b else if (dg > dr) return hsv_rgb_axis.g else return hsv_rgb_axis.r;
}

// Mirror of glsl code
fn pixelToRgb(lightness: f32, pixel_pos: MousePos, bounds: PixelBBox) ?Color {
    const uv = sphmath.Vec2{
        (pixel_pos.x - @as(f32, @floatFromInt(bounds.left))) / @as(f32, @floatFromInt(bounds.calcWidth())),
        -(pixel_pos.y - @as(f32, @floatFromInt(bounds.bottom))) / @as(f32, @floatFromInt(bounds.calcWidth())),
    };

    const center_offs = uv * sphmath.Vec2{ 2.0, 2.0 } - sphmath.Vec2{ 1.0, 1.0 };

    const best_axis = bestAxis(center_offs);

    const white_point = hsv_rgb_axis.r + hsv_rgb_axis.g + hsv_rgb_axis.b;
    const white_to_axis = best_axis - white_point;
    const white_to_axis_xy = sphmath.Vec2{ white_to_axis[0], white_to_axis[1] };
    const best_axis_xy = sphmath.Vec2{ best_axis[0], best_axis[1] };
    const best_axis_xy_len = sphmath.length(best_axis_xy);
    const surface_scalar = sphmath.dot(center_offs, sphmath.normalize(white_to_axis_xy) / sphmath.Vec2{ best_axis_xy_len, best_axis_xy_len });
    const surface_z = white_point[2] + surface_scalar * white_to_axis[2];
    const surface_point = sphmath.Vec3{ center_offs[0], center_offs[1], surface_z };

    const r = sphmath.dot(surface_point, hsv_rgb_axis.r);
    const g = sphmath.dot(surface_point, hsv_rgb_axis.g);
    const b = sphmath.dot(surface_point, hsv_rgb_axis.b);
    if (b < 0.0 or g < 0.0 or r < 0.0) {
        return null;
    }
    return Color{ .r = r * lightness, .g = g * lightness, .b = b * lightness, .a = 1.0 };
}

fn getDragBounds(drag_widget: Widget(f32), bounds: PixelBBox) PixelBBox {
    var drag_bounds = bounds;
    const drag_size = drag_widget.getSize();
    drag_bounds.bottom = bounds.top + drag_size.height;
    drag_bounds.right = bounds.left + drag_size.width;

    return drag_bounds;
}

const ColorAxis = struct {
    r: sphmath.Vec3,
    g: sphmath.Vec3,
    b: sphmath.Vec3,

    fn calcHsvFacing() ColorAxis {
        const Vec3 = sphmath.Vec3;

        // Rotate the RGB cube such that we are looking at it along the x=y=z
        // axis. In this scenario we want the white vector to point straight
        // towards the camera (z), and the blue axis to point straight up
        // (towards y). Since the green and red vectors need to be evenly
        // rotated, we rotate these by 2pi/3 around the camera axis

        const rgb_white = Vec3{ 1, 1, 1 };
        const rgb_blue = Vec3{ 0, 0, 1 };

        const white_length = sphmath.length(rgb_white);

        // If we want to place the cube on it's corner, we need the angle
        // between the axis and the ground. You may expect this to be 45
        // degrees, but it's not.
        //
        // We know that the white line points straight up, so we can find the
        // angle between white and an axis, and then do 90 degrees - that angle
        // to find angle to the ground
        //
        // We don't actually care about the angle though, just the distance
        // from the axis to the ground, and the new xy length. We have distance
        // from the ground because
        //
        //    1.0  .-^
        //     .-^   | (sin(t))
        // .-^       |
        // ^^^^^^^^^^^
        //    cos(t)

        // And since sin(t) and cos(t) are 90 degrees rotated from eachother,
        // we can just calculate the  cross and dot product between the blue
        // and white vectors and use those for our xy length and z heights,
        // scaled to make the axis lengths 1

        const z_height = sphmath.dot(rgb_white, rgb_blue) / white_length;
        const xy_len = sphmath.length(sphmath.cross(rgb_white, rgb_blue)) / white_length;

        const blue_axis = Vec3{ 0, xy_len, z_height };

        // Now we just need to rotate by 1/3 and 2/3 turns
        const rg_x = xy_len * @cos(std.math.pi / 6.0);
        const rg_y = -xy_len * @sin(std.math.pi / 6.0);

        const red_axis = Vec3{ rg_x, rg_y, z_height };
        const green_axis = Vec3{ -rg_x, rg_y, z_height };
        return .{
            .r = red_axis,
            .b = blue_axis,
            .g = green_axis,
        };
    }
};

// Why not just use HSV? I don't like the idea of it. Geometrically it doesn't
// make sense to me. We have RGB pixels in our monitor. These are 3 independent
// axis which cap out at a value of 1. How can we possibly display the range of
// colors in a circle? We can because as we rotate through the hues, the
// overall brightness actually goes up. red/green -> yellow is more total
// brightness than either individually
//
// Use a geometrically consistent view of RGB. The way the color picker is
// shown in HSV is nice, however it is deceiving. We will instead use a
// projection of the RGB cube where we are looking down towards the brightest
// corner. All math below is just to project our view onto the 3 surfaces of
// the cube that we can see.
//
// This is probably worse than HSV, but conceptually I like it more :)
pub const color_picker_frag = std.fmt.comptimePrint(
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform float lightness;
    \\
    \\vec3 blue_axis = vec3({d}, {d}, {d});
    \\vec3 red_axis = vec3({d}, {d}, {d});
    \\vec3 green_axis = vec3({d}, {d}, {d});
    \\vec3 white_point = blue_axis + red_axis + green_axis;
    \\
    \\// Mirrored in zig code
    \\vec3 bestAxis(vec2 center_offs) {{
    \\    // Which of the RGB axis are we most aligned with? We'll sample from
    \\    // the quad on that side
    \\    float db = dot(center_offs, blue_axis.xy);
    \\    float dr = dot(center_offs, red_axis.xy);
    \\    float dg = dot(center_offs, green_axis.xy);
    \\
    \\    if (db > dg && db > dr) return blue_axis;
    \\    else if (dg > dr) return green_axis;
    \\    else return red_axis;
    \\}}
    \\
    \\// Mirrored in zig code
    \\void main()
    \\{{
    \\    vec2 center_offs = vec2(uv * 2.0 - 1.0);
    \\
    \\    vec3 best_axis = bestAxis(center_offs);
    \\
    \\    // Imagine we are raycasting from a plane that touches the brightest
    \\    // corner of the cube downwards, where do we hit the surface of the
    \\    // cube?
    \\
    \\    // ______w__v_______
    \\    //      .^. |
    \\    //    .^   ^.
    \\    //   ^.     .^ a
    \\    //     ^. .^
    \\    //       ^
    \\    //
    \\    // We know that point w is at center_offs 0, 0
    \\    // We know that point a is where the axis tip is
    \\    // We have the vector wa and the vector wv
    \\    // Our depth is how much along the surface of our plane
    \\    // we've moved towards a, multiplied by the total depth at a
    \\    vec3 white_to_axis = best_axis - white_point;
    \\    float surface_scalar = dot(center_offs, normalize(white_to_axis.xy) / length(best_axis.xy));
    \\    float surface_z = white_point.z + surface_scalar * white_to_axis.z;
    \\    vec3 surface_point = vec3(center_offs, surface_z);
    \\
    \\    // We have a point on the surface of the cube, just find it's rgb components
    \\    float r = dot(surface_point, red_axis);
    \\    float g = dot(surface_point, green_axis);
    \\    float b = dot(surface_point, blue_axis);
    \\    // Actually we lied, the point isn't on the surface of the cube, it's
    \\    // on the surface of a pyramid that matches the top of the cube. We
    \\    // just have to bounds check to see if we've left where the pyramid
    \\    // and the cube are the same
    \\    if (b < 0.0 || g < 0.0 || r < 0.0) {{
    \\        discard;
    \\    }}
    \\    fragment = vec4(r * lightness, g * lightness, b * lightness, 1.0);
    \\}}
, .{
    hsv_rgb_axis.b[0],
    hsv_rgb_axis.b[1],
    hsv_rgb_axis.b[2],
    hsv_rgb_axis.r[0],
    hsv_rgb_axis.r[1],
    hsv_rgb_axis.r[2],
    hsv_rgb_axis.g[0],
    hsv_rgb_axis.g[1],
    hsv_rgb_axis.g[2],
});
