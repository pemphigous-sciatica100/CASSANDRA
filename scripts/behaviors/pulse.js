// Pulse object size
function(obj, t, dt, opts) {
    const base = opts.base || 1.5;
    const amp = opts.amplitude || 0.3;
    const speed = opts.speed || 2.0;
    obj.size = base + Math.sin(t * speed) * amp;
}
