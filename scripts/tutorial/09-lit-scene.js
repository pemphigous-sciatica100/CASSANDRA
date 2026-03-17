// Tutorial 09 — Multiple lit objects
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 450, 400);
scene.position(50, 30);
scene.background(10, 10, 20);

scene.text({ x: 10, y: 10, label: "09 - Lit Scene", size: 16, color: gfx.rgb(200, 200, 200) });

// Three solid cubes with different colors and speeds
scene.cube({ solid: true, x: -2.5, y: 0, z: 0, size: 1.2, color: gfx.rgb(255, 80, 80),
    lightX: 1, lightY: -1, lightZ: 0.5 })
    .behave("rotate", { speed: 1.5 });

scene.cube({ solid: true, x: 0, y: 0, z: 0, size: 1.5, color: gfx.rgb(80, 200, 80),
    lightX: 1, lightY: -1, lightZ: 0.5 })
    .behave("rotate", { speed: 1.0 })
    .behave("bounce", { amplitude: 0.3, speed: 2 });

scene.cube({ solid: true, x: 2.5, y: 0, z: 0, size: 1.0, color: gfx.rgb(80, 80, 255),
    lightX: 1, lightY: -1, lightZ: 0.5 })
    .behave("rotate", { speed: 2.0 })
    .behave("color-cycle", { speed: 0.5 });

// Wireframe floor grid
for (let i = -4; i <= 4; i++) {
    scene.line({ x: i * 30 + 225, y: 320, x2: i * 30 + 225, y2: 280, color: gfx.rgba(50, 50, 70, 150) });
    scene.line({ x: 105, y: 280 + i * 5 + 20, x2: 345, y2: 280 + i * 5 + 20, color: gfx.rgba(50, 50, 70, 150) });
}

scene.cam.dist = 6;
scene.cam.pitch = 0.35;

scene.text({ x: 10, y: 380, label: "", size: 10, color: gfx.rgb(100, 100, 100) })
    .behave(function(obj, t) {
        scene.cam.yaw = t * 0.2;
    });

scene.run();
