const rl = @import("rl.zig");
const constants = @import("constants.zig");
const data = @import("data.zig");
const std = @import("std");

pub const CameraState = struct {
    cam: rl.Camera2D,
    dragging: bool = false,
    drag_start: rl.Vector2 = .{ .x = 0, .y = 0 },
    selected_point: ?u16 = null,

    pub fn init() CameraState {
        return .{
            .cam = .{
                .offset = .{
                    .x = @as(f32, @floatFromInt(constants.WINDOW_W)) / 2.0,
                    .y = @as(f32, @floatFromInt(constants.WINDOW_H)) / 2.0,
                },
                .target = .{ .x = 0, .y = 0 },
                .rotation = 0,
                .zoom = 25.0,
            },
        };
    }

    pub fn update(self: *CameraState, points: ?[]const data.Point, sw: c_int, sh: c_int) void {
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            const mouse_pos = rl.getMousePosition();
            const world_before = rl.getScreenToWorld2D(mouse_pos, self.cam);

            self.cam.zoom *= if (wheel > 0) 1.1 else 1.0 / 1.1;
            self.cam.zoom = std.math.clamp(self.cam.zoom, 2.0, 200.0);

            const world_after = rl.getScreenToWorld2D(mouse_pos, self.cam);
            self.cam.target.x += world_before.x - world_after.x;
            self.cam.target.y += world_before.y - world_after.y;
        }

        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) {
            self.dragging = true;
            self.drag_start = rl.getMousePosition();
        }
        if (rl.isMouseButtonReleased(rl.MOUSE_BUTTON_RIGHT)) {
            self.dragging = false;
        }
        if (self.dragging) {
            const mouse_pos = rl.getMousePosition();
            const dx = (mouse_pos.x - self.drag_start.x) / self.cam.zoom;
            const dy = (mouse_pos.y - self.drag_start.y) / self.cam.zoom;
            self.cam.target.x -= dx;
            self.cam.target.y -= dy;
            self.drag_start = mouse_pos;
        }

        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mouse_pos = rl.getMousePosition();
            _ = sw;
            if (mouse_pos.y < @as(f32, @floatFromInt(sh)) - 50) {
                const world_pos = rl.getScreenToWorld2D(mouse_pos, self.cam);
                self.selected_point = hitTest(world_pos, points, self.cam.zoom);
            }
        }

        if (rl.isKeyPressed(rl.KEY_HOME)) {
            self.cam.target = .{ .x = 0, .y = 0 };
            self.cam.zoom = 25.0;
            self.selected_point = null;
        }

        if (rl.isKeyPressed(rl.KEY_ESCAPE)) {
            self.selected_point = null;
        }
    }
};

fn hitTest(world_pos: rl.Vector2, points: ?[]const data.Point, zoom: f32) ?u16 {
    const pts = points orelse return null;
    const hit_radius = 15.0 / zoom;
    var best_dist: f32 = hit_radius * hit_radius;
    var best_idx: ?u16 = null;

    for (pts, 0..) |p, i| {
        const dx = world_pos.x - p.x;
        const dy = world_pos.y - p.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_dist) {
            best_dist = d2;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}
