const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");

/// Post-process effects pipeline.
/// Toggle with T (trails), B (bloom), C (chromatic aberration),
/// V (scanlines), X (night vision), H (hologram), J (VHS glitch),
/// K (CRT).
pub const Effects = struct {
    // Trail: ping-pong between two render textures
    trail_a: rl.c.RenderTexture2D = undefined,
    trail_b: rl.c.RenderTexture2D = undefined,
    which: bool = false,

    // Bloom: two-pass Gaussian blur
    bloom_tex: rl.c.RenderTexture2D = undefined,
    scratch_tex: rl.c.RenderTexture2D = undefined,
    blur_shader: rl.c.Shader = undefined,
    blur_res_loc: c_int = -1,
    blur_dir_loc: c_int = -1,

    // Post-process shaders (applied as full-screen passes)
    post_tex: rl.c.RenderTexture2D = undefined, // ping-pong target for chaining post shaders

    scanline_shader: rl.c.Shader = undefined,
    scanline_res_loc: c_int = -1,
    scanline_time_loc: c_int = -1,

    nightvis_shader: rl.c.Shader = undefined,
    nightvis_res_loc: c_int = -1,
    nightvis_time_loc: c_int = -1,

    chromab_shader: rl.c.Shader = undefined,
    chromab_res_loc: c_int = -1,

    crt_shader: rl.c.Shader = undefined,
    crt_res_loc: c_int = -1,
    crt_time_loc: c_int = -1,

    hologram_shader: rl.c.Shader = undefined,
    hologram_res_loc: c_int = -1,
    hologram_time_loc: c_int = -1,

    vhs_shader: rl.c.Shader = undefined,
    vhs_res_loc: c_int = -1,
    vhs_time_loc: c_int = -1,

    // Scene capture
    scene_tex: rl.c.RenderTexture2D = undefined,

    trails_on: bool = false,
    bloom_on: bool = false,
    scanlines_on: bool = false,
    nightvis_on: bool = false,
    chromab_on: bool = false,
    crt_on: bool = false,
    hologram_on: bool = false,
    vhs_on: bool = false,
    trail_fade: f32 = 0.92,

    width: c_int = 0,
    height: c_int = 0,
    initialized: bool = false,

    pub fn init(self: *Effects, w: c_int, h: c_int) void {
        self.width = w;
        self.height = h;
        self.scene_tex = rl.c.LoadRenderTexture(w, h);
        self.trail_a = rl.c.LoadRenderTexture(w, h);
        self.trail_b = rl.c.LoadRenderTexture(w, h);
        self.bloom_tex = rl.c.LoadRenderTexture(w, h);
        self.scratch_tex = rl.c.LoadRenderTexture(w, h);

        // Bilinear filtering on all render textures — critical for smooth bloom sampling
        rl.c.SetTextureFilter(self.scene_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.trail_a.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.trail_b.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.bloom_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.scratch_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);

        rl.c.BeginTextureMode(self.trail_a);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.EndTextureMode();
        rl.c.BeginTextureMode(self.trail_b);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.EndTextureMode();

        self.post_tex = rl.c.LoadRenderTexture(w, h);
        rl.c.SetTextureFilter(self.post_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);

        self.blur_shader = rl.c.LoadShaderFromMemory(null, blur_fs);
        self.blur_res_loc = rl.c.GetShaderLocation(self.blur_shader, "resolution");
        self.blur_dir_loc = rl.c.GetShaderLocation(self.blur_shader, "direction");

        self.scanline_shader = rl.c.LoadShaderFromMemory(null, scanline_fs);
        self.scanline_res_loc = rl.c.GetShaderLocation(self.scanline_shader, "resolution");
        self.scanline_time_loc = rl.c.GetShaderLocation(self.scanline_shader, "time");

        self.nightvis_shader = rl.c.LoadShaderFromMemory(null, nightvis_fs);
        self.nightvis_res_loc = rl.c.GetShaderLocation(self.nightvis_shader, "resolution");
        self.nightvis_time_loc = rl.c.GetShaderLocation(self.nightvis_shader, "time");

        self.chromab_shader = rl.c.LoadShaderFromMemory(null, chromab_fs);
        self.chromab_res_loc = rl.c.GetShaderLocation(self.chromab_shader, "resolution");

        self.crt_shader = rl.c.LoadShaderFromMemory(null, crt_fs);
        self.crt_res_loc = rl.c.GetShaderLocation(self.crt_shader, "resolution");
        self.crt_time_loc = rl.c.GetShaderLocation(self.crt_shader, "time");

        self.hologram_shader = rl.c.LoadShaderFromMemory(null, hologram_fs);
        self.hologram_res_loc = rl.c.GetShaderLocation(self.hologram_shader, "resolution");
        self.hologram_time_loc = rl.c.GetShaderLocation(self.hologram_shader, "time");

        self.vhs_shader = rl.c.LoadShaderFromMemory(null, vhs_fs);
        self.vhs_res_loc = rl.c.GetShaderLocation(self.vhs_shader, "resolution");
        self.vhs_time_loc = rl.c.GetShaderLocation(self.vhs_shader, "time");

        self.initialized = true;
    }

    pub fn deinit(self: *Effects) void {
        if (!self.initialized) return;
        rl.c.UnloadRenderTexture(self.scene_tex);
        rl.c.UnloadRenderTexture(self.trail_a);
        rl.c.UnloadRenderTexture(self.trail_b);
        rl.c.UnloadRenderTexture(self.bloom_tex);
        rl.c.UnloadRenderTexture(self.scratch_tex);
        rl.c.UnloadRenderTexture(self.post_tex);
        rl.c.UnloadShader(self.blur_shader);
        rl.c.UnloadShader(self.scanline_shader);
        rl.c.UnloadShader(self.nightvis_shader);
        rl.c.UnloadShader(self.chromab_shader);
        rl.c.UnloadShader(self.crt_shader);
        rl.c.UnloadShader(self.hologram_shader);
        rl.c.UnloadShader(self.vhs_shader);
        self.initialized = false;
    }

    pub fn handleResize(self: *Effects, w: c_int, h: c_int) void {
        if (w == self.width and h == self.height) return;
        if (self.initialized) self.deinit();
        self.init(w, h);
    }

    pub fn handleInput(self: *Effects) void {
        if (rl.isKeyPressed(rl.c.KEY_T)) self.trails_on = !self.trails_on;
        if (rl.isKeyPressed(rl.c.KEY_B)) self.bloom_on = !self.bloom_on;
        if (rl.isKeyPressed(rl.c.KEY_C)) self.chromab_on = !self.chromab_on;
        if (rl.isKeyPressed(rl.c.KEY_V)) self.scanlines_on = !self.scanlines_on;
        if (rl.isKeyPressed(rl.c.KEY_X)) self.nightvis_on = !self.nightvis_on;
        if (rl.isKeyPressed(rl.c.KEY_H)) self.hologram_on = !self.hologram_on;
        if (rl.isKeyPressed(rl.c.KEY_J)) self.vhs_on = !self.vhs_on;
        if (rl.isKeyPressed(rl.c.KEY_K)) self.crt_on = !self.crt_on;
    }

    pub fn anyActive(self: *const Effects) bool {
        return self.trails_on or self.bloom_on or self.scanlines_on or self.nightvis_on or
            self.chromab_on or self.crt_on or self.hologram_on or self.vhs_on;
    }

    pub fn beginScene(self: *Effects) void {
        rl.c.BeginTextureMode(self.scene_tex);
        // Transparent when trails are on so previous frames show through.
        // Opaque BG when only bloom is active.
        if (self.trails_on) {
            rl.c.ClearBackground(rl.c.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        } else {
            rl.c.ClearBackground(constants.BG_COLOR);
        }
    }

    pub fn endScene(self: *Effects) void {
        rl.c.EndTextureMode();

        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        const resolution = [2]f32{ w, h };
        const time = [1]f32{@as(f32, @floatCast(rl.c.GetTime()))};

        if (self.trails_on) self.compositeTrails(w, h);
        if (self.bloom_on) self.compositeBloom(w, h);

        // Determine the "current" texture after trails/bloom
        var current_tex = if (self.trails_on)
            (if (self.which) self.trail_a.texture else self.trail_b.texture)
        else
            self.scene_tex.texture;

        // Track which render target post_tex is using for ping-pong
        var post_is_current = false;

        // Apply post-process shader chain: each reads current_tex, writes to post_tex, then swap
        if (self.chromab_on) {
            rl.c.SetShaderValue(self.chromab_shader, self.chromab_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);
            const target = if (post_is_current) self.scratch_tex else self.post_tex;
            rl.c.BeginTextureMode(target);
            rl.c.ClearBackground(rl.c.BLACK);
            rl.c.BeginShaderMode(self.chromab_shader);
            blitRT(current_tex, w, h, rl.c.WHITE);
            rl.c.EndShaderMode();
            rl.c.EndTextureMode();
            current_tex = target.texture;
            post_is_current = !post_is_current;
        }

        if (self.scanlines_on) {
            rl.c.SetShaderValue(self.scanline_shader, self.scanline_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);
            rl.c.SetShaderValue(self.scanline_shader, self.scanline_time_loc, &time, rl.c.SHADER_UNIFORM_FLOAT);
            const target = if (post_is_current) self.scratch_tex else self.post_tex;
            rl.c.BeginTextureMode(target);
            rl.c.ClearBackground(rl.c.BLACK);
            rl.c.BeginShaderMode(self.scanline_shader);
            blitRT(current_tex, w, h, rl.c.WHITE);
            rl.c.EndShaderMode();
            rl.c.EndTextureMode();
            current_tex = target.texture;
            post_is_current = !post_is_current;
        }

        if (self.nightvis_on) {
            rl.c.SetShaderValue(self.nightvis_shader, self.nightvis_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);
            rl.c.SetShaderValue(self.nightvis_shader, self.nightvis_time_loc, &time, rl.c.SHADER_UNIFORM_FLOAT);
            const target = if (post_is_current) self.scratch_tex else self.post_tex;
            rl.c.BeginTextureMode(target);
            rl.c.ClearBackground(rl.c.BLACK);
            rl.c.BeginShaderMode(self.nightvis_shader);
            blitRT(current_tex, w, h, rl.c.WHITE);
            rl.c.EndShaderMode();
            rl.c.EndTextureMode();
            current_tex = target.texture;
            post_is_current = !post_is_current;
        }

        if (self.crt_on) {
            rl.c.SetShaderValue(self.crt_shader, self.crt_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);
            rl.c.SetShaderValue(self.crt_shader, self.crt_time_loc, &time, rl.c.SHADER_UNIFORM_FLOAT);
            const target = if (post_is_current) self.scratch_tex else self.post_tex;
            rl.c.BeginTextureMode(target);
            rl.c.ClearBackground(rl.c.BLACK);
            rl.c.BeginShaderMode(self.crt_shader);
            blitRT(current_tex, w, h, rl.c.WHITE);
            rl.c.EndShaderMode();
            rl.c.EndTextureMode();
            current_tex = target.texture;
            post_is_current = !post_is_current;
        }

        if (self.hologram_on) {
            rl.c.SetShaderValue(self.hologram_shader, self.hologram_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);
            rl.c.SetShaderValue(self.hologram_shader, self.hologram_time_loc, &time, rl.c.SHADER_UNIFORM_FLOAT);
            const target = if (post_is_current) self.scratch_tex else self.post_tex;
            rl.c.BeginTextureMode(target);
            rl.c.ClearBackground(rl.c.BLACK);
            rl.c.BeginShaderMode(self.hologram_shader);
            blitRT(current_tex, w, h, rl.c.WHITE);
            rl.c.EndShaderMode();
            rl.c.EndTextureMode();
            current_tex = target.texture;
            post_is_current = !post_is_current;
        }

        if (self.vhs_on) {
            rl.c.SetShaderValue(self.vhs_shader, self.vhs_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);
            rl.c.SetShaderValue(self.vhs_shader, self.vhs_time_loc, &time, rl.c.SHADER_UNIFORM_FLOAT);
            const target = if (post_is_current) self.scratch_tex else self.post_tex;
            rl.c.BeginTextureMode(target);
            rl.c.ClearBackground(rl.c.BLACK);
            rl.c.BeginShaderMode(self.vhs_shader);
            blitRT(current_tex, w, h, rl.c.WHITE);
            rl.c.EndShaderMode();
            rl.c.EndTextureMode();
            current_tex = target.texture;
            post_is_current = !post_is_current;
        }

        // Final blit to screen
        rl.c.BeginDrawing();
        rl.c.ClearBackground(rl.c.BLACK);

        blitRT(current_tex, w, h, rl.c.WHITE);

        if (self.bloom_on) {
            rl.c.BeginBlendMode(rl.c.BLEND_ADDITIVE);
            blitRT(self.bloom_tex.texture, w, h, rl.c.WHITE);
            rl.c.EndBlendMode();
        }
    }

    fn compositeTrails(self: *Effects, w: f32, h: f32) void {
        const read_tex = if (self.which) self.trail_a.texture else self.trail_b.texture;
        const write_target = if (self.which) self.trail_b else self.trail_a;

        rl.c.BeginTextureMode(write_target);

        // Start with the background color
        rl.c.ClearBackground(constants.BG_COLOR);

        // Draw previous trail frame with fade (the persistence effect)
        const fade_alpha: u8 = @intFromFloat(self.trail_fade * 255.0);
        blitRT(read_tex, w, h, rl.color(255, 255, 255, fade_alpha));

        // Draw current scene on top (transparent background, only dots/glow/lines)
        rl.c.BeginBlendMode(rl.c.BLEND_ALPHA);
        blitRT(self.scene_tex.texture, w, h, rl.c.WHITE);
        rl.c.EndBlendMode();

        rl.c.EndTextureMode();
        self.which = !self.which;
    }

    fn compositeBloom(self: *Effects, w: f32, h: f32) void {
        const resolution = [2]f32{ w, h };
        rl.c.SetShaderValue(self.blur_shader, self.blur_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);

        const source = if (self.trails_on)
            (if (self.which) self.trail_a.texture else self.trail_b.texture)
        else
            self.scene_tex.texture;

        // Pass 1: horizontal blur → scratch_tex
        const dir_h = [2]f32{ 1.0, 0.0 };
        rl.c.SetShaderValue(self.blur_shader, self.blur_dir_loc, &dir_h, rl.c.SHADER_UNIFORM_VEC2);
        rl.c.BeginTextureMode(self.scratch_tex);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.BeginShaderMode(self.blur_shader);
        blitRT(source, w, h, rl.c.WHITE);
        rl.c.EndShaderMode();
        rl.c.EndTextureMode();

        // Pass 2: vertical blur → bloom_tex
        const dir_v = [2]f32{ 0.0, 1.0 };
        rl.c.SetShaderValue(self.blur_shader, self.blur_dir_loc, &dir_v, rl.c.SHADER_UNIFORM_VEC2);
        rl.c.BeginTextureMode(self.bloom_tex);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.BeginShaderMode(self.blur_shader);
        blitRT(self.scratch_tex.texture, w, h, rl.c.WHITE);
        rl.c.EndShaderMode();
        rl.c.EndTextureMode();
    }
};

/// Blit a render texture. Always flips Y because OpenGL render textures
/// store data bottom-up, but Raylib's DrawTexturePro reads top-down.
/// Works for both drawing to screen AND drawing into another render texture
/// (BeginTextureMode internally handles the destination coordinate system).
fn blitRT(tex: rl.c.Texture2D, w: f32, h: f32, tint: rl.c.Color) void {
    const src = rl.c.Rectangle{ .x = 0, .y = 0, .width = w, .height = -h };
    const dst = rl.c.Rectangle{ .x = 0, .y = 0, .width = w, .height = h };
    rl.c.DrawTexturePro(tex, src, dst, rl.c.Vector2{ .x = 0, .y = 0 }, 0, tint);
}

// --- Chromatic aberration: subtle RGB channel offset ---
const chromab_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\out vec4 finalColor;
    \\
    \\void main() {
    \\    vec2 uv = fragTexCoord;
    \\    vec2 center = uv - 0.5;
    \\    float dist = length(center);
    \\    vec2 offset = center * dist * 0.006;
    \\    float r = texture(texture0, uv + offset).r;
    \\    float g = texture(texture0, uv).g;
    \\    float b = texture(texture0, uv - offset).b;
    \\    finalColor = vec4(r, g, b, 1.0);
    \\}
;

// --- Scanlines: CRT monitor effect with subtle flicker ---
const scanline_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform float time;
    \\out vec4 finalColor;
    \\
    \\void main() {
    \\    vec2 uv = fragTexCoord;
    \\    vec3 col = texture(texture0, uv).rgb;
    \\
    \\    // Scanlines
    \\    float scanline = sin(uv.y * resolution.y * 1.5) * 0.5 + 0.5;
    \\    scanline = mix(0.75, 1.0, scanline);
    \\    col *= scanline;
    \\
    \\    // Subtle rolling bar
    \\    float roll = sin(uv.y * 3.0 + time * 1.5) * 0.5 + 0.5;
    \\    col *= mix(0.97, 1.0, roll);
    \\
    \\    // Vignette
    \\    vec2 center = uv - 0.5;
    \\    float vig = 1.0 - dot(center, center) * 1.2;
    \\    col *= clamp(vig, 0.0, 1.0);
    \\
    \\    finalColor = vec4(col, 1.0);
    \\}
;

// --- Night vision: green phosphor + noise + vignette ---
const nightvis_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform float time;
    \\out vec4 finalColor;
    \\
    \\float hash(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    \\}
    \\
    \\void main() {
    \\    vec2 uv = fragTexCoord;
    \\    vec3 col = texture(texture0, uv).rgb;
    \\
    \\    // Convert to luminance
    \\    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    \\
    \\    // Boost and curve for night-vision look
    \\    lum = pow(lum, 0.7) * 1.4;
    \\
    \\    // Green phosphor tint
    \\    vec3 green = vec3(0.1, 1.0, 0.2) * lum;
    \\
    \\    // Film grain noise
    \\    float noise = hash(uv * resolution + vec2(time * 100.0)) * 0.12;
    \\    green += vec3(noise * 0.1, noise, noise * 0.1);
    \\
    \\    // Heavy vignette (night-vision tube look)
    \\    vec2 center = uv - 0.5;
    \\    float vig = 1.0 - dot(center, center) * 2.8;
    \\    vig = clamp(vig, 0.0, 1.0);
    \\    vig = smoothstep(0.0, 0.5, vig);
    \\    green *= vig;
    \\
    \\    finalColor = vec4(green, 1.0);
    \\}
;

// --- CRT (advanced): barrel distortion, phosphor RGB, scanlines, flicker ---
const crt_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform float time;
    \\out vec4 finalColor;
    \\
    \\void main() {
    \\    // Barrel distortion (curved screen)
    \\    vec2 uv = fragTexCoord * 2.0 - 1.0;
    \\    float barrel = 0.15;
    \\    float r2 = dot(uv, uv);
    \\    uv *= 1.0 + barrel * r2;
    \\    uv = (uv + 1.0) * 0.5;
    \\
    \\    // Black outside curved edges
    \\    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    \\        finalColor = vec4(0.0, 0.0, 0.0, 1.0);
    \\        return;
    \\    }
    \\
    \\    // Sub-pixel phosphor sampling (RGB triad)
    \\    float px = 1.0 / resolution.x;
    \\    float r = texture(texture0, vec2(uv.x - px * 0.33, uv.y)).r;
    \\    float g = texture(texture0, uv).g;
    \\    float b = texture(texture0, vec2(uv.x + px * 0.33, uv.y)).b;
    \\    vec3 col = vec3(r, g, b);
    \\
    \\    // Phosphor grid pattern
    \\    float phosphor = sin(uv.x * resolution.x * 3.14159) * 0.5 + 0.5;
    \\    col *= mix(0.85, 1.0, phosphor);
    \\
    \\    // Scanlines
    \\    float scan = sin(uv.y * resolution.y * 3.14159) * 0.5 + 0.5;
    \\    col *= mix(0.7, 1.0, scan);
    \\
    \\    // Brightness flicker
    \\    float flicker = 0.97 + 0.03 * sin(time * 8.0);
    \\    col *= flicker;
    \\
    \\    // Corner shadow (CRT bezel)
    \\    vec2 center = uv - 0.5;
    \\    float vig = 1.0 - dot(center, center) * 1.8;
    \\    col *= clamp(vig, 0.0, 1.0);
    \\
    \\    finalColor = vec4(col, 1.0);
    \\}
;

// --- Hologram/Scanner: digital scan lines with cyan/green glow ---
const hologram_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform float time;
    \\out vec4 finalColor;
    \\
    \\float hash(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    \\}
    \\
    \\void main() {
    \\    vec2 uv = fragTexCoord;
    \\    vec3 col = texture(texture0, uv).rgb;
    \\    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    \\
    \\    // Holographic cyan/green tint
    \\    vec3 holo = mix(vec3(0.0, 0.9, 1.0), vec3(0.0, 1.0, 0.4), lum) * lum;
    \\
    \\    // Horizontal scan lines (fine)
    \\    float scanline = sin(uv.y * resolution.y * 1.0) * 0.5 + 0.5;
    \\    holo *= mix(0.7, 1.0, scanline);
    \\
    \\    // Moving scan bar
    \\    float scan_pos = fract(time * 0.15);
    \\    float scan_bar = 1.0 - smoothstep(0.0, 0.06, abs(uv.y - scan_pos));
    \\    holo += vec3(0.05, 0.3, 0.4) * scan_bar;
    \\
    \\    // Horizontal jitter (subtle)
    \\    float jitter = hash(vec2(floor(uv.y * resolution.y * 0.5), time * 10.0));
    \\    holo += vec3(0.0, 0.02, 0.03) * step(0.97, jitter);
    \\
    \\    // Edge glow — boost brighter areas
    \\    holo *= 1.0 + lum * 0.5;
    \\
    \\    // Flicker
    \\    float flicker = 0.95 + 0.05 * sin(time * 12.0 + uv.y * 5.0);
    \\    holo *= flicker;
    \\
    \\    // Noise grain
    \\    float noise = hash(uv * resolution + vec2(time * 50.0)) * 0.06;
    \\    holo += vec3(noise * 0.3, noise, noise * 0.8);
    \\
    \\    finalColor = vec4(holo, 1.0);
    \\}
;

// --- VHS/VCR Glitch: horizontal tearing, color bleed, static, tracking ---
const vhs_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform float time;
    \\out vec4 finalColor;
    \\
    \\float hash(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    \\}
    \\
    \\float hash1(float p) {
    \\    return fract(sin(p * 127.1) * 43758.5453);
    \\}
    \\
    \\void main() {
    \\    vec2 uv = fragTexCoord;
    \\    float t = time;
    \\
    \\    // Tracking wobble (whole-image horizontal shift)
    \\    float wobble = sin(uv.y * 1.5 + t * 0.7) * 0.001;
    \\    wobble += sin(uv.y * 20.0 + t * 3.0) * 0.0005;
    \\    uv.x += wobble;
    \\
    \\    // Horizontal tearing — random rows get displaced
    \\    float row = floor(uv.y * resolution.y);
    \\    float tear_seed = hash(vec2(row, floor(t * 4.0)));
    \\    if (tear_seed > 0.985) {
    \\        float shift = (hash(vec2(row, t)) - 0.5) * 0.06;
    \\        uv.x += shift;
    \\    }
    \\
    \\    // Larger glitch blocks (occasional)
    \\    float block = floor(uv.y * 20.0);
    \\    float block_seed = hash(vec2(block, floor(t * 2.0)));
    \\    if (block_seed > 0.993) {
    \\        uv.x += (hash(vec2(block, t * 3.0)) - 0.5) * 0.08;
    \\    }
    \\
    \\    // Color bleeding (chromatic aberration, VHS-style horizontal only)
    \\    float bleed = 3.0 / resolution.x;
    \\    float r = texture(texture0, vec2(uv.x + bleed, uv.y)).r;
    \\    float g = texture(texture0, uv).g;
    \\    float b = texture(texture0, vec2(uv.x - bleed, uv.y)).b;
    \\    vec3 col = vec3(r, g, b);
    \\
    \\    // Scanlines
    \\    float scan = sin(uv.y * resolution.y * 3.14159) * 0.5 + 0.5;
    \\    col *= mix(0.85, 1.0, scan);
    \\
    \\    // Static noise (heavier near edges and glitch rows)
    \\    float noise = hash(uv * resolution + vec2(t * 100.0));
    \\    float noise_strength = 0.06 + 0.1 * step(0.98, tear_seed);
    \\    col = mix(col, vec3(noise), noise_strength * noise);
    \\
    \\    // Rolling tracking bar (bottom of screen artifact)
    \\    float track_pos = fract(t * 0.08);
    \\    float track_bar = smoothstep(0.0, 0.02, abs(uv.y - track_pos)) *
    \\                      smoothstep(0.0, 0.02, abs(uv.y - track_pos - 0.03));
    \\    col *= mix(0.4, 1.0, track_bar);
    \\
    \\    // Slight desaturation (VHS color loss)
    \\    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    \\    col = mix(vec3(lum), col, 0.8);
    \\
    \\    // Brightness variation
    \\    col *= 0.95 + 0.05 * sin(t * 3.0);
    \\
    \\    finalColor = vec4(col, 1.0);
    \\}
;

const blur_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform vec2 direction;
    \\out vec4 finalColor;
    \\
    \\void main() {
    \\    vec2 texel = 1.0 / resolution;
    \\
    \\    // 13-tap Gaussian via bilinear trick (7 fetches)
    \\    float w0 = 0.1964825501511404;
    \\    float w1 = 0.2969069646728344;
    \\    float w2 = 0.09447039785044732;
    \\    float w3 = 0.010381362401148057;
    \\    float o1 = 1.411764705882353;
    \\    float o2 = 3.2941176470588234;
    \\    float o3 = 5.176470588235294;
    \\
    \\    vec2 step = direction * texel * 2.0;
    \\
    \\    vec3 result = texture(texture0, fragTexCoord).rgb * w0;
    \\    result += texture(texture0, fragTexCoord + step * o1).rgb * w1;
    \\    result += texture(texture0, fragTexCoord - step * o1).rgb * w1;
    \\    result += texture(texture0, fragTexCoord + step * o2).rgb * w2;
    \\    result += texture(texture0, fragTexCoord - step * o2).rgb * w2;
    \\    result += texture(texture0, fragTexCoord + step * o3).rgb * w3;
    \\    result += texture(texture0, fragTexCoord - step * o3).rgb * w3;
    \\
    \\    finalColor = vec4(result, 1.0);
    \\}
;
