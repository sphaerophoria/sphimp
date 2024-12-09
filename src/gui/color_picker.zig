const std = @import("std");
const gui = @import("gui.zig");
const sphmath = @import("sphmath");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const util = @import("util.zig");
const Widget = gui.Widget;
const Layout = gui.layout.Layout;
const MousePos = gui.MousePos;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Color = gui.Color;
const PlaneRenderProgram = sphrender.PlaneRenderProgram;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const ColorStyle = struct {
    width: u31,
    color_preview_height: u31,
    corner_radius: f32,
    item_pad: u31,
    drag_style: gui.drag_float.DragFloatStyle,
};

pub const SharedColorPickerState = struct {
    style: ColorStyle,
    renderer: PlaneRenderProgram,
    vertex_buffer: PlaneRenderProgram.Buffer,
    label_state: *const gui.label.SharedLabelState,
    squircle_renderer: *const SquircleRenderer,

    pub fn init(
        alloc: Allocator,
        style: ColorStyle,
        label_state: *const gui.label.SharedLabelState,
        squircle_renderer: *const SquircleRenderer,
    ) !SharedColorPickerState {
        const renderer = try PlaneRenderProgram.init(
            alloc,
            sphrender.plane_vertex_shader,
            color_picker_frag,
            ColorUniformIndex,
        );
        errdefer renderer.deinit(alloc);

        const buffer = renderer.makeDefaultBuffer();

        return .{
            .style = style,
            .renderer = renderer,
            .vertex_buffer = buffer,
            .label_state = label_state,
            .squircle_renderer = squircle_renderer,
        };
    }

    pub fn deinit(self: *SharedColorPickerState, alloc: Allocator) void {
        self.renderer.deinit(alloc);
        self.vertex_buffer.deinit();
    }
};

pub fn ColorPicker(comptime ActionType: type, comptime ColorRetriever: type, comptime ColorGenerator: type) type {
    return struct {
        const Self = @This();

        layout: Layout(ColorPickerAction),
        color_retriever: ColorRetriever,
        color_generator: ColorGenerator,
        shared: *const SharedColorPickerState,

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = Self.update,
        };

        pub fn init(
            alloc: Allocator,
            color_retriever: ColorRetriever,
            color_generator: ColorGenerator,
            shared: *const SharedColorPickerState,
        ) !Widget(ActionType) {
            const color_picker = try alloc.create(Self);
            errdefer alloc.destroy(color_picker);

            color_picker.* = .{
                .color_retriever = color_retriever,
                .color_generator = color_generator,
                .layout = .{
                    .item_pad = shared.style.item_pad,
                },
                .shared = shared,
            };

            errdefer color_picker.layout.deinit(alloc, .no_widgets);
            const widget_gen = WidgetGenerator{
                .alloc = alloc,
                .label_state = shared.label_state,
                .squircle_renderer = shared.squircle_renderer,
                .shared = shared,
            };

            const hexagon = try ColorHexagon(ColorRetriever).init(alloc, color_retriever, shared);
            errdefer @TypeOf(hexagon.*).deinit(@ptrCast(hexagon), alloc);

            const lightness_label = try widget_gen.makeLabel("lightness");
            errdefer lightness_label.deinit(alloc);

            const lightness_drag = try widget_gen.makeFloatDrag(makeColorRetrieverDependent(LightnessGenerator, color_retriever), &ColorPickerAction.makeLightness);
            errdefer lightness_drag.deinit(alloc);

            const red_label = try widget_gen.makeLabel("red");
            errdefer red_label.deinit(alloc);

            const red_drag = try widget_gen.makeFloatDrag(makeColorRetrieverDependent(RedGenerator, color_retriever), &ColorPickerAction.makeChangeRed);
            errdefer red_drag.deinit(alloc);

            const green_label = try widget_gen.makeLabel("green");
            errdefer green_label.deinit(alloc);

            const green_drag = try widget_gen.makeFloatDrag(makeColorRetrieverDependent(GreenGenerator, color_retriever), &ColorPickerAction.makeChangeGreen);
            errdefer green_drag.deinit(alloc);

            const blue_label = try widget_gen.makeLabel("blue");
            errdefer blue_label.deinit(alloc);

            const blue_drag = try widget_gen.makeFloatDrag(makeColorRetrieverDependent(BlueGenerator, color_retriever), &ColorPickerAction.makeChangeBlue);
            errdefer blue_drag.deinit(alloc);

            const color_preview = try ColorPreview(ColorRetriever).init(
                alloc,
                color_retriever,
                shared,
            );
            errdefer color_preview.deinit(alloc);

            try color_picker.layout.pushWidget(alloc, lightness_label);
            try color_picker.layout.pushWidget(alloc, lightness_drag);
            try color_picker.layout.pushWidget(alloc, red_label);
            try color_picker.layout.pushWidget(alloc, red_drag);
            try color_picker.layout.pushWidget(alloc, green_label);
            try color_picker.layout.pushWidget(alloc, green_drag);
            try color_picker.layout.pushWidget(alloc, blue_label);
            try color_picker.layout.pushWidget(alloc, blue_drag);
            try color_picker.layout.pushWidget(alloc, hexagon.toWidget(ColorPickerAction));
            try color_picker.layout.pushWidget(alloc, color_preview);

            return .{
                .vtable = &widget_vtable,
                .ctx = color_picker,
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.layout.deinit(alloc, .full);
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.layout.contentSize();
        }

        fn update(ctx: ?*anyopaque, bounds: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.layout.update(bounds);
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_state: InputState) ?ActionType {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.layout.dispatchInput(bounds, input_state)) |val| {
                switch (val) {
                    .change_lightness => |lightness| {
                        var color = getColor(&self.color_retriever);

                        const current_lightness = calcLightness(color);

                        const eps = 1e-7;
                        const ratio = if (current_lightness < eps)
                            0.0
                        else
                            lightness / current_lightness;

                        color.r *= ratio;
                        color.g *= ratio;
                        color.b *= ratio;

                        if (current_lightness < eps) {
                            color.r = lightness;
                            color.g = lightness;
                            color.b = lightness;
                        }

                        return generateAction(ActionType, &self.color_generator, color);
                    },
                    .change_color => |color| {
                        return generateAction(ActionType, &self.color_generator, color);
                    },
                    .change_red => |red| {
                        var color = getColor(&self.color_retriever);
                        color.r = red;
                        return generateAction(ActionType, &self.color_generator, color);
                    },
                    .change_green => |green| {
                        var color = getColor(&self.color_retriever);
                        color.g = green;
                        return generateAction(ActionType, &self.color_generator, color);
                    },
                    .change_blue => |blue| {
                        var color = getColor(&self.color_retriever);
                        color.b = blue;
                        return generateAction(ActionType, &self.color_generator, color);
                    },
                }
            }

            return null;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.layout.render(bounds, window_bounds);
        }
    };
}

pub fn makeColorPicker(
    comptime ActionType: type,
    alloc: Allocator,
    color_retriever: anytype,
    color_generator: anytype,
    shared: *const SharedColorPickerState,
) !Widget(ActionType) {
    return ColorPicker(ActionType, @TypeOf(color_retriever), @TypeOf(color_generator)).init(
        alloc,
        color_retriever,
        color_generator,
        shared,
    );
}

const ColorUniformIndex = enum {
    lightness,

    pub fn asIndex(self: ColorUniformIndex) usize {
        return @intFromEnum(self);
    }
};

const ColorPickerAction = union(enum) {
    change_lightness: f32,
    change_color: Color,
    change_red: f32,
    change_green: f32,
    change_blue: f32,

    pub fn makeLightness(val: f32) ColorPickerAction {
        return .{ .change_lightness = val };
    }

    pub fn makeChangeRed(val: f32) ColorPickerAction {
        return .{ .change_red = val };
    }

    pub fn makeChangeGreen(val: f32) ColorPickerAction {
        return .{ .change_green = val };
    }

    pub fn makeChangeBlue(val: f32) ColorPickerAction {
        return .{ .change_blue = val };
    }
};

fn LightnessGenerator(comptime ColorRetriever: type) type {
    return struct {
        color_retriever: ColorRetriever,

        const Self = @This();

        pub fn getVal(self: Self) f32 {
            const color = getColor(&self.color_retriever);
            return calcLightness(color);
        }
    };
}

fn RedGenerator(comptime ColorRetriever: type) type {
    return struct {
        color_retriever: ColorRetriever,

        const Self = @This();

        pub fn getVal(self: Self) f32 {
            const color = getColor(&self.color_retriever);
            return color.r;
        }
    };
}

fn BlueGenerator(comptime ColorRetriever: type) type {
    return struct {
        color_retriever: ColorRetriever,

        const Self = @This();

        pub fn getVal(self: Self) f32 {
            const color = getColor(&self.color_retriever);
            return color.b;
        }
    };
}

fn GreenGenerator(comptime ColorRetriever: type) type {
    return struct {
        color_retriever: ColorRetriever,

        const Self = @This();

        pub fn getVal(self: Self) f32 {
            const color = getColor(&self.color_retriever);
            return color.g;
        }
    };
}

fn makeColorRetrieverDependent(comptime T: anytype, retriever: anytype) T(@TypeOf(retriever)) {
    return .{
        .color_retriever = retriever,
    };
}

const WidgetGenerator = struct {
    alloc: Allocator,
    label_state: *const gui.label.SharedLabelState,
    squircle_renderer: *const SquircleRenderer,
    shared: *const SharedColorPickerState,

    fn makeLabel(self: WidgetGenerator, name: []const u8) !Widget(ColorPickerAction) {
        return gui.label.makeLabel(
            ColorPickerAction,
            self.alloc,
            name,
            std.math.maxInt(u31),
            self.label_state,
        );
    }

    fn makeFloatDrag(self: WidgetGenerator, val: anytype, generator: anytype) !Widget(ColorPickerAction) {
        return gui.drag_float.makeWidget(
            ColorPickerAction,
            self.alloc,
            val,
            generator,
            &self.shared.style.drag_style,
            self.label_state,
            self.squircle_renderer,
        );
    }
};

pub fn ColorPreview(comptime ColorRetriever: type) type {
    return struct {
        const Self = @This();
        color_retriever: ColorRetriever,
        shared: *const SharedColorPickerState,

        pub fn init(alloc: Allocator, color_retriever: ColorRetriever, shared: *const SharedColorPickerState) !Widget(ColorPickerAction) {
            const preview = try alloc.create(Self);
            errdefer alloc.destroy(preview);

            preview.* = .{
                .color_retriever = color_retriever,
                .shared = shared,
            };

            const widget_vtable = Widget(ColorPickerAction).VTable{
                .deinit = Self.deinit,
                .render = Self.render,
                .getSize = Self.getSize,
            };

            return .{
                .vtable = &widget_vtable,
                .ctx = preview,
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .width = self.shared.style.width,
                .height = self.shared.style.color_preview_height,
            };
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window_bounds);
            const color = getColor(&self.color_retriever);
            self.shared.squircle_renderer.render(
                color,
                self.shared.style.corner_radius,
                bounds,
                transform,
            );
        }
    };
}

fn generateAction(comptime ActionType: type, color_generator: anytype, color: Color) ActionType {
    const Ptr = @TypeOf(color_generator);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Pointer => |p| {
            switch (@typeInfo(p.child)) {
                .Fn => {
                    return color_generator.*(color);
                },
                else => {},
            }
        },
        else => {},
    }
    @compileError("Failed to generate action" ++ @typeName(T));
}

fn calcLightness(color: Color) f32 {
    var current_lightness = @max(color.r, color.g);
    current_lightness = @max(current_lightness, color.b);
    return current_lightness;
}

fn getColor(color_retriever: anytype) Color {
    const Ptr = @TypeOf(color_retriever);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Pointer => {
            return color_retriever.*.*;
        },
        else => {},
    }

    @compileError("Cannot get color from type " ++ T);
}

fn ColorHexagon(comptime ColorRetriever: type) type {
    return struct {
        const Self = @This();
        color_retriever: ColorRetriever,
        shared: *const SharedColorPickerState,

        pub fn init(alloc: Allocator, color_retriever: ColorRetriever, shared: *const SharedColorPickerState) !*Self {
            const color_picker = try alloc.create(Self);
            errdefer alloc.destroy(color_picker);

            color_picker.* = .{
                .color_retriever = color_retriever,
                .shared = shared,
            };

            return color_picker;
        }

        fn toWidget(self: *Self, comptime ActionType: type) Widget(ActionType) {
            const widget_vtable = Widget(ActionType).VTable{
                .deinit = Self.deinit,
                .render = Self.render,
                .getSize = Self.getSize,
                .setInputState = Self.setInputState,
                .update = Self.update,
            };

            return .{
                .vtable = &widget_vtable,
                .ctx = self,
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .width = self.shared.style.width,
                .height = self.shared.style.width,
            };
        }

        fn update(ctx: ?*anyopaque, _: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_state: InputState) ?ColorPickerAction {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (bounds.containsOptMousePos(input_state.mouse_down_location)) {
                const prev_color = getColor(&self.color_retriever);
                const color = pixelToRgb(calcLightness(prev_color), input_state.mouse_pos, bounds);
                return .{ .change_color = color };
            }

            return null;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const lightness = calcLightness(getColor(&self.color_retriever));

            const transform = util.widgetToClipTransform(bounds, window_bounds);
            self.shared.renderer.render(self.shared.vertex_buffer, &.{}, &.{.{
                .idx = ColorUniformIndex.lightness.asIndex(),
                .val = .{ .float = lightness },
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
fn pixelToRgb(lightness: f32, pixel_pos: MousePos, bounds: PixelBBox) Color {
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

    var r = sphmath.dot(surface_point, hsv_rgb_axis.r);
    var g = sphmath.dot(surface_point, hsv_rgb_axis.g);
    var b = sphmath.dot(surface_point, hsv_rgb_axis.b);

    // Here we diverge from the GLSL code a little bit. In GLSL we want to
    // discard out of bounds items, however we want to snap to the closest edge
    r = std.math.clamp(r, 0.0, 1.0);
    g = std.math.clamp(g, 0.0, 1.0);
    b = std.math.clamp(b, 0.0, 1.0);

    r *= lightness;
    g *= lightness;
    b *= lightness;
    return Color{ .r = r, .g = g, .b = b, .a = 1.0 };
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
    \\    }} else {{
    \\        fragment = vec4(r * lightness, g * lightness, b * lightness, 1.0);
    \\    }}
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
