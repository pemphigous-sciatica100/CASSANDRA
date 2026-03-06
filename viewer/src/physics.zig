const std = @import("std");
const data = @import("data.zig");
const bvh = @import("bvh.zig");

pub const PhysicsMode = enum {
    off,
    blending_in,
    active,
    blending_out,
};

pub const Constants = struct {
    anchor_k_cold: f32 = 8.0,
    anchor_k_hot: f32 = 0.05,
    anchor_power: f32 = 4.0, // quartic falloff: mid-activity nodes loosen even faster
    center_gravity: f32 = 16.0, // spring-to-origin: force = k * dist * activity
    velocity_freeze: f32 = 0.1, // zero velocity below this speed
    repulsion_strength: f32 = 0.08,
    repulsion_activity_boost: f32 = 80.0, // hot-hot pairs repel harder (product scaling)
    repulsion_cutoff: f32 = 4.0,
    repulsion_min_dist: f32 = 0.3,
    repulsion_activity_threshold: f32 = 0.01, // skip pairs where both below this
    damping: f32 = 0.05,
    attractor_spring_k: f32 = 1.5,
    attractor_spring_rest_len: f32 = 2.0,
    max_velocity: f32 = 20.0,
    time_scale: f32 = 0.25, // slow-mo: simulation runs at 1/4 real time
    blend_duration: f32 = 1.5,
    geo_spring_k: f32 = 36.0, // spring constant for geo pull toward country centroids
};

pub const PhysicsState = struct {
    allocator: std.mem.Allocator,
    // SoA parallel arrays
    pos_x: []f32,
    pos_y: []f32,
    vel_x: []f32,
    vel_y: []f32,
    rest_x: []f32,
    rest_y: []f32,
    activity: []f32, // 0..1 normalized
    name_indices: []u16,
    nearest_attractor: []u16,
    is_attractor: []bool,
    geo_x: []f32,
    geo_y: []f32,
    has_geo: []bool,
    count: usize,
    capacity: usize,

    mode: PhysicsMode,
    blend_t: f32,
    geo_strength: f32,
    geo_active: bool,
    consts: Constants,

    pub fn init(allocator: std.mem.Allocator) PhysicsState {
        return .{
            .allocator = allocator,
            .pos_x = &.{},
            .pos_y = &.{},
            .vel_x = &.{},
            .vel_y = &.{},
            .rest_x = &.{},
            .rest_y = &.{},
            .activity = &.{},
            .name_indices = &.{},
            .nearest_attractor = &.{},
            .is_attractor = &.{},
            .geo_x = &.{},
            .geo_y = &.{},
            .has_geo = &.{},
            .count = 0,
            .capacity = 0,
            .mode = .off,
            .blend_t = 0,
            .geo_strength = 0,
            .geo_active = false,
            .consts = .{},
        };
    }

    pub fn isActive(self: *const PhysicsState) bool {
        return self.mode != .off;
    }

    pub fn toggle(self: *PhysicsState) void {
        switch (self.mode) {
            .off => {
                self.mode = .blending_in;
                self.blend_t = 0;
            },
            .blending_in, .active => {
                self.mode = .blending_out;
                self.blend_t = 1.0;
            },
            .blending_out => {
                self.mode = .blending_in;
                self.blend_t = 1.0 - self.blend_t;
            },
        }
    }

    fn ensureCapacity(self: *PhysicsState, n: usize) !void {
        if (n <= self.capacity) return;
        const new_cap = @max(n, self.capacity * 2);

        self.pos_x = try self.allocator.realloc(self.pos_x, new_cap);
        self.pos_y = try self.allocator.realloc(self.pos_y, new_cap);
        self.vel_x = try self.allocator.realloc(self.vel_x, new_cap);
        self.vel_y = try self.allocator.realloc(self.vel_y, new_cap);
        self.rest_x = try self.allocator.realloc(self.rest_x, new_cap);
        self.rest_y = try self.allocator.realloc(self.rest_y, new_cap);
        self.activity = try self.allocator.realloc(self.activity, new_cap);
        self.name_indices = try self.allocator.realloc(self.name_indices, new_cap);
        self.nearest_attractor = try self.allocator.realloc(self.nearest_attractor, new_cap);
        self.is_attractor = try self.allocator.realloc(self.is_attractor, new_cap);
        self.geo_x = try self.allocator.realloc(self.geo_x, new_cap);
        self.geo_y = try self.allocator.realloc(self.geo_y, new_cap);
        self.has_geo = try self.allocator.realloc(self.has_geo, new_cap);
        self.capacity = new_cap;
    }

    /// Sync physics arrays from current keyframe points. Preserves velocity for persistent nodes.
    pub fn syncToPoints(self: *PhysicsState, points: []const data.Point, max_delta: f32) !void {
        const n = points.len;
        try self.ensureCapacity(n);

        // Build lookup from old name_idx -> physics index
        var old_map = std.AutoHashMap(u16, usize).init(self.allocator);
        defer old_map.deinit();
        for (0..self.count) |i| {
            try old_map.put(self.name_indices[i], i);
        }

        // Save old velocities and positions
        const old_vx = try self.allocator.alloc(f32, self.count);
        defer self.allocator.free(old_vx);
        const old_vy = try self.allocator.alloc(f32, self.count);
        defer self.allocator.free(old_vy);
        const old_px = try self.allocator.alloc(f32, self.count);
        defer self.allocator.free(old_px);
        const old_py = try self.allocator.alloc(f32, self.count);
        defer self.allocator.free(old_py);
        @memcpy(old_vx, self.vel_x[0..self.count]);
        @memcpy(old_vy, self.vel_y[0..self.count]);
        @memcpy(old_px, self.pos_x[0..self.count]);
        @memcpy(old_py, self.pos_y[0..self.count]);

        const md = @max(max_delta, 1.0);
        for (points, 0..) |p, i| {
            self.rest_x[i] = p.x;
            self.rest_y[i] = p.y;
            self.activity[i] = p.delta / md;
            self.name_indices[i] = p.name_idx;
            self.nearest_attractor[i] = p.nearest_attractor;
            self.is_attractor[i] = p.is_attractor;

            if (old_map.get(p.name_idx)) |old_i| {
                // Preserve velocity and position for persistent nodes
                self.vel_x[i] = old_vx[old_i];
                self.vel_y[i] = old_vy[old_i];
                self.pos_x[i] = old_px[old_i];
                self.pos_y[i] = old_py[old_i];
            } else {
                // New node: start at rest position with zero velocity
                self.pos_x[i] = p.x;
                self.pos_y[i] = p.y;
                self.vel_x[i] = 0;
                self.vel_y[i] = 0;
            }
        }
        self.count = n;
    }

    /// Run one physics step: accumulate forces, integrate, damp.
    pub fn step(self: *PhysicsState, raw_dt: f32) void {
        if (self.count == 0) return;
        const c = self.consts;
        const dt = raw_dt * c.time_scale;
        const n = self.count;
        const geo_str = self.geo_strength;

        // Find attractor positions (in physics space)
        var att_px: [10]f32 = undefined;
        var att_py: [10]f32 = undefined;
        var num_att: usize = 0;
        for (0..n) |i| {
            if (self.is_attractor[i] and num_att < 10) {
                att_px[num_att] = self.pos_x[i];
                att_py[num_att] = self.pos_y[i];
                num_att += 1;
            }
        }

        for (0..n) |i| {
            var fx: f32 = 0;
            var fy: f32 = 0;
            const act = self.activity[i];

            // 1. Anchor spring: quartic falloff so mid-activity nodes loosen fast
            const inv_act = 1.0 - act;
            const inv_act2 = inv_act * inv_act;
            const inv_act3 = inv_act2 * inv_act2; // (1-act)^4
            const k_base = c.anchor_k_hot + (c.anchor_k_cold - c.anchor_k_hot) * inv_act3;
            // Weaken anchor for geo-matched nodes when geo is active
            const k = if (geo_str > 0 and self.has_geo[i]) k_base * (1.0 - geo_str * 0.95) else k_base;
            fx += (self.rest_x[i] - self.pos_x[i]) * k;
            fy += (self.rest_y[i] - self.pos_y[i]) * k;

            // 2. Center gravity: spring-to-origin, strength proportional to activity
            // Weaken for geo nodes so they can reach far-flung country positions
            const cg = if (geo_str > 0 and self.has_geo[i]) c.center_gravity * (1.0 - geo_str) else c.center_gravity;
            fx -= self.pos_x[i] * cg * act;
            fy -= self.pos_y[i] * cg * act;

            // 2b. Geo spring: pull geo-matched nodes toward country centroid
            // Uses raw_dt (not time_scaled dt) so it isn't weakened by slow-mo
            if (geo_str > 0 and self.has_geo[i]) {
                const gdx = self.geo_x[i] - self.pos_x[i];
                const gdy = self.geo_y[i] - self.pos_y[i];
                const scale = geo_str * (0.3 + 0.7 * act);
                self.vel_x[i] += c.geo_spring_k * scale * gdx * raw_dt;
                self.vel_y[i] += c.geo_spring_k * scale * gdy * raw_dt;
            }

            // 3. Attractor-satellite spring
            if (!self.is_attractor[i]) {
                const ai = self.nearest_attractor[i];
                if (ai < num_att) {
                    const dx_a = att_px[ai] - self.pos_x[i];
                    const dy_a = att_py[ai] - self.pos_y[i];
                    const dist_a = @sqrt(dx_a * dx_a + dy_a * dy_a);
                    if (dist_a > 0.01) {
                        const stretch = dist_a - c.attractor_spring_rest_len;
                        const force = c.attractor_spring_k * act * stretch;
                        fx += (dx_a / dist_a) * force;
                        fy += (dy_a / dist_a) * force;
                    }
                }
            }

            // Integrate
            self.vel_x[i] += fx * dt;
            self.vel_y[i] += fy * dt;

            // Damping
            const damp = 1.0 - c.damping;
            self.vel_x[i] *= damp;
            self.vel_y[i] *= damp;
        }

        // 4. Repulsion pass — BVH-accelerated, activity-weighted
        const thresh = c.repulsion_activity_threshold;
        var rep_bvh: bvh.Bvh = undefined;
        rep_bvh.build(self.pos_x[0..n], self.pos_y[0..n], n);

        for (0..n) |i| {
            const act_i = self.activity[i];
            const is_cold = act_i < thresh;
            var iter = rep_bvh.queryRadius(
                self.pos_x[i],
                self.pos_y[i],
                c.repulsion_cutoff,
                self.pos_x[0..n],
                self.pos_y[0..n],
            );
            while (iter.next()) |j| {
                if (j <= i) continue; // avoid double-counting
                const act_j = self.activity[j];
                if (is_cold and act_j < thresh) continue;
                const dx = self.pos_x[j] - self.pos_x[i];
                const dy = self.pos_y[j] - self.pos_y[i];
                const d2 = dx * dx + dy * dy;
                const dist = @max(@sqrt(d2), c.repulsion_min_dist);
                const activity_scale = 1.0 + c.repulsion_activity_boost * act_i * act_j;
                const force = c.repulsion_strength * activity_scale / (dist * dist);
                const nx = dx / dist;
                const ny = dy / dist;
                self.vel_x[i] -= nx * force;
                self.vel_y[i] -= ny * force;
                self.vel_x[j] += nx * force;
                self.vel_y[j] += ny * force;
            }
        }

        // 5. Final pass: freeze, clamp, integrate position
        for (0..n) |i| {
            const spd = @sqrt(self.vel_x[i] * self.vel_x[i] + self.vel_y[i] * self.vel_y[i]);
            if (spd < c.velocity_freeze) {
                self.vel_x[i] = 0;
                self.vel_y[i] = 0;
            } else if (spd > c.max_velocity) {
                const scale = c.max_velocity / spd;
                self.vel_x[i] *= scale;
                self.vel_y[i] *= scale;
            }
            self.pos_x[i] += self.vel_x[i] * dt;
            self.pos_y[i] += self.vel_y[i] * dt;
        }
    }

    /// Update blend transition.
    pub fn updateBlend(self: *PhysicsState, dt: f32) void {
        const rate = dt / self.consts.blend_duration;
        switch (self.mode) {
            .blending_in => {
                self.blend_t += rate;
                if (self.blend_t >= 1.0) {
                    self.blend_t = 1.0;
                    self.mode = .active;
                }
            },
            .blending_out => {
                self.blend_t -= rate;
                if (self.blend_t <= 0.0) {
                    self.blend_t = 0.0;
                    self.mode = .off;
                }
            },
            else => {},
        }
    }

    /// Toggle geo-gravity mode.
    pub fn toggleGeo(self: *PhysicsState) void {
        self.geo_active = !self.geo_active;
    }

    /// Lerp geo_strength toward target (0 or 1) over blend_duration.
    pub fn updateGeo(self: *PhysicsState, dt: f32) void {
        const target: f32 = if (self.geo_active) 1.0 else 0.0;
        const rate = dt / self.consts.blend_duration;
        if (self.geo_strength < target) {
            self.geo_strength = @min(self.geo_strength + rate, target);
        } else if (self.geo_strength > target) {
            self.geo_strength = @max(self.geo_strength - rate, target);
        }
    }

    /// Write simulated positions and velocity into a mutable point buffer, blended with rest positions.
    pub fn applyToPoints(self: *const PhysicsState, points: []data.Point) void {
        const t = smoothstep(self.blend_t);
        for (points) |*p| {
            for (0..self.count) |i| {
                if (self.name_indices[i] == p.name_idx) {
                    p.x = lerp(self.rest_x[i], self.pos_x[i], t);
                    p.y = lerp(self.rest_y[i], self.pos_y[i], t);
                    p.speed = @sqrt(self.vel_x[i] * self.vel_x[i] + self.vel_y[i] * self.vel_y[i]) * t;
                    break;
                }
            }
        }
    }
};

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
