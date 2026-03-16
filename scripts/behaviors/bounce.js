// Bounce object up and down
function(obj, t, dt, opts) {
    const amp = opts.amplitude || 0.5;
    const speed = opts.speed || 3.0;
    obj.y = (obj.data._baseY || 0) + Math.sin(t * speed) * amp;
    if (obj.data._baseY === undefined) obj.data._baseY = obj.y;
}
