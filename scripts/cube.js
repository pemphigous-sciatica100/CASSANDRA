// Spinning cube — the simplest 3D demo
gfx.create(0, 300, 300);
gfx.move(0, 100, 50);

const GREEN = gfx.rgb(0, 255, 100);
const CYAN = gfx.rgb(0, 200, 255);
const WHITE = gfx.rgb(255, 255, 255);

let t = 0;
while (true) {
    gfx.begin(0);
    gfx.clear(10, 10, 20);

    // Set camera
    gfx.camera(0, 5.0, 0.4, t * 0.02);

    // Draw a spinning cube
    gfx.cube(0, 0, 0, 1.5, GREEN, t * 0.03, t * 0.02);

    // Label
    gfx.text(8, 8, "CASSANDRA OS", 20, CYAN);
    gfx.text(8, 280, "Frame " + t, 10, WHITE);

    gfx.end(0);
    t++;
    sleep(16);
}
