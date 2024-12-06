const gui = @import("gui.zig");
const sphmath = @import("sphmath");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;

pub fn ReturnType(F: anytype) type {
    return @typeInfo(@TypeOf(F)).Fn.return_type.?;
}

pub fn shouldDeinit(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Struct => {
            return @hasDecl(T, "deinit");
        },
        .Pointer => {
            return false;
        },
        else => @compileError("Unsure"),
    }
}

pub fn widgetToClipTransform(bounds: PixelBBox, window: PixelBBox) sphmath.Transform {
    return sphmath.Transform.scale(
        widgetToClipScale(bounds.calcWidth(), window.calcWidth()),
        widgetToClipScale(bounds.calcHeight(), window.calcHeight()),
    ).then(sphmath.Transform.translate(
        widgetToClipCenterX(bounds.cx(), window.cx()),
        widgetToClipCenterY(bounds.cy(), window.cy()),
    ));
}

pub fn widgetToClipScale(widget_size: i32, window_size: i32) f32 {
    const widget_size_f: f32 = @floatFromInt(widget_size);
    const window_size_f: f32 = @floatFromInt(window_size);
    return widget_size_f / window_size_f;
}

pub fn widgetToClipCenterX(widget_center: i32, window_center: i32) f32 {
    const window_center_f: f32 = @floatFromInt(window_center);
    const widget_center_f: f32 = @floatFromInt(widget_center);
    return (widget_center_f - window_center_f) / window_center_f;
}

pub fn widgetToClipCenterY(widget_center: i32, window_center: i32) f32 {
    const window_center_f: f32 = @floatFromInt(window_center);
    const widget_center_f: f32 = @floatFromInt(widget_center);
    return -(widget_center_f - window_center_f) / window_center_f;
}

pub fn centerBoxInBounds(box: PixelSize, bounds: PixelBBox) PixelBBox {
    const width_pad = @divTrunc(bounds.calcWidth() - box.width, 2);
    const height_pad = @divTrunc(bounds.calcHeight() - box.height, 2);

    // FIXME: integer division
    var output = bounds;
    output.left += width_pad;
    output.right -= width_pad;
    output.top += height_pad;
    output.bottom -= height_pad;
    return output;
}
