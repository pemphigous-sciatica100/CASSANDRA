const std = @import("std");
const rl = @import("rl.zig");
const overlay_db_mod = @import("overlay_db.zig");

const MAX_CACHE: usize = 128;
const MAX_QUEUE: usize = 8;

pub const VesselId = struct { mmsi: u32, imo: u32 };

pub const PhotoKey = union(enum) {
    icao: [6]u8,
    vessel: VesselId,

    pub fn eql(a: PhotoKey, b: PhotoKey) bool {
        return switch (a) {
            .icao => |ai| switch (b) {
                .icao => |bi| std.mem.eql(u8, &ai, &bi),
                else => false,
            },
            .vessel => |av| switch (b) {
                .vessel => |bv| av.mmsi == bv.mmsi,
                else => false,
            },
        };
    }

    pub fn hash(self: PhotoKey) u64 {
        var h = std.hash.Wyhash.init(0);
        switch (self) {
            .icao => |v| {
                h.update(&[_]u8{0}); // tag
                h.update(&v);
            },
            .vessel => |v| {
                h.update(&[_]u8{1}); // tag
                h.update(std.mem.asBytes(&v.mmsi));
            },
        }
        return h.final();
    }
};

pub const CacheEntry = union(enum) {
    pending,
    not_found,
    loaded: rl.c.Texture2D,
};

const Response = struct {
    key: PhotoKey,
    image_bytes: ?[]u8,
};

pub const PhotoCache = struct {
    // Cache: ordered map for FIFO eviction
    cache_keys: [MAX_CACHE]PhotoKey = undefined,
    cache_vals: [MAX_CACHE]CacheEntry = undefined,
    cache_len: usize = 0,

    // Request queue: main → worker
    req_queue: [MAX_QUEUE]PhotoKey = undefined,
    req_len: usize = 0,

    // Response queue: worker → main
    resp_queue: [MAX_QUEUE]Response = undefined,
    resp_len: usize = 0,

    mutex: std.Thread.Mutex = .{},
    worker: ?std.Thread = null,
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    overlay_db: ?*overlay_db_mod.OverlayDb = null,

    pub fn start(self: *PhotoCache) void {
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
    }

    pub fn shutdown(self: *PhotoCache) void {
        self.shutdown_flag.store(true, .release);
        if (self.worker) |w| {
            w.join();
            self.worker = null;
        }
    }

    pub fn deinit(self: *PhotoCache) void {
        // Unload all textures
        for (self.cache_vals[0..self.cache_len]) |entry| {
            switch (entry) {
                .loaded => |tex| rl.c.UnloadTexture(tex),
                else => {},
            }
        }
        self.cache_len = 0;
        // Free any unprocessed response bytes
        self.mutex.lock();
        for (self.resp_queue[0..self.resp_len]) |resp| {
            if (resp.image_bytes) |bytes| std.heap.page_allocator.free(bytes);
        }
        self.resp_len = 0;
        self.mutex.unlock();
    }

    /// Enqueue a photo request if not already cached or pending.
    pub fn requestPhoto(self: *PhotoCache, key: PhotoKey) void {
        // Check cache first (no lock needed, only main thread touches cache)
        if (self.cacheFind(key) != null) return;

        // Insert as pending in cache immediately (main thread only)
        self.cacheInsertPending(key);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already in request queue
        for (self.req_queue[0..self.req_len]) |rk| {
            if (rk.eql(key)) return;
        }
        if (self.req_len >= MAX_QUEUE) return; // queue full, drop
        self.req_queue[self.req_len] = key;
        self.req_len += 1;
    }

    /// Look up a texture in cache. Returns null if not cached.
    pub fn getTexture(self: *const PhotoCache, key: PhotoKey) ?rl.c.Texture2D {
        if (self.cacheFind(key)) |idx| {
            return switch (self.cache_vals[idx]) {
                .loaded => |tex| tex,
                else => null,
            };
        }
        return null;
    }

    /// Get the cache state for a key.
    pub fn getState(self: *const PhotoCache, key: PhotoKey) ?CacheEntry {
        if (self.cacheFind(key)) |idx| {
            return self.cache_vals[idx];
        }
        return null;
    }

    /// Drain response queue and convert image bytes → GPU textures.
    /// MUST be called from the main/render thread only.
    pub fn processCompleted(self: *PhotoCache) void {
        self.mutex.lock();
        const n = self.resp_len;
        var resps: [MAX_QUEUE]Response = undefined;
        @memcpy(resps[0..n], self.resp_queue[0..n]);
        self.resp_len = 0;
        self.mutex.unlock();

        for (resps[0..n]) |resp| {
            // Remove pending entry if it exists
            if (self.cacheFind(resp.key)) |idx| {
                // Already have an entry (pending) — update in place
                if (resp.image_bytes) |bytes| {
                    defer std.heap.page_allocator.free(bytes);
                    const fmt = detectFormat(bytes);
                    const img = rl.c.LoadImageFromMemory(fmt, bytes.ptr, @intCast(bytes.len));
                    if (img.data != null) {
                        const tex = rl.c.LoadTextureFromImage(img);
                        rl.c.UnloadImage(img);
                        self.cache_vals[idx] = .{ .loaded = tex };
                    } else {
                        self.cache_vals[idx] = .not_found;
                    }
                } else {
                    self.cache_vals[idx] = .not_found;
                }
            }
        }
    }

    fn cacheFind(self: *const PhotoCache, key: PhotoKey) ?usize {
        for (self.cache_keys[0..self.cache_len], 0..) |k, i| {
            if (k.eql(key)) return i;
        }
        return null;
    }

    fn cacheInsertPending(self: *PhotoCache, key: PhotoKey) void {
        if (self.cacheFind(key) != null) return;
        if (self.cache_len >= MAX_CACHE) {
            // Evict oldest (index 0)
            switch (self.cache_vals[0]) {
                .loaded => |tex| rl.c.UnloadTexture(tex),
                else => {},
            }
            // Shift down
            for (1..self.cache_len) |i| {
                self.cache_keys[i - 1] = self.cache_keys[i];
                self.cache_vals[i - 1] = self.cache_vals[i];
            }
            self.cache_len -= 1;
        }
        self.cache_keys[self.cache_len] = key;
        self.cache_vals[self.cache_len] = .pending;
        self.cache_len += 1;
    }

    // ---------------------------------------------------------------
    // Worker thread
    // ---------------------------------------------------------------

    fn workerLoop(self: *PhotoCache) void {
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();

        while (!self.shutdown_flag.load(.acquire)) {
            // Drain request queue
            var keys: [MAX_QUEUE]PhotoKey = undefined;
            var n: usize = 0;
            {
                self.mutex.lock();
                n = self.req_len;
                @memcpy(keys[0..n], self.req_queue[0..n]);
                self.req_len = 0;
                self.mutex.unlock();
            }

            for (keys[0..n]) |key| {
                if (self.shutdown_flag.load(.acquire)) break;

                // Build DB key string
                var key_buf: [32]u8 = undefined;
                const key_str = photoKeyStr(key, &key_buf);

                // Check DB cache first
                var image_bytes: ?[]u8 = null;
                if (self.overlay_db) |db| {
                    if (db.getPhoto(key_str)) |cached| {
                        std.debug.print("PHOTO: cache hit for {s}\n", .{key_str});
                        image_bytes = cached.bytes;
                        std.heap.page_allocator.free(cached.format);
                    }
                }

                // Network fetch if not in DB
                if (image_bytes == null) {
                    image_bytes = switch (key) {
                        .icao => |icao| fetchAircraftPhoto(&client, &icao),
                        .vessel => |vid| fetchVesselPhoto(&client, vid.mmsi, vid.imo),
                    };

                    // Save to DB on successful fetch
                    if (image_bytes) |bytes| {
                        if (self.overlay_db) |db| {
                            const fmt = detectFormatSlice(bytes);
                            db.putPhoto(key_str, fmt, bytes);
                        }
                    }
                }

                // Push response
                self.mutex.lock();
                if (self.resp_len < MAX_QUEUE) {
                    self.resp_queue[self.resp_len] = .{ .key = key, .image_bytes = image_bytes };
                    self.resp_len += 1;
                } else {
                    // Queue full, discard
                    if (image_bytes) |bytes| std.heap.page_allocator.free(bytes);
                }
                self.mutex.unlock();
            }

            // Sleep 100ms between polls
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    // ---------------------------------------------------------------
    // Aircraft photo fetch (planespotters.net)
    // ---------------------------------------------------------------

    fn fetchAircraftPhoto(client: *std.http.Client, icao: *const [6]u8) ?[]u8 {
        // Build URL: https://api.planespotters.net/pub/photos/hex/{ICAO}
        var url_buf: [128]u8 = undefined;
        const prefix = "https://api.planespotters.net/pub/photos/hex/";
        @memcpy(url_buf[0..prefix.len], prefix);
        // Find actual length of ICAO (trim trailing zeros)
        var icao_len: usize = 6;
        while (icao_len > 0 and icao[icao_len - 1] == 0) icao_len -= 1;
        if (icao_len == 0) return null;
        @memcpy(url_buf[prefix.len..][0..icao_len], icao[0..icao_len]);
        url_buf[prefix.len + icao_len] = 0;

        const url_slice = url_buf[0 .. prefix.len + icao_len];
        std.debug.print("PHOTO: fetching aircraft {s}\n", .{url_slice});

        const uri = std.Uri.parse(url_slice) catch return null;
        const json_body = httpGet(client, uri, null) orelse return null;
        defer json_body.deinit();

        // Parse JSON: { "photos": [ { "thumbnail_large": { "src": "..." } } ] }
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_body.items, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;
        const photos = root.object.get("photos") orelse return null;
        if (photos != .array) return null;
        if (photos.array.items.len == 0) {
            std.debug.print("PHOTO: no aircraft photos found\n", .{});
            return null;
        }

        const first = photos.array.items[0];
        if (first != .object) return null;
        const thumb = first.object.get("thumbnail_large") orelse return null;
        if (thumb != .object) return null;
        const src_val = thumb.object.get("src") orelse return null;
        if (src_val != .string) return null;
        const src = src_val.string;

        std.debug.print("PHOTO: downloading {s}\n", .{src[0..@min(src.len, 80)]});

        // Fetch the actual image
        const img_uri = std.Uri.parse(src) catch return null;
        const img_body = httpGet(client, img_uri, null) orelse return null;
        // Transfer ownership — caller frees
        const result = std.heap.page_allocator.alloc(u8, img_body.items.len) catch {
            img_body.deinit();
            return null;
        };
        @memcpy(result, img_body.items);
        img_body.deinit();
        std.debug.print("PHOTO: got {d} bytes\n", .{result.len});
        return result;
    }

    // ---------------------------------------------------------------
    // Vessel photo fetch (Wikidata SPARQL)
    // ---------------------------------------------------------------

    fn fetchVesselPhoto(client: *std.http.Client, mmsi: u32, imo: u32) ?[]u8 {
        // Build SPARQL UNION query: try MMSI (P587) and IMO (P458)
        // SELECT ?image WHERE {
        //   { ?v wdt:P587 "MMSI". ?v wdt:P18 ?image }
        //   UNION
        //   { ?v wdt:P458 "IMO". ?v wdt:P18 ?image }
        // } LIMIT 1
        var query_buf: [512]u8 = undefined;
        var qi: usize = 0;

        const prefix = "SELECT ?image WHERE { ";
        @memcpy(query_buf[qi..][0..prefix.len], prefix);
        qi += prefix.len;

        // MMSI clause
        var mmsi_str: [16]u8 = undefined;
        const mmsi_slice = std.fmt.bufPrint(&mmsi_str, "{d}", .{mmsi}) catch return null;
        {
            const p1 = "{ ?v wdt:P587 \"";
            const p2 = "\". ?v wdt:P18 ?image }";
            @memcpy(query_buf[qi..][0..p1.len], p1);
            qi += p1.len;
            @memcpy(query_buf[qi..][0..mmsi_slice.len], mmsi_slice);
            qi += mmsi_slice.len;
            @memcpy(query_buf[qi..][0..p2.len], p2);
            qi += p2.len;
        }

        // IMO clause (only if we have one)
        if (imo > 0) {
            var imo_str: [16]u8 = undefined;
            const imo_slice = std.fmt.bufPrint(&imo_str, "{d}", .{imo}) catch return null;
            const un1 = " UNION { ?v wdt:P458 \"";
            const un2 = "\". ?v wdt:P18 ?image }";
            @memcpy(query_buf[qi..][0..un1.len], un1);
            qi += un1.len;
            @memcpy(query_buf[qi..][0..imo_slice.len], imo_slice);
            qi += imo_slice.len;
            @memcpy(query_buf[qi..][0..un2.len], un2);
            qi += un2.len;
        }

        const suffix = " } LIMIT 1";
        @memcpy(query_buf[qi..][0..suffix.len], suffix);
        qi += suffix.len;

        // URL-encode the query
        var encoded_buf: [2048]u8 = undefined;
        const encoded = urlEncode(query_buf[0..qi], &encoded_buf);

        // Build full URL
        const base = "https://query.wikidata.org/sparql?format=json&query=";
        var url_buf: [4096]u8 = undefined;
        @memcpy(url_buf[0..base.len], base);
        @memcpy(url_buf[base.len..][0..encoded.len], encoded);
        const url_slice = url_buf[0 .. base.len + encoded.len];

        if (imo > 0) {
            std.debug.print("PHOTO: fetching vessel MMSI={d} IMO={d}\n", .{ mmsi, imo });
        } else {
            std.debug.print("PHOTO: fetching vessel MMSI={d}\n", .{mmsi});
        }

        const uri = std.Uri.parse(url_slice) catch return null;
        const json_body = httpGet(client, uri, null) orelse return null;
        defer json_body.deinit();

        // Parse JSON: { "results": { "bindings": [ { "image": { "value": "..." } } ] } }
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_body.items, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;
        const results = root.object.get("results") orelse return null;
        if (results != .object) return null;
        const bindings = results.object.get("bindings") orelse return null;
        if (bindings != .array) return null;
        if (bindings.array.items.len == 0) {
            std.debug.print("PHOTO: no vessel photo on Wikidata\n", .{});
            return null;
        }

        const first = bindings.array.items[0];
        if (first != .object) return null;
        const image_val = first.object.get("image") orelse return null;
        if (image_val != .object) return null;
        const value_val = image_val.object.get("value") orelse return null;
        if (value_val != .string) return null;
        const image_url = value_val.string;

        // Wikidata returns URLs like:
        //   http://commons.wikimedia.org/wiki/Special:FilePath/CarnivalSunshineCL.JPG
        // Extract filename and use Wikimedia REST API to get a direct upload URL
        // (avoids redirect chain that loses User-Agent).
        const direct_url = resolveWikimediaUrl(client, image_url, null) orelse {
            std.debug.print("PHOTO: could not resolve Wikimedia URL\n", .{});
            return null;
        };
        defer std.heap.page_allocator.free(direct_url);

        std.debug.print("PHOTO: downloading {s}\n", .{direct_url[0..@min(direct_url.len, 100)]});

        const img_uri = std.Uri.parse(direct_url) catch return null;
        const img_body = httpGet(client, img_uri, null) orelse return null; // default UA; Wikimedia blocks custom ones
        const result = std.heap.page_allocator.alloc(u8, img_body.items.len) catch {
            img_body.deinit();
            return null;
        };
        @memcpy(result, img_body.items);
        img_body.deinit();
        std.debug.print("PHOTO: got {d} bytes\n", .{result.len});
        return result;
    }
};

/// Resolve a Wikimedia Commons Special:FilePath URL to a direct upload.wikimedia.org URL
/// by calling the Wikimedia REST API.
/// Input:  "http://commons.wikimedia.org/wiki/Special:FilePath/CarnivalSunshineCL.JPG"
/// Output: "https://upload.wikimedia.org/wikipedia/commons/f/fb/CarnivalSunshineCL.JPG"
fn resolveWikimediaUrl(client: *std.http.Client, raw_url: []const u8, user_agent: ?[]const u8) ?[]u8 {
    // Extract filename from URL: everything after the last '/'
    const last_slash = std.mem.lastIndexOf(u8, raw_url, "/") orelse return null;
    const filename = raw_url[last_slash + 1 ..];
    if (filename.len == 0) return null;

    // Build REST API URL: https://api.wikimedia.org/core/v1/commons/file/File:{filename}
    const api_base = "https://api.wikimedia.org/core/v1/commons/file/File:";
    var api_url_buf: [512]u8 = undefined;
    if (api_base.len + filename.len >= api_url_buf.len) return null;
    @memcpy(api_url_buf[0..api_base.len], api_base);
    @memcpy(api_url_buf[api_base.len..][0..filename.len], filename);
    const api_url = api_url_buf[0 .. api_base.len + filename.len];

    const uri = std.Uri.parse(api_url) catch return null;
    const json_body = httpGet(client, uri, user_agent) orelse return null;
    defer json_body.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_body.items, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Try thumbnail first (usually same as original for photos), then original
    const url_str = blk: {
        if (root.object.get("thumbnail")) |thumb| {
            if (thumb == .object) {
                if (thumb.object.get("url")) |u| {
                    if (u == .string) break :blk u.string;
                }
            }
        }
        if (root.object.get("original")) |orig| {
            if (orig == .object) {
                if (orig.object.get("url")) |u| {
                    if (u == .string) break :blk u.string;
                }
            }
        }
        return null;
    };

    // Dupe the string so it outlives the JSON parse
    const result = std.heap.page_allocator.alloc(u8, url_str.len) catch return null;
    @memcpy(result, url_str);
    return result;
}

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

/// Encode a PhotoKey as a DB key string: "v:MMSI" or "a:ICAO"
fn photoKeyStr(key: PhotoKey, buf: *[32]u8) []const u8 {
    switch (key) {
        .vessel => |vid| {
            const result = std.fmt.bufPrint(buf, "v:{d}", .{vid.mmsi}) catch return buf[0..0];
            return result;
        },
        .icao => |icao| {
            var icao_len: usize = 6;
            while (icao_len > 0 and icao[icao_len - 1] == 0) icao_len -= 1;
            buf[0] = 'a';
            buf[1] = ':';
            @memcpy(buf[2..][0..icao_len], icao[0..icao_len]);
            return buf[0 .. 2 + icao_len];
        },
    }
}

/// Detect image format, returns a slice (not sentinel-terminated)
fn detectFormatSlice(bytes: []const u8) []const u8 {
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8) return ".jpg";
    if (bytes.len >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47) return ".png";
    if (bytes.len >= 4 and bytes[0] == 'R' and bytes[1] == 'I' and bytes[2] == 'F' and bytes[3] == 'F') return ".webp";
    return ".jpg";
}

fn detectFormat(bytes: []const u8) [*:0]const u8 {
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8) return ".jpg";
    if (bytes.len >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47) return ".png";
    if (bytes.len >= 4 and bytes[0] == 'R' and bytes[1] == 'I' and bytes[2] == 'F' and bytes[3] == 'F') return ".webp";
    return ".jpg"; // fallback
}

fn urlEncode(input: []const u8, buf: []u8) []const u8 {
    var out: usize = 0;
    for (input) |ch| {
        if (out + 3 > buf.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            buf[out] = ch;
            out += 1;
        } else {
            buf[out] = '%';
            buf[out + 1] = hexDigit(@as(u4, @truncate(ch >> 4)));
            buf[out + 2] = hexDigit(@as(u4, @truncate(ch & 0x0F)));
            out += 3;
        }
    }
    return buf[0..out];
}

fn hexDigit(v: u4) u8 {
    const w: u8 = v;
    return if (w < 10) '0' + w else 'A' + (w - 10);
}

const PHOTO_UA = "NucleusViewer/1.0 (https://github.com; contact@example.com)";

fn httpGet(client: *std.http.Client, uri: std.Uri, user_agent: ?[]const u8) ?std.ArrayList(u8) {
    return httpGetFollow(client, uri, user_agent, 0);
}

/// HTTP GET with manual redirect following (preserves User-Agent across hops).
fn httpGetFollow(client: *std.http.Client, uri: std.Uri, user_agent: ?[]const u8, depth: u8) ?std.ArrayList(u8) {
    if (depth > 10) return null;
    var server_header_buf: [16384]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buf,
        .redirect_behavior = .unhandled,
        .headers = if (user_agent) |ua|
            .{ .user_agent = .{ .override = ua } }
        else
            .{},
    }) catch return null;
    defer req.deinit();

    req.send() catch return null;
    req.finish() catch return null;
    req.wait() catch return null;

    const status = @intFromEnum(req.response.status);
    if (status >= 301 and status <= 308) {
        // Follow redirect manually with same User-Agent
        const location = req.response.location orelse return null;
        const next_uri = std.Uri.parse(location) catch return null;
        return httpGetFollow(client, next_uri, user_agent, depth + 1);
    }

    if (req.response.status != .ok) {
        std.debug.print("PHOTO: HTTP {d}\n", .{status});
        return null;
    }

    var body = std.ArrayList(u8).init(std.heap.page_allocator);
    var reader = req.reader();
    reader.readAllArrayList(&body, 8 * 1024 * 1024) catch {
        body.deinit();
        return null;
    };
    return body;
}
