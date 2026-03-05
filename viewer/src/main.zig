const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const render = @import("render.zig");
const camera = @import("camera.zig");
const timeline_mod = @import("timeline.zig");
const ui = @import("ui.zig");
const constants = @import("constants.zig");
const physics = @import("physics.zig");
const live = @import("live.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.debug.print("CASSANDRA Nucleus Viewer\n", .{});

    var nd = data.NucleusData.init(allocator);

    // Load positions (fast: ~138KB JSON)
    data.loadPositions(&nd, "../nucleus_positions.json") catch {
        std.debug.print("Warning: no positions file yet\n", .{});
    };
    std.debug.print("Loaded {d} positions\n", .{nd.positions.count()});

    // --- Spawn worker thread (handles all snapshot loading + live) ---
    var running_recency = std.StringHashMap(u32).init(allocator);
    var nds = live.NdSnapshot.init(&nd, &running_recency);
    var queue = live.LiveQueue{};
    queue.spawn(&nds);
    defer queue.requestShutdown();

    // --- Raylib init ---
    rl.setConfigFlags(rl.FLAG_MSAA_4X_HINT | rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.initWindow(constants.WINDOW_W, constants.WINDOW_H, "CASSANDRA — Nucleus Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(constants.TARGET_FPS);

    const font = rl.getFontDefault();

    // Start with default bounds — camera will fit when first data arrives
    const default_bounds = camera.Bounds{ .min_x = -20, .max_x = 20, .min_y = -20, .max_y = 20 };
    var cam_state = camera.CameraState.init(default_bounds, rl.getScreenWidth(), rl.getScreenHeight());
    var tl = timeline_mod.Timeline.init(0);
    var search = ui.SearchState{};
    var cluster_filter = ui.ClusterFilter{};

    var interp_buf: ?[]data.Point = null;
    var phys = physics.PhysicsState.init(allocator);
    var phys_buf: ?[]data.Point = null;
    var prev_ki: u32 = std.math.maxInt(u32);
    var needs_camera_fit = true;

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        // --- Live reload: check queue (lock-free pop, microseconds) ---
        if (queue.pop()) |result| {
            const was_at_end = tl.wasAtEnd();

            // Update attractor info
            if (result.num_attractors > 0) {
                nd.num_attractors = result.num_attractors;
                for (0..result.num_attractors) |i| {
                    nd.attractor_names[i] = result.attractor_name_indices[i];
                }
            }

            // Register any new names the worker discovered
            for (result.new_names.items) |ne| {
                _ = nd.getOrAddName(ne.synset, ne.word) catch continue;
            }
            // Merge new positions
            for (result.new_positions.items) |pe| {
                if (!nd.positions.contains(pe.name)) {
                    const arena = nd.string_arena.allocator();
                    const key = arena.dupe(u8, pe.name) catch continue;
                    nd.positions.put(key, pe.pos) catch {};
                }
            }

            // Copy points and timestamp to main-thread allocator so eviction can free them
            const points_copy = allocator.dupe(data.Point, result.keyframe.points) catch {
                var r = result;
                r.deinit();
                std.heap.page_allocator.destroy(r);
                continue;
            };
            const ts_copy = allocator.dupe(u8, result.keyframe.timestamp) catch {
                allocator.free(points_copy);
                var r = result;
                r.deinit();
                std.heap.page_allocator.destroy(r);
                continue;
            };
            var kf = result.keyframe;
            kf.points = points_copy;
            kf.timestamp = ts_copy;

            nd.keyframes.append(kf) catch {};

            // Drop oldest keyframes if over the cap
            var evicted: u32 = 0;
            while (nd.keyframes.items.len > constants.MAX_KEYFRAMES) {
                const old_kf = nd.keyframes.orderedRemove(0);
                allocator.free(old_kf.points);
                evicted += 1;
            }
            if (evicted > 0) {
                tl.current_time = @max(tl.current_time - @as(f32, @floatFromInt(evicted)), 0.0);
            }

            tl.num_keyframes = @intCast(nd.keyframes.items.len);
            tl.computeTickFracs(nd.keyframes.items, allocator) catch {};
            tl.noteArrival();
            const following = was_at_end or nd.keyframes.items.len == 1 or tl.follow_target != null;
            if (following) {
                // Snap playhead to end — no lag during fast bootstrap or eviction
                const end: f32 = @floatFromInt(tl.num_keyframes - 1);
                tl.current_time = end;
                tl.follow_target = null;
            }

            // Clean up result (frees arena — we've copied what we need)
            var r = result;
            r.deinit();
            std.heap.page_allocator.destroy(r);
        }

        // Fit camera when first data arrives
        if (needs_camera_fit and nd.keyframes.items.len > 0) {
            const bounds = camera.computeBounds(nd.keyframes.items[nd.keyframes.items.len - 1].points);
            cam_state.bounds = bounds;
            cam_state.fitToScreen(sw, sh);
            needs_camera_fit = false;
        }

        // Input
        if (rl.isKeyPressed(rl.KEY_F11) or rl.isKeyPressed(rl.KEY_F)) {
            rl.toggleFullscreen();
        }
        if (search.active) {
            search.handleInput();
        } else {
            search.handleInput();
            tl.handleInput();
            cluster_filter.handleInput();
            if (rl.isKeyPressed(rl.KEY_G)) {
                phys.toggle();
            }
        }
        tl.update(dt);

        // --- Drawing ---
        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        const keyframes = nd.keyframes.items;
        if (keyframes.len == 0) {
            // Loading screen
            rl.drawTextEx(font, "CASSANDRA", rl.vec2(20, 20), 24, 2.0, constants.HUD_COLOR);
            rl.drawTextEx(font, "WordNet Nucleus Observer", rl.vec2(20, 52), 11, 1.0, constants.HUD_DIM);
            rl.drawTextEx(font, "Loading snapshots...", rl.vec2(20, 72), 14, 1.0, constants.HUD_DIM);
            rl.drawFPS(sw - 90, sh - 60);
            rl.endDrawing();
            continue;
        }

        const ki = @min(tl.keyframeIndex(), @as(u32, @intCast(keyframes.len - 1)));
        const frac = tl.interpFraction();

        const current_points: []const data.Point = blk: {
            if (frac < 0.01 or ki >= keyframes.len - 1) {
                break :blk keyframes[ki].points;
            } else {
                if (interp_buf) |buf| allocator.free(buf);
                interp_buf = try timeline_mod.lerpPoints(
                    keyframes[ki].points,
                    keyframes[ki + 1].points,
                    frac,
                    allocator,
                );
                break :blk interp_buf.?;
            }
        };

        const cur_kf = keyframes[ki];

        // --- Physics integration ---
        if (phys.isActive()) {
            if (ki != prev_ki) {
                try phys.syncToPoints(current_points, cur_kf.max_delta);
                prev_ki = ki;
            } else {
                const md = @max(cur_kf.max_delta, 1.0);
                for (current_points, 0..) |p, idx| {
                    if (idx < phys.count and phys.name_indices[idx] == p.name_idx) {
                        phys.activity[idx] = p.delta / md;
                    }
                }
            }
            phys.step(dt);
            phys.updateBlend(dt);

            if (phys_buf) |buf| allocator.free(buf);
            phys_buf = try allocator.alloc(data.Point, current_points.len);
            @memcpy(phys_buf.?, current_points);
            phys.applyToPoints(phys_buf.?);
        } else {
            phys.updateBlend(dt);
        }

        const render_points: []const data.Point = if (phys.isActive())
            phys_buf.?
        else
            current_points;

        cam_state.update(render_points, sw, sh);

        rl.beginMode2D(cam_state.cam);
        render.drawGrid(cam_state.cam, sw, sh);
        render.drawConnectionLines(render_points, &nd, &cluster_filter);
        render.drawGlow(render_points, cur_kf.max_delta, &cluster_filter);
        render.drawDots(render_points, cur_kf.max_total, cur_kf.max_delta, &cluster_filter);
        render.drawAttractorRings(render_points, &cluster_filter);

        if (cam_state.selected_point) |sel| {
            render.drawHighlight(render_points, sel);
        }
        if (search.len > 0) {
            render.drawSearchHighlights(render_points, &nd, search.query());
        }
        rl.endMode2D();

        render.drawLabels(render_points, &nd, cam_state.cam, font, &cluster_filter, cur_kf.max_delta);
        render.drawVignette(sw, sh);

        ui.drawHUD(font, cur_kf.timestamp, cur_kf.num_visible, cur_kf.num_hot, @intCast(keyframes.len), &tl, phys.isActive());
        ui.drawScrubber(&tl, font, sw, sh);
        ui.drawClusterFilter(&cluster_filter, sw);
        ui.drawSearchBar(&search, font, sw);

        if (cam_state.selected_point) |sel| {
            ui.drawDetailPanel(render_points, sel, &nd, font, sw);
        }

        rl.drawFPS(sw - 90, sh - 60);
        rl.endDrawing();
    }
}
