// Cycle through rainbow colors
function(obj, t, dt, opts) {
    const speed = opts.speed || 1.0;
    const phase = t * speed;
    const r = Math.floor(Math.sin(phase) * 127 + 128);
    const g = Math.floor(Math.sin(phase + 2.094) * 127 + 128);
    const b = Math.floor(Math.sin(phase + 4.189) * 127 + 128);
    obj.color = gfx.rgb(r, g, b);
}
