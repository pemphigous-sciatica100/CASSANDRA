// Orbit around origin
function(obj, t, dt, opts) {
    const radius = opts.radius || 2.0;
    const speed = opts.speed || 1.0;
    obj.x = Math.cos(t * speed) * radius;
    obj.z = Math.sin(t * speed) * radius;
}
