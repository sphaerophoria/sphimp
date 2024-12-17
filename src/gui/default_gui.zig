const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphtext = @import("sphtext");
const gui = @import("gui.zig");

pub fn defaultGui(comptime ActionType: type, alloc: Allocator) !*DefaultGui(ActionType) {
    const ret = try alloc.create(DefaultGui(ActionType));
    errdefer alloc.destroy(ret);
    ret.root = null;
    ret.alloc = alloc;

    ret.input_state = gui.InputState{};
    errdefer ret.input_state.deinit(alloc);

    const font_size = 11.0;
    ret.text_renderer = try sphtext.TextRenderer.init(alloc, font_size);
    errdefer ret.text_renderer.deinit(alloc);

    ret.distance_field_renderer = try sphrender.DistanceFieldGenerator.init();
    errdefer ret.distance_field_renderer.deinit();

    const font_data = @embedFile("res/Hack-Regular.ttf");
    ret.ttf = try sphtext.ttf.Ttf.init(alloc, font_data);
    errdefer ret.ttf.deinit(alloc);

    const unit: f32 = @floatFromInt(sphtext.ttf.lineHeightPx(ret.ttf, font_size));
    ret.layout_pad = @intFromFloat(unit / 2);

    const widget_width: u31 = @intFromFloat(unit * 8);
    const button_height: u31 = @intFromFloat(unit * 1.4);
    const text_wrapped_height: u31 = @intFromFloat(unit * 1.3);
    const widget_text_padding: u31 = @intFromFloat(unit / 5);
    const corner_radius: f32 = unit / 5;

    ret.drag_style = gui.drag_float.DragFloatStyle{
        .size = .{
            .width = widget_width,
            .height = text_wrapped_height,
        },
        .corner_radius = corner_radius,
        .default_color = GlobalStyle.default_color,
        .hover_color = GlobalStyle.hover_color,
        .active_color = GlobalStyle.active_color,
    };

    ret.squircle_renderer = try gui.SquircleRenderer.init(alloc);
    errdefer ret.squircle_renderer.deinit(alloc);

    ret.guitext_state = gui.gui_text.SharedState{
        .ttf = &ret.ttf,
        .text_renderer = &ret.text_renderer,
        .distance_field_generator = &ret.distance_field_renderer,
    };

    ret.shared_button_state = gui.button.SharedButtonState{
        .text_shared = &ret.guitext_state,
        .style = .{
            .default_color = GlobalStyle.default_color,
            .hover_color = GlobalStyle.hover_color,
            .click_color = GlobalStyle.active_color,
            .desired_width = widget_width,
            .desired_height = button_height,
            .corner_radius = corner_radius,
            .padding = widget_text_padding,
        },
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.scroll_style = gui.scrollbar.Style{
        .default_color = GlobalStyle.default_color,
        .hover_color = GlobalStyle.hover_color,
        .active_color = GlobalStyle.active_color,
        .gutter_color = GlobalStyle.background_color2,
        .corner_radius = corner_radius,
        .width = @intFromFloat(unit * 0.75),
    };

    ret.shared_color = try gui.color_picker.SharedColorPickerState.init(
        alloc,
        gui.color_picker.ColorStyle{
            .preview_width = widget_width,
            .popup_width = widget_width,
            .popup_background = GlobalStyle.background_color2,
            .color_preview_height = text_wrapped_height,
            .item_pad = widget_text_padding,
            .corner_radius = corner_radius,
            .drag_style = ret.drag_style,
        },
        &ret.guitext_state,
        &ret.squircle_renderer,
    );
    errdefer ret.shared_color.deinit(alloc);

    ret.shared_textbox_state = gui.textbox.SharedTextboxState{
        .squircle_renderer = &ret.squircle_renderer,
        .guitext_shared = &ret.guitext_state,
        .style = .{
            .cursor_width = @intFromFloat(unit * 0.1),
            .cursor_height = @intFromFloat(unit * 0.9),
            .corner_radius = corner_radius,
            .cursor_color = gui.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
            .label_pad = widget_text_padding,
            .background_color = GlobalStyle.default_color,
            .size = .{
                .width = widget_width,
                .height = text_wrapped_height,
            },
        },
    };

    ret.shared_selecatble_list_state = gui.selectable_list.SharedState{
        .gui_state = &ret.guitext_state,
        .squircle_renderer = &ret.squircle_renderer,
        .style = .{
            .highlight_color = GlobalStyle.default_color,
            .hover_color = GlobalStyle.hover_color,
            .active_color = GlobalStyle.active_color,
            .background_color = GlobalStyle.background_color2,
            .corner_radius = corner_radius,
            .item_pad = widget_text_padding,
            .width = widget_width,
            .min_item_height = @intFromFloat(unit),
        },
    };


    ret.overlay = gui.popup_layer.PopupLayer(ActionType){};


    return ret;
}

pub const GlobalStyle = struct {
    pub const default_color = gui.Color{ .r = 0.38, .g = 0.35, .b = 0.44, .a = 1.0 };
    pub const hover_color = hoverColor(default_color);
    pub const active_color = activeColor(default_color);
    pub const background_color = gui.Color{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 };
    pub const background_color2 = gui.Color{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };

    pub fn hoverColor(default: gui.Color) gui.Color {
        return .{
            .r = default.r * 3.0 / 2.0,
            .g = default.g * 3.0 / 2.0,
            .b = default.b * 3.0 / 2.0,
            .a = default.a,
        };
    }

    pub fn activeColor(default: gui.Color) gui.Color {
        return .{
            .r = default.r * 4.0 / 2.0,
            .g = default.g * 4.0 / 2.0,
            .b = default.b * 4.0 / 2.0,
            .a = default.a,
        };
    }
};

pub fn DefaultGui(comptime ActionType: type) type {
    return struct {
        alloc: Allocator,
        root: ?gui.Widget(ActionType),

        layout_pad: u31,
        input_state: gui.InputState,
        text_renderer: sphtext.TextRenderer,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
        ttf: sphtext.ttf.Ttf,
        guitext_state: gui.gui_text.SharedState,
        drag_style: gui.drag_float.DragFloatStyle,
        shared_button_state: gui.button.SharedButtonState,
        squircle_renderer: gui.SquircleRenderer,
        scroll_style: gui.scrollbar.Style,
        shared_color: gui.color_picker.SharedColorPickerState,
        shared_textbox_state: gui.textbox.SharedTextboxState,
        shared_selecatble_list_state: gui.selectable_list.SharedState,
        overlay: gui.popup_layer.PopupLayer(ActionType),

        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (self.root) |r| r.deinit(self.alloc);

            self.text_renderer.deinit(self.alloc);
            self.distance_field_renderer.deinit();
            self.ttf.deinit(self.alloc);
            self.squircle_renderer.deinit(self.alloc);
            self.shared_color.deinit(self.alloc);
            self.overlay.reset();
            self.alloc.destroy(self);
        }

        pub fn makeLabel(self: *const Self, text_retriever: anytype, wrap_width: u31) !gui.Widget(ActionType) {
            return gui.label.makeLabel(
                ActionType,
                self.alloc,
                text_retriever,
                wrap_width,
                &self.guitext_state,
            );
        }

        pub fn makeButton(self: *const Self, text_retriever: anytype, click_action: anytype) !gui.Widget(ActionType) {
            return gui.button.makeButton(
                ActionType,
                self.alloc,
                text_retriever,
                &self.shared_button_state,
                click_action,
            );
        }

        pub fn makeTextbox(self: *const Self, text_retriever: anytype, action: anytype) !gui.Widget(ActionType) {
            return gui.textbox.makeTextbox(
                ActionType,
                self.alloc,
                text_retriever,
                action,
                &self.shared_textbox_state,
            );
        }

        pub fn makeSelectableList(self: *const Self, retriever: anytype, action_gen: anytype) !gui.Widget(ActionType) {
            return gui.selectable_list.selectableList(
                ActionType,
                self.alloc,
                retriever,
                action_gen,
                &self.shared_selecatble_list_state,
            );
        }

        pub fn makeColorPicker(self: *Self, retriever: anytype, action_gen: anytype) !gui.Widget(ActionType) {
            return gui.color_picker.makeColorPicker(
                ActionType,
                self.alloc,
                retriever,
                action_gen,
                &self.shared_color,
                &self.overlay,
            );
        }

        pub fn makeDragFloat(self: *Self, retriever: anytype, action_gen: anytype) !gui.Widget(ActionType) {
            return gui.drag_float.makeWidget(
                ActionType,
                self.alloc,
                retriever,
                action_gen,
                &self.drag_style,
                &self.guitext_state,
                &self.squircle_renderer,
            );
        }

        pub fn makeLayout(self: *Self) !*gui.layout.Layout(ActionType) {
            return gui.layout.Layout(ActionType).init(self.alloc, self.layout_pad);
        }

        pub fn makeScrollView(self: *Self, inner: gui.Widget(ActionType)) !gui.Widget(ActionType) {
            return gui.scroll_view.ScrollView(ActionType).init(self.alloc, inner, &self.scroll_style, &self.squircle_renderer);
        }

        pub fn makeEvenVertLayout(self: *Self) !*gui.even_vert_layout.EvenVertLayout(ActionType) {
            const ret = try self.alloc.create(gui.even_vert_layout.EvenVertLayout(ActionType));
            ret.* = .{};
            return ret;
        }

        pub fn makeStack(self: *Self) !*gui.stack.Stack(ActionType) {
            return gui.stack.Stack(ActionType).init(self.alloc);
        }

        pub fn makeRect(self: *Self, size: gui.PixelSize, color: gui.Color, fill_parent: bool) !gui.Widget(ActionType) {
            return gui.rect.Rect(ActionType).init(
                self.alloc,
                size,
                color,
                fill_parent,
                &self.squircle_renderer
            );
        }

        pub fn setRootWidgetOrDeinit(self: *Self, widget: gui.Widget(ActionType)) !void {
            errdefer widget.deinit(self.alloc);

            const root_stack = try gui.stack.Stack(ActionType).init(self.alloc);
            errdefer root_stack.deinit(self.alloc);

            try root_stack.pushWidgetOrDeinit(self.alloc, widget, .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });
            try root_stack.pushWidgetOrDeinit(self.alloc, self.overlay.asWidget(), .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });
            if (self.root) |r| r.deinit(self.alloc);
            self.root = root_stack.asWidget();
        }

        pub fn step(self: *Self, widget_bounds: gui.PixelBBox, window_size: gui.PixelSize, input_queue: anytype) !?ActionType {
            const root = self.root orelse return null;
            const widget_size = gui.PixelSize {
                .width = widget_bounds.calcWidth(),
                .height = widget_bounds.calcHeight(),

            };
            try root.update(widget_size);

            self.input_state.startFrame();
            while (input_queue.readItem()) |action| {
                try self.input_state.pushInput(self.alloc, action);
            }

            const window_bounds = gui.PixelBBox{
                .top = 0,
                .bottom = window_size.height,
                .left = 0,
                .right = window_size.width,
            };

            const input_response = root.setInputState(widget_bounds, widget_bounds, self.input_state);
            root.setFocused(input_response.wants_focus);
            root.render(widget_bounds, window_bounds);
            return input_response.action;
        }
    };
}


