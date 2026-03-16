// Rotate object continuously
function(obj, t, dt, opts) {
    const speed = opts.speed || 2.0;
    obj.ry += dt * speed;
    obj.rx += dt * speed * 0.7;
}
