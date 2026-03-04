const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const constants = @import("constants.zig");

pub const Timeline = struct {
    current_time: f32 = 0.0,
    playing: bool = false,
    speed_idx: u8 = 2,
    num_keyframes: u32 = 0,

    pub fn init(num_kf: u32) Timeline {
        return .{
            .num_keyframes = num_kf,
            .current_time = if (num_kf > 0) @as(f32, @floatFromInt(num_kf - 1)) else 0,
        };
    }

    pub fn update(self: *Timeline, dt: f32) void {
        if (!self.playing or self.num_keyframes < 2) return;
        const spd = constants.SPEED_LEVELS[self.speed_idx];
        self.current_time += spd * dt;
        const max_t: f32 = @floatFromInt(self.num_keyframes - 1);
        if (self.current_time >= max_t) {
            self.current_time = max_t;
            self.playing = false;
        }
        if (self.current_time < 0) self.current_time = 0;
    }

    pub fn handleInput(self: *Timeline) void {
        if (rl.isKeyPressed(rl.KEY_SPACE)) {
            self.playing = !self.playing;
            const max_t: f32 = @floatFromInt(self.num_keyframes - 1);
            if (self.current_time >= max_t and self.playing) {
                self.current_time = 0;
            }
        }
        if (rl.isKeyPressed(rl.KEY_RIGHT_BRACKET)) {
            if (self.speed_idx < constants.SPEED_LEVELS.len - 1) self.speed_idx += 1;
        }
        if (rl.isKeyPressed(rl.KEY_LEFT_BRACKET)) {
            if (self.speed_idx > 0) self.speed_idx -= 1;
        }
        if (rl.isKeyPressed(rl.KEY_RIGHT)) {
            self.current_time = @min(self.current_time + 1.0, @as(f32, @floatFromInt(self.num_keyframes - 1)));
            self.playing = false;
        }
        if (rl.isKeyPressed(rl.KEY_LEFT)) {
            self.current_time = @max(self.current_time - 1.0, 0.0);
            self.playing = false;
        }
    }

    pub fn speed(self: *const Timeline) f32 {
        return constants.SPEED_LEVELS[self.speed_idx];
    }

    pub fn keyframeIndex(self: *const Timeline) u32 {
        return @intFromFloat(@floor(self.current_time));
    }

    pub fn interpFraction(self: *const Timeline) f32 {
        return self.current_time - @floor(self.current_time);
    }

    pub fn seek(self: *Timeline, t: f32) void {
        const max_t: f32 = @floatFromInt(self.num_keyframes - 1);
        self.current_time = std.math.clamp(t, 0, max_t);
    }
};

pub fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn lerpPoints(
    a: []const data.Point,
    b: []const data.Point,
    t: f32,
    allocator: std.mem.Allocator,
) ![]data.Point {
    const s = smoothstep(t);
    var b_map = std.AutoHashMap(u16, usize).init(allocator);
    defer b_map.deinit();
    for (b, 0..) |bp, i| {
        try b_map.put(bp.name_idx, i);
    }

    var result = std.ArrayList(data.Point).init(allocator);

    for (a) |ap| {
        if (b_map.get(ap.name_idx)) |bi| {
            const bp = b[bi];
            try result.append(.{
                .name_idx = ap.name_idx,
                .x = ap.x,
                .y = ap.y,
                .total = lerp(ap.total, bp.total, s),
                .exemplars = lerp(ap.exemplars, bp.exemplars, s),
                .delta = lerp(ap.delta, bp.delta, s),
                .uncertainty = lerp(ap.uncertainty, bp.uncertainty, s),
                .u_shift = lerp(ap.u_shift, bp.u_shift, s),
                .fade = lerp(ap.fade, bp.fade, s),
                .cluster = if (s < 0.5) ap.cluster else bp.cluster,
                .is_attractor = ap.is_attractor or bp.is_attractor,
                .nearest_attractor = if (s < 0.5) ap.nearest_attractor else bp.nearest_attractor,
            });
        } else {
            var faded = ap;
            faded.fade *= (1.0 - s);
            try result.append(faded);
        }
    }

    for (b) |bp| {
        var found = false;
        for (a) |ap| {
            if (ap.name_idx == bp.name_idx) {
                found = true;
                break;
            }
        }
        if (!found) {
            var fading_in = bp;
            fading_in.fade *= s;
            try result.append(fading_in);
        }
    }

    return try result.toOwnedSlice();
}
