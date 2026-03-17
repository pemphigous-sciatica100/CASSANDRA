// Tutorial 10 — Mesh builder: icosphere from point cloud
exec("../scripts/lib/mesh.js");

// Generate an icosphere — points on a sphere, properly triangulated
const sphere = Mesh.icosphere(1.5, 2); // radius 1.5, 2 subdivisions = 320 triangles

print("Icosphere: " + sphere.vertices.length + " vertices, " + sphere.triangles.length + " triangles");

gfx.create(0, 450, 400);
gfx.move(0, 50, 30);

const GREEN = gfx.rgb(30, 200, 120);
const WHITE = gfx.rgb(200, 200, 200);

let t = 0;
while (true) {
    gfx.begin(0);
    gfx.clear(10, 10, 20);
    gfx.text(10, 10, "10 - Icosphere (" + sphere.triangles.length + " tris)", 16, WHITE);

    // Orbiting camera
    const camX = Math.cos(t * 0.015) * 5;
    const camZ = Math.sin(t * 0.015) * 5;
    gfx.begin3d(camX, 2.5, camZ, 0, 0, 0, 45);

    // Draw the mesh with per-face lighting
    sphere.draw(0, 0, 0, GREEN, [0.577, -0.577, 0.577]);

    gfx.end3d();

    gfx.text(10, 380, "Frame " + t, 10, gfx.rgb(100, 100, 100));
    gfx.end(0);
    t++;
    sleep(16);
}
