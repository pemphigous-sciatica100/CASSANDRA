const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const render = @import("render.zig");
const camera = @import("camera.zig");
const timeline_mod = @import("timeline.zig");
const ui = @import("ui.zig");
const constants = @import("constants.zig");
const physics = @import("physics.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.debug.print("CASSANDRA Nucleus Viewer\n", .{});
    std.debug.print("Loading data...\n", .{});

    var nd = data.NucleusData.init(allocator);

    // Load positions
    try data.loadPositions(&nd, "../nucleus_positions.json");
    std.debug.print("Loaded {d} positions\n", .{nd.positions.count()});

    // Scan for snapshots
    const timestamps = try data.scanSnapshots(allocator, "../snapshots");
    std.debug.print("Found {d} snapshot timestamps\n", .{timestamps.len});

    if (timestamps.len == 0) {
        std.debug.print("ERROR: No snapshots found in ../snapshots/\n", .{});
        return;
    }

    // Load the latest snapshot to determine attractors
    var latest_snapshot = try data.loadSnapshot(&nd, timestamps[timestamps.len - 1].snap_path);
    const attractor_synsets = try data.findAttractors(&latest_snapshot, allocator);
    std.debug.print("Attractors: ", .{});
    for (attractor_synsets) |a| {
        std.debug.print("{s} ", .{a});
    }
    std.debug.print("\n", .{});

    // K-means on attractors
    const k: u8 = @intCast(@min(constants.NUM_CLUSTERS, attractor_synsets.len));
    const attractor_labels = try data.kmeansAttractors(attractor_synsets, &nd.anchors, k, allocator);

    // Store attractor name indices
    for (attractor_synsets, 0..) |aname, i| {
        nd.attractor_names[i] = nd.name_to_idx.get(aname) orelse 0;
    }
    nd.num_attractors = attractor_synsets.len;

    // Reconstruct recency for each timestamp
    std.debug.print("Reconstructing recency...\n", .{});
    const recencies = try data.reconstructRecency(timestamps, &nd);

    // Build keyframes
    // Stretch x positions to fill widescreen
    const x_scale: f32 = @as(f32, @floatFromInt(constants.WINDOW_W)) / @as(f32, @floatFromInt(constants.WINDOW_H));

    // Track loaded timestamps for live reload detection
    var loaded_timestamps = std.StringHashMap(void).init(allocator);

    // Running recency — kept alive for incremental keyframe building
    var running_recency = std.StringHashMap(u32).init(allocator);

    std.debug.print("Building keyframes (x_scale={d:.2})...\n", .{x_scale});
    var prev_snap: ?std.StringHashMap(data.SnapshotEntry) = null;
    for (timestamps, 0..) |ts_info, ti| {
        var snapshot = try data.loadSnapshot(&nd, ts_info.snap_path);
        var delta_map = data.loadDelta(&nd, ts_info.delta_path) catch std.StringHashMap(i64).init(allocator);

        const kf = try data.buildKeyframe(
            &nd,
            &snapshot,
            &delta_map,
            &recencies[ti],
            if (prev_snap) |*ps| ps else null,
            attractor_synsets,
            attractor_labels,
            ts_info.timestamp,
            x_scale,
        );
        try nd.keyframes.append(kf);

        std.debug.print("  Keyframe {s}: {d} points, max_delta={d:.0}\n", .{
            ts_info.timestamp, kf.points.len, kf.max_delta,
        });

        // Seed loaded_timestamps
        try loaded_timestamps.put(ts_info.timestamp, {});

        if (prev_snap) |*ps| ps.deinit();
        prev_snap = snapshot;
    }

    // Seed running_recency from the last reconstructed recency
    if (recencies.len > 0) {
        var rc_it = recencies[recencies.len - 1].iterator();
        while (rc_it.next()) |entry| {
            try running_recency.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // latest_snapshot was only needed for findAttractors — deinit it now
    latest_snapshot.deinit();

    std.debug.print("Ready! {d} keyframes, {d} names\n", .{
        nd.keyframes.items.len,
        nd.synset_names.items.len,
    });

    // --- Raylib init ---
    rl.setConfigFlags(rl.FLAG_MSAA_4X_HINT | rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.initWindow(constants.WINDOW_W, constants.WINDOW_H, "CASSANDRA — Nucleus Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(constants.TARGET_FPS);

    const font = rl.getFontDefault();

    // Compute bounds from the last keyframe (has all points)
    const bounds = camera.computeBounds(nd.keyframes.items[nd.keyframes.items.len - 1].points);
    var cam_state = camera.CameraState.init(bounds, rl.getScreenWidth(), rl.getScreenHeight());
    var tl = timeline_mod.Timeline.init(@intCast(nd.keyframes.items.len));
    try tl.computeTickFracs(nd.keyframes.items, allocator);
    var search = ui.SearchState{};
    var cluster_filter = ui.ClusterFilter{};

    var interp_buf: ?[]data.Point = null;
    var phys = physics.PhysicsState.init(allocator);
    var phys_buf: ?[]data.Point = null;
    var prev_ki: u32 = std.math.maxInt(u32);
    var scan_timer: f32 = 0;

    // Background loader state
    var loader = BgLoader.init(allocator);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();

        // --- Live reload (threaded) ---
        scan_timer += dt;
        // Check if background load completed
        if (loader.tryGetResult()) |result| {
            const was_at_end = tl.wasAtEnd();
            // Parse + build keyframe on main thread (data is already in RAM)
            integrateLoadResult(
                allocator,
                &nd,
                &loaded_timestamps,
                &running_recency,
                &prev_snap,
                attractor_synsets,
                attractor_labels,
                x_scale,
                result,
            ) catch {};
            tl.num_keyframes = @intCast(nd.keyframes.items.len);
            tl.computeTickFracs(nd.keyframes.items, allocator) catch {};
            if (was_at_end) {
                tl.follow_target = @floatFromInt(tl.num_keyframes - 1);
            }
            scan_timer = 0; // reset so we don't immediately re-scan
        }
        // Kick off a new background scan every 2s if not already loading
        if (scan_timer >= 2.0 and !loader.isBusy()) {
            scan_timer = 0;
            loader.startScan(&loaded_timestamps);
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

        // Current points
        const keyframes = nd.keyframes.items;
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
            // Re-sync when keyframe changes or on every frame to track interpolated activity
            if (ki != prev_ki) {
                try phys.syncToPoints(current_points, cur_kf.max_delta);
                prev_ki = ki;
            } else {
                // Update activity values from interpolated points each frame
                const md = @max(cur_kf.max_delta, 1.0);
                for (current_points, 0..) |p, idx| {
                    if (idx < phys.count and phys.name_indices[idx] == p.name_idx) {
                        phys.activity[idx] = p.delta / md;
                    }
                }
            }
            phys.step(dt);
            phys.updateBlend(dt);

            // Copy points into mutable buffer and apply physics positions
            if (phys_buf) |buf| allocator.free(buf);
            phys_buf = try allocator.alloc(data.Point, current_points.len);
            @memcpy(phys_buf.?, current_points);
            phys.applyToPoints(phys_buf.?);
        } else {
            phys.updateBlend(dt); // finish blending_out transition
        }

        const render_points: []const data.Point = if (phys.isActive())
            phys_buf.?
        else
            current_points;

        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        cam_state.update(render_points, sw, sh);

        // --- Drawing ---
        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        // World-space (through Camera2D)
        rl.beginMode2D(cam_state.cam);
        render.drawGrid(cam_state.cam, sw, sh);
        render.drawConnectionLines(render_points, &nd, &cluster_filter);
        render.drawGlow(render_points, cur_kf.max_delta, &cluster_filter);
        render.drawDots(render_points, cur_kf.max_total, cur_kf.max_delta, &cluster_filter);
        render.drawAttractorRings(render_points, &cluster_filter);
        render.drawUncertaintyArrows(render_points, &cluster_filter);
        if (cam_state.selected_point) |sel| {
            render.drawHighlight(render_points, sel);
        }
        if (search.len > 0) {
            render.drawSearchHighlights(render_points, &nd, search.query());
        }
        rl.endMode2D();

        // Screen-space
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

/// Result produced by background loader thread — raw file bytes, no parsing.
const LoadResult = struct {
    timestamp: [20]u8,
    ts_len: u8,
    snap_bytes: []u8,
    delta_bytes: []u8,
    pos_bytes: ?[]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *LoadResult) void {
        self.allocator.free(self.snap_bytes);
        self.allocator.free(self.delta_bytes);
        if (self.pos_bytes) |b| self.allocator.free(b);
    }
};

/// Background file loader — does dir scan + file reads on a separate thread.
const BgLoader = struct {
    allocator: std.mem.Allocator,
    result: ?LoadResult = null,
    busy: bool = false,
    thread: ?std.Thread = null,
    // Snapshot of loaded timestamps passed to thread (keys are stable arena strings)
    known_ts: ?std.StringHashMap(void) = null,

    fn init(alloc: std.mem.Allocator) BgLoader {
        return .{ .allocator = alloc };
    }

    fn isBusy(self: *BgLoader) bool {
        return self.busy;
    }

    fn tryGetResult(self: *BgLoader) ?LoadResult {
        if (self.busy) return null;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.result) |r| {
            self.result = null;
            if (self.known_ts) |*kt| {
                kt.deinit();
                self.known_ts = null;
            }
            return r;
        }
        return null;
    }

    fn startScan(self: *BgLoader, loaded_timestamps: *std.StringHashMap(void)) void {
        if (self.busy) return;
        // Clone the set of known timestamps (keys point to arena — stable)
        var clone = std.StringHashMap(void).init(self.allocator);
        var it = loaded_timestamps.iterator();
        while (it.next()) |entry| {
            clone.put(entry.key_ptr.*, {}) catch {};
        }
        self.known_ts = clone;
        self.busy = true;
        self.thread = std.Thread.spawn(.{}, bgWorker, .{self}) catch {
            self.busy = false;
            if (self.known_ts) |*kt| {
                kt.deinit();
                self.known_ts = null;
            }
            return;
        };
    }

    fn bgWorker(self: *BgLoader) void {
        defer self.busy = false;
        self.result = doLoad(self.allocator, &self.known_ts.?) catch null;
    }

    fn doLoad(alloc: std.mem.Allocator, known: *std.StringHashMap(void)) !LoadResult {
        // Scan directory for first unknown snapshot
        var dir = try std.fs.cwd().openDir("../snapshots", .{ .iterate = true });
        defer dir.close();

        // Collect unknown timestamps, find earliest
        var best_ts: ?[20]u8 = null;
        var best_len: u8 = 0;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (name.len >= 5 and std.mem.eql(u8, name[0..5], "snap_") and std.mem.endsWith(u8, name, ".json")) {
                const ts = name[5 .. name.len - 5];
                if (ts.len > 20) continue;
                if (!known.contains(ts)) {
                    if (best_ts == null or std.mem.order(u8, ts, best_ts.?[0..best_len]) == .lt) {
                        var buf: [20]u8 = undefined;
                        @memcpy(buf[0..ts.len], ts);
                        best_ts = buf;
                        best_len = @intCast(ts.len);
                    }
                }
            }
        }

        const ts_buf = best_ts orelse return error.NoNewSnapshots;
        const ts = ts_buf[0..best_len];

        // Read files
        const snap_path = try std.fmt.allocPrint(alloc, "../snapshots/snap_{s}.json", .{ts});
        defer alloc.free(snap_path);
        const delta_path = try std.fmt.allocPrint(alloc, "../snapshots/delta_{s}.json", .{ts});
        defer alloc.free(delta_path);

        const snap_bytes = readFileAlloc(alloc, snap_path) catch return error.ReadFailed;
        const delta_bytes = readFileAlloc(alloc, delta_path) catch {
            alloc.free(snap_bytes);
            return error.ReadFailed;
        };
        const pos_bytes = readFileAlloc(alloc, "../nucleus_positions.json") catch null;

        var result: LoadResult = .{
            .timestamp = ts_buf,
            .ts_len = best_len,
            .snap_bytes = snap_bytes,
            .delta_bytes = delta_bytes,
            .pos_bytes = pos_bytes,
            .allocator = alloc,
        };
        _ = &result;
        return result;
    }

    fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return try file.readToEndAlloc(alloc, 50 * 1024 * 1024);
    }
};

/// Parse pre-loaded bytes and integrate into the live viewer state.
/// All JSON parsing happens here on the main thread, but from RAM — no disk I/O.
fn integrateLoadResult(
    allocator: std.mem.Allocator,
    nd: *data.NucleusData,
    loaded_timestamps: *std.StringHashMap(void),
    running_recency: *std.StringHashMap(u32),
    prev_snap: *?std.StringHashMap(data.SnapshotEntry),
    attractor_synsets: []const []const u8,
    attractor_labels: []const u8,
    x_scale: f32,
    raw: LoadResult,
) !void {
    var result = raw;
    defer result.deinit();

    const ts = result.timestamp[0..result.ts_len];

    // Reload positions from pre-read bytes
    if (result.pos_bytes) |pos_bytes| {
        parsePositionsFromBytes(nd, pos_bytes) catch {};
    }

    // Parse snapshot from bytes
    var snapshot = parseSnapshotFromBytes(nd, result.snap_bytes) catch return;
    var delta_map = parseDeltaFromBytes(nd, result.delta_bytes) catch std.StringHashMap(i64).init(allocator);

    // Update running_recency
    var age_it = running_recency.iterator();
    while (age_it.next()) |entry| {
        entry.value_ptr.* += 1;
    }
    var delta_it = delta_map.iterator();
    while (delta_it.next()) |d_entry| {
        const arena = nd.string_arena.allocator();
        const key = arena.dupe(u8, d_entry.key_ptr.*) catch continue;
        running_recency.put(key, 0) catch {};
    }
    const evict_threshold: u32 = @intFromFloat(constants.FADE_WINDOW * 2);
    {
        var remove_list = std.ArrayList([]const u8).init(allocator);
        defer remove_list.deinit();
        var rm_it = running_recency.iterator();
        while (rm_it.next()) |entry| {
            if (entry.value_ptr.* > evict_threshold) {
                remove_list.append(entry.key_ptr.*) catch {};
            }
        }
        for (remove_list.items) |key| {
            _ = running_recency.remove(key);
        }
    }

    // Copy timestamp to arena
    const arena = nd.string_arena.allocator();
    const ts_copy = try arena.dupe(u8, ts);

    const kf = try data.buildKeyframe(
        nd,
        &snapshot,
        &delta_map,
        running_recency,
        if (prev_snap.*) |*ps| ps else null,
        attractor_synsets,
        attractor_labels,
        ts_copy,
        x_scale,
    );
    try nd.keyframes.append(kf);

    if (prev_snap.*) |*ps| ps.deinit();
    prev_snap.* = snapshot;

    try loaded_timestamps.put(ts_copy, {});
    std.debug.print("Live: loaded {s} ({d} points)\n", .{ ts, kf.points.len });
}

/// Parse positions JSON from in-memory bytes (idempotent — skips existing keys)
fn parsePositionsFromBytes(nd: *data.NucleusData, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, nd.allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (nd.positions.contains(name)) continue;
        const arr = entry.value_ptr.array.items;
        const x: f32 = switch (arr[0]) {
            .float => @floatCast(arr[0].float),
            .integer => @floatFromInt(arr[0].integer),
            else => 0.0,
        };
        const y: f32 = switch (arr[1]) {
            .float => @floatCast(arr[1].float),
            .integer => @floatFromInt(arr[1].integer),
            else => 0.0,
        };
        const arena = nd.string_arena.allocator();
        const name_copy = try arena.dupe(u8, name);
        try nd.positions.put(name_copy, .{ x, y });
    }
}

/// Parse snapshot JSON from in-memory bytes
fn parseSnapshotFromBytes(nd: *data.NucleusData, bytes: []const u8) !std.StringHashMap(data.SnapshotEntry) {
    const parsed = try std.json.parseFromSlice(std.json.Value, nd.allocator, bytes, .{});
    defer parsed.deinit();

    var result = std.StringHashMap(data.SnapshotEntry).init(nd.allocator);
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const val = entry.value_ptr.object;

        const word_val = val.get("word") orelse continue;
        const word = switch (word_val) {
            .string => |s| s,
            else => continue,
        };
        const uc_val = val.get("update_count") orelse continue;
        const uc: i64 = switch (uc_val) {
            .integer => uc_val.integer,
            else => 0,
        };
        const ec_val = val.get("exemplar_count") orelse continue;
        const ec: i64 = switch (ec_val) {
            .integer => ec_val.integer,
            else => 0,
        };
        const unc_val = val.get("uncertainty") orelse continue;
        const unc: f64 = switch (unc_val) {
            .float => unc_val.float,
            .integer => @floatFromInt(unc_val.integer),
            else => 0.0,
        };

        if (val.get("anchor")) |anc_val| {
            if (anc_val == .array) {
                const items = anc_val.array.items;
                var anchor_f32: [constants.ANCHOR_DIM]f32 = undefined;
                for (0..@min(constants.ANCHOR_DIM, items.len)) |i| {
                    anchor_f32[i] = switch (items[i]) {
                        .float => @floatCast(items[i].float),
                        .integer => @floatFromInt(items[i].integer),
                        else => 0.0,
                    };
                }
                const arena = nd.string_arena.allocator();
                const akey = try arena.dupe(u8, name);
                try nd.anchors.put(akey, anchor_f32);
            }
        }

        const arena = nd.string_arena.allocator();
        const name_copy = try arena.dupe(u8, name);
        const word_copy = try arena.dupe(u8, word);
        _ = try nd.getOrAddName(name_copy, word_copy);

        try result.put(name_copy, .{
            .word = word_copy,
            .update_count = uc,
            .exemplar_count = ec,
            .uncertainty = unc,
            .anchor = undefined,
        });
    }
    return result;
}

/// Parse delta JSON from in-memory bytes
fn parseDeltaFromBytes(nd: *data.NucleusData, bytes: []const u8) !std.StringHashMap(i64) {
    const parsed = try std.json.parseFromSlice(std.json.Value, nd.allocator, bytes, .{});
    defer parsed.deinit();

    var result = std.StringHashMap(i64).init(nd.allocator);
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const arena = nd.string_arena.allocator();
        const name_copy = try arena.dupe(u8, entry.key_ptr.*);
        const v: i64 = switch (entry.value_ptr.*) {
            .integer => entry.value_ptr.integer,
            else => 0,
        };
        try result.put(name_copy, v);
    }
    return result;
}
