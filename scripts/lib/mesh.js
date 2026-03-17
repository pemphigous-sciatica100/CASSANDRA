// mesh.js — Mesh builder with generators and triangulation
// Meshes are arrays of vertices and triangle indices

function Mesh() {
    this.vertices = [];  // [[x,y,z], ...]
    this.normals = [];   // [[nx,ny,nz], ...] (per vertex)
    this.triangles = []; // [[i0,i1,i2], ...]
}

// Add a vertex, returns its index
Mesh.prototype.addVertex = function(x, y, z) {
    const idx = this.vertices.length;
    this.vertices.push([x, y, z]);
    return idx;
};

// Add a triangle by vertex indices
Mesh.prototype.addTriangle = function(i0, i1, i2) {
    this.triangles.push([i0, i1, i2]);
};

// Compute per-vertex normals by averaging face normals
Mesh.prototype.computeNormals = function() {
    const n = this.vertices.length;
    this.normals = [];
    for (let i = 0; i < n; i++) this.normals.push([0, 0, 0]);

    for (const [i0, i1, i2] of this.triangles) {
        const v0 = this.vertices[i0];
        const v1 = this.vertices[i1];
        const v2 = this.vertices[i2];
        // Edge vectors
        const ax = v1[0] - v0[0], ay = v1[1] - v0[1], az = v1[2] - v0[2];
        const bx = v2[0] - v0[0], by = v2[1] - v0[1], bz = v2[2] - v0[2];
        // Cross product = face normal
        const nx = ay * bz - az * by;
        const ny = az * bx - ax * bz;
        const nz = ax * by - ay * bx;
        // Accumulate
        for (const idx of [i0, i1, i2]) {
            this.normals[idx][0] += nx;
            this.normals[idx][1] += ny;
            this.normals[idx][2] += nz;
        }
    }

    // Normalize
    for (let i = 0; i < n; i++) {
        const nn = this.normals[i];
        const len = Math.sqrt(nn[0]*nn[0] + nn[1]*nn[1] + nn[2]*nn[2]);
        if (len > 0.0001) {
            nn[0] /= len; nn[1] /= len; nn[2] /= len;
        }
    }
    return this;
};

// Get midpoint of two vertices, projected onto unit sphere
Mesh.prototype._midpoint = function(cache, i0, i1, radius) {
    const key = Math.min(i0, i1) + "," + Math.max(i0, i1);
    if (cache[key] !== undefined) return cache[key];
    const v0 = this.vertices[i0];
    const v1 = this.vertices[i1];
    let mx = (v0[0] + v1[0]) * 0.5;
    let my = (v0[1] + v1[1]) * 0.5;
    let mz = (v0[2] + v1[2]) * 0.5;
    // Project onto sphere
    const len = Math.sqrt(mx*mx + my*my + mz*mz);
    mx = mx / len * radius;
    my = my / len * radius;
    mz = mz / len * radius;
    const idx = this.addVertex(mx, my, mz);
    cache[key] = idx;
    return idx;
};

// ---------------------------------------------------------------
// Generators
// ---------------------------------------------------------------

// Create an icosphere: start with icosahedron, subdivide N times
Mesh.icosphere = function(radius, subdivisions) {
    const mesh = new Mesh();
    radius = radius || 1.0;
    subdivisions = subdivisions || 2;

    // Golden ratio
    const t = (1 + Math.sqrt(5)) / 2;
    const s = radius / Math.sqrt(1 + t * t);

    // 12 vertices of icosahedron
    const verts = [
        [-1,  t,  0], [ 1,  t,  0], [-1, -t,  0], [ 1, -t,  0],
        [ 0, -1,  t], [ 0,  1,  t], [ 0, -1, -t], [ 0,  1, -t],
        [ t,  0, -1], [ t,  0,  1], [-t,  0, -1], [-t,  0,  1],
    ];
    for (const v of verts) {
        mesh.addVertex(v[0] * s, v[1] * s, v[2] * s);
    }

    // 20 triangles of icosahedron
    const faces = [
        [0,11,5], [0,5,1], [0,1,7], [0,7,10], [0,10,11],
        [1,5,9], [5,11,4], [11,10,2], [10,7,6], [7,1,8],
        [3,9,4], [3,4,2], [3,2,6], [3,6,8], [3,8,9],
        [4,9,5], [2,4,11], [6,2,10], [8,6,7], [9,8,1],
    ];
    for (const f of faces) {
        mesh.addTriangle(f[0], f[1], f[2]);
    }

    // Subdivide
    for (let level = 0; level < subdivisions; level++) {
        const newTriangles = [];
        const cache = {};
        for (const [i0, i1, i2] of mesh.triangles) {
            const a = mesh._midpoint(cache, i0, i1, radius);
            const b = mesh._midpoint(cache, i1, i2, radius);
            const c = mesh._midpoint(cache, i2, i0, radius);
            newTriangles.push([i0, a, c]);
            newTriangles.push([i1, b, a]);
            newTriangles.push([i2, c, b]);
            newTriangles.push([a, b, c]);
        }
        mesh.triangles = newTriangles;
    }

    mesh.computeNormals();
    return mesh;
};

// Create a box mesh
Mesh.box = function(w, h, d) {
    const mesh = new Mesh();
    w = (w || 1) * 0.5; h = (h || 1) * 0.5; d = (d || 1) * 0.5;
    // 8 vertices
    const v = [
        [-w,-h,-d], [w,-h,-d], [w,h,-d], [-w,h,-d],
        [-w,-h, d], [w,-h, d], [w,h, d], [-w,h, d],
    ];
    for (const p of v) mesh.addVertex(p[0], p[1], p[2]);
    // 12 triangles (6 faces × 2)
    const f = [
        [0,2,1],[0,3,2], [4,5,6],[4,6,7], [0,1,5],[0,5,4],
        [2,3,7],[2,7,6], [1,2,6],[1,6,5], [0,4,7],[0,7,3],
    ];
    for (const t of f) mesh.addTriangle(t[0], t[1], t[2]);
    mesh.computeNormals();
    return mesh;
};

// Create a plane/grid mesh
Mesh.plane = function(w, d, segsW, segsD) {
    const mesh = new Mesh();
    w = w || 4; d = d || 4;
    segsW = segsW || 8; segsD = segsD || 8;
    for (let iz = 0; iz <= segsD; iz++) {
        for (let ix = 0; ix <= segsW; ix++) {
            const x = (ix / segsW - 0.5) * w;
            const z = (iz / segsD - 0.5) * d;
            mesh.addVertex(x, 0, z);
        }
    }
    for (let iz = 0; iz < segsD; iz++) {
        for (let ix = 0; ix < segsW; ix++) {
            const i = iz * (segsW + 1) + ix;
            mesh.addTriangle(i, i + segsW + 1, i + 1);
            mesh.addTriangle(i + 1, i + segsW + 1, i + segsW + 2);
        }
    }
    mesh.computeNormals();
    return mesh;
};

// ---------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------

// Draw mesh using triangle3d calls with simple diffuse shading
Mesh.prototype.draw = function(ox, oy, oz, color, lightDir) {
    ox = ox || 0; oy = oy || 0; oz = oz || 0;
    const r = (color >> 0) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = (color >> 16) & 0xFF;
    const lx = lightDir ? lightDir[0] : 0.577;
    const ly = lightDir ? lightDir[1] : -0.577;
    const lz = lightDir ? lightDir[2] : 0.577;

    for (const [i0, i1, i2] of this.triangles) {
        const v0 = this.vertices[i0];
        const v1 = this.vertices[i1];
        const v2 = this.vertices[i2];

        // Face normal for lighting
        const ax = v1[0]-v0[0], ay = v1[1]-v0[1], az = v1[2]-v0[2];
        const bx = v2[0]-v0[0], by = v2[1]-v0[1], bz = v2[2]-v0[2];
        const nx = ay*bz - az*by;
        const ny = az*bx - ax*bz;
        const nz = ax*by - ay*bx;
        const nl = Math.sqrt(nx*nx + ny*ny + nz*nz);
        if (nl < 0.0001) continue;

        const dot = (nx/nl)*lx + (ny/nl)*ly + (nz/nl)*lz;
        const brightness = 0.2 + 0.8 * Math.max(0, -dot);

        const cr = Math.floor(r * brightness);
        const cg = Math.floor(g * brightness);
        const cb = Math.floor(b * brightness);

        gfx.triangle3d(
            ox+v0[0], oy+v0[1], oz+v0[2],
            ox+v1[0], oy+v1[1], oz+v1[2],
            ox+v2[0], oy+v2[1], oz+v2[2],
            gfx.rgb(cr, cg, cb)
        );
    }
};

// Expose globally
globalThis.Mesh = Mesh;
