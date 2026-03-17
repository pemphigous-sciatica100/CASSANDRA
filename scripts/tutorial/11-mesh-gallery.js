// Tutorial 11 — Mesh gallery: sphere, box, plane
exec("../scripts/lib/mesh.js");

const sphere = Mesh.icosphere(1.0, 2);
const box = Mesh.box(1.5, 1.5, 1.5);
const plane = Mesh.plane(3, 3, 6, 6);

print("Sphere: " + sphere.triangles.length + " tris");
print("Box: " + box.triangles.length + " tris");
print("Plane: " + plane.triangles.length + " tris");

gfx.create(0, 500, 400);
gfx.move(0, 40, 30);

const CYAN = gfx.rgb(50, 200, 220);
const RED = gfx.rgb(220, 80, 60);
const GOLD = gfx.rgb(220, 180, 50);
const WHITE = gfx.rgb(200, 200, 200);
const LIGHT = [0.5, -0.7, 0.5];

let t = 0;
while (true) {
    gfx.begin(0);
    gfx.clear(8, 8, 16);
    gfx.text(10, 10, "11 - Mesh Gallery", 16, WHITE);

    const camX = Math.cos(t * 0.012) * 8;
    const camZ = Math.sin(t * 0.012) * 8;
    gfx.begin3d(camX, 4, camZ, 0, 0, 0, 45);

    // Sphere on the left
    sphere.draw(-2.5, 0, 0, CYAN, LIGHT);

    // Box in the center
    box.draw(0, 0, 0, RED, LIGHT);

    // Plane on the right (with wave deformation)
    for (let i = 0; i < plane.vertices.length; i++) {
        const v = plane.vertices[i];
        v[1] = Math.sin(v[0] * 2 + t * 0.03) * 0.2 + Math.cos(v[2] * 2 + t * 0.02) * 0.15;
    }
    plane.computeNormals();
    plane.draw(2.5, 0, 0, GOLD, LIGHT);

    gfx.end3d();

    gfx.text(10, 380, "Frame " + t, 10, gfx.rgb(100, 100, 100));
    gfx.end(0);
    t++;
    sleep(16);
}
