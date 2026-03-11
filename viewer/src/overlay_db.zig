const std = @import("std");
const ais_mod = @import("overlays/ais.zig");
const adsb_mod = @import("overlays/adsb.zig");
const worldmap_mod = @import("worldmap.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const OverlayDb = struct {
    db: *c.sqlite3,
    stmt_upsert_vessel: *c.sqlite3_stmt,
    stmt_upsert_aircraft: *c.sqlite3_stmt,
    stmt_load_vessels: *c.sqlite3_stmt,
    stmt_load_aircraft: *c.sqlite3_stmt,
    stmt_get_photo: *c.sqlite3_stmt,
    stmt_put_photo: *c.sqlite3_stmt,

    pub fn open(path: [*:0]const u8) ?OverlayDb {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(path, &handle, flags, null) != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            std.debug.print("overlay_db: open failed\n", .{});
            return null;
        }
        const db = handle.?;

        // WAL mode
        _ = execSimple(db, "PRAGMA journal_mode=WAL");
        _ = execSimple(db, "PRAGMA synchronous=NORMAL");

        // Create tables
        _ = execSimple(db,
            \\CREATE TABLE IF NOT EXISTS vessels (
            \\    mmsi INTEGER PRIMARY KEY,
            \\    imo INTEGER DEFAULT 0,
            \\    name TEXT DEFAULT '',
            \\    ship_type INTEGER DEFAULT 0,
            \\    x REAL, y REAL,
            \\    course REAL DEFAULT 0,
            \\    speed REAL DEFAULT 0,
            \\    last_seen INTEGER DEFAULT 0
            \\)
        );
        _ = execSimple(db,
            \\CREATE TABLE IF NOT EXISTS aircraft (
            \\    icao TEXT PRIMARY KEY,
            \\    callsign TEXT DEFAULT '',
            \\    x REAL, y REAL,
            \\    altitude REAL DEFAULT 0,
            \\    heading REAL DEFAULT 0,
            \\    velocity REAL DEFAULT 0,
            \\    on_ground INTEGER DEFAULT 0,
            \\    last_seen INTEGER DEFAULT 0
            \\)
        );
        _ = execSimple(db,
            \\CREATE TABLE IF NOT EXISTS photos (
            \\    key TEXT PRIMARY KEY,
            \\    format TEXT NOT NULL,
            \\    bytes BLOB NOT NULL,
            \\    fetched_at INTEGER DEFAULT 0
            \\)
        );

        const s1 = prepare(db,
            \\INSERT OR REPLACE INTO vessels (mmsi, imo, name, ship_type, x, y, course, speed, last_seen)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ) orelse return null;
        const s2 = prepare(db,
            \\INSERT OR REPLACE INTO aircraft (icao, callsign, x, y, altitude, heading, velocity, on_ground, last_seen)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ) orelse return null;
        const s3 = prepare(db, "SELECT mmsi, imo, name, ship_type, x, y, course, speed FROM vessels ORDER BY mmsi") orelse return null;
        const s4 = prepare(db, "SELECT icao, callsign, x, y, altitude, heading, velocity, on_ground FROM aircraft ORDER BY icao") orelse return null;
        const s5 = prepare(db, "SELECT format, bytes FROM photos WHERE key = ?1") orelse return null;
        const s6 = prepare(db,
            \\INSERT OR REPLACE INTO photos (key, format, bytes, fetched_at)
            \\VALUES (?1, ?2, ?3, ?4)
        ) orelse return null;

        std.debug.print("overlay_db: opened {s}\n", .{path});

        return .{
            .db = db,
            .stmt_upsert_vessel = s1,
            .stmt_upsert_aircraft = s2,
            .stmt_load_vessels = s3,
            .stmt_load_aircraft = s4,
            .stmt_get_photo = s5,
            .stmt_put_photo = s6,
        };
    }

    pub fn close(self: *OverlayDb) void {
        _ = c.sqlite3_finalize(self.stmt_upsert_vessel);
        _ = c.sqlite3_finalize(self.stmt_upsert_aircraft);
        _ = c.sqlite3_finalize(self.stmt_load_vessels);
        _ = c.sqlite3_finalize(self.stmt_load_aircraft);
        _ = c.sqlite3_finalize(self.stmt_get_photo);
        _ = c.sqlite3_finalize(self.stmt_put_photo);
        _ = c.sqlite3_close(self.db);
        std.debug.print("overlay_db: closed\n", .{});
    }

    pub fn upsertVessel(self: *OverlayDb, v: ais_mod.Vessel) void {
        const s = self.stmt_upsert_vessel;
        _ = c.sqlite3_reset(s);
        _ = c.sqlite3_bind_int64(s, 1, @intCast(v.mmsi));
        _ = c.sqlite3_bind_int64(s, 2, @intCast(v.imo));
        if (v.name_len > 0) {
            _ = c.sqlite3_bind_text(s, 3, @ptrCast(&v.name), @intCast(v.name_len), c.SQLITE_TRANSIENT);
        } else {
            _ = c.sqlite3_bind_text(s, 3, "", 0, c.SQLITE_STATIC);
        }
        _ = c.sqlite3_bind_int64(s, 4, @intCast(v.ship_type));
        _ = c.sqlite3_bind_double(s, 5, @floatCast(v.x));
        _ = c.sqlite3_bind_double(s, 6, @floatCast(v.y));
        _ = c.sqlite3_bind_double(s, 7, @floatCast(v.course));
        _ = c.sqlite3_bind_double(s, 8, @floatCast(v.speed));
        _ = c.sqlite3_bind_int64(s, 9, std.time.timestamp());
        _ = c.sqlite3_step(s);
    }

    pub fn upsertAircraftBatch(self: *OverlayDb, aircraft: []const adsb_mod.Aircraft) void {
        _ = execSimple(self.db, "BEGIN");
        for (aircraft) |ac| {
            const s = self.stmt_upsert_aircraft;
            _ = c.sqlite3_reset(s);
            // ICAO as text
            var icao_len: usize = 6;
            while (icao_len > 0 and ac.icao[icao_len - 1] == 0) icao_len -= 1;
            if (icao_len == 0) continue;
            _ = c.sqlite3_bind_text(s, 1, @ptrCast(&ac.icao), @intCast(icao_len), c.SQLITE_TRANSIENT);
            // Callsign
            if (ac.callsign_len > 0) {
                _ = c.sqlite3_bind_text(s, 2, @ptrCast(&ac.callsign), @intCast(ac.callsign_len), c.SQLITE_TRANSIENT);
            } else {
                _ = c.sqlite3_bind_text(s, 2, "", 0, c.SQLITE_STATIC);
            }
            _ = c.sqlite3_bind_double(s, 3, @floatCast(ac.x));
            _ = c.sqlite3_bind_double(s, 4, @floatCast(ac.y));
            _ = c.sqlite3_bind_double(s, 5, @floatCast(ac.altitude));
            _ = c.sqlite3_bind_double(s, 6, @floatCast(ac.heading));
            _ = c.sqlite3_bind_double(s, 7, @floatCast(ac.velocity));
            _ = c.sqlite3_bind_int64(s, 8, if (ac.on_ground) 1 else 0);
            _ = c.sqlite3_bind_int64(s, 9, std.time.timestamp());
            _ = c.sqlite3_step(s);
        }
        _ = execSimple(self.db, "COMMIT");
    }

    pub fn loadAllVessels(self: *OverlayDb, buf: []ais_mod.Vessel) usize {
        const s = self.stmt_load_vessels;
        _ = c.sqlite3_reset(s);
        var count: usize = 0;
        while (c.sqlite3_step(s) == c.SQLITE_ROW) {
            if (count >= buf.len) break;
            var v = ais_mod.Vessel{
                .x = @floatCast(c.sqlite3_column_double(s, 4)),
                .y = @floatCast(c.sqlite3_column_double(s, 5)),
            };
            v.mmsi = @intCast(c.sqlite3_column_int64(s, 0));
            v.imo = @intCast(c.sqlite3_column_int64(s, 1));
            // Name
            const name_ptr = c.sqlite3_column_text(s, 2);
            const name_len: usize = @intCast(c.sqlite3_column_bytes(s, 2));
            if (name_ptr != null and name_len > 0) {
                const copy_len = @min(name_len, 20);
                @memcpy(v.name[0..copy_len], name_ptr[0..copy_len]);
                v.name_len = @intCast(copy_len);
            }
            v.ship_type = @intCast(c.sqlite3_column_int64(s, 3));
            v.course = @floatCast(c.sqlite3_column_double(s, 6));
            v.speed = @floatCast(c.sqlite3_column_double(s, 7));
            buf[count] = v;
            count += 1;
        }
        std.debug.print("overlay_db: loaded {d} vessels\n", .{count});
        return count;
    }

    pub fn loadAllAircraft(self: *OverlayDb, buf: []adsb_mod.Aircraft) usize {
        const s = self.stmt_load_aircraft;
        _ = c.sqlite3_reset(s);
        var count: usize = 0;
        while (c.sqlite3_step(s) == c.SQLITE_ROW) {
            if (count >= buf.len) break;
            var ac = adsb_mod.Aircraft{
                .x = @floatCast(c.sqlite3_column_double(s, 2)),
                .y = @floatCast(c.sqlite3_column_double(s, 3)),
            };
            // ICAO
            const icao_ptr = c.sqlite3_column_text(s, 0);
            const icao_len: usize = @intCast(c.sqlite3_column_bytes(s, 0));
            if (icao_ptr != null and icao_len > 0) {
                const copy_len = @min(icao_len, 6);
                @memcpy(ac.icao[0..copy_len], icao_ptr[0..copy_len]);
                ac.icao_len = @intCast(copy_len);
            }
            // Callsign
            const cs_ptr = c.sqlite3_column_text(s, 1);
            const cs_len: usize = @intCast(c.sqlite3_column_bytes(s, 1));
            if (cs_ptr != null and cs_len > 0) {
                const copy_len = @min(cs_len, 8);
                @memcpy(ac.callsign[0..copy_len], cs_ptr[0..copy_len]);
                ac.callsign_len = @intCast(copy_len);
            }
            ac.altitude = @floatCast(c.sqlite3_column_double(s, 4));
            ac.heading = @floatCast(c.sqlite3_column_double(s, 5));
            ac.velocity = @floatCast(c.sqlite3_column_double(s, 6));
            ac.on_ground = c.sqlite3_column_int64(s, 7) != 0;
            buf[count] = ac;
            count += 1;
        }
        std.debug.print("overlay_db: loaded {d} aircraft\n", .{count});
        return count;
    }

    pub const PhotoResult = struct {
        bytes: []u8,
        format: []u8,
    };

    pub fn getPhoto(self: *OverlayDb, key_str: []const u8) ?PhotoResult {
        const s = self.stmt_get_photo;
        _ = c.sqlite3_reset(s);
        _ = c.sqlite3_bind_text(s, 1, @ptrCast(key_str.ptr), @intCast(key_str.len), c.SQLITE_TRANSIENT);
        if (c.sqlite3_step(s) != c.SQLITE_ROW) return null;

        // Format
        const fmt_ptr = c.sqlite3_column_text(s, 0);
        const fmt_len: usize = @intCast(c.sqlite3_column_bytes(s, 0));
        if (fmt_ptr == null or fmt_len == 0) return null;

        // Bytes
        const blob_ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(s, 1));
        const blob_len: usize = @intCast(c.sqlite3_column_bytes(s, 1));
        if (blob_ptr == null or blob_len == 0) return null;

        // Copy to owned memory
        const format = std.heap.page_allocator.alloc(u8, fmt_len) catch return null;
        @memcpy(format, fmt_ptr[0..fmt_len]);
        const bytes = std.heap.page_allocator.alloc(u8, blob_len) catch {
            std.heap.page_allocator.free(format);
            return null;
        };
        @memcpy(bytes, blob_ptr.?[0..blob_len]);

        return .{ .bytes = bytes, .format = format };
    }

    pub fn putPhoto(self: *OverlayDb, key_str: []const u8, format: []const u8, bytes: []const u8) void {
        const s = self.stmt_put_photo;
        _ = c.sqlite3_reset(s);
        _ = c.sqlite3_bind_text(s, 1, @ptrCast(key_str.ptr), @intCast(key_str.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(s, 2, @ptrCast(format.ptr), @intCast(format.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_blob(s, 3, @ptrCast(bytes.ptr), @intCast(bytes.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int64(s, 4, std.time.timestamp());
        _ = c.sqlite3_step(s);
    }
};

fn prepare(db: *c.sqlite3, sql: [*:0]const u8) ?*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        const err = c.sqlite3_errmsg(db);
        std.debug.print("overlay_db: prepare failed: {s}\n", .{err});
        return null;
    }
    return stmt.?;
}

fn execSimple(db: *c.sqlite3, sql: [*:0]const u8) c_int {
    return c.sqlite3_exec(db, sql, null, null, null);
}
