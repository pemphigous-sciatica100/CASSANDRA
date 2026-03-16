// 3D demo — multiple objects with behaviors
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 350);
scene.position(80, 30);
scene.background(5, 5, 15);

// Central cube — rotates and color-cycles
scene.cube({ size: 1.0, color: gfx.rgb(0, 255, 100) })
    .behave("rotate", { speed: 1.5 })
    .behave("color-cycle", { speed: 0.8 });

// Orbiting cube
scene.cube({ size: 0.5, color: gfx.rgb(255, 100, 50) })
    .behave("orbit", { radius: 2.5, speed: 1.2 })
    .behave("rotate", { speed: 4.0 });

// Another orbiter going the other way
scene.cube({ size: 0.4, color: gfx.rgb(100, 150, 255) })
    .behave("orbit", { radius: 1.8, speed: -2.0 })
    .behave("rotate", { speed: 3.0 })
    .behave("bounce", { amplitude: 0.3, speed: 4 });

// Title
scene.text({ x: 8, y: 8, label: "CASSANDRA OS", size: 20, color: gfx.rgb(0, 200, 255) });
scene.text({ x: 8, y: 330, label: "Behaviors: rotate, orbit, bounce, color-cycle", size: 10, color: gfx.rgb(100, 100, 100) });

scene.run();
