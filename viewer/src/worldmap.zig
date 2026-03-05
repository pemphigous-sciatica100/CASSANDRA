const std = @import("std");
const rl = @import("rl.zig");

const BORDER_COLOR = rl.color(40, 60, 90, 160);
const LABEL_COLOR = rl.color(40, 50, 70, 60);
const LABEL_ZOOM_MIN: f32 = 0.8; // show labels above this zoom
const LABEL_ZOOM_MAX: f32 = 6.0; // hide labels above this (too zoomed in)

const Polygon = struct {
    points: [][2]f32,
    // Bounding box for viewport culling
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

const Region = struct {
    name: []const u8,
    iso: [2]u8,
    centroid: [2]f32,
    polygons: []Polygon,
};

pub const WorldMap = struct {
    regions: []Region,
    buf: []align(4) u8, // backing memory for the binary file

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !WorldMap {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("worldmap: cannot open {s}: {}\n", .{ path, err });
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const buf = try allocator.alignedAlloc(u8, 4, stat.size);
        const n = try file.readAll(buf);
        if (n != stat.size) return error.ShortRead;

        var off: usize = 0;

        const num_regions = readU32(buf, &off);
        const regions = try allocator.alloc(Region, num_regions);

        for (regions) |*region| {
            const name_len = readU16(buf, &off);
            const name = buf[off..][0..name_len];
            off += name_len;

            const iso: [2]u8 = .{ buf[off], buf[off + 1] };
            off += 2;

            const cx = readF32(buf, &off);
            const cy = readF32(buf, &off);

            const num_polys = readU16(buf, &off);
            const polygons = try allocator.alloc(Polygon, num_polys);

            for (polygons) |*poly| {
                const num_pts = readU32(buf, &off);
                const points = try allocator.alloc([2]f32, num_pts);

                var min_x: f32 = std.math.floatMax(f32);
                var min_y: f32 = std.math.floatMax(f32);
                var max_x: f32 = -std.math.floatMax(f32);
                var max_y: f32 = -std.math.floatMax(f32);

                for (points) |*pt| {
                    const x = readF32(buf, &off);
                    const y = readF32(buf, &off);
                    pt.* = .{ x, y };
                    min_x = @min(min_x, x);
                    min_y = @min(min_y, y);
                    max_x = @max(max_x, x);
                    max_y = @max(max_y, y);
                }

                poly.* = .{
                    .points = points,
                    .min_x = min_x,
                    .min_y = min_y,
                    .max_x = max_x,
                    .max_y = max_y,
                };
            }

            region.* = .{
                .name = name,
                .iso = iso,
                .centroid = .{ cx, cy },
                .polygons = polygons,
            };
        }

        std.debug.print("worldmap: loaded {} regions\n", .{num_regions});
        return .{ .regions = regions, .buf = buf };
    }

    pub fn draw(self: *const WorldMap, cam: rl.Camera2D, sw: c_int, sh: c_int) void {
        // Viewport bounds in world space
        const tl = rl.getScreenToWorld2D(rl.vec2(0, 0), cam);
        const br = rl.getScreenToWorld2D(rl.vec2(@floatFromInt(sw), @floatFromInt(sh)), cam);

        for (self.regions) |region| {
            for (region.polygons) |poly| {
                // Viewport culling
                if (poly.max_x < tl.x or poly.min_x > br.x) continue;
                if (poly.max_y < tl.y or poly.min_y > br.y) continue;

                const pts = poly.points;
                if (pts.len < 2) continue;

                // Draw line strip (closed loop)
                for (0..pts.len) |i| {
                    const j = (i + 1) % pts.len;
                    rl.drawLineV(
                        rl.vec2(pts[i][0], pts[i][1]),
                        rl.vec2(pts[j][0], pts[j][1]),
                        BORDER_COLOR,
                    );
                }
            }
        }
    }

    pub fn drawLabels(self: *const WorldMap, cam: rl.Camera2D, font: rl.Font) void {
        const zoom = cam.zoom;
        if (zoom < LABEL_ZOOM_MIN or zoom > LABEL_ZOOM_MAX) return;

        // Fade in/out at thresholds
        const alpha_f = blk: {
            if (zoom < LABEL_ZOOM_MIN + 0.3) {
                break :blk (zoom - LABEL_ZOOM_MIN) / 0.3;
            }
            if (zoom > LABEL_ZOOM_MAX - 1.0) {
                break :blk (LABEL_ZOOM_MAX - zoom) / 1.0;
            }
            break :blk 1.0;
        };

        const base_a: f32 = @floatFromInt(LABEL_COLOR.a);
        const a: u8 = @intFromFloat(@max(0, @min(255, base_a * alpha_f)));
        const col = rl.color(LABEL_COLOR.r, LABEL_COLOR.g, LABEL_COLOR.b, a);

        const font_size: f32 = 9.0 / zoom; // constant screen-size appearance

        for (self.regions) |region| {
            if (region.name.len == 0) continue;

            // Null-terminate for raylib (name points into buf, append not possible)
            // Use a stack buffer
            var name_buf: [64]u8 = undefined;
            const len = @min(region.name.len, 63);
            @memcpy(name_buf[0..len], region.name[0..len]);
            name_buf[len] = 0;
            const name_z: [*:0]const u8 = @ptrCast(&name_buf);

            const pos = rl.vec2(region.centroid[0], region.centroid[1]);
            rl.drawTextEx(font, name_z, pos, font_size, font_size * 0.1, col);
        }
    }
};

fn readU32(buf: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, buf[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

fn readU16(buf: []const u8, off: *usize) u16 {
    const v = std.mem.readInt(u16, buf[off.*..][0..2], .little);
    off.* += 2;
    return v;
}

fn readF32(buf: []const u8, off: *usize) f32 {
    const bytes = buf[off.*..][0..4];
    off.* += 4;
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
