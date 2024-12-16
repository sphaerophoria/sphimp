const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphtext = @import("sphtext");
const gui = @import("gui.zig");

pub fn defaultGui(comptime ActionType: type, alloc: Allocator) !*DefaultGui(ActionType) {
    const ret = try alloc.create(DefaultGui(ActionType));
    errdefer alloc.destroy(ret);
    ret.alloc = alloc;

    const font_size = 11.0;
    ret.text_renderer = try sphtext.TextRenderer.init(alloc, font_size);
    errdefer ret.text_renderer.deinit(alloc);

    ret.distance_field_renderer = try sphrender.DistanceFieldGenerator.init();
    errdefer ret.distance_field_renderer.deinit();

    const font_data = @embedFile("res/Hack-Regular.ttf");
    ret.ttf = try sphtext.ttf.Ttf.init(alloc, font_data);
    errdefer ret.ttf.deinit(alloc);

    const unit: f32 = @floatFromInt(sphtext.ttf.lineHeightPx(ret.ttf, font_size));

    const widget_width: u31 = @intFromFloat(unit * 8);
    const button_height: u31 = @intFromFloat(unit * 2);
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

    var root_stack = try gui.stack.Stack(ActionType).init(alloc);
    errdefer root_stack.deinit(alloc);
    ret.root = root_stack.asWidget();

    ret.overlay = gui.popup_layer.PopupLayer(ActionType){};

    ret.main_layout = try gui.layout.Layout(ActionType).init(alloc, @intFromFloat(unit / 2));
    //errdefer ret.main_layout.deinit(alloc);
    const scroll = try gui.scroll_view.ScrollView(ActionType).init(alloc, ret.main_layout.asWidget(), &ret.scroll_style, &ret.squircle_renderer);
    // FIXME: Error handling of overlay/main/scroll

    try root_stack.pushWidgetOrDeinit(alloc, scroll, .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });
    try root_stack.pushWidgetOrDeinit(alloc, ret.overlay.asWidget(), .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });

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
        root: gui.Widget(ActionType),

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
        main_layout: *gui.layout.Layout(ActionType),

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.root.deinit(self.alloc);
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
    };
}


