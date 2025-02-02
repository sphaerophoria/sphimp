const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");

pub fn Runner(comptime Action: type) type {
    return struct {
        root: gui.Widget(Action),
        input_state: gui.InputState,

        const Self = @This();

        pub fn init(gpa: Allocator, widget: gui.Widget(Action)) Self {
            const input_state = gui.InputState.init(gpa);

            return .{
                .root = widget,
                .input_state = input_state,
            };
        }

        pub fn step(self: *Self, widget_bounds: gui.PixelBBox, window_size: gui.PixelSize, input_queue: anytype) !?Action {
            const widget_size = gui.PixelSize{
                .width = widget_bounds.calcWidth(),
                .height = widget_bounds.calcHeight(),
            };
            try self.root.update(widget_size);

            self.input_state.startFrame();
            while (input_queue.readItem()) |action| {
                try self.input_state.pushInput(action);
            }

            const window_bounds = gui.PixelBBox{
                .top = 0,
                .bottom = window_size.height,
                .left = 0,
                .right = window_size.width,
            };

            const input_response = self.root.setInputState(widget_bounds, widget_bounds, self.input_state);
            self.root.setFocused(input_response.wants_focus);
            self.root.render(widget_bounds, window_bounds);
            return input_response.action;
        }
    };
}
