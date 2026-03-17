// Tutorial 08 — Solid cube with lighting
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 400);
scene.position(50, 30);
scene.background(15, 15, 25);

scene.text({ x: 10, y: 10, label: "08 - Solid Cube + Lighting", size: 16, color: gfx.rgb(200, 200, 200) });

// Solid lit cube
scene.cube({ solid: true, size: 2.0, color: gfx.rgb(50, 150, 255),
    lightX: 1, lightY: -1, lightZ: 0.5 })
    .behave("rotate", { speed: 1.0 });

scene.cam.dist = 5;
scene.cam.pitch = 0.4;

// Slowly orbit camera
scene.text({ x: 10, y: 380, label: "", size: 10, color: gfx.rgb(100, 100, 100) })
    .behave(function(obj, t) {
        scene.cam.yaw = t * 0.3;
    });

scene.run();
