// Orbital Laser's post pass (capability `render`): one full-screen pass over the
// world, drawn after any shader pack. Everything is anchored in the world by
// rebuilding each pixel's position from the depth buffer and the camera
// matrices, or by tracing the view ray against shapes placed in the world
// (planes, cylinders, a volume). Nothing is painted flat on the screen except
// the lens: bloom, a streak, the flash.
//
// The mod hands it sixteen numbers each frame, `frame.mod_params`:
//   [0] target x, y, z (the point hit), strike clock in seconds
//   [1] hit block centre x, z, the wings' facing (radians: towards the player, the mothership points away), laser
//   [2] seed, intensity, capture mode (0 off, 3 video capture), hit block y
//   [3] the mothership's approach (0 towards the player, 1 from behind them, 2 from their left, 3 from their right,
//       4 from overhead), and how it arrives (0 snap, 1 unfold, 2 warp); unused by the others
//
// Lasers:
//   0 Plasma   a raging plasma beam, forked lightning, a churning fireball, a smoke plume
//   1 Godly    the clouds part, a calm pillar of light comes down, halo rings and wings stand
//              in the sky, six pillars of light land round a golden sigil, a dome of light
//   2 Black hole  a singularity over the target bends the light round it; an accretion disk, a jet
//              out of both poles, the land dragged in, and it evaporates in a flash (`singularity`)
//   3 Meteor storm  meteors pound the land round the target, then one the size of a hill lands on it: a
//              fireball, a shockwave, ejecta across the sky and a sky gone brown with dust (`meteor_storm`)
//   4 Mothership  a slab of dark metal a kilometre long drops out of hyperspace over the target and stops dead, its
//              shadow on the land; its emitters' green beams meet under it, and one beam comes down and sweeps away,
//              cutting a molten trench; then it is gone (`mothership`)
//   5 Downfall  its own pass (shaders/downfall.wgsl, after everything here up to fs_main): the mothership brought down
//              by a meteor, its black hole engine rupturing (`downfall`). [3].z there is how far downrange its stern
//              comes to rest. Kept out of this pass so its size costs the other lasers nothing.

fn target_x() -> f32 { return frame.mod_params[0].x; }
fn target_y() -> f32 { return frame.mod_params[0].y; }
fn target_z() -> f32 { return frame.mod_params[0].z; }
fn anchor_x() -> f32 { return frame.mod_params[1].x; }
fn anchor_z() -> f32 { return frame.mod_params[1].y; }
fn wing_a() -> f32 { return frame.mod_params[1].z; }
fn laser() -> f32 { return frame.mod_params[1].w; }
fn seed_v() -> f32 { return frame.mod_params[2].x; }
fn intensity_v() -> f32 { return max(frame.mod_params[2].y, 0.05); }
fn capture() -> f32 { return frame.mod_params[2].z; }
fn block_y() -> f32 { return frame.mod_params[2].w; }
fn approach() -> i32 { return i32(frame.mod_params[3].x + 0.5); }
// The ship lasers' own light, in the colour picked for them (frame.mod_params[3].w: 0 green, the Mothership's own, 1 red,
// 2 amber, 3 blue, 4 violet, 5 white): their green lights taken through a matrix (each column what that channel turns
// into). Green leaves them exactly as they are.
fn ship_tint(c: vec3<f32>) -> vec3<f32> {
    let i = i32(frame.mod_params[3].w + 0.5);
    if (i <= 0) {
        return c;
    }
    var m = mat3x3<f32>(0.25, 0.25, 0.25, 0.62, 0.65, 0.68, 0.1, 0.1, 0.1);
    switch i {
        case 1: { m = mat3x3<f32>(0.2, 0.35, 0.0, 1.0, 0.1, 0.03, 0.0, 0.0, 0.2); }
        case 2: { m = mat3x3<f32>(0.2, 0.3, 0.0, 1.0, 0.55, 0.05, 0.0, 0.0, 0.15); }
        case 3: { m = mat3x3<f32>(0.1, 0.1, 0.2, 0.12, 0.45, 1.0, 0.0, 0.1, 0.3); }
        case 4: { m = mat3x3<f32>(0.2, 0.2, 0.1, 0.7, 0.12, 1.0, 0.0, 0.0, 0.3); }
        default: {}
    }
    return m * c;
}
fn arrival_style() -> i32 { return i32(frame.mod_params[3].y + 0.5); }

const TAU: f32 = 6.2831853;
const T_FIRE: f32 = 4.0;
const PILLAR_R: f32 = 40.0;       // keep in step with strike.py: GODLY_PILLAR_R, GODLY_PILLAR_A0
const PILLAR_A0: f32 = 0.5235988;
const SIGIL_R1: f32 = 31.0;       // the inner etched ring (godly bowl_r + 3)

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash31(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3<f32>(127.1, 311.7, 74.7))) * 43758.5453);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p: vec2<f32>) -> f32 {
    let o = vec2<f32>(17.3, 9.1);
    let q1 = p * 2.03 + o;
    let q2 = q1 * 2.03 + o;
    let q3 = q2 * 2.03 + o;
    let q4 = q3 * 2.03 + o;
    return 0.5 * vnoise(p) + 0.25 * vnoise(q1) + 0.125 * vnoise(q2) + 0.0625 * vnoise(q3) + 0.03125 * vnoise(q4);
}

fn vnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(hash31(i), hash31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(hash31(i + vec3<f32>(0.0, 1.0, 0.0)), hash31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(hash31(i + vec3<f32>(0.0, 0.0, 1.0)), hash31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(hash31(i + vec3<f32>(0.0, 1.0, 1.0)), hash31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

fn fbm3(p: vec3<f32>) -> f32 {
    let q = p * 2.07 + vec3<f32>(5.1, 1.3, 7.7);
    let r = q * 2.11 + vec3<f32>(2.9, 8.3, 4.1);
    return 0.55 * vnoise3(p) + 0.3 * vnoise3(q) + 0.15 * vnoise3(r);
}

// Cheaper noise for the heavy passes (the black hole, the meteor storm): an integer hash (PCG) instead of sin.
fn pcg(x: u32) -> u32 {
    let s = x * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn fh21(p: vec2<f32>) -> f32 {
    let q = bitcast<vec2<u32>>(vec2<i32>(floor(p)));
    return f32(pcg(q.x ^ pcg(q.y))) * (1.0 / 4294967295.0);
}
fn fh31(p: vec3<f32>) -> f32 {
    let q = bitcast<vec3<u32>>(vec3<i32>(floor(p)));
    return f32(pcg(q.x ^ pcg(q.y ^ pcg(q.z)))) * (1.0 / 4294967295.0);
}
fn fvnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(fh21(i), fh21(i + vec2<f32>(1.0, 0.0)), u.x), mix(fh21(i + vec2<f32>(0.0, 1.0)), fh21(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}
fn ffbm(p: vec2<f32>) -> f32 {
    return 0.55 * fvnoise(p) + 0.3 * fvnoise(p * 2.03 + vec2<f32>(17.3, 9.1)) + 0.15 * fvnoise(p * 4.1 + vec2<f32>(3.1, 5.7));
}
fn fvnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(fh31(i), fh31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(fh31(i + vec3<f32>(0.0, 1.0, 0.0)), fh31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(fh31(i + vec3<f32>(0.0, 0.0, 1.0)), fh31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(fh31(i + vec3<f32>(0.0, 1.0, 1.0)), fh31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}
fn ffbm3(p: vec3<f32>) -> f32 {
    return 0.62 * fvnoise3(p) + 0.38 * fvnoise3(p * 2.07 + vec3<f32>(5.1, 1.3, 7.7));
}

fn lava_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.02, 0.0, 0.0), vec3<f32>(0.7, 0.05, 0.0), smoothstep(0.0, 0.3, h));
    c = mix(c, vec3<f32>(1.0, 0.38, 0.02), smoothstep(0.25, 0.55, h));
    c = mix(c, vec3<f32>(1.0, 0.85, 0.35), smoothstep(0.5, 0.8, h));
    c = mix(c, vec3<f32>(1.0, 1.0, 1.0), smoothstep(0.8, 1.0, h));
    return c;
}

fn gold_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.12, 0.05, 0.0), vec3<f32>(0.85, 0.45, 0.05), smoothstep(0.0, 0.3, h));
    c = mix(c, vec3<f32>(1.0, 0.82, 0.3), smoothstep(0.25, 0.6, h));
    c = mix(c, vec3<f32>(1.0, 0.98, 0.9), smoothstep(0.6, 1.0, h));
    return c;
}

// The plasma fireball's colour by temperature: smoke, a violet-blue body, cyan, then white.
fn plasma_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.0), vec3<f32>(0.35, 0.08, 0.6), smoothstep(0.05, 0.3, h));
    c = mix(c, vec3<f32>(0.3, 0.6, 2.2), smoothstep(0.25, 0.55, h));
    c = mix(c, vec3<f32>(1.2, 2.0, 3.0), smoothstep(0.5, 0.8, h));
    c = mix(c, vec3<f32>(4.0, 4.0, 4.2), smoothstep(0.8, 1.0, h));
    return c;
}

// 1 when `theme` is i, else 0 (the option arrives as a float).
fn th_is(i: f32) -> f32 {
    return 1.0 - step(0.5, abs(laser() - i));
}

fn pick2(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return a * th_is(0.0) + b * th_is(1.0);
}

fn aces(x: vec3<f32>) -> vec3<f32> {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fn target_pos() -> vec3<f32> {
    var v = vec3<f32>(0.0);
    v.x = target_x();
    v.y = target_y();
    v.z = target_z();
    return v;
}

fn anchor_xz() -> vec2<f32> {
    var v = vec2<f32>(0.0);
    v.x = anchor_x();
    v.y = anchor_z();
    return v;
}

fn wing_dirs() -> vec4<f32> {
    // xy: the wings' facing (towards the shooter), zw: the span direction, both in the xz plane
    let a = wing_a();
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(c, s, -s, c);
}

// The strike's clock (it starts at 0 when the designator fires): the mod gives its whole ticks, and the frame's partial
// tick (frame.time.w, the one the camera is drawn at) carries it on between them, so what it moves stays in step with a
// moving camera (the mod's own count of the time since its tick ran ahead of or behind the camera's by up to a frame:
// what flies jittered against the camera as it moved).
fn now() -> f32 {
    return frame.mod_params[0].w + frame.time.w * 0.05;
}

// What frame.camera_position's f32 rounding leaves out of where the camera is (the fork's api-10 prelude): for a
// difference from it taken first, then less this, exact far from the world's origin.
fn camera_rest() -> vec3<f32> {
    return frame.camera_rest.xyz;
}

fn phase_time() -> f32 {
    return now();
}

// Screen uv of a camera-relative world point; z < 0 when behind the camera.
fn project_rel(p: vec3<f32>) -> vec3<f32> {
    let clip = frame.projection * (frame.view * vec4<f32>(p, 1.0));
    let ndc = clip.xy / max(abs(clip.w), 1e-4);
    return vec3<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, select(-1.0, 1.0, clip.w > 0.0));
}

fn bolt_disp(len: f32, u: f32, seed: f32, tq: f32) -> f32 {
    let amp = len * 0.2;
    let n1 = (vnoise(vec2<f32>(u * 4.0 + seed, tq)) - 0.5) * 2.0;
    let n2 = (vnoise(vec2<f32>(u * 13.0 + seed * 3.1, tq * 1.7)) - 0.5) * 2.0;
    let n3 = (vnoise(vec2<f32>(u * 41.0 + seed * 5.3, tq * 2.3)) - 0.5) * 2.0;
    return (n1 * amp + n2 * amp * 0.38 + n3 * amp * 0.12) * smoothstep(0.0, 0.1, u);
}

// x: hot core, y: soft glow, z: position along the bolt (0 at its root)
fn bolt_line(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, seed: f32, tq: f32, wid: f32) -> vec3<f32> {
    let ab = b - a;
    let len = max(length(ab), 1.0e-4);
    let dir = ab / len;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let ap = p - a;
    let u = clamp(dot(ap, dir) / len, 0.0, 1.0);
    let off = dot(ap, nrm) - bolt_disp(len, u, seed, tq);
    let along = dot(ap, dir) - u * len;
    let d = length(vec2<f32>(off, along));
    let w = wid * (1.0 - 0.75 * u);
    let core = exp(-pow(d / w, 2.0));
    let g = 1.0 / (1.0 + pow(d / (w * 3.0), 2.0));
    return vec3<f32>(core, g * g, u);
}

// Soft capsule between two points of a plane (world units): x = hot core, y = glow. Thinner towards the far end.
fn seg_soft(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, w: f32) -> vec2<f32> {
    let ab = b - a;
    let l2 = max(dot(ab, ab), 1.0e-8);
    let u = clamp(dot(p - a, ab) / l2, 0.0, 1.0);
    let d = length(p - (a + ab * u));
    let ww = w * (1.0 - 0.65 * u);
    return vec2<f32>(exp(-pow(d / ww, 2.0)), 1.0 / (1.0 + pow(d / (ww * 4.0), 2.0)));
}

// Distance-based edge of one equilateral triangle (circumradius R) at polar (r, ang); its edges face ang = 0, 120, 240 degrees.
fn tri_line(r: f32, ang: f32, R: f32, w: f32) -> f32 {
    let sector = TAU / 3.0;
    let a = ang - floor(ang / sector + 0.5) * sector;
    let d = r * cos(a) - R * 0.5;
    return exp(-pow(d / w, 2.0)) * (1.0 - smoothstep(R * 0.98, R * 1.04, r));
}

// Distance from the view ray to a vertical axis at xz `c` (camera-relative): x = ray distance at closest approach,
// y = distance from the axis there, z = height of that point. x < 0 when the axis is behind.
fn axis_hit(c: vec2<f32>, v2: vec2<f32>, vv: f32, cam_y: f32, rdy: f32) -> vec3<f32> {
    var t = length(c);
    var d = length(c);
    if (vv > 1.0e-5) {
        t = dot(c, v2) / vv;
        d = length(c - v2 * t);
    }
    return vec3<f32>(t, d, cam_y + rdy * t);
}

// ---- laser 2: the black hole ----------------------------------------------------------------
// A singularity hangs over the target. Light is bent round it by marching each view ray that passes near it through
// the hole's gravity (the photon orbit equation, r'' = -1.5 h^2 r / |r|^5, in horizon radii): rays that fall in are
// black, rays that cross the disk pick up its light, and the rest resample the scene (or the starry sky) in the
// direction they leave in. Its jet is a vertical column like the other lasers' beams.

const HOLE_H: f32 = 28.0;         // keep in step with strike.rs: HOLE_H, BH_END
const BH_END: f32 = 10.0;
const BH_RS: f32 = 3.6;           // the horizon's radius, in blocks
const DISK_IN: f32 = 2.6;         // the accretion disk, in horizon radii
const DISK_OUT: f32 = 9.0;
const LENS_R: f32 = 12.0;         // how far out light is bent, in horizon radii

// A dark sky of stars and violet haze, looking along `d`.
fn bh_sky(d: vec3<f32>, seed: f32) -> vec3<f32> {
    let q = d * 140.0;
    let f = fract(q) - 0.5;
    let h = fh31(floor(q) + vec3<f32>(seed));
    let star = step(0.975, h) * exp(-dot(f, f) * 40.0) * (0.5 + 4.0 * fract(h * 37.0));
    let tint = mix(vec3<f32>(0.7, 0.8, 1.25), vec3<f32>(1.25, 0.9, 0.7), fract(h * 91.0));
    let neb = ffbm3(d * 2.6 + vec3<f32>(seed * 0.01));
    let neb2 = ffbm3(d * 6.0 - vec3<f32>(2.0, 0.0, 1.0));
    let haze = vec3<f32>(0.10, 0.02, 0.17) * smoothstep(0.4, 0.85, neb) + vec3<f32>(0.02, 0.04, 0.13) * smoothstep(0.5, 0.9, neb2);
    return tint * star + haze;
}

// The disk's colour by temperature: dull red at the rim, orange, white, then blue-white at the inner edge.
fn disk_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.0), vec3<f32>(0.7, 0.07, 0.02), smoothstep(0.0, 0.25, h));
    c = mix(c, vec3<f32>(2.4, 0.75, 0.12), smoothstep(0.2, 0.5, h));
    c = mix(c, vec3<f32>(3.4, 2.5, 1.35), smoothstep(0.45, 0.75, h));
    c = mix(c, vec3<f32>(3.2, 3.6, 5.0), smoothstep(0.75, 1.0, h));
    return c;
}

// The scene at `uvs`, dimmed, its sky turned to the black hole's starry dark (seen along `dir`).
fn bh_scene(uvs: vec2<f32>, dir: vec3<f32>, seed: f32, sky_env: f32, dim: f32) -> vec3<f32> {
    let c = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uvs, 0.0).rgb) * dim;
    if (is_sky(depth_at(uvs))) {
        return mix(c, bh_sky(dir, seed), sky_env * 0.94);
    }
    return c;
}

// ---- the black hole's debris: blocks torn out of the ground, spiralling in, eaten or flung ----
// strike.rs tears the same blocks out of the ground at the same moments (debris_*): keep the formulas in step.
const DEBRIS: i32 = 160;

fn debris_angle(fi: f32, seed: f32) -> f32 { return fract(fi * 0.381966 + seed * 0.1137) * TAU; }
fn debris_r0(fi: f32, seed: f32) -> f32 { return 35.0 + 15.0 * fract(fi * 0.618034 + seed * 0.1234); }
fn debris_t(fi: f32) -> f32 { return 0.4 + 6.0 * fi / f32(DEBRIS) + 0.3 * fract(fi * 0.7548777); }
fn debris_big(fi: f32, seed: f32) -> bool { return fract(fi * 0.2763932 + seed * 0.0517) > 0.78; }

fn rot_axis(v: vec3<f32>, a: vec3<f32>, ang: f32) -> vec3<f32> {
    let c = cos(ang);
    let s = sin(ang);
    return v * c + cross(a, v) * s + a * dot(a, v) * (1.0 - c);
}

// ---- falling into a black hole (the Black Hole's and the Downfall's debris, and the Downfall's wreck) ----
// How far out a piece is `u` (0 to 1) of the way through its fall from `r0`: from rest, slowly at first, then faster and
// faster, through the horizon and into the middle by u = 1 (r0 (1 - u²)^(2/3), close to a free fall's).
fn bh_fall(r0: f32, u: f32) -> f32 {
    return r0 * pow(max(1.0 - u * u, 0.0), 0.6667);
}
// How many times as long a piece `l0` long is drawn out at `u` through its fall from `r0` (its near end at `r`, bh_fall):
// its far end falls the same way from further out, so later (`lag` times as long: the free fall's time goes as r^1.5),
// and the gap between them grows faster and faster as they near the hole; at most 6 times.
fn bh_tide(r0: f32, l0: f32, r: f32, u: f32, lag: f32) -> f32 {
    return clamp((bh_fall(r0 + l0, u / lag) - r) / l0, 1.0, 6.0);
}
// No less than bh_tide, without its pow (the far end's fall to first order): for culling.
fn bh_tide_max(r0: f32, l0: f32, r: f32, u: f32, lag: f32) -> f32 {
    let rt = (r0 + l0) / r0 * r * (1.0 + 1.3333 * u * u * (1.0 - 1.0 / lag) / max(1.0 - u * u, 1.0e-4));
    return select(clamp((rt - r) / l0, 1.0, 6.0), 6.0, u > 0.97);
}
// The light from something `r` from the hole: redder and dimmer nearer the horizon (climbing out of the hole's pull),
// none from the horizon in.
fn bh_redshift(r: f32, rs: f32) -> vec3<f32> {
    let z = sqrt(saturate(1.0 - rs / max(r, 1.0e-3)));
    return vec3<f32>(pow(z, 0.7), pow(z, 1.6), pow(z, 2.6));
}
// A ray from the camera (`rd`) against a piece falling in: a box of half-size `hs`, turned `ang` about `ax`, drawn out
// `k` times along `u` (out from the hole) and thinned across about its middle `c` (camera-relative); none of it from the
// horizon (`rs` round `H`) in. How far (x, -1: missed), and where on it in its own space (yzw, the box -1 to 1).
fn bh_chunk(c: vec3<f32>, rd: vec3<f32>, u: vec3<f32>, k: f32, hs: f32, ax: vec3<f32>, ang: f32, H: vec3<f32>, rs: f32) -> vec4<f32> {
    let sk = sqrt(k);
    let ro = -c;
    let ro_s = (ro - u * dot(u, ro)) * sk + u * dot(u, ro) / k;
    let rd_s = (rd - u * dot(u, rd)) * sk + u * dot(u, rd) / k;
    let ro_l = rot_axis(ro_s, ax, -ang) / hs;
    let rd_l = rot_axis(rd_s, ax, -ang) / hs;
    let inv = 1.0 / select(rd_l, vec3<f32>(1.0e-6), abs(rd_l) < vec3<f32>(1.0e-6));
    let ta = (vec3<f32>(-1.0) - ro_l) * inv;
    let tb = (vec3<f32>(1.0) - ro_l) * inv;
    let tlo = min(ta, tb);
    let thi = max(ta, tb);
    let tn = max(max(tlo.x, tlo.y), tlo.z);
    let tf = min(min(thi.x, thi.y), thi.z);
    // (where the ray meets it inside the horizon, what is behind is in the hole's shadow)
    if (tf < tn || tn < 0.0 || length(rd * tn - H) < rs) {
        return vec4<f32>(-1.0);
    }
    return vec4<f32>(tn, ro_l + rd_l * tn);
}
// The world normal of the face of a bh_chunk box at `lp` (its own space).
fn bh_chunk_n(lp: vec3<f32>, u: vec3<f32>, k: f32, ax: vec3<f32>, ang: f32) -> vec3<f32> {
    let al = abs(lp);
    var nl = vec3<f32>(0.0, sign(lp.y), 0.0);
    if (al.x >= al.y && al.x >= al.z) {
        nl = vec3<f32>(sign(lp.x), 0.0, 0.0);
    } else if (al.z >= al.y) {
        nl = vec3<f32>(0.0, 0.0, sign(lp.z));
    }
    // (the stretch is symmetric, so normals go back through it as it is)
    let ns = rot_axis(nl, ax, ang);
    return normalize((ns - u * dot(u, ns)) * sqrt(k) + u * dot(u, ns) / k);
}

// One piece of debris: where its near end is (camera-relative), its radial direction from the hole, how stretched it
// is (or below 0: drawn out by the tides, worked out by bh_tide from `tide` (r0, l0, u, lag) and `r` only once the ray is
// known to pass near it), how hot, how present (0: not there).
struct Piece {
    c: vec3<f32>,
    u: vec3<f32>,
    k: f32,
    glow: f32,
    alive: f32,
    tide: vec4<f32>,
    r: f32,
}

fn debris_piece(i: i32, ft: f32, seed: f32, cam: vec3<f32>, tgt: vec3<f32>, H: vec3<f32>, n: vec3<f32>, rs: f32) -> Piece {
    var pc: Piece;
    pc.alive = 0.0;
    pc.k = 1.0;
    pc.glow = 0.0;
    pc.u = vec3<f32>(0.0, 1.0, 0.0);
    pc.c = vec3<f32>(0.0);
    let fi = f32(i);
    let t_rip = debris_t(fi);
    let s = min(ft, BH_END) - t_rip;
    if (s <= 0.0) {
        return pc;
    }
    let a0 = debris_angle(fi, seed);
    let R0 = debris_r0(fi, seed);
    let big = debris_big(fi, seed);
    let h1 = fh21(vec2<f32>(fi, seed + 5.0));
    let h2 = fh21(vec2<f32>(fi, seed + 9.0));
    let T_in = 2.6 + 1.4 * h2;
    let flung = h1 < 0.28;
    let u_f = 0.5 + 0.2 * h2;
    let ub = s / T_in;
    let l0 = select(1.0, 2.0, big);
    let lag = (R0 + l0) / R0 * sqrt((R0 + l0) / R0);
    let u = min(ub, select(lag, u_f, flung));
    // the disk's plane, with world x and z laid onto it so the orbit starts where the block was torn out
    let E1 = normalize(vec3<f32>(1.0, 0.0, 0.0) - n * n.x);
    let E2 = normalize(vec3<f32>(0.0, 0.0, 1.0) - n * n.z - E1 * dot(vec3<f32>(0.0, 0.0, 1.0), E1));
    let rsn = max(rs, 0.6);
    // its near end falls from rest, faster and faster, through the horizon to the middle; its far end, a block or two
    // further out, falls in a little after it (the free fall's time goes as r^1.5): so the tides draw it out along the
    // way in, more and more as it nears the hole
    let r = bh_fall(R0, u);
    let th = a0 - (3.0 + 3.0 * h1) * u * u;                    // the same way round as the disk turns
    let lift = smoothstep(0.0, 0.45, u);
    // torn out of the ground where strike.rs removes it (block-aligned), then up into the disk's plane
    let src = floor(tgt.xz + vec2<f32>(cos(a0), sin(a0)) * R0) + select(vec2<f32>(0.5), vec2<f32>(0.0), big);
    let gy = block_y() + select(0.5, 0.0, big);           // the hit block's layer, which the blast levels the ground to
    let ground = vec3<f32>(src.x, gy, src.y) - cam;
    let ground_r = vec3<f32>(tgt.x - cam.x, gy - cam.y, tgt.z - cam.z) + vec3<f32>(cos(th), 0.0, sin(th)) * r;
    let gp = mix(ground, ground_r, smoothstep(0.0, 0.15, u));
    let dp = H + (E1 * cos(th) + E2 * sin(th)) * r;
    var c = mix(gp, dp, lift) + vec3<f32>(0.0, sin(lift * 3.14159) * 7.0, 0.0);
    var alive = smoothstep(0.0, 0.05, s);
    var stretch = select(1.0, -bh_tide_max(R0, l0, r, u, lag), !flung || ub < u_f);
    if (flung && ub > u_f) {
        // slingshot round the hole and away
        let dt = (ub - u_f) * T_in;
        let tdir = E1 * sin(th) - E2 * cos(th);
        c = c + (tdir * 65.0 + n * 16.0) * dt;
        alive = alive * (1.0 - smoothstep(2.5, 4.0, dt));
        stretch = 1.0;
    } else if (!flung) {
        // eaten: gone once its far end too is through the horizon
        alive = alive * (1.0 - step(lag, ub));
    }
    if (ft > BH_END) {
        // what was still circling when it evaporated is thrown outwards
        let ef = ft - BH_END;
        c = c + normalize(c - H) * ef * 70.0;
        alive = alive * (1.0 - smoothstep(1.0, 2.5, ef));
        stretch = 1.0;
    }
    pc.u = normalize(c - H + vec3<f32>(1.0e-4));
    pc.c = c;
    pc.k = stretch;
    pc.tide = vec4<f32>(R0, l0, u, lag);
    pc.r = r;
    pc.glow = select(smoothstep(rsn * 4.0, rsn * 1.2, r), 0.0, flung && ub > u_f) * f32(ft <= BH_END);
    pc.alive = alive;
    return pc;
}

// A block's face colour (sRGB) at face pixel `px`: grass, dirt, stone, deepslate, log or leaves.
fn debris_tex(kind: i32, px: vec2<f32>, top: bool, side_y: f32, seed: f32) -> vec3<f32> {
    let nz = fh21(px + vec2<f32>(seed * 3.1, f32(kind) * 17.0));
    let nz2 = fh21(px * 1.7 + vec2<f32>(5.0, seed));
    switch kind {
        case 0: {
            if (top || side_y > 0.8) {
                return vec3<f32>(0.33, 0.55, 0.2) * (0.75 + 0.45 * nz);
            }
            return vec3<f32>(0.52, 0.36, 0.24) * (0.75 + 0.45 * nz);
        }
        case 1: { return vec3<f32>(0.52, 0.36, 0.24) * (0.75 + 0.45 * nz); }
        case 2: { return vec3<f32>(0.5, 0.5, 0.5) * (0.78 + 0.35 * nz) * (0.9 + 0.1 * nz2); }
        case 3: { return vec3<f32>(0.27, 0.27, 0.3) * (0.75 + 0.4 * nz); }
        case 4: {
            if (top) {
                let ring = fract(length(px - vec2<f32>(7.5)) * 0.35);
                return mix(vec3<f32>(0.68, 0.55, 0.34), vec3<f32>(0.5, 0.38, 0.22), step(0.5, ring)) * (0.9 + 0.2 * nz);
            }
            return vec3<f32>(0.4, 0.31, 0.19) * (0.7 + 0.5 * hash21(vec2<f32>(px.x, seed))) * (0.9 + 0.2 * nz);
        }
        default: {
            return vec3<f32>(0.2, 0.42, 0.13) * (0.5 + 0.8 * nz) * (0.6 + 0.4 * step(0.25, nz2));
        }
    }
}

// What a view ray brings back past a black hole at `H` (camera-relative) of horizon radius `rs_l`: it is marched through
// the hole's gravity (the photon orbit equation, in horizon radii), picking up the disk's light (`acc`, seen through
// `trans` of it) where it crosses the disk's plane (normal `n`, `e1` `e2` in it), and either falls in (`captured`), ends
// on the scene (`hit`), or leaves along `v` from `p` (camera-relative) and resamples the scene that way (`bent`; `w`
// how much the bending counts). `on`: whether the ray came near enough to be bent at all.
struct BhLens {
    on: bool,
    captured: bool,
    hit: bool,
    bent: vec3<f32>,
    trans: f32,
    acc: vec3<f32>,
    rmin: f32,
    p: vec3<f32>,
    v: vec3<f32>,
    w: f32,
}
fn bh_lens(H: vec3<f32>, rs_l: f32, rd: vec3<f32>, uv2: vec2<f32>, scene_len: f32, sky: bool, n: vec3<f32>, e1: vec3<f32>,
           e2: vec3<f32>, disk_env: f32, hot: f32, seed: f32, time: f32, sky_env: f32, dim: f32) -> BhLens {
    var L: BhLens;
    L.on = false;
    L.captured = false;
    L.hit = false;
    L.bent = vec3<f32>(0.0);
    L.trans = 1.0;
    L.acc = vec3<f32>(0.0);
    L.rmin = 1.0e9;
    L.p = vec3<f32>(0.0);
    L.v = rd;
    L.w = 0.0;
    let infl = LENS_R * rs_l;
    let tc = dot(H, rd);
    let b = length(H - rd * tc);
    let t0 = max(tc - infl, 0.0);
    if (b < infl && tc + infl > 0.0 && scene_len > t0) {
        L.on = true;
        var pp = (rd * t0 - H) / rs_l;                     // the ray, relative to the hole, in horizon radii
        var v = rd;
        var travel = t0;
        let hv = cross(pp, v);
        let h2 = dot(hv, hv);
        var trans = 1.0;
        var acc = vec3<f32>(0.0);
        var captured = false;
        var hit = false;
        var rmin = 1.0e9;
        for (var i = 0; i < 96; i = i + 1) {
            let r = length(pp);
            rmin = min(rmin, r);
            if (r < 1.0) {
                captured = true;
                break;
            }
            if (r > LENS_R + 0.5 && dot(pp, v) > 0.0) {
                break;
            }
            let dt = clamp((r - 0.9) * 0.16, 0.03, 1.5);
            let prev = pp;
            let r2 = r * r;
            v = normalize(v - 1.5 * h2 * pp / (r2 * r2 * r) * dt);
            pp = pp + v * dt;
            travel = travel + dt * rs_l;
            if (!sky && travel > scene_len) {
                hit = true;
                break;
            }
            // crossing the disk's plane: its light, seen through whatever bending got the ray here
            let s0 = dot(prev, n);
            let s1 = dot(pp, n);
            if (disk_env > 0.001 && s0 * s1 < 0.0) {
                let x = mix(prev, pp, s0 / (s0 - s1));
                let dr = length(x);
                if (dr > DISK_IN * 0.9 && dr < DISK_OUT) {
                    let dx = vec2<f32>(dot(x, e1), dot(x, e2));
                    // inner rings turn faster than outer ones (Kepler), so the gas shears into streaks
                    let rot = -time * 5.5 / pow(dr, 1.5);
                    let q = vec2<f32>(dx.x * cos(rot) - dx.y * sin(rot), dx.x * sin(rot) + dx.y * cos(rot));
                    let nz = fbm(q * 0.9 + vec2<f32>(seed, 3.0));
                    let bands = 0.55 + 0.45 * sin(dr * 7.0 + nz * 7.0);
                    let dens = saturate(bands * (0.35 + 1.1 * nz));
                    let edge = smoothstep(DISK_IN * 0.9, DISK_IN * 1.15, dr) * (1.0 - smoothstep(DISK_OUT * 0.55, DISK_OUT, dr));
                    // the side turning towards you is brighter and bluer (relativistic beaming)
                    let tdir = normalize(cross(n, x));
                    let beta = 0.62 * sqrt(DISK_IN / dr);
                    let g = sqrt(1.0 - beta * beta) / (1.0 - beta * dot(tdir, -v));
                    let temp = pow(DISK_IN / dr, 0.85) * (0.7 + 0.4 * nz) * g * 0.95 * hot;
                    let a_d = saturate(dens * edge * 1.1) * disk_env;
                    acc = acc + trans * a_d * disk_ramp(temp) * min(g * g * g, 4.0) * 1.6;
                    trans = trans * (1.0 - a_d * 0.92);
                }
            }
            if (trans < 0.02) {
                break;
            }
        }
        // how much the bending counts: all of it near the hole, none at the edge, so it meets the unbent world
        let w = 1.0 - smoothstep(LENS_R * 0.35, LENS_R * 0.95, rmin);
        var bent = vec3<f32>(0.0);
        if (!captured) {
            let dir_b = normalize(mix(rd, v, w));
            var far = H + pp * rs_l + v * 4000.0;
            if (hit) {
                far = H + pp * rs_l;
            }
            let pr = project_rel(far);
            let uvb = mix(uv2, pr.xy, w);
            let on = pr.z > 0.0 && all(uvb > vec2<f32>(0.001)) && all(uvb < vec2<f32>(0.999));
            if (on || w < 0.01) {
                bent = bh_scene(clamp(uvb, vec2<f32>(0.001), vec2<f32>(0.999)), dir_b, seed, sky_env, dim);
            } else if (dir_b.y > -0.03) {
                bent = bh_sky(dir_b, seed) * sky_env + vec3<f32>(0.03, 0.025, 0.04) * (1.0 - sky_env);
            } else {
                bent = vec3<f32>(0.02, 0.016, 0.022) * dim;
            }
        }
        L.captured = captured;
        L.hit = hit;
        L.bent = bent;
        L.trans = trans;
        L.acc = acc;
        L.rmin = rmin;
        L.p = H + pp * rs_l;
        L.v = v;
        L.w = w;
    }
    return L;
}


// Gradient noise (smooth, without the square grid value noise shows), from a cheap integer hash, for the meteor
// storm's fire and smoke. Each octave is turned so their grids never line up.
fn pcg3d(v0: vec3<u32>) -> vec3<u32> {
    var v = v0 * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> vec3<u32>(16u));
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}
fn grad3(i: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(i)))) * (2.0 / 4294967295.0) - 1.0;
}
fn gnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n000 = dot(grad3(i), f);
    let n100 = dot(grad3(i + vec3<f32>(1.0, 0.0, 0.0)), f - vec3<f32>(1.0, 0.0, 0.0));
    let n010 = dot(grad3(i + vec3<f32>(0.0, 1.0, 0.0)), f - vec3<f32>(0.0, 1.0, 0.0));
    let n110 = dot(grad3(i + vec3<f32>(1.0, 1.0, 0.0)), f - vec3<f32>(1.0, 1.0, 0.0));
    let n001 = dot(grad3(i + vec3<f32>(0.0, 0.0, 1.0)), f - vec3<f32>(0.0, 0.0, 1.0));
    let n101 = dot(grad3(i + vec3<f32>(1.0, 0.0, 1.0)), f - vec3<f32>(1.0, 0.0, 1.0));
    let n011 = dot(grad3(i + vec3<f32>(0.0, 1.0, 1.0)), f - vec3<f32>(0.0, 1.0, 1.0));
    let n111 = dot(grad3(i + vec3<f32>(1.0, 1.0, 1.0)), f - vec3<f32>(1.0, 1.0, 1.0));
    let x0 = mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y);
    let x1 = mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y);
    return mix(x0, x1, u.z) * 0.75 + 0.5;
}
fn gfbm3(p: vec3<f32>, octaves: i32) -> f32 {
    let m = mat3x3<f32>(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64);
    var q = p;
    var a = 0.5;
    var s = 0.0;
    var w = 0.0;
    for (var o = 0; o < octaves; o = o + 1) {
        s = s + a * gnoise3(q);
        w = w + a;
        q = m * q * 2.03 + vec3<f32>(1.7, 9.2, 5.3);
        a = a * 0.5;
    }
    return s / w;
}
fn grad2(i: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(vec2<i32>(i), 7))).xy) * (2.0 / 4294967295.0) - 1.0;
}
fn gnoise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = dot(grad2(i), f);
    let b = dot(grad2(i + vec2<f32>(1.0, 0.0)), f - vec2<f32>(1.0, 0.0));
    let c = dot(grad2(i + vec2<f32>(0.0, 1.0)), f - vec2<f32>(0.0, 1.0));
    let d = dot(grad2(i + vec2<f32>(1.0, 1.0)), f - vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.9 + 0.5;
}
fn gfbm2(p: vec2<f32>) -> f32 {
    let m = mat2x2<f32>(0.8, 0.6, -0.6, 0.8);
    let q1 = m * p * 2.03 + vec2<f32>(1.7, 9.2);
    let q2 = m * q1 * 2.01 + vec2<f32>(5.3, 2.8);
    return (0.5 * gnoise2(p) + 0.25 * gnoise2(q1) + 0.125 * gnoise2(q2)) / 0.875;
}
// A dither that changes from pixel to pixel without clumping, to hide the steps of a march.
fn ign(px: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(px, vec2<f32>(0.06711056, 0.00583715))));
}

// ---- laser 3: the meteor storm ------------------------------------------------------------------
// Seventy-two meteors come in from one direction and land over the land round the target, then one the size of a
// hill comes down on the target itself. Each meteor is a glowing head and a trail on its path, hidden by the terrain
// in front of it (so it disappears into the ground where it really hits), a fireball and a ring on the ground where it
// lands. strike.rs digs the craters at the same places and moments (met_*): keep the formulas in step.

const MET_N: i32 = 72;             // keep in step with strike.rs: MET_N, MET_SPAN, BIG_T
const MET_SPAN: f32 = 120.0;
const BIG_T: f32 = 13.5;           // the big one lands this long after the fire, on the target
const BIG_R: f32 = 16.0;           // its radius, in blocks
const MET_V: f32 = 150.0;          // how fast the small ones are going when they land, blocks a second
const MET_A: f32 = 45.0;           // how hard the air slows them (they come in four times faster)
const MET_ENTRY: f32 = 5.0;        // seconds from the top of their path to the ground
const BIG_V: f32 = 260.0;
const MET_END: f32 = 34.0;         // when everything has faded (the strike runs 38 s)

// A meteor's own random numbers (`k` picks which): an integer hash, so strike.rs gets exactly the same ones.
fn mh(i: u32, seed: u32, k: u32) -> f32 { return f32(pcg(i ^ pcg(seed ^ pcg(k)))) * (1.0 / 4294967296.0); }
// Where a meteor lands (x, z off the target) and when (seconds after the fire). A third of them come down together,
// the fragments of one that broke up, close to one another and within a second or so of each other; the rest
// anywhere, at any time.
fn met_where(fi: f32, seed: f32) -> vec3<f32> {
    let i = u32(fi);
    let s = u32(seed);
    if (mh(i, s, 5u) < 0.33) {
        let c = 100u + min(u32(mh(i, s, 6u) * 6.0), 5u);
        let ca = mh(c, s, 1u) * TAU;
        let cr = 24.0 + (MET_SPAN - 30.0) * sqrt(mh(c, s, 2u));
        let oa = mh(i, s, 7u) * TAU;
        let orr = 3.0 + 11.0 * mh(i, s, 8u);
        let pos = vec2<f32>(cos(ca), sin(ca)) * cr + vec2<f32>(cos(oa), sin(oa)) * orr;
        return vec3<f32>(pos, 3.0 + 8.5 * mh(c, s, 3u) + 1.4 * mh(i, s, 9u));
    }
    let a = mh(i, s, 1u) * TAU;
    let r = 14.0 + (MET_SPAN - 14.0) * sqrt(mh(i, s, 2u));
    return vec3<f32>(cos(a) * r, sin(a) * r, 2.5 + 9.5 * mh(i, s, 3u));
}
fn met_t(fi: f32, seed: f32) -> f32 { return met_where(fi, seed).z; }
// How far up its path a meteor is `tau` seconds before it lands, and when (seconds before landing) it passed `l`.
fn met_path(tau: f32) -> f32 { return MET_V * tau + MET_A * tau * tau; }
fn met_when(l: f32) -> f32 { return (sqrt(MET_V * MET_V + 4.0 * MET_A * l) - MET_V) / (2.0 * MET_A); }
fn met_off(fi: f32, seed: f32) -> vec2<f32> { return met_where(fi, seed).xy; }
fn met_class(fi: f32, seed: f32) -> i32 {
    let h = mh(u32(fi), u32(seed), 4u);
    return select(select(2, 1, h < 0.87), 0, h < 0.6);
}
// Where a meteor comes from (pointing back up its path): all from one part of the sky, a little scattered.
fn met_dir(fi: f32, seed: f32, elev: f32, spread: f32) -> vec3<f32> {
    let phi = fract(seed * 0.0911) * TAU + (fh21(vec2<f32>(fi, 31.0)) - 0.5) * 0.45 * spread;
    let e = elev + (fh21(vec2<f32>(fi, 37.0)) - 0.5) * 0.3 * spread;
    return vec3<f32>(cos(e) * cos(phi), sin(e), cos(e) * sin(phi));
}

// The closest approach of the view ray (from the eye, along `rd`) to the segment ab (camera-relative):
// x = the distance between them, y = how far along the ray, z = where along ab (0 at a).
fn ray_seg(rd: vec3<f32>, a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    let ab = b - a;
    let l2 = max(dot(ab, ab), 1.0e-6);
    let rab = dot(rd, ab);
    let den = l2 - rab * rab;
    var s = clamp(select(0.0, (rab * dot(rd, a) - dot(a, ab)) / den, den > 1.0e-6), 0.0, 1.0);
    let t = max(dot(rd, a + ab * s), 0.0);
    s = clamp(dot(rd * t - a, ab) / l2, 0.0, 1.0);
    return vec3<f32>(length(rd * t - (a + ab * s)), t, s);
}


const CLOUD_Y: f32 = 192.0;        // the vanilla cloud layer

const FW_RIPPLE: f32 = 6.6;
const FW_SCORE: f32 = 12.0;
const FW_TEAR: f32 = 16.0;
const FW_FOLD: f32 = 19.0;
const FW_SEAL: f32 = 35.0;
const FW_CRUSH: f32 = 35.0;
const FW_BEAT: f32 = 40.0;
const FW_REL: f32 = 40.5;
const FW_FLAT: f32 = 44.1;         // strike/fold.rs's FD_SLAM[0]: the first ring lands, all else still up
const FW_SLAM4: f32 = 48.7;        // the last of the slams (strike/fold.rs's FD_SLAM)
const FW_END: f32 = 56.7;
const FW_FADE: f32 = 49.1;         // the comedown begins
const FW_TAU: f32 = 6.2831853;
const FW_PI: f32 = 3.14159265;
const FW_LEN: f32 = 480.0;         // the sheet's length, the last ring (strike/fold.rs's FD_RINGS[4])
const FW_SINK: f32 = 16.0;         // how far the sheet sinks from under the player
const FW_FEET: f32 = 15.0;         // how far from the player the land is all their own, no part of the sheet's motion
const FW_EYE: f32 = 1.62;          // their eye over their feet
const FW_LAND_R: f32 = 480.0;      // from FD_LAND on the crater is in the land within this: nothing is cut under it
const FW_BOWL: f32 = 66.0;         // how deep the crater's bowl is (strike/fold_land.rs's FD_BOWL)
const FW_SUNK: f32 = 6.6;          // the crater has fallen in by this long after the last slam
const FW_ERUPT: f32 = 49.9;         // what was pent up bursts out (strike/fold.rs's FD_ERUPT)
const FW_ISLE: f32 = 41.4;          // the land round the player, chunk by chunk, left for the last slam (strike/fold_land.rs's FD_ISLE + 11.4)
const FW_CAVE_SLOW: f32 = 10.0;     // the panels fall slower than the player's own, which has them on it
const FW_CAVE: f32 = 18.0;         // half the panels' fall's acceleration, blocks a second squared: a little more than what the player falls with

// ---- what can be taken out: 0 turns each off -----------------------------------------------------------------------
const FW_IRID: f32 = 1.0;          // the iridescence's strength: 1 is about 36 degrees of hue and a quarter more saturation at its peak
const FW_FRACTAL: f32 = 1.0;       // block faces showing smaller copies of themselves
const FW_PLEATS: f32 = 1.0;        // the radial pleats
const FW_UNDER: f32 = 1.0;         // the sheet's underside painted as rock
const FW_LAY0: f32 = 27.6;         // the bud lies down onto the sphere's floor between these
const FW_LAY1: f32 = 32.6;
const FW_FLAT0: f32 = 34.5;        // from here on the sheet lies on the sphere with nothing left standing on it
const FW_WRAP0: f32 = 27.0;        // the roll's ring comes in to the target, its tube to the sphere's size, from here to FW_SEAL
const FW_SINK_END: f32 = 0.0;      // how much of FW_SINK is left once the sheet lies on the sphere
const FW_HOLD: f32 = 31.5;         // the fold's clock where the tube stops closing (fw_tb)
const FW_EASE: f32 = 1.5;          // how long it takes to stop
const FW_TUBE_W: f32 = 0.5933;     // fw_bend's w, and how much of the r0 of fw_bend is left, as it holds
const FW_TUBE_R0: f32 = 0.352;
const FW_END_K: f32 = 0.97;        // how much of the far land's reach is drawn: its own end goes in steps, a chunk at a time, and this one is a circle
const FW_MOUTH: f32 = 2.8;         // how far round the tube the land's end comes, radians, wherever the far land ends
fn fw_ss(a: f32, b: f32, x: f32) -> f32 {
    let t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
// ---- the sphere ------------------------------------------------------------------------------------------------------
// How big it ends: the player well inside, whatever their distance and however high they stood over the target.
fn fw_radius(d: f32, y: f32) -> f32 {
    return max(max(d * 1.3, 170.0), y * 1.15);
}
// The fold's clock: the strike's up to FW_BEAT, then back to FW_BACK by FW_FLAT. Not the fold played backwards: it stays shut through the touch and while the metal goes;
// the tube gives all at once and catches itself, hangs there, and then lets go for good, the far land falling away as it did.
const FW_BACK: f32 = 20.0;
fn fw_tau(t: f32) -> f32 {
    if (t < FW_BEAT) {
        return t;
    }
    if (t < FW_REL) {
        return FW_BEAT;
    }
    if (t < 42.2) {
        return fw_h(vec3<f32>(FW_REL, FW_BEAT, 0.0), vec3<f32>(42.2, 34.6, -3.0), t);
    }
    if (t < 42.55) {
        return fw_h(vec3<f32>(42.2, 34.6, -3.0), vec3<f32>(42.55, 32.0, -8.5), t);
    }
    if (t < 42.88) {
        return fw_h(vec3<f32>(42.55, 32.0, -8.5), vec3<f32>(42.88, 31.1, -1.0), t);
    }
    if (t < 43.3) {
        return fw_h(vec3<f32>(42.88, 31.1, -1.0), vec3<f32>(43.3, 28.37, -6.7), t);
    }
    let u = clamp((t - FW_REL) / (FW_FLAT - FW_REL), 0.0, 1.0);
    return FW_BEAT - (FW_BEAT - FW_BACK) * u * u * (3.11 + u * (-5.05 + u * 2.94));
}
// ...and it doesn't go all round at once: as the tube gives, each side of it is a little ahead of or behind the rest.
fn fw_uneven(a: f32, t: f32) -> f32 {
    return 0.9 * fw_ss(42.15, 42.6, t) * (1.0 - fw_ss(43.0, 43.45, t)) * (sin(a * 2.0 + 0.8) + 0.6 * sin(a * 3.0 - 1.2));
}
// ---- what isn't on the fold's clock, keyed by hand -------------------------------------------------------------------------
// One piece of a track: from (time, value, slope) a to b.
fn fw_h(a: vec3<f32>, b: vec3<f32>, t: f32) -> f32 {
    let w = b.x - a.x;
    let u = clamp((t - a.x) / w, 0.0, 1.0);
    let u2 = u * u;
    let u3 = u2 * u;
    return a.y * (2.0 * u3 - 3.0 * u2 + 1.0) + b.y * (3.0 * u2 - 2.0 * u3) + w * (a.z * (u3 - 2.0 * u2 + u) + b.z * (u3 - u2));
}
// How much further round the tube the land's end comes, radians: the hole closing on the boil (fold.wgsl), slow to start, heavy; on the way back it holds through the touch,
// lets go with the metal at FW_LETGO, opens fast, past where it was, and settles.
const FW_SHUT: f32 = 0.15;
const FW_LETGO: f32 = 40.95;
fn fw_shut(t: f32) -> f32 {
    if (t < 32.5 || t > 42.3) { return 0.0; }
    if (t < 36.4) { return fw_h(vec3<f32>(32.5, 0.0, 0.0), vec3<f32>(36.4, FW_SHUT, 0.0), t); }
    if (t < FW_LETGO) { return FW_SHUT; }
    if (t < 41.5) { return fw_h(vec3<f32>(FW_LETGO, FW_SHUT, 0.0), vec3<f32>(41.5, -0.03, 0.0), t); }
    return fw_h(vec3<f32>(41.5, -0.03, 0.0), vec3<f32>(42.3, 0.0, 0.0), t);
}
// ---- the roll -----------------------------------------------------------------------------------------------------------
// Past `r0` the sheet rolls up and in over a tube of radius `rc`, up to `fm` round it. As the world closes r0 comes in to
// the target and the tube's radius to the sphere's: a tube whose ring has come down to nothing is a sphere, so it is one
// sheet and one motion from the horizon's first curl to the tube. `w` eases it from the roll's own spacing towards the stereographic
// map's, conformal, so that the land is only scaled, hardly stretched.
// The player's feet, and the land under them, are left where they are, level: the whole of it is turned about them.
struct FwBend { tau: f32, t: f32, d: f32, e: vec2<f32>, edge: f32, top: f32, r0: f32, rc: f32, fm: f32, w: f32, fit: f32, pin: f32, rim: f32, tail: f32 }
// The clock the tube closes by: `tau` to FW_HOLD - FW_EASE, then easing to a stop at FW_HOLD, and the same way back.
fn fw_tb(tau: f32) -> f32 {
    let s = FW_HOLD - FW_EASE;
    return select(tau, FW_HOLD - FW_EASE * exp((s - tau) / FW_EASE), tau > s);
}
const FW_TAIL0: f32 = 0.7;         // the land past the roll's end lies on along its tangent till fm is this, and is drawn in by FW_TAIL1
const FW_TAIL1: f32 = 1.5;
// How far the horizon has curled on its way up: an S in the time from FW_FOLD + 1 to FW_HOLD, starting slowly, fastest about half way, slowing into the tube. What it
// has to do is keep the land's end climbing as seen from the player: the land past the roll's end lies on along the tangent at first, and as that is drawn in
// (FW_UP_TAIL0 to FW_UP_TAIL1, on the clock, not on fm) the land's end would fall back unless the roll goes on round at the same time: hence the jump about 26.
// Worked out with the elevation of the land's end, and kept to that: tools/foldview's plots of it. (value, slope per second) every FW_UP_DT from FW_UP_T0.
const FW_UP_T0: f32 = 20.0;
const FW_UP_DT: f32 = 1.2777778;
var<private> FW_UP: array<vec2<f32>, 10> = array<vec2<f32>, 10>(vec2<f32>(0.0000, 0.0000), vec2<f32>(0.0170, 0.0226), vec2<f32>(0.0540, 0.0366), vec2<f32>(0.1160, 0.0636), vec2<f32>(0.2200, 0.0988), vec2<f32>(0.4350, 0.2902), vec2<f32>(0.8430, 0.2029), vec2<f32>(0.9020, -0.0056), vec2<f32>(0.9450, 0.0589), vec2<f32>(1.0000, 0.0000));
const FW_UP_TAIL0: f32 = 22.0;
const FW_UP_TAIL1: f32 = 28.0;
fn fw_up(tau: f32) -> f32 {
    let x = (tau - FW_UP_T0) / FW_UP_DT;
    if (x <= 0.0) {
        return 0.0;
    }
    if (x >= 9.0) {
        return 1.0;
    }
    let i = i32(x);
    let a = FW_UP[i];
    let b = FW_UP[i + 1];
    return fw_h(vec3<f32>(0.0, a.x, a.y * FW_UP_DT), vec3<f32>(1.0, b.x, b.y * FW_UP_DT), x - f32(i));
}
// Running back it goes as it always has: the curl and the tail by this.
fn fw_curl(tau: f32) -> f32 {
    return fw_ss(FW_FOLD + 1.0, 29.0, tau);
}
fn fw_bend(tau: f32, t: f32, foot: f32, mq: vec3<f32>, e: vec2<f32>, edge: f32, top: f32) -> FwBend {
    let d = length(mq.xz);
    let back = t >= FW_REL;
    let curl = select(fw_up(tau), fw_curl(tau), back);
    let tb = fw_tb(tau);
    let w = fw_ss(FW_WRAP0, FW_SEAL, tb);
    let S = fw_radius(d, mq.y);
    let r0 = (max(foot, d) + 170.0) * (1.0 - fw_ss(FW_WRAP0, FW_SEAL - 0.5, tb));
    let rc = mix(mix(3000.0, 700.0, select(fw_ss(FW_FOLD + 1.0, 24.0, tau), curl, back)), S, w);
    let fm = mix(curl * 3.2, FW_PI, w);
    let tail = 1.0 - select(fw_ss(FW_UP_TAIL0, FW_UP_TAIL1, tau), fw_ss(FW_TAIL0, FW_TAIL1, fm), back);
    // (where the far land ends is the player's setting: wherever that is, the land's end comes as far round the tube)
    let en = max(edge - r0, 1.0) / (rc * max(fm, 0.001));
    let fe = fm * mix(1.0 - exp(-en), 0.63662 * atan(en * 1.5707963), w);
    let fit = max(FW_MOUTH + fw_shut(t) - fe, 0.0) * fw_ss(FW_WRAP0, FW_HOLD, tb);
    return FwBend(tau, t, d, e, edge, top, r0, rc, fm, w, fit, mq.y, fw_rim(d), tail);
}
// A point R along the sheet, y over it, on the roll: (out from the axis, up, how far round).
fn fw_roll(R: f32, y: f32, g: FwBend) -> vec3<f32> {
    let u = R - g.r0;
    if (u <= 0.0 || g.fm < 0.001) {
        return vec3<f32>(R, y, 0.0);
    }
    let e = u / (g.rc * g.fm);
    let x = e * 1.5707963;
    let ex = exp(-e);
    var f = g.fm * mix(1.0 - ex, 0.63662 * atan(x), g.w);
    f = min(f + g.fit * fw_ss(0.2 * g.edge, g.edge, R), 3.3);
    let lip = 34.0 * g.w * pow(fw_ss(g.rim * 0.8, g.rim, R), 2.0);
    // (the roll is only rc * fm long, and fm starts from nothing: what is past that lies on along the tangent, or all the land out to the horizon would land on one
    // circle the moment it starts; drawn in as the roll grows long enough to take it)
    let rem = max(u - g.rc * f, 0.0) * g.tail;
    let yy = y * mix(mix(ex, 1.0 / (1.0 + x * x), g.w), 1.0, g.tail) - lip;
    let s = sin(f);
    let c = cos(f);
    return vec3<f32>(g.r0 + (g.rc - yy) * s + rem * c, g.rc * (1.0 - c) + yy * c + rem * s, f);
}
// Where the sheet goes: R along it from the target at the bearing (ca, sa), y over it. The result is from the target, x and z as the world's.
fn fw_place(R: f32, ca: f32, sa: f32, y: f32, g: FwBend) -> vec3<f32> {
    let on = fw_roll(R, y, g);
    return fw_turn(on.x * ca, on.y, on.x * sa, fw_roll(g.d, g.pin, g), g);
}
// Where the lip of the land near the target's own columns ends.
fn fw_rim(d: f32) -> f32 {
    return max(620.0, d + 480.0);
}
// The player's place on the held tube: fw_roll at that place, as the rim's tip has it. With fw_turned, what puts the rim's tip on the target:
// fold.wgsl's fd_seat and fd_turned light the target with the same (`the_warp_keeps_the_beats`).
fn fw_seat(d: f32, mh: f32) -> vec3<f32> {
    let S = fw_radius(d, mh);
    let rim = fw_rim(d);
    let r0 = (max(FW_LEN, d) + 170.0) * FW_TUBE_R0;
    let rc = mix(700.0, S, FW_TUBE_W);
    let fm = mix(3.2, FW_PI, FW_TUBE_W);
    let u = d - r0;
    if (u <= 0.0) {
        return vec3<f32>(d, mh, 0.0);
    }
    let e = u / (rc * fm);
    let x = e * 1.5707963;
    let ex = exp(-e);
    let f = min(fm * mix(1.0 - ex, 0.63662 * atan(x), FW_TUBE_W), 3.3);
    let lip = 34.0 * FW_TUBE_W * pow(fw_ss(rim * 0.8, rim, d), 2.0);
    let yy = mh * mix(ex, 1.0 / (1.0 + x * x), FW_TUBE_W) - lip;
    let s = sin(f);
    let c = cos(f);
    return vec3<f32>(r0 + (rc - yy) * s, rc * (1.0 - c) + yy * c, f);
}
// `du` along the land from the player's place and `dy` off it, turned to bring that place to their feet: (out from the axis, up).
fn fw_turned(du: f32, dy: f32, at: vec3<f32>, d: f32, mh: f32) -> vec2<f32> {
    let c = cos(at.z);
    let s = sin(at.z);
    return vec2<f32>(d + du * c + dy * s, -du * s + dy * c + mh);
}
// Turned about the feet, `at` on the roll, to bring them to the bottom.
fn fw_turn(x3: f32, Y: f32, z3: f32, at: vec3<f32>, g: FwBend) -> vec3<f32> {
    let dv = -x3 * g.e.y + z3 * g.e.x;
    let q = fw_turned(x3 * g.e.x + z3 * g.e.y - at.x, Y - at.y, at, g.d, g.pin);
    return vec3<f32>(q.x * g.e.x - dv * g.e.y, q.y, q.x * g.e.y + dv * g.e.x);
}
// Orbital Laser's post pass for the Fold (laser 14). The mod builds it from shaders/strike.wgsl up to its fs_main less the
// other lasers' own functions, followed by this file, and sets it for a fold strike only. Validate with
// tools/check-shader.sh.

// ---- laser 14: the fold -------------------------------------------------------------------------------------------
// The world's bending, its creases, its tears and its colours aren't here: the land's own vertices and pixels go through
// shaders/fold_warp.wgsl. This pass draws what is not the world: the droplet (its fall, its stop, its meld), the void and
// its stars where the land has left, the point, the one flash, and the dust of the slams.
// strike/fold.rs plans the sounds and the land: keep the FD_* in step with its and fold_warp.wgsl's.
const FD_STOP: f32 = 3.4;          // the middle of its brake
const FD_HANG: f32 = 4.5;          // it has hung still; it is let go
const FD_TOUCH: f32 = 6.0;         // it touches the land
const FD_MELD: f32 = 6.2;          // the land has closed over its tip: it has gone in
const FD_FOLD: f32 = 19.0;
const FD_SEAL: f32 = 35.0;
const FD_CRUSH: f32 = 35.0;
const FD_BEAT: f32 = 40.0;         // the tip touches the target
const FD_REL: f32 = 40.5;          // it all runs backwards
const FD_SLAM0: f32 = 44.1;         // the first ring lands
const FD_SLAM4: f32 = 48.7;        // the last slam
const FD_ERUPT: f32 = 49.9;        // what was pent up bursts out (strike/fold.rs's FD_ERUPT)
const FD_FALL: f32 = 3600.0;       // how high it starts over the target

fn fd_ss(a: f32, b: f32, x: f32) -> f32 { return smoothstep(a, b, x); }
fn fd_sample(uv: vec2<f32>) -> vec3<f32> {
    return srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0)), 0.0).rgb);
}
// The void (fw_stars in fold_warp.wgsl: the same sky through a tear and round the world).
fn fd_stars(dir: vec3<f32>) -> vec3<f32> {
    let c = floor(dir * 300.0);
    let q = fract((c.xy + c.z * 37.7) * vec2<f32>(0.1031, 0.1137));
    let d = dot(q, q.yx + 33.33);
    let h = fract((q.x + d) * (q.y + d));
    let s = select(0.0, (h - 0.99) / 0.01, h > 0.99);
    let glow = 0.5 + 0.5 * sin(dir.x * 4.0 + dir.y * 3.0 + dir.z * 5.0);
    return mix(vec3<f32>(0.006, 0.005, 0.016), vec3<f32>(0.03, 0.012, 0.05), glow * glow) + vec3<f32>(0.8, 0.82, 1.0) * s * s;
}
fn fd_ring(i: i32) -> f32 {
    switch i {
        case 0: { return 44.0; }
        case 1: { return 104.0; }
        case 2: { return 176.0; }
        case 3: { return 290.0; }
        default: { return 480.0; }
    }
}
fn fd_slam(i: i32) -> f32 {
    switch i {
        case 4: { return 44.1; }
        case 3: { return 45.2; }
        case 2: { return 46.3; }
        case 1: { return 47.4; }
        default: { return 48.7; }
    }
}

// ---- the droplet: a classic teardrop of liquid metal, round end down, its tip straight up, the same shape from the top of
// the sky to the ground. It falls hard, braking all the way (FD_B), then OVERRUN's long smooth brake (fd_brake_t) takes the rest; what
// was moving with it isn't stopped: the fire and the wake go on past it and down (fd_slip), hit the land and throw out a low
// ring of dust (fd_dust), and it shakes like a jelly for a second (fd_drop), hangs, and is let go: it falls to the land from rest.
// Its height over the land is d.h, to its centre; its bottom is d.R under that, its tip FD_TIP * d.R over it.
const FD_V: f32 = 280.0;           // how fast it is going as it stops, blocks a second
const FD_LEAD: f32 = 4.0;          // the clock starts this far before 0: its fall takes FD_LEAD + FD_STOP, time to look up (lib.rs's Strike::wait, fold.rs's FD_LEAD)
const FD_B: f32 = 27.88;           // its braking: (FD_FALL - FD_V * T) / T^2, T being FD_LEAD + FD_STOP
const FD_SLIP: f32 = 0.3;          // how soon what moved with it loses its speed, seconds
const FD_BRAKE: f32 = 0.5;         // OVERRUN's stop: it starts braking this long before FD_STOP and comes to rest about as long after it (fd_brake_t), the force rising and falling smoothly
const FD_GONE: f32 = 15.0;         // the last of the smoke has faded
const FD_OVER: f32 = 1.6;          // OVERRUN: how soon the air it brakes out of loses its speed, seconds
const FD_TIP: f32 = 1.72;          // the tip, in radii over the centre
const FD_PIV: f32 = -0.3;          // the point it squashes about, in radii over the centre: low, the tip does the moving
struct FdDrop { R: f32, stop_h: f32, h: f32, sx: f32, sy: f32, piv: f32, rip: f32, ph: f32, sway: vec2<f32>, pool: f32, pw: f32 }
// It comes down an arc, not a plumb line: seen from under a straight fall its whole trail lies end on, a dot. High up it is off to the player's side, so the trail is seen
// side on across the sky, and it comes round to plumb over the target by the time it stops. How far to the side it is, H over where it stops.
const FD_ARC: f32 = 820.0;
fn fd_arc(H: f32) -> f32 {
    let u = max(H, 0.0) / FD_FALL;
    return FD_ARC * u * u;
}
struct FdLight { L: vec3<f32>, sunc: vec3<f32>, amb: vec3<f32>, haze: vec3<f32> }
struct FdMist { c: vec3<f32>, tau: f32, glow: vec3<f32>, fire: vec4<f32> }
// How far over where it stops it is, `tau` seconds before it does, and when it was at that height.
fn fd_fall(tau: f32) -> f32 { return tau * (FD_V + FD_B * tau); }
fn fd_fall_inv(H: f32) -> f32 { return (sqrt(FD_V * FD_V + 4.0 * FD_B * max(H, 0.0)) - FD_V) / (2.0 * FD_B); }
// How far the air that was moving with it has gone on, `after` seconds after the stop.
fn fd_slip(after: f32) -> f32 {
    if (fd_stop() == 4) {
        // (OVERRUN: `after` is from the brake's start, and the air goes on at the speed it was doing as the drop slows away from it)
        return (FD_V + 2.0 * FD_B * FD_BRAKE) * after / (1.0 + after / FD_OVER);
    }
    return FD_V * FD_SLIP * (1.0 - exp(-after / FD_SLIP));
}
fn fd_erf(x: f32) -> f32 {
    let y = clamp(x, -4.0, 4.0);
    return tanh(1.1284 * y + 0.1009 * y * y * y);
}
// How high its foot hangs over the target, and how high it is `a` from the touch: from rest, under gravity, straight on through
// the land, the FD_DROP s fall ending on FD_TOUCH at every size. It stops 70 blocks up at R 8.5, and goes into the land at
// fd_vc: 82 blocks a second at R 8.5, its gravity 54.7. fold_warp.wgsl's fw_high and fw_over the same.
const FD_DROP: f32 = 1.5;          // FD_TOUCH - FD_HANG
fn fd_high(R: f32) -> f32 {
    return 5.0 * R + 19.0;
}
fn fd_over(a: f32, R: f32) -> f32 {
    let u = (a + FD_DROP) / FD_DROP;
    return fd_high(R) * (1.0 - u * u);
}
fn fd_vc(R: f32) -> f32 { return 2.0 * fd_high(R) / FD_DROP; }
// From FD_TOUCH: height of its centre over the target, and the ripple on its side (d.rip, d.ph). Nothing changes for it at
// the land: the same speed, the same gravity, straight through, like a stone into water. The land's depth hides it.
fn fd_meld(t: f32, R: f32) -> vec3<f32> {
    let a = t - FD_TOUCH;
    // (waves run up it from the neck, as they do up a drop going into water, and are gone before it is)
    return vec3<f32>(R + fd_over(a, R), 0.05 * (1.0 - exp(-a * 18.0)) * exp(-a * 3.2), a * 30.0);
}
const FD_FOOT: f32 = 0.25;
const FD_MEET: f32 = -0.08;        // when it and the land's finger meet, seconds from FD_TOUCH: fold_warp.wgsl's FW_MEET
// The metal at its foot, where it and the land become one: how high over the target, and how wide. It starts thin and widens
// fast, as a neck does (with the root of the time), keeps just over the land's swell (fold_warp.wgsl's fw_neck), and goes
// under it as the last of the drop does. fw_land's height of the land at the middle.
fn fd_sink(a: f32) -> f32 {
    return 1.0 - fd_ss(0.95, 1.95, a);
}
fn fd_wide(a: f32, R: f32) -> f32 {
    let u = clamp((a + 0.5) / 1.1, 0.0, 1.0);
    let v = 1.0 - u * u * sqrt(u);
    return 0.4725 * R * (1.0 - v * v) * fd_sink(a);
}
fn fd_land(a: f32, R: f32) -> f32 {
    let full = 1.35 * R;
    // (how high the drop's foot is as they meet)
    let meet = fd_over(FD_MEET, R);
    if (a < FD_MEET) {
        let u = clamp((a + 0.5) / (FD_MEET + 0.5), 0.0, 1.0);
        let u3 = u * u * u;
        return fd_wide(a, R) + (meet - fd_wide(FD_MEET, R)) * u3 * u3;
    }
    let s = a - FD_MEET;
    let rise = 1.0 - (1.0 - meet / full) * exp(-s / 0.16);
    return full * ((rise + 0.2 * fd_ss(0.0, 0.45, s) * exp(-1.4 * s) * sin(6.2 * s - 1.35)) * fd_sink(a) - 0.08 * fd_ss(1.7, 2.15, a) * (1.0 - fd_ss(2.15, 2.9, a)));
}
// (`h`: the drop's centre over the target)
fn fd_foot(a: f32, h: f32, R: f32) -> vec2<f32> {
    if (a < FD_MEET || a > 0.4) {
        return vec2<f32>(0.0, 1.0);
    }
    // (the drop's width at the top of the land's skirt, which is where the neck is)
    let land = fd_land(a, R);
    let y = clamp((land - h) / R, -1.0, FD_TIP);
    let rho = R * sqrt(max(fd_prof(y).x, 0.0));
    // (its height from FD_FOOT under the target, so its edge goes into the land rather than lying on it; drawn down at the end)
    let top = land + 0.02 * R * fd_ss(0.0, 0.2, a) + FD_FOOT * R - (land + 0.4 * R) * fd_ss(0.12, 0.26, a);
    return vec2<f32>(max(top, 0.0), rho + 0.12 * R);
}
// How long OVERRUN's brake takes: from the speed it has at FD_STOP - FD_BRAKE down to nothing over what is left of its fall. The speed goes by a smoothstep, so the force on it rises from nothing,
// peaks half way and dies away to nothing: no jolt at either end. Everything after the stop goes by this clock too: `fd_since`.
fn fd_brake_t() -> f32 {
    return 2.0 * fd_fall(FD_BRAKE) / (FD_V + 2.0 * FD_B * FD_BRAKE);
}
// Seconds since what was moving with it started to leave it: the stop for the rest, the brake's start for OVERRUN.
fn fd_since(t: f32) -> f32 { return max(t - select(FD_STOP, FD_STOP - FD_BRAKE, fd_stop() == 4), 0.0); }
// `side`: across the view, what its tip sways along.
fn fd_drop(t: f32, dist: f32, side: vec2<f32>) -> FdDrop {
    let R = clamp(dist * 0.05, 5.0, 15.0);
    let stop_h = R + fd_high(R);
    var h = stop_h;
    var sx = 1.0;
    var sy = 1.0;
    var piv = FD_PIV;
    var rip = 0.0;
    var ph = 0.0;
    var sway = vec2<f32>(0.0);
    var foot = vec2<f32>(0.0, 1.0);
    // (OVERRUN: a hard, quick, smooth brake, no dead stop)
    let brake_t = select(0.0, fd_brake_t(), fd_stop() == 4);
    let at_rest = FD_STOP - FD_BRAKE + brake_t;
    if (brake_t > 0.0 && t >= FD_STOP - FD_BRAKE && t < at_rest) {
        // (the integral of 1 - smoothstep(u); and it squashes with the force on it, its foot held back, and the settle below takes it from there)
        let u = (t - (FD_STOP - FD_BRAKE)) / brake_t;
        h = stop_h + fd_fall(FD_BRAKE) * (1.0 - 2.0 * (u - u * u * u + 0.5 * u * u * u * u));
        sy = 1.0 - 0.06 * 4.0 * u * (1.0 - u);
        sx = 1.0 / sqrt(sy);
        piv = -1.0;
    } else if (t < FD_STOP) {
        h = stop_h + fd_fall(FD_STOP - t);
    } else if (t < FD_TOUCH) {
        // (its centre stops, its surface doesn't: from no change at all in the first frame, one heavy settle and a smaller one
        // back, 2.2 Hz, its volume kept, all gone in half a second; a little ripple up it to the tip, and the tip left swaying a
        // little; then perfectly still, a good half second before it is let go)
        let a = t - max(FD_STOP, select(FD_STOP, at_rest, brake_t > 0.0));
        let e = exp(-a * 5.5) * (1.0 - fd_ss(0.25, 0.5, a));
        // (OVERRUN: the brake has taken all that up, so only the faintest settle is left)
        let wob = select(1.0, 0.15, fd_stop() == 4);
        sy = 1.0 - 0.055 * wob * e * sin(a * 14.0);
        sx = 1.0 / sqrt(sy);
        rip = 0.015 * wob * e * (1.0 - exp(-a * 30.0));
        ph = a * 24.0;
        sway = side * 0.035 * wob * e * sin(a * 10.0);
        if (fd_stop() == 3) {
            // (SQUASH: it takes it all itself, its foot held and the rest coming down on it, and rocks back slowly, heavy)
            let sq = fd_ss(0.0, 0.12, a) * exp(-a * 1.9) * cos(7.85 * (a - 0.12)) * (1.0 - fd_ss(0.85, 1.05, a));
            sy = 1.0 - 0.5 * sq;
            sx = 1.0 / sqrt(sy);
            piv = -1.0;
            rip = 0.03 * exp(-a * 3.0) * (1.0 - exp(-a * 30.0));
            ph = a * 16.0;
            sway = vec2<f32>(0.0);
        }
        if (t > FD_HANG) {
            // (let go: from rest where it stopped, under gravity, reaching the land on FD_TOUCH whatever its size: fd_vc)
            h = R + fd_over(t - FD_TOUCH, R);
            foot = fd_foot(t - FD_TOUCH, h, R);
        }
    } else {
        let m = fd_meld(t, R);
        h = m.x;
        rip = m.y;
        ph = m.z;
        foot = fd_foot(t - FD_TOUCH, h, R);
    }
    return FdDrop(R, stop_h, h, max(sx, 0.001), sy, piv, rip, ph, sway, foot.x, foot.y);
}
// The teardrop's side: its radius squared at height y (radii over the centre, -1 its bottom, FD_TIP its tip), and how fast
// that changes with y. Fitted to the user's picture: within 1.2% of its radius all the way up.
fn fd_prof(y: f32) -> vec2<f32> {
    let a = y + 1.0;
    let b = FD_TIP - y;
    let rb = sqrt(b);
    let q = 0.25773 + y * (0.09111 + y * (-0.07338 + y * (-0.05797 + y * 0.03297)));
    let dq = 0.09111 + y * (-0.14676 + y * (-0.17391 + y * 0.13188));
    let b2 = b * b * rb;
    return vec2<f32>(a * b2 * q, b2 * q - 2.5 * a * b * rb * q + a * b2 * dq);
}
// About the distance to its surface, in blocks, from p (from its centre); never much over, up to twice under far off.
fn fd_bead(pIn: vec3<f32>, d: FdDrop) -> f32 {
    var p = pIn / d.R;
    let sc = min(min(d.sx, d.sy), 1.0);
    p.y = (p.y - d.piv) / d.sy + d.piv;
    p = vec3<f32>(p.x / d.sx, p.y, p.z / d.sx);
    let u = clamp((p.y + 1.0) / (FD_TIP + 1.0), 0.0, 1.0);
    let o = p.xz - d.sway * u * u;
    let rr = dot(o, o);
    var e: f32;
    if (p.y >= FD_TIP) {
        e = sqrt(rr + (p.y - FD_TIP) * (p.y - FD_TIP));
    } else if (p.y <= -1.0) {
        e = sqrt(rr + (p.y + 1.0) * (p.y + 1.0));
    } else {
        let f = fd_prof(p.y);
        let m = 1.0 + d.rip * sin(d.ph - p.y * 5.0) * fd_ss(-0.9, -0.3, p.y);
        e = (rr - f.x * m * m) / sqrt(4.0 * rr + f.y * f.y * m * m * m * m + 1.0e-4);
    }
    return e * d.R * sc;
}
// Its normal at p on its surface, worked out, not differenced: the differences depend on how far from the surface the march
// stopped, and showed as contours in the chrome.
fn fd_bead_n(pIn: vec3<f32>, d: FdDrop) -> vec3<f32> {
    var p = pIn / d.R;
    p.y = (p.y - d.piv) / d.sy + d.piv;
    p = vec3<f32>(p.x / d.sx, clamp(p.y, -1.0, FD_TIP), p.z / d.sx);
    let u = (p.y + 1.0) / (FD_TIP + 1.0);
    let o = p.xz - d.sway * u * u;
    let f = fd_prof(p.y);
    let w = fd_ss(-0.9, -0.3, p.y);
    let a = d.ph - p.y * 5.0;
    let m = 1.0 + d.rip * sin(a) * w;
    let dm = -5.0 * d.rip * cos(a) * w;
    let gy = -2.0 * dot(o, d.sway) * 2.0 * u / (FD_TIP + 1.0) - (f.y * m * m + 2.0 * f.x * m * dm);
    return normalize(vec3<f32>(2.0 * o.x / d.sx, gy / d.sy, 2.0 * o.y / d.sx) + vec3<f32>(0.0, -1.0e-5, 0.0));
}
// The drop and the foot of metal it melts into, one surface: a smooth union, so the neck flows.
fn fd_foot_at(pIn: vec3<f32>, d: FdDrop) -> vec4<f32> {
    let q = pIn + vec3<f32>(0.0, d.h + FD_FOOT * d.R, 0.0);
    let s = vec3<f32>(q.x / d.pw, q.y / d.pool, q.z / d.pw);
    let l = max(length(s), 0.001);
    let g = vec3<f32>(s.x / d.pw, s.y / d.pool, s.z / d.pw);
    return vec4<f32>(g / max(length(g), 0.0001), (l - 1.0) * min(d.pool, d.pw));
}
fn fd_blend(a: f32, b: f32, k: f32) -> f32 {
    return clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
}
fn fd_sdf(pIn: vec3<f32>, d: FdDrop) -> f32 {
    let a = fd_bead(pIn, d);
    if (d.pool <= 0.0) {
        return a;
    }
    let b = fd_foot_at(pIn, d).w;
    let k = 0.22 * d.R;
    let h = fd_blend(a, b, k);
    return mix(b, a, h) - k * h * (1.0 - h);
}
fn fd_normal(pIn: vec3<f32>, d: FdDrop) -> vec3<f32> {
    let n = fd_bead_n(pIn, d);
    if (d.pool <= 0.0) {
        return n;
    }
    let f = fd_foot_at(pIn, d);
    return normalize(mix(f.xyz, n, fd_blend(fd_bead(pIn, d), f.w, 0.22 * d.R)));
}
// ---- the two glows: one soft ring round where they meet, from first touch; then, the drop gone in, one soft glow over the whole
// landing, and no flash in either ------------------------------------------------------------------------------------------
const FD_GLOW: vec3<f32> = vec3<f32>(0.86, 0.93, 1.1);
// How the land's sides differ: fold_warp.wgsl's fw_side, with its seed.
fn fd_side(ang: f32, a: f32) -> vec2<f32> {
    let s = seed_v() * 2.399;
    return vec2<f32>(
        0.52 * sin(ang + s) + 0.34 * sin(2.0 * ang + s * 1.7 - 0.9 * a) + 0.22 * sin(3.0 * ang - s * 2.3 + 1.4 * a),
        0.5 * sin(ang - s * 1.3 + 2.1) + 0.36 * sin(2.0 * ang + s * 0.7 + 1.1 * a) + 0.2 * sin(5.0 * ang + s * 3.1 - 1.3 * a));
}
fn fd_glow(colIn: vec3<f32>, t: f32, v: vec3<f32>, G: vec3<f32>, P: vec3<f32>, lit: f32, far: f32, d: FdDrop) -> vec3<f32> {
    let a = t - FD_TOUCH;
    if (a < FD_MEET - 0.25 || a > 3.0) {
        return colIn;
    }
    var col = colIn;
    let R = d.R;
    // (the ray's nearest to the place, and whether the land is in front of it)
    let H = G + vec3<f32>(0.0, 0.4 * R, 0.0);
    let hd = dot(H, v);
    let miss = length(H - v * hd);
    let seen = select(0.35, 1.0, far > hd - 3.0 * R);
    let rr = length(P.xz);
    // ---- the join: the land itself lit where it meets the drop, its blocks kept, and hot right at the line ---------------------
    // (a first warmth as the gap closes, all of it the moment they touch, a little over at first, and going as the drop does)
    let snap = fd_ss(FD_MEET, FD_MEET + 0.1, a);
    let g1 = (0.22 * fd_ss(FD_MEET - 0.25, FD_MEET, a) + snap * (0.78 + 0.5 * exp(-max(a - FD_MEET, 0.0) / 0.16))) * (1.0 - fd_ss(0.35, 0.85, a));
    if (g1 > 0.0) {
        let neck = select(0.15 * R, max(d.pw - 0.12 * R, 0.15 * R), d.pool > 0.0);
        if (lit > 0.0) {
            // (uneven round it, the way the land's skirt is)
            let L = fd_side(atan2(P.z, P.x) + rr / (3.2 * R), a);
            let edge = neck * (1.0 + 0.12 * L.x);
            let x = max(rr - edge, 0.0);
            let e = exp(-x / ((0.55 + 0.22 * L.y) * R)) * exp(-max(P.y - fd_land(a, R), 0.0) / (0.8 * R));
            let hot = exp(-abs(rr - edge) / (0.14 * R));
            col = col + (col * 1.2 * e + (col * 1.1 + FD_GLOW * 0.1) * hot * e) * g1 * lit;
        }
        col = col + FD_GLOW * 0.09 * g1 * seen * exp(-miss * miss / (2.0 * R * R));
    }
    // ---- all of it -----------------------------------------------------------------------------------------------------------
    // (what it took in, coming up through the land as it closes and going out through the land's heaving)
    let g2 = fd_ss(0.25, 0.75, a) * (1.0 - fd_ss(0.75, 3.0, a));
    if (g2 > 0.0) {
        let wide = R * (3.0 + 1.0 * fd_ss(0.3, 3.0, a));
        if (lit > 0.0) {
            let x = rr / wide;
            col = col + (col * 1.0 + FD_GLOW * 0.03) * exp(-x * x) * exp(-max(abs(P.y) - 6.0, 0.0) / (1.2 * R)) * g2 * lit;
        }
        col = col + FD_GLOW * 0.05 * g2 * seen * exp(-miss * miss / (wide * wide * 0.9));
    }
    return col;
}
// The light on smoke and dust: the Payload's.
fn fd_light() -> FdLight {
    let sun = normalize(frame.sun.xyz);
    let day = smoothstep(-0.2, 0.1, sun.y);
    let sun_up = smoothstep(-0.12, 0.06, sun.y);
    let warm = (1.0 - smoothstep(0.02, 0.4, sun.y)) * smoothstep(-0.2, -0.02, sun.y);
    let moon = smoothstep(-0.02, -0.2, sun.y);
    let L = normalize(select(-sun, sun, sun.y > -0.04) + vec3<f32>(0.0, 0.03, 0.0));
    let skyl = srgb_to_linear(frame.sky_color.rgb);
    let amb = mix(vec3<f32>(0.03, 0.035, 0.05), skyl * 0.85 + vec3<f32>(0.04), day);
    let sunc = mix(vec3<f32>(1.35, 1.24, 1.06), mix(vec3<f32>(1.5, 0.68, 0.3), vec3<f32>(1.3, 0.38, 0.14), smoothstep(0.0, -0.1, sun.y)), warm) * sun_up + vec3<f32>(0.07, 0.09, 0.14) * moon;
    return FdLight(L, sunc, amb, mix(vec3<f32>(0.02, 0.025, 0.04), skyl * 1.05, day));
}
// The wake: the Payload's trail on the droplet's straight fall, one piece: a cord of lumpy smoke hung in the sky where it came
// down, its lumps fixed where they were laid, tight off the tip and swelling with age, pale high up and dark low down, with the
// flame in its first fifth of a second. After the stop the last of it keeps falling, past the droplet and into the land.
fn fd_trail(v: vec3<f32>, C: vec3<f32>, d: FdDrop, way: vec2<f32>, t: f32, px: f32, li: FdLight, far: f32) -> FdMist {
    var m = FdMist(vec3<f32>(0.0), 0.0, vec3<f32>(0.0), vec4<f32>(0.0));
    let a2 = max(dot(v.xz, v.xz), 1.0e-4);
    // (where the ray passes nearest the arc: the arc is the plumb line's height's way off to the side, and a couple of steps find it)
    let head0 = d.h - d.stop_h;
    let S = C - vec3<f32>(way.x * fd_arc(head0), head0, way.y * fd_arc(head0));
    var nearest = S.xz;
    var sc = dot(nearest, v.xz) / a2;
    for (var i = 0; i < 3; i += 1) {
        nearest = S.xz + way * fd_arc(v.y * sc - S.y);
        sc = dot(nearest, v.xz) / a2;
    }
    if (sc <= 0.0 || sc > far) {
        return m;
    }
    let after = fd_since(t);
    let ycl = v.y * sc - C.y;                    // how far over the droplet's centre the ray passes the fall's line
    let gy = ycl + d.h;                          // over the land
    if (gy < -1.0) {
        return m;
    }
    let tipy = FD_TIP * d.R;
    let yw = ycl + d.h - d.stop_h;
    // (the last of the wake carried on down, less of it the higher up)
    let mode = fd_stop();
    let k = fd_stopk(mode);
    let laid = yw + k.x * fd_slip(after) * exp(-max(yw, 0.0) / select(170.0, 900.0, mode == 4)) - tipy;
    let head = d.h - d.stop_h;
    let on = fd_ss(head - 0.1 * d.R, head + 0.9 * d.R, laid);
    if (on <= 0.0) {
        return m;
    }
    let te = FD_STOP - fd_fall_inv(laid);
    let age = max(t - te, 0.0);
    let dive = fd_ss(-2.5, 1.5, te);
    let smk = fd_ss(2500.0, 1100.0, laid);
    // (it wanders as it ages, the wind having it)
    let wa = min(age, 18.0);
    let bend = vec2<f32>(sin(laid * 0.0071 + 1.3) + 0.5 * sin(laid * 0.019), cos(laid * 0.0053) + 0.5 * sin(laid * 0.023 + 2.0)) * wa * (1.5 + 0.18 * wa);
    let off = v.xz * sc - (nearest + bend);
    let hx = length(off);
    // (tight off the tip; where the air it has dragged down meets the land it spreads)
    let flare = 10.0 * fd_ss(26.0, 0.0, gy) * fd_ss(0.0, 0.1, after);
    // (and never thinner than a pixel or two: from far off it is a line drawn across the sky, not nothing)
    let rad = max(mix(0.3 * d.R, 0.72 * d.R + 1.5, 1.0 - exp(-age / 0.14)) + 3.4 * sqrt(age) + 1.1 * max(t - FD_STOP, 0.0) + flare + select(0.0, 11.0 * (1.0 - exp(-after / 0.3)) * exp(-max(yw, 0.0) / 50.0), mode == 5), 1.5 * px * sc);
    if (hx >= rad * 3.4) {
        return m;
    }
    let sn = max(sqrt(a2), 0.08);
    let sw = 2.2 * rad + 3.0;
    // (its lumps twisted round it, the wind of the fall winding the rope the fire is wound round the droplet with)
    let tw = laid * 0.045 + seed_v();
    let ct = cos(tw);
    let st = sin(tw);
    let across = vec3<f32>(ct * off.x - st * off.y, 0.0, st * off.x + ct * off.y) / sw + vec3<f32>(seed_v() * 0.31, seed_v() * 0.17, 0.0);
    let lv = log2(sw / 8.0);
    let lk = floor(lv);
    let lf = lv - lk;
    let sA = 8.0 * exp2(lk);
    let lp = vec3<f32>(0.0, laid, 0.0);
    let qa = lp / sA + across + vec3<f32>(lk * 17.3, lk * 5.1, 0.0);
    let qb = lp / (2.0 * sA) + across + vec3<f32>((lk + 1.0) * 17.3, (lk + 1.0) * 5.1, 0.0);
    let lsp = 1.0 / sqrt(lf * lf + (1.0 - lf) * (1.0 - lf));
    let qs = 1.0 / sw;
    let along = sc * px / sn * qs;
    let thru = 2.0 * sqrt(max(2.1 * rad * rad - hx * hx, 0.0)) * abs(v.y) / sn * qs + 1.0e-3;
    let w1 = min(saturate(2.0 * sqrt(1.0 / thru)), saturate(2.0 - 10.0 * along));
    let w2 = min(saturate(2.0 * sqrt(0.385 / thru)), saturate(2.0 - 10.0 * along * 2.6));
    let w3 = min(saturate(2.0 * sqrt(0.164 / thru)), saturate(2.0 - 10.0 * along * 6.1));
    var n1 = 0.5;
    var n2 = 0.5;
    var n3 = 0.5;
    if (w1 > 0.0) {
        let o = vec3<f32>(0.0, 0.0, 0.06 * age);
        n1 = 0.5 + (mix(gnoise3(qa + o), gnoise3(qb + o), lf) - 0.5) * lsp;
    }
    if (w2 > 0.0) {
        let o = vec3<f32>(4.0, 0.08 * age, 1.0);
        n2 = 0.5 + (mix(gnoise3(qa * 2.6 + o), gnoise3(qb * 2.6 + o), lf) - 0.5) * lsp;
    }
    if (w3 > 0.0) {
        let o = vec3<f32>(1.0, 7.0, 0.15 * age);
        n3 = 0.5 + (mix(gnoise3(qa * 6.1 + o), gnoise3(qb * 6.1 + o), lf) - 0.5) * lsp;
    }
    let puff = 0.5 + 0.72 * w1 * (n1 - 0.5) + 0.42 * w2 * (n2 - 0.5) + 0.16 * w3 * (n3 - 0.5);
    let rw = rad * (0.45 + puff);
    let rr = hx / rw;
    let prof = exp(-rr * rr * 1.4) * fd_ss(2.3, 1.5, rr);
    let gin = 1.0 / max(sn, 0.5);
    // (the thin between its lumps opening a little as it goes: all of it at once, from when the drop has stopped, `FD_GONE` below)
    let thr = mix(0.32, 0.12, smk) + 0.2 * fd_ss(0.5, 11.0, t - FD_STOP);
    let mm = (puff - thr) * 3.2 + 0.3 * exp(-age / 0.8);
    let sl = 3.2 * 0.14 * sqrt(0.384 * (1.0 - w1 * w1) + 0.09 * (1.0 - w2 * w2) + 0.0064 * (1.0 - w3 * w3)) + 1.0e-3;
    // (a soft max(mm, 0): past 30 its exp would run out, and it is mm)
    let mz = mm / sl;
    let dens = saturate(select(sl * log(1.0 + exp(max(mz, -30.0))), mm, mz > 30.0));
    // (dense where it is laid and thinning slowly; right behind the flame nearly solid, the fire going out into dark smoke)
    let sig = (0.24 + 0.5 * exp(-age / 0.6) * dive) * mix(0.6, 1.15, smk);
    let life = fd_ss(0.1 - FD_LEAD, 0.9 - FD_LEAD, t);
    var dtau = sig * prof * dens * 1.6 * rad * gin * on * life;
    // (the whole of it fading together, top to bottom, on one clock from when the drop has stopped. On how much it hides, not its thickness: thinned, a thick column would stay solid
    // nearly to the end and then go all at once)
    let left = 1.0 - fd_ss(FD_STOP + 0.5, FD_GONE, t);
    if (left < 1.0) {
        dtau = -log(max(1.0 - (1.0 - exp(-dtau)) * left, 1.0e-4));
    }
    let nrm = normalize(vec3<f32>(off.x, 0.0, off.y) - v * (0.6 * rad) + vec3<f32>(0.0, 1.0e-4, 0.0));
    let ln = 0.5 + w1 * (n1 - 0.5);
    let lit = (0.35 + 0.65 * saturate(dot(nrm, li.L) * 0.5 + 0.5)) * (0.6 + 0.8 * ln * ln);
    // (white vapour high up, soot-dark low down, paling as it spreads thin)
    var alb = mix(vec3<f32>(0.74, 0.74, 0.76), vec3<f32>(0.115, 0.1, 0.09), smk);
    alb = mix(alb, alb * 1.35 + vec3<f32>(0.03), fd_ss(FD_STOP, FD_GONE, t));
    var c = alb * (li.sunc * lit * 0.85 + li.amb * (0.6 + 0.4 * ln));
    // (just behind the fire the smoke is lit by it, dying back at once)
    c = c + vec3<f32>(1.2, 0.42, 0.09) * exp(-age / 0.1) * dive * (0.4 + 0.6 * ln);
    c = mix(c, li.haze, (1.0 - exp(-sc / 3000.0)) * 0.5);
    m.c = c;
    m.tau = dtau;
    // (the fire, a body and not a light: burning back off the tip, how long by how fast it goes; white at its root, yellow, orange, dull red at its end, torn to tongues there.
    // It hides what is behind it, or over a bright sky it would only wash out)
    let spd = FD_V + 2.0 * FD_B * max(FD_STOP - te, 0.0);
    let db = max(laid - head, 0.0);
    let u = db / (34.0 + 0.055 * spd);
    let fw = max(d.R * (0.74 - 0.42 * saturate(u)), 1.4 * px * sc);
    let tore = u + 1.3 * (n2 - 0.5) * saturate(u * 2.0) + 0.5 * sin(t * 31.0 + laid * 0.17) * saturate(u * 1.4) * 0.3;
    let ee = hx / fw * (1.0 + 0.9 * (n1 - 0.5) * saturate(u * 3.0));
    let body = fd_ss(1.15, 0.45, ee) * fd_ss(1.25, 0.7, tore) * dive * on * exp(-after / k.y);
    if (body > 0.0) {
        let heat = saturate(1.0 - 0.8 * tore - 0.45 * ee);
        var fc = mix(vec3<f32>(0.62, 0.09, 0.015), vec3<f32>(1.0, 0.36, 0.05), fd_ss(0.05, 0.4, heat));
        fc = mix(fc, vec3<f32>(1.0, 0.72, 0.2), fd_ss(0.4, 0.68, heat));
        fc = mix(fc, vec3<f32>(1.0, 0.97, 0.82), fd_ss(0.68, 0.92, heat));
        m.fire = vec4<f32>(fc, body);
    }
    // (high up, the hot streak of air it leaves, white, cooling within a second)
    let fh = (1.0 - dive) * exp(-age / 0.45) * life;
    let fprof = exp(-pow(hx / max(rad * 0.6, 0.5), 2.0) * 1.6);
    m.glow = vec3<f32>(2.0, 1.9, 1.75) * fh * min(fprof * rad * 0.3, 1.0);
    return m;
}
// The fire on the droplet: a skin of flame wrapped round the teardrop itself, thin and white on the round end it is falling on,
// streaming up its sides in ribbons that wind round it, drawn in to the tip where it goes dark and turns into the wake. Marched
// through, up to `s_end`. At the stop the droplet is left behind: the skin goes on down in its shape, swelling, and is gone.
fn fd_sheath(colIn: vec3<f32>, v: vec3<f32>, C: vec3<f32>, d: FdDrop, t: f32, s_end: f32, jit: f32) -> vec3<f32> {
    let after = fd_since(t);
    let hi = fd_ss(FD_STOP - 5.5, FD_STOP - 0.3, t);
    let k = fd_stopk(fd_stop());
    let on = hi * exp(-after / k.z);
    if (on < 0.01) {
        return colIn;
    }
    // (OVERRUN: it holds its shape and burns out as the speed goes, sliding off past the drop: swelling as it does, over a whole second, it was a big glass dome)
    let over = select(1.0, 0.16, fd_stop() == 4);
    let grow = 1.0 + after * 2.5 * over;
    // (OVERRUN: it only goes on past the drop by what the drop has fallen behind it)
    let past = k.x * fd_slip(after) - select(0.0, d.stop_h + fd_fall(FD_BRAKE) - d.h, fd_stop() == 4 && t >= FD_STOP - FD_BRAKE);
    let Cg = C - vec3<f32>(0.0, min(max(past, 0.0), max(d.h - d.R, 0.0)), 0.0);
    let bc = Cg + vec3<f32>(0.0, 0.36 * d.R * grow, 0.0);
    let br = 1.8 * d.R * grow;
    let cd = dot(bc, v);
    let b2 = dot(bc, bc) - cd * cd;
    if (cd < 0.0 || b2 > br * br) {
        return colIn;
    }
    let hc = sqrt(br * br - b2);
    let s0 = max(cd - hc, 0.05);
    let s1 = min(cd + hc, s_end);
    if (s1 <= s0) {
        return colIn;
    }
    const N = 24;
    let ds = (s1 - s0) / f32(N);
    var T = 1.0;
    var E = vec3<f32>(0.0);
    let dn = ds / (d.R * grow);
    for (var i = 0; i < N; i += 1) {
        let q = (v * (s0 + (f32(i) + jit) * ds) - Cg) / (d.R * grow);
        // (how far off its side, across: the same either side of the tip, as a true distance isn't cheaply)
        let ro = length(q.xz);
        var e: f32;
        if (q.y >= FD_TIP) {
            e = length(vec2<f32>(ro, q.y - FD_TIP));
        } else if (q.y <= -1.0) {
            e = length(vec2<f32>(ro, q.y + 1.0));
        } else {
            e = ro - sqrt(max(fd_prof(q.y).x, 0.0));
        }
        let hgt = saturate((q.y + 1.0) / (FD_TIP + 1.0));
        let th = mix(0.1, 0.34, hgt) * (1.0 - fd_ss(0.8, 1.0, hgt) * 0.5) * (1.0 + after * 16.0 * over);
        if (e > th * 2.4 || e < -0.06) {
            continue;
        }
        // (ribbons running up it and winding half way round on the way; seamless round it)
        let az = atan2(q.z, q.x) + hgt * 3.8 + seed_v();
        let ca = cos(az);
        let sa = sin(az);
        let fl = q.y * 0.55 - t * 6.0;
        let n = gnoise3(vec3<f32>(ca * 1.2, sa * 1.2, fl)) * 0.72 + gnoise3(vec3<f32>(ca * 3.0, sa * 3.0, fl * 2.0 + 3.0)) * 0.28;
        let tt = th * (0.5 + 1.1 * n);
        let sh = exp(-pow(max(e, 0.0) / tt, 2.0));
        let nose = exp(-hgt * 7.0);
        let rib = mix(fd_ss(0.46, 0.6, n), 1.0, nose * 0.3);
        let dens = sh * rib * on;
        let x = saturate(hgt * 1.1 + max(e, 0.0) / tt * 0.25);
        var c = mix(vec3<f32>(1.0, 0.95, 0.72), vec3<f32>(1.0, 0.5, 0.08), fd_ss(0.05, 0.4, x));
        c = mix(c, vec3<f32>(0.6, 0.09, 0.015), fd_ss(0.45, 0.9, x));
        // (it hides what is behind it: fire over a bright sky, added to it, only goes pink)
        let fa = 1.0 - exp(-dens * dn * 4.0 / (1.0 + after * 26.0 * over));
        E = E + c * T * fa;
        T = T * (1.0 - fa);
        // (dark round the tip: the flame burning out into smoke, wrapped in to its point)
        let sm = dens * fd_ss(0.42, 0.85, hgt) * dn * 5.0;
        E = E + vec3<f32>(0.09, 0.075, 0.07) * T * sm;
        T = T * exp(-sm - dens * dn * 0.8);
    }
    return colIn * T + E;
}
// The dust: the air that came down with it hits the land and goes by, a faint breath of it close round the target, low, and gone
// in a second or so: enough to see the air arrive, the land clear through it. Marched, up to `s_end`.
fn fd_dust(colIn: vec3<f32>, v: vec3<f32>, G: vec3<f32>, a: f32, s_end: f32, land: vec4<f32>, li: FdLight, jit: f32) -> vec3<f32> {
    if (a <= 0.0 || a > 1.6) {
        return colIn;
    }
    let rf = 6.0 + 44.0 * (1.0 - exp(-a / 0.55));
    let w = 5.0 + 4.0 * a;
    let top = 4.0 + 3.0 * (1.0 - exp(-a / 0.45)) + 0.4 * a;
    let fade = (1.0 - fd_ss(0.3, 1.6, a)) * fd_ss(0.0, 0.08, a);
    let ylo = min(G.y + land.y, G.y) - 2.0;
    let yhi = max(G.y + land.y, G.y) + top * 2.0;
    // (the ray in the slab of air it fills, and in the disc out to the front)
    var s0 = 0.05;
    var s1 = s_end;
    if (abs(v.y) > 1.0e-5) {
        let ya = ylo / v.y;
        let yb = yhi / v.y;
        s0 = max(s0, min(ya, yb));
        s1 = min(s1, max(ya, yb));
    }
    let a2 = max(dot(v.xz, v.xz), 1.0e-6);
    let bb = -dot(v.xz, G.xz);
    let Ro = rf * 1.14 + w * 2.0;
    let dout = bb * bb - a2 * (dot(G.xz, G.xz) - Ro * Ro);
    if (dout <= 0.0) {
        return colIn;
    }
    let qd = sqrt(dout);
    s0 = max(s0, (-bb - qd) / a2);
    s1 = min(s1, (-bb + qd) / a2);
    if (s1 <= s0) {
        return colIn;
    }
    const N = 14;
    let ds = (s1 - s0) / f32(N);
    var T = 1.0;
    var C = vec3<f32>(0.0);
    let alb = vec3<f32>(0.34, 0.29, 0.23);
    for (var i = 0; i < N; i += 1) {
        let p = v * (s0 + (f32(i) + jit) * ds) - G;
        // (its height over the land: the land under this pixel's own end, near it)
        let dl = p.xz - land.zw;
        let gh = clamp(land.x, -14.0, 14.0) * exp(-dot(dl, dl) / 900.0);
        let y = p.y - gh;
        if (y < -1.5) {
            continue;
        }
        let r = length(p.xz);
        let ang = atan2(p.z, p.x);
        let wob = vnoise(vec2<f32>(cos(ang) * 2.4 + 5.0, sin(ang) * 2.4 + a * 0.2));
        let rl = rf * (0.9 + 0.2 * wob);
        let x = (r - rl) / w;
        if (x > 2.2) {
            continue;
        }
        // (carried out with the front, and rising)
        let n = fbm3(vec3<f32>(p.x, p.y * 1.5 - a * 9.0, p.z) * 0.075 - vec3<f32>(p.x, 0.0, p.z) / max(r, 1.0) * (rf * 0.075));
        let ht = top * (0.5 + 1.0 * n);
        let roll = exp(-x * x * 1.2) * exp(-pow(max(y, 0.0) / ht, 2.0));
        let haze = 0.025 * fd_ss(0.2, -1.2, x) * exp(-max(y, 0.0) / (top * 0.5));
        let dens = max(fd_ss(0.36, 0.62, n + 0.2 * exp(-x * x)) * roll, haze) * fade;
        if (dens < 0.003) {
            continue;
        }
        let dt = dens * ds * 0.035;
        let lit = 0.55 + 0.45 * saturate(y / ht) + 0.35 * saturate(dot(normalize(vec3<f32>(p.x / max(r, 1.0), 0.6, p.z / max(r, 1.0))), li.L));
        C = C + alb * (li.sunc * lit * 0.75 + li.amb * 0.9) * T * (1.0 - exp(-dt));
        T = T * exp(-dt);
    }
    return colIn * T + C;
}
// Beads of burning metal shed off it in the last of its fall, each dropping back behind it with a short bright tail, as the Payload sheds its pieces.
fn fd_sparks(colIn: vec3<f32>, v: vec3<f32>, S: vec3<f32>, way: vec2<f32>, t: f32, px: f32) -> vec3<f32> {
    var col = colIn;
    for (var i = 0; i < 6; i += 1) {
        let k = f32(i);
        let ti = 0.6 + 0.27 * k + 0.09 * sin(k * 12.9 + seed_v());
        let a = t - ti;
        if (a <= 0.0 || a > 1.3) {
            continue;
        }
        let tau = FD_STOP - ti;
        let H0 = fd_fall(tau);
        let sp = FD_V + 2.0 * FD_B * tau;
        let b = S + vec3<f32>(way.x * fd_arc(H0), H0, way.y * fd_arc(H0));
        let ang = k * 2.4 + seed_v() * 3.0;
        let dir = vec3<f32>(cos(ang), 0.0, sin(ang)) * (24.0 + 26.0 * fract(k * 0.37 + seed_v()));
        let a0 = max(a - 0.045, 0.0);
        let A = b - vec3<f32>(0.0, sp * (1.0 - exp(-2.0 * a)) / 2.0, 0.0) + dir * (1.0 - exp(-2.5 * a));
        let B = b - vec3<f32>(0.0, sp * (1.0 - exp(-2.0 * a0)) / 2.0, 0.0) + dir * (1.0 - exp(-2.5 * a0));
        let h = ray_seg(v, A, B);
        let w = max(0.8, 1.1 * px * h.y);
        let c = exp(-h.x * h.x / (w * w)) * (1.0 - h.z * 0.8) * (1.0 - fd_ss(0.7, 1.3, a));
        col = mix(col, mix(vec3<f32>(1.0, 0.92, 0.6), vec3<f32>(1.0, 0.4, 0.06), h.z), saturate(c * 1.5));
    }
    return col;
}
// ---- how it stops: `/orbitallite foldstop N`, for trying them. What each keeps the same: it stops at FD_STOP, it is let go at FD_HANG and it touches on FD_TOUCH.
//   0 THE WAKE   as it was: the fire and the wake go on past it and hit the land
//   1 AIR POND   the air takes it as water takes a drop: rings run out across a plane at its foot, seen by what they bend behind them, and the fire and the smoke flatten on it
//   2 SHOCK      all that speed goes into the air at once: a white bubble of condensation and the ring of its shock front leave it and run out, bending the sky as they go
//   3 SQUASH     it takes the stop itself: flattens hard, comes back tall, and rocks slowly to rest, heavy
//   4 OVERRUN    the one the game uses. It brakes over about a second (FD_BRAKE), the force rising and falling smoothly, and the fire and the wake overrun it: they pour on past and round it, and it is left standing in the stream
//   5 MUSHROOM   the column behind it has nowhere to go: it stacks up over it and rolls out in one thick smoke ring
//   6 STUTTER    time catches: the fire and the smoke hang frozen for a beat with the world drained, the drop's echoes running on under it, and everything lets go
// (a quarter on it says the terrain is on: fold_warp.wgsl's fw_real_land)
fn fd_stop() -> i32 { return clamp(i32(frame.mod_params[3].w + 0.25), 0, 6); }
// (how much of the wake goes on past it, how long the fire lasts, and how long the fire's skin)
fn fd_stopk(mode: i32) -> vec3<f32> {
    switch mode {
        case 1: { return vec3<f32>(0.0, 0.03, 0.04); }
        case 2: { return vec3<f32>(0.6, 0.04, 0.05); }
        case 3: { return vec3<f32>(0.35, 0.04, 0.035); }
        case 4: { return vec3<f32>(1.0, 0.6, 0.3); }
        case 5: { return vec3<f32>(0.0, 0.04, 0.05); }
        default: { return vec3<f32>(1.0, 0.05, 0.09); }
    }
}
// The clock the fire and the smoke go by: the strike's, but STUTTER's hangs at the stop for FD_HOLD, then catches up.
const FD_HOLD: f32 = 0.3;
fn fd_stopclock(t: f32, mode: i32) -> f32 {
    if (mode != 6 || t < FD_STOP) {
        return t;
    }
    if (t < FD_STOP + FD_HOLD) {
        return FD_STOP;
    }
    return t - FD_HOLD * (1.0 - fd_ss(FD_STOP + 0.8, FD_STOP + 1.8, t));
}
// Where the ray meets the level of the drop's foot: (how far along the ray, x and z from the drop), the second -1 if it doesn't.
fn fd_plane(v: vec3<f32>, y: f32, far: f32) -> f32 {
    if (abs(v.y) < 1.0e-4) {
        return -1.0;
    }
    let s = y / v.y;
    return select(-1.0, s, s > 0.0 && s < far);
}
// AIR POND's rings at r: (their height's slope, how much of it there is here). Groups running out, the crests quicker than the group, as on water.
fn fd_pond(r: f32, a: f32) -> vec2<f32> {
    var sl = 0.0;
    var on = 0.0;
    for (var i = 0; i < 3; i += 1) {
        let b = a - f32(i) * 0.2;
        if (b <= 0.0) {
            continue;
        }
        let g = 150.0 * b + 6.0;
        let w = 15.0 + 36.0 * b;
        let x = (r - g) / w;
        let e = exp(-x * x) * exp(-b * 1.5);
        sl += e * sin((r - 2.0 * g) * 0.42 / (1.0 + 0.5 * b)) * (1.0 - f32(i) * 0.25);
        on = max(on, e);
    }
    return vec2<f32>(sl, on);
}
// The picture behind what is in the air, bent by what the stop did to it.
fn fd_bent(colIn: vec3<f32>, v: vec3<f32>, C: vec3<f32>, d: FdDrop, a: f32, far: f32, uv: vec2<f32>, aspect: f32, mode: i32) -> vec3<f32> {
    var col = colIn;
    if (mode == 1 && a < 2.4) {
        let y = C.y - (d.h - d.stop_h) - d.R;
        let s = fd_plane(v, y, far);
        if (s > 30.0) {
            let P = v * s;
            let q = P.xz - C.xz;
            let r = length(q);
            let w = fd_pond(r, a);
            if (w.y > 0.003) {
                let dir = q / max(r, 0.1);
                let p0 = project_rel(P);
                let p1 = project_rel(P + vec3<f32>(dir.x, 0.0, dir.y) * 24.0);
                let fade = fd_ss(0.0, 0.05, a) * (1.0 - fd_ss(1.6, 2.4, a));
                if (p0.z > 0.0 && p1.z > 0.0) {
                    let bend = (p1.xy - p0.xy) * w.x * 1.1;
                    let lb = length(bend);
                    col = fd_sample(clamp(uv + bend * min(1.0, 0.03 / max(lb, 1.0e-5)) * fade * fd_ss(30.0, 90.0, s), vec2<f32>(0.002), vec2<f32>(0.998)));
                }
                // (its crests catching the sky's light, as a skin on the air)
                let lift = max(w.x, 0.0);
                col = col + vec3<f32>(0.62, 0.68, 0.76) * pow(lift, 2.0) * 0.5 * fade + vec3<f32>(0.5, 0.56, 0.66) * w.y * 0.05 * fade;
            }
        }
    }
    if (mode == 2 && a < 1.6) {
        let Rs = 12.0 + 330.0 * a * (1.0 - 0.22 * a);
        let c0 = dot(C, v);
        let b = length(C - v * c0);
        let wd = 5.0 + 26.0 * a;
        let x = (b - Rs) / wd;
        if (abs(x) < 3.0 && c0 > 0.0) {
            let q = project_rel(C);
            let dr = (uv - q.xy) * vec2<f32>(aspect, 1.0);
            let dir = dr / max(length(dr), 1.0e-4);
            let k = x * exp(-x * x) * exp(-a * 1.8) * fd_ss(0.0, 0.04, a) * 0.03 * (1.0 - fd_ss(1.0, 1.6, a));
            col = fd_sample(clamp(uv + dir * k / vec2<f32>(aspect, 1.0), vec2<f32>(0.002), vec2<f32>(0.998)));
        }
    }
    return col;
}
// What the stop leaves in the air, in front of what is behind it, up to `s_end`.
fn fd_after(colIn: vec3<f32>, v: vec3<f32>, C: vec3<f32>, d: FdDrop, t: f32, a: f32, s_end: f32, li: FdLight, jit: f32, mode: i32) -> vec3<f32> {
    var col = colIn;
    if (a <= 0.0) {
        return col;
    }
    if (mode == 1 && a < 3.0) {
        // (the fire and the smoke stopped by the skin of the air and running out flat along it)
        let s = fd_plane(v, C.y - (d.h - d.stop_h) - d.R, s_end);
        if (s > 0.0) {
            let P = v * s;
            let q = P.xz - C.xz;
            let r = length(q);
            let Rd = 7.0 + 62.0 * (1.0 - exp(-a / 0.5));
            let ang = atan2(q.y, q.x);
            let wob = 0.84 + 0.32 * vnoise(vec2<f32>(cos(ang) * 2.2 + 3.0, sin(ang) * 2.2 + a * 0.25));
            let x = r / (Rd * wob);
            if (x < 1.5) {
                let n = fbm3(vec3<f32>(q.x * 0.05, a * 0.5, q.y * 0.05) + vec3<f32>(0.0, 0.0, seed_v()));
                let rim = fd_ss(1.0, 0.72, x + (n - 0.5) * 0.9) * fd_ss(0.0, 0.1, a);
                let hole = fd_ss(0.9 * d.R, 1.5 * d.R, r);
                let thin = (1.0 - fd_ss(0.7, 3.0, a)) * fd_ss(0.28, 0.6, n);
                let alpha = saturate(0.8 * rim * hole * thin);
                let lit = 0.5 + 0.5 * saturate(li.L.y + n - 0.3);
                var c = vec3<f32>(0.13, 0.115, 0.105) * (li.sunc * lit * 0.85 + li.amb);
                let burn = exp(-a / 0.2) * fd_ss(0.5, 1.0, x + n * 0.5);
                c = mix(c, vec3<f32>(1.0, 0.5, 0.1), saturate(burn * 1.3));
                col = mix(col, c, alpha);
            }
        }
    }
    if (mode == 2 && a < 1.5) {
        // (the bubble: cloud for a moment, where the air was let go; its skin brighter, seen edge on)
        let Rs = 12.0 + 330.0 * a * (1.0 - 0.22 * a);
        let c0 = dot(C, v);
        let b = length(C - v * c0);
        if (c0 > 0.0) {
            let bub = fd_ss(0.0, 0.03, a) * exp(-a / 0.16);
            let u = saturate(b / Rs);
            let n = vnoise(vec2<f32>(atan2(v.z, v.x) * 30.0, v.y * 60.0) + vec2<f32>(a * 2.0));
            col = mix(col, vec3<f32>(0.92, 0.94, 0.98), saturate(bub * (0.2 + 0.7 * u * u * u * u) * (0.6 + 0.8 * n)) * fd_ss(1.03, 0.97, b / Rs));
        }
        // (and the ring round it, where the shock runs flat out through the drop's own level)
        let s = fd_plane(v, C.y, s_end);
        if (s > 0.0) {
            let q = (v * s).xz - C.xz;
            let r = length(q);
            let w = 3.0 + 16.0 * a;
            let x = (r - Rs) / w;
            if (abs(x) < 3.0) {
                let n = fbm3(vec3<f32>(q.x * 0.035, a * 0.8, q.y * 0.035));
                let al = exp(-x * x) * (0.3 + 1.0 * n) * exp(-a * 2.1) * fd_ss(0.0, 0.05, a);
                col = mix(col, vec3<f32>(0.9, 0.92, 0.96), saturate(al));
            }
        }
    }
    if (mode == 5 && a < 3.2) {
        // (the ring: what piled up over it rolls out and over, the thick of it going round its own core)
        let Rt = 5.0 + 46.0 * (1.0 - exp(-a / 0.6));
        let rt = 6.0 + 12.0 * (1.0 - exp(-a / 0.6));
        let Ct = C + vec3<f32>(0.0, FD_TIP * d.R + 7.0 + 26.0 * (1.0 - exp(-a / 0.5)), 0.0);
        let Bo = Rt + rt * 1.9;
        let c0 = dot(Ct, v);
        let h = dot(Ct, Ct) - c0 * c0;
        if (h < Bo * Bo) {
            let sq = sqrt(Bo * Bo - h);
            let s0 = max(c0 - sq, 0.05);
            let s1 = min(c0 + sq, s_end);
            if (s1 > s0) {
                const N = 16;
                let ds = (s1 - s0) / f32(N);
                var T = 1.0;
                var L = vec3<f32>(0.0);
                let fade = fd_ss(0.0, 0.12, a) * (1.0 - fd_ss(0.9, 2.6, a));
                for (var i = 0; i < N; i += 1) {
                    let p = v * (s0 + (f32(i) + jit) * ds) - Ct;
                    let ro = length(p.xz);
                    let qx = ro - Rt;
                    let e = length(vec2<f32>(qx, p.y * 1.15));
                    if (e > rt * 1.5) {
                        continue;
                    }
                    let phi = atan2(p.y, qx);
                    let n = gnoise3(vec3<f32>(p.x * 0.1, p.z * 0.1, phi * 0.9 - a * 2.8)) * 0.65 + gnoise3(vec3<f32>(p.x * 0.27, p.z * 0.27, phi * 2.0 - a * 3.6 + 2.0)) * 0.35;
                    let dn = fd_ss(rt * (0.9 + 0.7 * n), rt * (0.1 + 0.5 * n), e) * fade;
                    if (dn < 0.01) {
                        continue;
                    }
                    let up = saturate(p.y / rt * 0.5 + 0.5);
                    var c = vec3<f32>(0.1, 0.09, 0.082) * (li.sunc * (0.3 + 0.7 * up * saturate(li.L.y + 0.4)) + li.amb * 0.8);
                    // (the fire still in its heart, going out)
                    c = c + vec3<f32>(1.3, 0.42, 0.07) * exp(-a / 0.28) * fd_ss(0.7, 0.1, e / rt);
                    let fa = 1.0 - exp(-dn * ds * 0.2);
                    L = L + c * T * fa;
                    T = T * (1.0 - fa);
                }
                col = col * T + L;
            }
        }
    }
    if (mode == 6 && a < 0.5) {
        // (the drop's echoes, running on where it would have gone, thinning out: hollow, the rim of it only)
        for (var i = 1; i < 6; i += 1) {
            let g = C - vec3<f32>(0.0, FD_V * 0.2 * a * f32(i) + f32(i) * 1.5 * d.R * fd_ss(0.0, 0.05, a), 0.0);
            let c0 = dot(g, v);
            let b = length(g - v * c0);
            let x = (b - d.R) / (0.09 * d.R);
            let al = exp(-x * x) * 0.8 * exp(-f32(i) * 0.4) * (1.0 - fd_ss(0.25, 0.5, a));
            col = mix(col, vec3<f32>(0.86, 0.92, 1.04), saturate(al));
        }
    }
    return col;
}
// What a chrome surface sees: the sky, a hard dark line at the horizon, the land, the sun as a hard bright point.
fn fd_env(dir: vec3<f32>, sun: vec3<f32>) -> vec3<f32> {
    let y = dir.y;
    let sky = mix(vec3<f32>(0.95, 1.0, 1.12), vec3<f32>(0.1, 0.2, 0.46), pow(clamp(y, 0.0, 1.0), 0.55));
    let ground = mix(vec3<f32>(0.2, 0.17, 0.13), vec3<f32>(0.035, 0.035, 0.04), pow(clamp(-y, 0.0, 1.0), 0.4));
    var c = select(ground, sky, y > 0.0);
    c = c * (1.0 - 0.95 * exp(-y * y * 2600.0));
    let s = max(dot(dir, sun), 0.0);
    return c + vec3<f32>(9.0, 8.6, 8.0) * pow(s, 1400.0) + vec3<f32>(0.5, 0.48, 0.44) * pow(s, 40.0);
}
// The droplet over the picture (`col` so far, `far` how far the scene is along this ray); `land` the land this pixel's ray ends
// on: its height over the target (x, kept near), where it is (zw), for the dust.
fn fd_droplet(colIn: vec3<f32>, t: f32, v: vec3<f32>, G: vec3<f32>, C: vec3<f32>, d: FdDrop, way: vec2<f32>, far: f32, uv: vec2<f32>, aspect: f32, land: vec4<f32>, li: FdLight, jit: f32) -> vec3<f32> {
    var col = colIn;
    let px = frame.view_params.w / frame.resolution.y;
    let q = project_rel(C);
    let after = fd_since(t);
    let hi = fd_ss(FD_STOP - 5.5, FD_STOP - 0.2, t);
    let mode = fd_stop();
    let tx = fd_stopclock(t, mode);
    if (after > 0.0) {
        col = fd_bent(col, v, C, d, after, far, uv, aspect, mode);
    }
    // ---- the wake, hung in the sky -----------------------------------------------------------------------------------------
    var wake = FdMist(vec3<f32>(0.0), 0.0, vec3<f32>(0.0), vec4<f32>(0.0));
    if (t < FD_GONE) {
        let m = fd_trail(v, C, d, way, tx, px, li, far);
        wake = m;
        if (m.tau > 0.0) {
            col = mix(col, m.c, 1.0 - exp(-m.tau));
        }
        col = mix(col, m.fire.rgb, m.fire.a) + m.glow;
    }
    if (t > 0.6 && t < 3.4) {
        let head0 = d.h - d.stop_h;
        col = fd_sparks(col, v, C - vec3<f32>(way.x * fd_arc(head0), head0, way.y * fd_arc(head0)), way, t, px);
    }
    // ---- the glint: from far up a star, for as long as it is smaller than a few pixels ------------------------------------
    if (q.z > 0.0 && t < FD_STOP) {
        let dp = (uv - q.xy) * vec2<f32>(aspect, 1.0);
        let dd = length(dp);
        let ang = d.R / max(length(C), 1.0);
        let small = 1.0 - fd_ss(0.002, 0.012, ang);
        let tw = 0.85 + 0.15 * sin(t * 37.0);
        let star = exp(-dd / 0.0024) * 2.4 + exp(-abs(dp.y) / 0.0016) * exp(-abs(dp.x) / 0.05) * 1.1 + exp(-abs(dp.x) / 0.0016) * exp(-abs(dp.y) / 0.03) * 0.7;
        col = col + vec3<f32>(1.0, 0.96, 0.9) * star * small * tw;
    }
    // ---- a steady soft halo round it while it hangs, so it can be found on a small screen, and no flicker in it ------------
    if (q.z > 0.0 && t >= FD_STOP && t < FD_MELD) {
        let dh = length((uv - q.xy) * vec2<f32>(aspect, 1.0));
        col = col + vec3<f32>(0.9, 0.95, 1.05) * exp(-dh / 0.016) * 0.2 * fd_ss(FD_STOP + 0.1, FD_STOP + 0.8, t) * (1.0 - fd_ss(FD_TOUCH - 0.2, FD_MELD, t));
    }
    // ---- the metal --------------------------------------------------------------------------------------------------------
    var s_end = far;
    let bc = C + vec3<f32>(0.0, 0.36 * d.R, 0.0);
    let bcd = dot(bc, v);
    // (with the foot of metal in it, a sphere taking that in too)
    let bR = select(1.75 * d.R * max(d.sx, 1.0), max(1.75 * d.R, length(bc - G) + 1.2 * d.pw + d.R), d.pool > 0.0);
    if (length(bc - v * bcd) < bR && bcd > 0.0) {
        var s = max(bcd - bR, 0.05);
        var best = 1.0e9;
        var sb = s;
        var hit = false;
        for (var i = 0; i < 56; i += 1) {
            let e = fd_sdf(v * s - C, d);
            let rel = e / (px * s);
            if (rel < best) {
                best = rel;
                sb = s;
            }
            if (rel < 0.1) {
                hit = true;
                sb = s + e + fd_sdf(v * (s + e) - C, d);
                break;
            }
            s += max(e, 0.15 * px * s);
            if (s > bcd + bR) {
                break;
            }
        }
        // (the edge smoothed over a pixel: a post pass has no other)
        let cov = saturate(1.0 - best);
        if (cov > 0.0 && sb < far + 0.4) {
            let p = v * sb - C;
            let n = fd_normal(p, d);
            let r = reflect(v, n);
            var c = fd_env(r, normalize(frame.sun.xyz));
            // (the real land in it: where the reflection meets the ground, read off the picture, the picture's edge if it is off it,
            // so its underside shows the land's own colours and not a grey)
            if (r.y < 0.15) {
                let up = max(-r.y, 0.03);
                let ro = project_rel(v * sb + r * clamp((dot(v * sb, vec3<f32>(0.0, 1.0, 0.0)) - G.y) / up, 8.0, 400.0));
                // (what lies behind the eye: the land nearest it, the picture's foot)
                let px_ = select(vec2<f32>(0.5, 0.92), clamp(ro.xy, vec2<f32>(0.02, 0.45), vec2<f32>(0.98, 0.98)), ro.z > 0.0);
                c = mix(c, fd_sample(px_) * 1.05, 0.85 * fd_ss(0.15, -0.05, r.y));
            }
            let fres = pow(1.0 - max(dot(-v, n), 0.0), 4.0);
            var mc = c * vec3<f32>(0.9, 0.93, 0.98) * (0.86 + 0.5 * fres);
            // (the sheath's heat on it as it falls, out of it within a second of the stop)
            // (its belly white hot, red up its sides, cooling to chrome from the top down within a second or so of the stop)
            let hot = fd_ss(0.25, -0.75, n.y) * hi * exp(-after / 0.4);
            mc = mix(mc, mix(vec3<f32>(0.85, 0.2, 0.03), vec3<f32>(1.0, 0.86, 0.6), fd_ss(-0.2, -0.85, n.y) * exp(-after / 0.15)), saturate(hot * 1.15));
            col = mix(col, mc, cov);
            // (the stream going by in front of it, thin, its lumps showing, and clearing off it as the stream dies: it stays the thing to look at)
            if (mode == 4 && wake.tau > 0.0) {
                col = mix(col, wake.c, cov * (1.0 - exp(-wake.tau)) * 0.55 * fd_ss(0.2, 0.7, after) * (1.0 - fd_ss(1.5, 3.2, after)));
            }
            if (hit) {
                s_end = min(s_end, sb);
            }
        }
    }
    // ---- the fire round it, and the dust the air raises -----------------------------------------------------------------
    col = fd_sheath(col, v, C, d, tx, s_end, jit);
    col = fd_after(col, v, C, d, t, after, s_end, li, jit, mode);
    // (the dust over it thinned: it stays the thing to look at)
    // (POND and MUSHROOM keep the air off the land; STUTTER's arrives late)
    let air = select(after - select((d.stop_h - d.R) / FD_V, 1.2, mode == 4) - select(0.0, FD_HOLD, mode == 6), -1.0, mode == 1 || mode == 5);
    let dusty = fd_dust(col, v, G, air, s_end, land, li, jit);
    var out_ = mix(dusty, col, select(0.0, 0.7, s_end < far));
    // (STUTTER: the world drained for the beat it hangs, and let go at once)
    if (mode == 6 && after > 0.0 && after < FD_HOLD + 0.1) {
        let g = dot(out_, vec3<f32>(0.3, 0.55, 0.15));
        out_ = mix(out_, vec3<f32>(g) * vec3<f32>(0.86, 0.9, 1.0), 0.42 * fd_ss(0.0, 0.03, after) * (1.0 - fd_ss(FD_HOLD, FD_HOLD + 0.1, after)));
    }
    return out_;
}

// ---- the slam's dust: what it drove out of the ground ------------------------------------------------------------------------
// A wall of dust and ash thrown out of the crater on the frame it appears, running out over the land and slowing, and the
// crater's air full of what fell into it, thinning as it rises. `a`: seconds since the slam.
const FDB_LEN: f32 = 9.0;
const FDB_RIM: f32 = 270.0;
const FDB_OUT: f32 = 280.0;
const FDB_HIGH: f32 = 160.0;
const FDB_STEPS: i32 = 14;
fn fdb_front(a: f32) -> f32 { return FDB_RIM + FDB_OUT * (1.0 - exp(-a * 0.85)); }
fn fdb_high(a: f32) -> f32 { return 22.0 + FDB_HIGH * (1.0 - exp(-a * 1.0)); }
/// How thick the dust is at `p` (from the target).
fn fdb_density(p: vec3<f32>, a: f32) -> f32 {
    let r = length(p.xz);
    let h = fdb_high(a);
    let width = 34.0 + 34.0 * a;
    let x = (r - fdb_front(a)) / width;
    // (the wall leans out, its foot ahead of its top)
    let lean = (r - fdb_front(a) + 0.5 * max(p.y, 0.0)) / width;
    let wall = 0.55 * fd_ss(0.0, 0.5, a) * exp(-min(x * x, lean * lean)) * fd_ss(h * (0.75 + 0.25 * fd_ss(0.0, 200.0, r)), h * 0.2, p.y);
    // (the crater's air: from the floor up over the rim, whatever is above it thin)
    // (only once the panels have fallen: it is what they drive up, and while they fall they are the picture)
    let air = 0.16 * fd_ss(3.6, 5.6, a) * fd_ss(350.0, 170.0, r) * fd_ss(h * 0.9, -30.0, p.y) * (1.0 - fd_ss(3.0, FDB_LEN - 0.5, a));
    let d = (wall + air) * pow(1.0 - a / FDB_LEN, 1.6);
    if (d < 0.01) { return 0.0; }
    let q = p * 0.021 + vec3<f32>(0.0, -a * 0.35, 0.0) + normalize(vec3<f32>(p.x, 0.0, p.z) + vec3<f32>(0.01)) * a * -0.3;
    let n = 0.6 * vnoise3(q) + 0.28 * vnoise3(q * 2.3) + 0.12 * vnoise3(q * 5.1);
    return d * fd_ss(0.3, 0.72, n);
}
/// The picture behind `col` seen through the dust, along `v` from `ro` (from the target), up to `far`.
// ---- the eruption: all that was pent up, let go along the ground. No column and no cloud: fire running out from the middle to the edges over the land as it lies, in the land itself
// (fold_warp.wgsl's own burn, the same front) and here the flames standing off it. Each pixel looks down the picture for the land under it, by the depth, so they follow every slope and
// stand on every ridge. `a`: seconds since FD_ERUPT.
const FDE_LEN: f32 = 4.4;
const FDE_OUT: f32 = 560.0;
const FDE_HIGH: f32 = 46.0;
const FDE_STEPS: i32 = 14;
fn fde_front(a: f32) -> f32 { return 14.0 + FDE_OUT * (1.0 - exp(-a / 1.5)); }
fn fd_erupt(colIn: vec3<f32>, ro: vec3<f32>, v: vec3<f32>, far: f32, a: f32, jit: f32, uv: vec2<f32>) -> vec3<f32> {
    var col = colIn;
    // (the first instant, on everything)
    col = col + (col * 1.6 + vec3<f32>(0.34, 0.22, 0.12)) * exp(-a / 0.2) * fd_ss(0.0, 0.03, a);
    if (a > FDE_LEN) {
        return col;
    }
    let f = fde_front(a);
    let w = 16.0 + 26.0 * a;
    // (how far up the picture a flame reaches from here)
    let P = v * clamp(far, 12.0, 900.0);
    let q0 = project_rel(P);
    let q1 = project_rel(P + vec3<f32>(0.0, FDE_HIGH, 0.0));
    if (q0.z < 0.0 || q1.z < 0.0) {
        return col;
    }
    let dv = q1.xy - q0.xy;
    let aa = max(dot(v.xz, v.xz), 1.0e-5);
    var best = 0.0;
    for (var k = 0; k < FDE_STEPS; k += 1) {
        let uk = uv - dv * (f32(k) + jit) / f32(FDE_STEPS);
        if (uk.x < 0.0 || uk.x > 1.0 || uk.y < 0.0 || uk.y > 1.0) {
            continue;
        }
        let dk = depth_at(uk);
        if (is_sky(dk)) {
            continue;
        }
        let off = world_offset(uk, dk);
        // (the clouds are in the depth too: that isn't land to burn)
        if (abs(off.y + frame.camera_position.y - CLOUD_Y - 2.0) < 6.0) {
            continue;
        }
        let G = off + ro;
        let r = length(G.xz);
        if (abs(r - f) > 3.0 * w + 40.0) {
            continue;
        }
        // (this pixel's ray over that bit of land: how high, and how near)
        let s = dot(off.xz, v.xz) / aa;
        let h = v.y * s - off.y;
        if (s <= 0.0 || s > far + 1.0 || h < -1.0) {
            continue;
        }
        let nw = gnoise3(vec3<f32>(G.xz * 0.05, a * 2.2));
        let x = (r - f + (nw - 0.5) * 70.0) / w;
        let band = fd_ss(1.0, 0.1, x) * fd_ss(-2.4, -0.3, x);
        if (band < 0.01) {
            continue;
        }
        let nf = gnoise3(vec3<f32>(G.xz * 0.09, h * 0.035 - a * 3.2));
        // (tongues, with the land's own fire showing between them)
        let tall = FDE_HIGH * band * fd_ss(0.38, 0.72, nf) * (1.0 - fd_ss(2.2, FDE_LEN, a)) * fd_ss(560.0, 420.0, r);
        let e = h / max(tall, 0.1);
        if (e >= 1.0) {
            continue;
        }
        let dens = (1.0 - e) * fd_ss(7.0, 1.0, length(v.xz * s - off.xz)) * (0.3 + 1.0 * gnoise3(vec3<f32>(G.xz * 0.2, a * 3.5 + h * 0.06)));
        best = max(best, dens);
    }
    if (best > 0.0) {
        // (white at its foot, yellow, orange, dull red at its tips)
        var fc = mix(vec3<f32>(0.34, 0.05, 0.01), vec3<f32>(0.98, 0.34, 0.05), fd_ss(0.18, 0.5, best));
        fc = mix(fc, vec3<f32>(1.05, 0.76, 0.3), fd_ss(0.62, 0.95, best));
        col = mix(col, fc, fd_ss(0.1, 0.34, best));
    }
    return col;
}
fn fd_blast(colIn: vec3<f32>, ro: vec3<f32>, v: vec3<f32>, far: f32, a: f32, jit: f32) -> vec3<f32> {
    let reach = fdb_front(a) + 90.0 + 30.0 * a;
    let top = fdb_high(a) * 1.15;
    // (only the slab of air it can be in, and the circle round the target)
    let b = dot(ro.xz, v.xz);
    let aa = max(dot(v.xz, v.xz), 1.0e-5);
    let c = dot(ro.xz, ro.xz) - reach * reach;
    let disc = b * b - aa * c;
    if (disc <= 0.0) { return colIn; }
    let sq = sqrt(disc);
    var s0 = max((-b - sq) / aa, 0.0);
    var s1 = min((-b + sq) / aa, far);
    let lo = -110.0;
    if (abs(v.y) > 1.0e-4) {
        let ya = (lo - ro.y) / v.y;
        let yb = (top - ro.y) / v.y;
        s0 = max(s0, min(ya, yb));
        s1 = min(s1, max(ya, yb));
    } else if (ro.y < lo || ro.y > top) {
        return colIn;
    }
    if (s1 <= s0) { return colIn; }
    let sun = normalize(frame.sun.xyz);
    let day = fd_ss(-0.12, 0.25, sun.y);
    let step = (s1 - s0) / f32(FDB_STEPS);
    var seen = 1.0;
    var light = vec3<f32>(0.0);
    for (var i = 0; i < FDB_STEPS; i += 1) {
        let p = ro + v * (s0 + (f32(i) + jit) * step);
        let d = fdb_density(p, a);
        if (d <= 0.0) { continue; }
        // (lit from above and towards the sun; dark ash at its foot, paler dust as it rises)
        let up = fd_ss(-20.0, fdb_high(a), p.y);
        let lit = fdb_density(p + sun * 14.0, a);
        let c = mix(vec3<f32>(0.1, 0.09, 0.085), vec3<f32>(0.5, 0.45, 0.39), up) * (0.35 + 0.65 * exp(-lit * 2.4)) * (0.16 + 0.84 * day);
        let t = 1.0 - exp(-d * step * 0.065);
        light += c * t * seen;
        seen *= 1.0 - t;
        if (seen < 0.02) { break; }
    }
    return colIn * seen + light;
}

// ---- the metal's frame --------------------------------------------------------------------------------------------------
// fw_turn undone: from where fw_place leaves a point, or a way, to the tube's own frame: the target at the origin, its axis up; and back, for a way.
fn fd_unturn(P: vec3<f32>, g: FwBend, at: vec3<f32>, point: bool) -> vec3<f32> {
    let ct = cos(at.z);
    let st = sin(at.z);
    let w = select(0.0, 1.0, point);
    let al = dot(P.xz, g.e) - g.d * w;
    let dv = -P.x * g.e.y + P.z * g.e.x;
    let dy0 = P.y - g.pin * w;
    let along = al * ct - dy0 * st + at.x * w;
    let Y = al * st + dy0 * ct + at.y * w;
    return vec3<f32>(along * g.e.x - dv * g.e.y, Y, along * g.e.y + dv * g.e.x);
}
fn fd_returned(n: vec3<f32>, g: FwBend, at: vec3<f32>) -> vec3<f32> {
    let ct = cos(at.z);
    let st = sin(at.z);
    let al = dot(n.xz, g.e);
    let dv = -n.x * g.e.y + n.z * g.e.x;
    let qx = al * ct + n.y * st;
    let qy = -al * st + n.y * ct;
    return vec3<f32>(qx * g.e.x - dv * g.e.y, qy, qx * g.e.y + dv * g.e.x);
}
// What the metal sees past the picture's edge. The picture hasn't what is behind the eye, and a mirror this big shows everything it reflects, so not a map of the land: what makes
// chrome chrome. Dark, the land's own dim greens and blues far off in it, and long soft ribbons of the sky's light lying along it, which the metal's curves draw out and bend.
fn fd_round(r: vec3<f32>) -> vec3<f32> {
    let w = r.y * 5.0 + 0.7 * sin(r.x * 2.7 + 1.0 * sin(r.z * 3.1)) + 0.55 * sin(r.z * 3.3 - 0.8 * sin(r.x * 2.2 + 1.0));
    let n = 0.6 * sin(r.x * 3.1 + 1.3 * sin(r.z * 3.7 + 0.7) + r.y) + 0.5 * sin(r.z * 4.3 - 1.1 * sin(r.x * 2.9 - 1.0) - 1.4 * r.y);
    let k = fw_ss(-0.4, 0.9, n);
    let hue = 0.5 + 0.5 * sin(r.x * 2.3 - r.z * 1.7 + 1.1 * sin(r.y * 5.0));
    let land = mix(vec3<f32>(0.03, 0.05, 0.03), vec3<f32>(0.02, 0.035, 0.075), hue);
    var c = mix(land * 0.3, land * 1.5 + vec3<f32>(0.035, 0.04, 0.05), k);
    let a = 0.5 + 0.5 * cos(w * 2.0);
    c = c + vec3<f32>(0.62, 0.66, 0.74) * pow(a, 26.0) * (0.3 + 0.7 * k);
    c = c + vec3<f32>(0.1, 0.11, 0.13) * pow(0.5 + 0.5 * cos(w * 2.0 + 1.9), 3.0);
    return c;
}
// The droplet's own metal, for a surface at `S` from the eye (along `v`) with normal `n`: fd_env's sky, its hard dark line, the sun, and under it the land off the picture.
// `near` how much of the real land it mirrors: what is under it at the tip, where there is land on the picture to mirror.
fn fd_chrome(v: vec3<f32>, S: vec3<f32>, n: vec3<f32>, G: vec3<f32>, near: f32) -> vec3<f32> {
    let r = reflect(v, n);
    // (its horizon drawn down: seen from under it, most of a thing hung up looks down, and the droplet's bright half would be lost)
    let e = normalize(vec3<f32>(r.x, (r.y + FD_LIFT) * 1.7, r.z));
    var c = fd_env(e, normalize(frame.sun.xyz));
    c = c * (1.0 - 0.9 * exp(-e.y * e.y * 24000.0));
    if (e.y < 0.03) {
        let up = max(-r.y, 0.03);
        let ro = project_rel(S + r * clamp((S.y - G.y) / up, 8.0, 400.0));
        let edge = fd_ss(0.0, 0.05, min(min(ro.x, 1.0 - ro.x), min(ro.y, 1.0 - ro.y)));
        let there = select(0.0, edge, ro.z > 0.0 && r.y < 0.0) * near;
        var l = fd_round(r);
        if (there > 0.0) {
            l = mix(l, fd_sample(ro.xy), there);
        }
        c = mix(c, l * 1.05, 0.9 * fd_ss(0.012, -0.012, e.y));
    }
    let fres = pow(1.0 - max(dot(-v, n), 0.0), 4.0);
    // (the droplet is small: this much of a thing at night has to go down with the sky)
    let day = 0.14 + 0.86 * fd_ss(-0.2, 0.1, frame.sun.y);
    return c * vec3<f32>(0.9, 0.93, 0.98) * (0.86 + 0.5 * fres) * day;
}
const FD_LIFT: f32 = 0.26;
// ---- the boil ---------------------------------------------------------------------------------------------------------------
// The hole in the roof closes, and what closes it is metal, slowly, heavy. The land's end melts: thick tongues of the droplet's metal crawl in from the rim for seconds, from one side first, the
// stars narrowing between them, and as they near each other their fronts and the pockets left between them seethe (fb_seethe), more and more; they bridge pair by pair (FB_JOIN on) and the last
// pockets close off to one side. The surface they make heaves and rolls and settles, with no streaming in it (fb_heave); the flow (fb_flow) grows out of that by the metal drawing itself to the drip:
// what is on it is carried along a real field, currents, eddies and all, so that the streaks are its lumps pulled out. A dimple, a bulge hanging out of it, a bead on a neck, a pinch, and one drop
// falls the length of the tube under gravity to the target on FD_BEAT. Out over the land past the rim there is no edge to it (fb_creep). All in the tube's own frame (fd_unturn), wherever the player has gone.
const FB_MELT: f32 = 32.5;         // the land's end starts to melt
const FB_JOIN: f32 = 35.8;         // the tongues start to bridge
const FB_SEAL: f32 = 36.85;        // the last of the stars has gone
const FB_RUN: f32 = 37.2;         // the flow begins to grow out of the settling surface
const FB_FLOWN: f32 = 38.7;        // by here it is flowing in full
const FB_PIN: f32 = 38.35;          // the pinch: the drop is let go
const FB_UP: f32 = 4.0;            // the surface over the land's end, so what is left of the land goes in front of it
const FB_FIT: f32 = 1.2;           // past the hole's rim it goes on, behind the land
const FB_LONG: f32 = 78.0;         // how far the bead hangs under the surface as it lets go
const FB_V0: f32 = 34.0;           // how fast it is going as it does
const FB_THICK: f32 = 24.0;        // the metal's thickness, blocks
const FB_EDGE: f32 = 19.0;         // how soon it reaches that from its edge
// The tongues' own clock: their shapes were keyed on one that ran from 34.5, and it goes by slowly here: ~3.3 s for its first second, then the join, drawn out.
fn fb_tm(t: f32) -> f32 {
    let a = (t - FB_MELT) / 3.3;
    if (a < 1.0) {
        return 34.5 + a;
    }
    return 35.5 + (t - (FB_MELT + 3.3)) * 0.42 / (FB_SEAL - (FB_MELT + 3.3));
}
fn fb_source(g: FwBend) -> vec2<f32> {
    // (off to one side of the player, so that it starts where they can see it start)
    return vec2<f32>(-0.32 * g.e.x - 0.947 * g.e.y, 0.947 * g.e.x - 0.32 * g.e.y);
}
// How late a bearing is, 0 on the side it starts, 1 across from it.
fn fb_late(dir: vec2<f32>, S: vec2<f32>) -> f32 {
    return 0.5 - 0.5 * dot(dir, S);
}
// The metal on the hole: `d` how far `q` is outside it, blocks (under 0 inside), and its slope. The rim growing in, and FB_TONGUES thick tongues from it to a place off to the far side, each its
// own width and time, the first from the side at `S`, one soft union whose softness jumps as they join. What is between them is the stars.
const FB_TONGUES: i32 = 9;
struct FbMetal { d: f32, g: vec2<f32> }
fn fb_metal(qIn: vec2<f32>, t: f32, S: vec2<f32>, rd: f32) -> FbMetal {
    // (no straight lines: the whole of it is bent a little, slowly)
    let q = qIn + 30.0 * vec2<f32>(sin(qIn.y * 0.0093 + 0.25 * t + 1.0) + 0.4 * sin(qIn.y * 0.031 - 0.17 * t), sin(qIn.x * 0.0107 - 0.21 * t + 2.0) + 0.4 * sin(qIn.x * 0.027 + 0.2 * t));
    let r = max(length(q), 0.01);
    let dirq = q / r;
    let tm = fb_tm(t);
    let jn = fw_ss(FB_JOIN, FB_JOIN + 0.5, t);
    let k = 13.0 + 11.0 * jn;
    // ---- the rim, growing in, unevenly ------------------------------------------------------------------------------------------
    let late = fb_late(dirq, S);
    let g0 = fw_ss(34.5 + 0.32 * late, 35.8 + 0.5 * late, tm);
    let th = atan2(q.y, q.x);
    let ringR = rd * (1.03 - 0.24 * g0 * (1.0 + 0.45 * sin(th * 2.0 + 1.0 + 0.9 * sin(th * 3.0)) + 0.3 * sin(th * 5.0 - 0.6)));
    let d0 = ringR - r;
    var sum = exp(clamp(-d0 / k, -40.0, 40.0));
    var gs = -dirq * sum;
    // ---- the tongues ----------------------------------------------------------------------------------------------------------
    let seal = -S * rd * 0.3;
    for (var i = 0; i < FB_TONGUES; i += 1) {
        let fi = f32(i);
        let h = hash21(vec2<f32>(fi, 41.0));
        let h2 = fract(h * 27.1);
        let an = (fi + 0.7 * h) * 6.2831853 / f32(FB_TONGUES);
        let A = vec2<f32>(cos(an), sin(an));
        let lt = fb_late(A, S);
        let u = clamp((tm - (34.6 + 0.85 * lt + 0.2 * h2)) / (0.95 + 0.55 * h), 0.0, 1.0);
        if (u <= 0.0) {
            continue;
        }
        // (slow to get going, heavy, and it doesn't quite stop; it comes on in surges, a lobe rolling over the front)
        let p0 = u * u * (3.0 - 2.0 * u);
        let p = p0 + 0.42 * p0 * (1.0 - p0) * sin(u * 11.0 + h * 6.28) * 0.5;
        let B = A * rd * 1.06;
        let T = mix(B, seal, 0.08 + 0.92 * p);
        let ba = T - B;
        let qa = q - B;
        let s = clamp(dot(qa, ba) / max(dot(ba, ba), 1.0), 0.0, 1.0);
        let e = qa - ba * s;
        let el = max(length(e), 0.01);
        // (thick: a blunt head on it, wider than what is behind it, a heavy thing that has to push)
        let head = exp(-pow((1.0 - s) * length(ba) / 70.0, 2.0));
        let wd = (30.0 + 40.0 * h2) * (0.55 + 0.45 * p) * (1.0 + 0.55 * (1.0 - s)) * (1.0 + 0.2 * jn + 0.06 * fw_ss(FB_JOIN + 0.2, FB_SEAL, t)) + 16.0 * head * (0.4 + 0.6 * p);
        let di = el - wd;
        let w = exp(clamp(-di / k, -40.0, 40.0));
        sum += w;
        gs += w * e / el;
    }
    // (what's left of the stars closes on its own, by FB_SEAL)
    let fill = 70.0 * fw_ss(FB_SEAL - 0.3, FB_SEAL + 0.02, t);
    return FbMetal(-k * log(max(sum, 1.0e-30)) - fill, gs / max(sum, 1.0e-30));
}
// The big slow bubbles: each swells where it is and bursts, a ring running off it. Their slope.
const FB_BUBBLES: i32 = 6;
fn fb_bubbles(q: vec2<f32>, t: f32, S: vec2<f32>, rd: f32) -> vec2<f32> {
    var g = vec2<f32>(0.0);
    if (t < 36.3 || t > 40.2) {
        return g;
    }
    let P = array<vec2<f32>, 6>(vec2<f32>(0.62, 0.7), vec2<f32>(0.5, 2.6), vec2<f32>(0.78, 4.1), vec2<f32>(0.45, 5.3), vec2<f32>(0.7, 1.7), vec2<f32>(0.58, 3.5));
    let W = array<vec3<f32>, 6>(vec3<f32>(36.4, 1.25, 46.0), vec3<f32>(36.72, 1.3, 62.0), vec3<f32>(36.95, 1.0, 38.0), vec3<f32>(37.3, 1.3, 54.0), vec3<f32>(37.55, 1.1, 42.0), vec3<f32>(37.8, 1.2, 34.0));
    let turn = atan2(S.y, S.x);
    for (var i = 0; i < FB_BUBBLES; i += 1) {
        let w = W[i];
        let a = t - (w.x + w.y);
        if (t < w.x || a > 1.5) {
            continue;
        }
        let bear = P[i].y + turn;
        let c = vec2<f32>(cos(bear), sin(bear)) * P[i].x * rd * (1.0 - 0.14 * clamp((t - w.x) / 2.0, 0.0, 1.0));
        let e = q - c;
        let el = max(length(e), 0.01);
        let dir = e / el;
        if (a < 0.0) {
            // (a heavy dome, its top slowly coming down towards the eye)
            let x = (t - w.x) / w.y;
            let R = w.z * (0.45 + 0.55 * sqrt(x));
            let u = el / R;
            if (u < 1.0) {
                let A = 0.3 * R * x * x * (3.0 - 2.0 * x);
                let f = 1.0 - u * u;
                g -= dir * 6.0 * A * u * f * f / R;
            }
        } else {
            // (it has burst: its skirt falls back and runs out as a ring, thick, gone in a second)
            let front = w.z * (1.0 + 1.1 * (1.0 - exp(-a / 0.34)));
            let wd = 10.0 + 0.3 * w.z;
            let x2 = (el - front) / wd;
            let A = 0.17 * w.z * exp(-a / 0.5);
            g -= dir * 2.0 * A * x2 * exp(-x2 * x2) / wd;
        }
    }
    return g;
}
// ---- the seethe: bubbles of every size in the metal at the fronts and round the pockets of stars, building as they close. Three loose scatters, big slow ones and small quick ones, each on its own
// rotated grid so nothing lines up; a cycle of each cell swells a dome where it likes and bursts it. Most cycles of most cells have nothing in them, so there is never a pattern of them. `amt`, how
// much seethe here, thins them out. Out: height, slope.
fn fb_seethe(q: vec2<f32>, t: f32, amt: f32, edge: f32) -> vec3<f32> {
    var o = vec3<f32>(0.0);
    let CELL = array<f32, 3>(205.0, 92.0, 50.0);
    let PER = array<f32, 3>(2.3, 1.35, 0.8);
    let RAD = array<f32, 3>(82.0, 38.0, 20.0);
    let SL = array<f32, 3>(1.0, 0.6, 0.3);
    let EDGE_K = array<f32, 3>(1.0e4, 110.0, 40.0);
    let ROT = array<vec2<f32>, 3>(vec2<f32>(0.8, 0.6), vec2<f32>(0.28, -0.96), vec2<f32>(-0.6, 0.8));
    for (var k = 0; k < 3; k += 1) {
        // (the small ones only right at the front: further in, only the big)
        let keep = fw_ss(EDGE_K[k], 0.6 * EDGE_K[k], edge);
        if (keep <= 0.0) {
            continue;
        }
        let u = vec2<f32>(q.x * ROT[k].x - q.y * ROT[k].y, q.x * ROT[k].y + q.y * ROT[k].x) / CELL[k] + vec2<f32>(f32(k) * 3.7, 11.0);
        let c0 = floor(u - 0.5);
        for (var j = 0; j < 4; j += 1) {
            let c = c0 + vec2<f32>(f32(j & 1), f32(j >> 1));
            let ph = hash21(c + f32(k) * 19.0);
            let cl = (t + ph * 40.0) / PER[k];
            let cy = floor(cl);
            let h = hash21(c * 1.7 + vec2<f32>(cy * 0.37 + f32(k) * 5.0, cy * 0.61));
            if (h > amt) {
                continue;
            }
            let h2 = fract(h * 91.7 + ph);
            let h3 = fract(h2 * 47.3);
            let life = fract(cl);
            let sz = RAD[k] * (0.5 + 0.5 * h2 * h2);
            let wt = fw_ss(0.0, 0.16, amt - h) * keep;
            let e0 = (u - (c + vec2<f32>(0.5) + (vec2<f32>(h2, h3) - 0.5) * max(0.5 - 1.5 * sz / CELL[k], 0.14))) * CELL[k];
            // (none of them round: each squashed its own way, and leaning)
            let an = h3 * 6.2831853;
            let ca = cos(an);
            let sa = sin(an);
            let sq = 1.0 + 0.9 * fract(h3 * 13.1);
            let e1 = vec2<f32>(ca * e0.x + sa * e0.y, (-sa * e0.x + ca * e0.y) * sq);
            let el = max(length(e1), 0.01);
            let d1 = vec2<f32>(ca * e1.x - sa * e1.y * sq, sa * e1.x + ca * e1.y * sq) / el;
            let dir = vec2<f32>(d1.x * ROT[k].x + d1.y * ROT[k].y, -d1.x * ROT[k].y + d1.y * ROT[k].x);
            let x = life / 0.74;
            if (x < 1.0) {
                let R = sz * (0.45 + 0.55 * sqrt(x));
                let w = el / R;
                if (w < 1.0) {
                    // (no flat top on it: a soft hump, with nothing in the middle to make it an eye)
                    let A = 0.3 * R * x * x * (3.0 - 2.0 * x);
                    let f = 1.0 - w * w;
                    // (the small ones are the edge's: they lift it and hardly mark the surface, which is where they would be eyes)
                    o = o + wt * vec3<f32>(A * f * f * f, -dir * 6.0 * A * w * f * f / R * SL[k]);
                }
            } else if (k == 0) {
                // (it goes down fast, not at once)
                {
                    let a0 = (life - 0.74) * PER[k];
                    let w = el / sz;
                    if (w < 1.0) {
                        let A = 0.3 * sz * exp(-a0 / (0.05 * PER[k]));
                        let f = 1.0 - w * w;
                        o = o + wt * vec3<f32>(A * f * f * f, -dir * 6.0 * A * w * f * f / sz * SL[k]);
                    }
                }
                // (a big one leaves a ring, thick, gone soon)
                let a = (life - 0.74) * PER[k];
                let front = sz * (1.0 + 0.4 * (1.0 - exp(-a / (0.14 * PER[k]))));
                let wd = 0.35 * sz + 2.0;
                let x2 = (el - front) / wd;
                let A = 0.13 * sz * exp(-a / (0.1 * PER[k]));
                let f = exp(-x2 * x2);
                // (where the metal is thin it bursts right through: stars for a moment)
                let gone = exp(-(el * el) / (sz * sz * 0.5)) * exp(-a / (0.13 * PER[k]));
                o = o + wt * vec3<f32>(A * f - 0.55 * sz * gone, -dir * 2.0 * A * x2 * f / wd);
            } else {
                let a = (life - 0.74) * PER[k];
                let w = el / sz;
                if (w < 1.0) {
                    let A = 0.3 * sz * exp(-a / (0.05 * PER[k]));
                    let f = 1.0 - w * w;
                    o = o + wt * vec3<f32>(A * f * f * f, -dir * 6.0 * A * w * f * f / sz * SL[k]);
                }
                o.x = o.x - wt * 0.6 * sz * exp(-(el * el) / (sz * sz * 0.5)) * exp(-a / (0.13 * PER[k]));
            }
        }
    }
    return o;
}
// The integral of fw_ss(a, b, t) over t: how far a thing has gone whose speed comes up smoothly.
fn fb_ramp(a: f32, b: f32, t: f32) -> f32 {
    let u = clamp((t - a) / (b - a), 0.0, 1.0);
    return (b - a) * u * u * u * (1.0 - 0.5 * u) + max(t - b, 0.0);
}
// How far the metal has been drawn, in blocks at the speed of the field below: nothing until the surface has settled, then it comes up slowly.
const FB_DRAW: f32 = 30.0;         // blocks a second, as it runs in full, where the field is 1
fn fb_drawn(t: f32) -> f32 {
    return FB_DRAW * fb_ramp(FB_RUN, FB_FLOWN, t);
}
// How far the metal was carried in as the tongues crawled.
fn fb_crawled(t: f32) -> f32 {
    return 110.0 * (fb_ramp(33.0, 34.2, t) - fb_ramp(35.6, 36.9, t));
}
// The field the metal is drawn along: to the drip, and over that plane waves of current, each part turning and part closing or spreading, so that there are eddies, and places currents meet and
// fold and places they part. x is how far it has been drawn: the field moves on as it goes, slowly. Out: velocity, and its gradient: (dv.x/dx, dv.x/dy, dv.y/dx, dv.y/dy).
struct FbField { v: vec2<f32>, dv: vec4<f32> }
fn fb_field(q: vec2<f32>, x: f32) -> FbField {
    let r = max(length(q), 1.0);
    let rh = q / r;
    let e = exp(-r / 170.0);
    let gate = fw_ss(3.0, 30.0, r);
    let S = (0.5 + 1.0 * e) * gate;
    let dS = -1.0 / 170.0 * e * gate;
    var v = -rh * S;
    // (-S rh: along rh its gradient is -dS, across it -S / r)
    let a = -dS;
    let b = -S / r;
    var dv = vec4<f32>(a * rh.x * rh.x + b * rh.y * rh.y, (a - b) * rh.x * rh.y, (a - b) * rh.x * rh.y, a * rh.y * rh.y + b * rh.x * rh.x);
    let K = array<vec2<f32>, 4>(vec2<f32>(0.0143, 0.0041), vec2<f32>(-0.0086, 0.0207), vec2<f32>(0.0238, -0.0167), vec2<f32>(-0.0301, -0.0223));
    let Pp = array<f32, 4>(0.7, 2.9, 4.6, 1.3);
    let Om = array<f32, 4>(0.0031, -0.0043, 0.0058, -0.0071);
    let Sp = array<f32, 4>(0.82, 0.7, 0.56, 0.4);
    let Tw = array<vec2<f32>, 4>(vec2<f32>(0.94, 0.3), vec2<f32>(-0.88, 0.45), vec2<f32>(0.75, -0.6), vec2<f32>(0.97, 0.2));
    for (var i = 0; i < 4; i += 1) {
        let k = K[i];
        let ph = dot(k, q) + Pp[i] + Om[i] * x;
        let c = cos(ph);
        let s = sin(ph);
        let kl = length(k);
        let kh = k / kl;
        // (Tw.x of it across the wave, turning; Tw.y along it, closing and spreading)
        let d = (vec2<f32>(-kh.y, kh.x) * Tw[i].x + kh * Tw[i].y) * Sp[i];
        v = v + d * c;
        dv = dv - vec4<f32>(d.x * k.x, d.x * k.y, d.y * k.x, d.y * k.y) * s;
    }
    return FbField(v, dv);
}
// The heave: what the surface does after it has joined, before anything runs: long swells rocking on the spot and rolling across it, slowly dying down, some of it never gone. Slope.
fn fb_heave(q: vec2<f32>, t: f32) -> vec2<f32> {
    let on = fw_ss(FB_JOIN, FB_JOIN + 0.7, t);
    if (on <= 0.0) {
        return vec2<f32>(0.0);
    }
    let dec = 0.32 + 0.68 * exp(-max(t - 36.9, 0.0) / 0.9);
    var g = vec2<f32>(0.0);
    // (rocking)
    let K = array<vec2<f32>, 3>(vec2<f32>(0.0121, 0.0072), vec2<f32>(-0.0083, 0.0144), vec2<f32>(0.0176, -0.0101));
    let W = array<vec3<f32>, 3>(vec3<f32>(1.5, 1.1, 9.0), vec3<f32>(1.1, 3.7, 11.0), vec3<f32>(1.9, 0.4, 6.0));
    for (var i = 0; i < 3; i += 1) {
        let w = W[i];
        g = g + K[i] * w.z * cos(dot(K[i], q) + 0.8 * sin(0.9 * t + w.y)) * sin(w.x * t + w.y);
    }
    // (rolling: long fronts coming through, curved, each from its own side and at its own speed)
    let C = array<vec2<f32>, 4>(vec2<f32>(-900.0, 300.0), vec2<f32>(700.0, 800.0), vec2<f32>(300.0, -1000.0), vec2<f32>(-500.0, -800.0));
    let T = array<vec3<f32>, 4>(vec3<f32>(36.1, 76.0, 9.0), vec3<f32>(36.9, 58.0, 7.5), vec3<f32>(37.7, 92.0, 6.0), vec3<f32>(38.6, 68.0, 7.0));
    for (var i = 0; i < 4; i += 1) {
        let w = T[i];
        let e = q - C[i];
        let el = length(e);
        let x = (el - (length(C[i]) - 420.0) - w.y * (t - w.x)) / 60.0;
        if (abs(x) < 3.0) {
            g = g + e / el * (-2.0 * x / 60.0) * exp(-x * x) * w.z * 3.0;
        }
    }
    return g * on * dec;
}
// The metal's own forms: broad rolling ones and, drawn out, narrow ones, plane waves at angles that never line up, each sliding over the metal at its own rate. Their slope, in the coordinates they are carried in.
fn fb_lumps(a: vec2<f32>, t: f32) -> vec2<f32> {
    let K = array<vec3<f32>, 5>(vec3<f32>(0.0191, 0.0072, 0.115), vec3<f32>(-0.0103, 0.0247, 0.1), vec3<f32>(0.0086, -0.0129, 0.11), vec3<f32>(-0.0313, -0.0141, 0.085), vec3<f32>(0.0292, 0.0303, 0.06));
    let W = array<vec2<f32>, 5>(vec2<f32>(0.24, 0.6), vec2<f32>(-0.37, 2.4), vec2<f32>(0.15, 4.4), vec2<f32>(0.5, 1.1), vec2<f32>(-0.64, 5.6));
    var g = vec2<f32>(0.0);
    for (var i = 0; i < 5; i += 1) {
        let k = K[i];
        let ph = k.x * a.x + k.y * a.y + W[i].y + W[i].x * t + 1.7 * sin(0.0083 * a.y - 0.0061 * a.x + W[i].y) + 1.2 * sin(0.0057 * a.x + 0.0121 * a.y + 2.1 * W[i].y);
        g = g + normalize(k.xy) * k.z * cos(ph);
    }
    return g;
}
fn fb_fine(a: vec2<f32>, t: f32) -> vec2<f32> {
    let K = array<vec3<f32>, 4>(vec3<f32>(0.0637, 0.0411, 0.1), vec3<f32>(-0.0352, 0.0837, 0.09), vec3<f32>(0.0953, -0.0524, 0.075), vec3<f32>(-0.0721, -0.1046, 0.06));
    let W = array<vec2<f32>, 4>(vec2<f32>(0.9, 3.1), vec2<f32>(-1.3, 0.7), vec2<f32>(1.7, 5.2), vec2<f32>(-2.1, 1.9));
    var g = vec2<f32>(0.0);
    for (var i = 0; i < 4; i += 1) {
        let k = K[i];
        g = g + normalize(k.xy) * k.z * cos(k.x * a.x + k.y * a.y + W[i].y + W[i].x * t);
    }
    return g;
}
// The metal's surface: (height, its slope along x, z), blocks. `ps`, how big a pixel is there.
const FB_STEPS: i32 = 5;
fn fb_flow(q: vec2<f32>, t: f32, ps: f32) -> vec3<f32> {
    let r = max(length(q), 1.0);
    let rh = q / r;
    // ---- where what is here came from ----
    let X = fb_drawn(t);
    var p = q;
    var J = vec4<f32>(1.0, 0.0, 0.0, 1.0);
    if (X > 0.5) {
        let dx = X / f32(FB_STEPS);
        for (var i = 0; i < FB_STEPS; i += 1) {
            let f = fb_field(p, X * (1.0 - (f32(i) + 0.5) / f32(FB_STEPS)));
            p = p - f.v * dx;
            let m = vec4<f32>(1.0, 0.0, 0.0, 1.0) - f.dv * dx;
            J = vec4<f32>(m.x * J.x + m.y * J.z, m.x * J.y + m.y * J.w, m.z * J.x + m.w * J.z, m.z * J.y + m.w * J.w);
        }
    }
    // (and as the tongues crawled, in from the rim. Near enough no shear in that, for what it adds)
    let cr = fb_crawled(t);
    let out = cr / (length(p) + 240.0);
    // (the broad forms are thick, and go at something over half the speed of what's on them)
    let d = p - q;
    let pa = (q + 0.55 * d) * (1.0 + out);
    let Ja = vec4<f32>(1.0, 0.0, 0.0, 1.0) + 0.55 * (J - vec4<f32>(1.0, 0.0, 0.0, 1.0));
    let ga = fb_lumps(pa, t);
    // (how hard it has been squeezed: what is squeezed thin goes under, or it crowds to a hair)
    let cc = dot(Ja, Ja);
    // (the drip: as the bead comes the middle goes smooth, a long clean funnel with nothing on it, so that the eye goes there and the bead can be seen)
    let well = fw_ss(FB_PIN - 1.3, FB_PIN - 0.5, t) * (1.0 - fw_ss(FB_PIN + 0.9, FB_PIN + 2.0, t));
    let calm = 1.0 - well * (1.0 - fw_ss(45.0, 190.0, r));
    var g = vec2<f32>(Ja.x * ga.x + Ja.z * ga.y, Ja.y * ga.x + Ja.w * ga.y) * 2.3 * calm / (1.0 + 0.1 * max(cc - 2.0, 0.0));
    // ---- the narrow forms, which the flow draws out to the streaks ----
    let c2 = dot(J, J);
    let on = (0.3 + 1.1 * fw_ss(6.0, 70.0, X)) * fw_ss(4.0, 30.0, r) * calm / (1.0 + 0.05 * max(c2 - 2.0, 0.0) + 0.04 * c2 * ps * ps);
    if (on > 0.01) {
        let gb = fb_fine(p * (1.0 + out), t);
        g = g + vec2<f32>(J.x * gb.x + J.z * gb.y, J.y * gb.x + J.w * gb.y) * on;
    }
    g = g + fb_heave(q, t) * calm + rh * well * 0.7 * (r / 85.0) * exp(0.5 - 0.5 * r * r / (85.0 * 85.0));
    // (rings running out of the middle from the pinch)
    let xp = t - FB_PIN;
    if (xp > 0.0 && xp < 1.6) {
        let ph = r * 0.16 - xp * 16.0;
        let a_ = 2.2 * exp(-xp / 0.5) * fw_ss(0.0, 0.05, xp) * fw_ss(r * 0.16 - 16.0 * xp - 0.5, r * 0.16 - 16.0 * xp + 1.5, 0.0);
        g = g + rh * a_ * 0.16 * cos(ph) * exp(-r / 150.0);
    }
    return vec3<f32>(0.0, g);
}
// How far out the hole has opened again as the metal lets go: all at once, from the middle, the plate and the metal drawing back to the rim.
fn fb_opened(t: f32, rd: f32) -> f32 {
    if (t <= FW_LETGO) {
        return -1.0;
    }
    return 1.12 * rd * (1.0 - exp(-(t - FW_LETGO) / 0.15));
}
// The shape hanging under the surface, from FB_RUN on: a dimple out of which a bulge hangs (a over the surface, wide w, its ring of dimple d), the bead on its neck. L how far
// the bead's centre is under the surface, R its radius, n the neck's radius, and top how far up the neck goes: past the pinch, what is left of it going back up.
struct FbPool { a: f32, w: f32, d: f32, L: f32, R: f32, n: f32, top: f32 }
fn fb_R(dist: f32) -> f32 {
    return clamp(dist * 0.085, 9.0, 22.0);
}
fn fb_pool(t: f32, Rd: f32) -> FbPool {
    let x = t - FB_PIN;
    // (the bead's hang: slowly out of the bulge, heavier and heavier, the last of it drawn long by its own weight)
    let long = clamp((x + 0.63) / 0.63, 0.0, 1.0);
    let L = FB_LONG * (0.17 * fw_ss(-1.15, -0.63, x) + 0.83 * long * long * long) + 1.4 * sin(t * 8.3) * fw_ss(-0.9, -0.57, x) * (1.0 - long);
    let R = Rd * (0.3 + 0.7 * fw_ss(-1.2, -0.35, x));
    if (x < 0.0) {
        let swell = fw_ss(-1.5, -0.75, x);
        return FbPool(30.0 * swell, 40.0 - 8.0 * swell, 6.0 * fw_ss(-1.6, -1.05, x), L, R, mix(0.62 * R, 0.1 * R, fw_ss(-0.75, 0.0, x)), 0.0);
    }
    // (let go: the bulge goes back up with a bounce or two and the dimple fills)
    let e = exp(-x / 0.62);
    let b = cos(x * 7.6) * e;
    return FbPool(max(30.0 * b, 0.0) + 2.2 * sin(x * 7.6 + 1.0) * e, 32.0, 6.0 * e, 0.0, 0.0, 0.12 * R * (1.0 + 2.2 * fw_ss(0.0, 0.16, x)), FB_LONG * 0.72 * exp(-x / 0.075));
}
// The drop as it hangs, its tip in the neck: fd_bead's own teardrop.
fn fb_drop_at(p0: vec2<f32>, R: f32, wob: f32) -> FdDrop {
    return FdDrop(R, 0.0, 0.0, 1.0 / sqrt(wob), wob, FD_PIV, 0.0, 0.0, p0, 0.0, 1.0);
}
// How far under the surface the drop's centre is, `x` seconds past the pinch: constant gravity, to touch the land at FD_BEAT.
fn fb_fall(x: f32, y0: f32, R: f32) -> f32 {
    let T = FD_BEAT - FB_PIN;
    let g = 2.0 * (y0 - FB_LONG - R - FB_V0 * T) / (T * T);
    return FB_LONG + FB_V0 * x + 0.5 * g * x * x;
}
fn fb_wobble(x: f32) -> f32 {
    return 1.0 + (0.2 * cos(x * 13.5) + 0.05 * cos(x * 21.0 + 1.0)) * exp(-x / 0.8);
}
fn fb_sdf(p: vec3<f32>, y0: f32, P: FbPool, d: FdDrop) -> f32 {
    let y = p.y - y0;
    let rho = length(p.xz);
    let u = rho / P.w;
    let den = 1.0 + u * u;
    let yc = -P.a / den + P.d * exp(-u * u * 0.18);
    let sl = 2.0 * P.a * u / (den * den * P.w);
    var s = (yc - y) / sqrt(1.0 + sl * sl) * 0.85;
    if (P.R > 0.0 && P.L > 0.0) {
        let b = fd_bead(p - vec3<f32>(0.0, y0 - P.L, 0.0), d);
        let ny = clamp(y, -P.L + 0.6 * P.R, -0.3 * P.a);
        let wide = P.n * (1.0 + 2.0 * fw_ss(-P.L * 0.5, -0.1 * P.a, ny));
        let neck = length(vec2<f32>(rho, y - ny)) - wide;
        s = fd_smin(s, fd_smin(b, neck, 0.5 * P.R), 2.5 + 0.34 * P.a);
    } else if (P.top > 0.5) {
        // (the neck's stump, pulled back up into the bulge)
        let ny = clamp(y, -P.top, 0.0);
        s = fd_smin(s, length(vec2<f32>(rho, y - ny)) - P.n, 4.0);
    }
    return s;
}
fn fb_normal(p: vec3<f32>, y0: f32, P: FbPool, d: FdDrop) -> vec3<f32> {
    let e = 0.25;
    let a = fb_sdf(p + vec3<f32>(e, -e, -e), y0, P, d);
    let b = fb_sdf(p + vec3<f32>(-e, -e, e), y0, P, d);
    let c = fb_sdf(p + vec3<f32>(-e, e, -e), y0, P, d);
    let f = fb_sdf(p + vec3<f32>(e, e, e), y0, P, d);
    return normalize(vec3<f32>(a - b - c + f, -a - b + c + f, -a + b - c + f));
}
fn fd_smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
// The metal's look: the droplet's chrome, the picture of the tube under it (fd_round), and a hard light off the rim of the world to catch the beads on.
fn fb_chrome(v: vec3<f32>, S: vec3<f32>, n: vec3<f32>, gq: vec3<f32>, seen: f32) -> vec3<f32> {
    var c = fd_chrome(v, S, n, gq, 0.0);
    let r = reflect(v, n);
    // (over it is the metal's own roof, not the sky)
    c = mix(c, fd_round(vec3<f32>(r.x, r.z * 0.42, r.y)) * 1.6 + vec3<f32>(0.05, 0.055, 0.06), fd_ss(-0.1, 0.2, r.y));
    // (the world in it. What a mirror overhead really shows is the floor behind the eye, which isn't on the picture: this bends its rays out to the walls round the hole, which are, and the
    // metal takes the land's own colours, bent by every lump in it)
    let side = vec3<f32>(r.x * 3.2, 0.3 + 0.5 * abs(r.y), r.z * 3.2) + 0.65 * v;
    let ro = project_rel(normalize(side) * 600.0);
    var there = seen * select(0.0, fd_ss(0.0, 0.14, min(min(ro.x, 1.0 - ro.x), min(ro.y, 1.0 - ro.y))), ro.z > 0.0);
    // (the land only: the picture still has the day's sky in the hole)
    if (there > 0.0 && is_sky(depth_at(ro.xy))) {
        there = 0.0;
    }
    if (there > 0.0) {
        let l = fd_sample(ro.xy);
        c = mix(c, l * (0.32 + 1.5 * luminance(l)) * 1.15 + c * 0.25, 0.85 * there);
    }
    let k1 = max(dot(r, normalize(vec3<f32>(0.5, -0.62, 0.3))), 0.0);
    let k2 = max(dot(r, normalize(vec3<f32>(-0.7, -0.5, -0.45))), 0.0);
    let day = 0.14 + 0.86 * fd_ss(-0.2, 0.1, frame.sun.y);
    c = c + (vec3<f32>(1.0, 0.98, 0.95) * (0.95 * pow(k1, 150.0) + 0.1 * pow(k1, 6.0)) + vec3<f32>(0.75, 0.85, 1.05) * (0.75 * pow(k2, 110.0) + 0.08 * pow(k2, 5.0))) * day;
    return c;
}
// ---- no edge to it: the metal doesn't stop at the land's end but creeps out over the land round it, in runs, thinning to a wet shine and ending in smears, the land's dark places
// (water, valleys, shadow) taking it first, so its own colours and grain show through as it goes. `q` a place on the land, `rho` how far out, the rim `rd`. Out: how far inside the metal, inside the wet.
fn fb_creep(q: vec2<f32>, rho: f32, rd: f32, t: f32, S: vec2<f32>) -> vec2<f32> {
    let th = atan2(q.y, q.x);
    let fa = 0.5 + 0.5 * sin(th * 3.0 + 1.0 + 0.8 * sin(th * 2.0 + 0.5));
    let fb = 0.5 + 0.5 * sin(th * 7.0 - 0.7 + 1.1 * sin(th * 3.0));
    let fc = 0.5 + 0.5 * sin(th * 17.0 + 2.0 + 1.3 * sin(th * 5.0));
    let runs = 0.22 + 0.6 * fa * fa + 0.5 * fb * fb * fb + 0.35 * fc * fc * fc * fc;
    let when_ = FB_MELT + 1.3 * fb_late(q / rho, S);
    let n1 = fbm(q * 0.021) - 0.5;
    let n2 = fbm(q * 0.083 + 9.0) - 0.5;
    let back = 1.0 - fw_ss(FW_LETGO + 0.12, FW_LETGO + 0.6, t);
    let out_ = rho - rd;
    let g = fw_ss(when_, when_ + 3.4, t);
    let f = 150.0 * runs * g * back - out_ + (70.0 * n1 + 34.0 * n2) * fw_ss(0.0, 0.3, g) - 40.0 * (1.0 - back) + 90.0 * fw_ss(0.05, 0.6, g) * back * (1.0 - fw_ss(0.0, 90.0, out_));
    let wet = (150.0 * runs * g + 40.0 * fw_ss(0.0, 0.3, g)) * (1.0 - fw_ss(FW_LETGO + 0.5, FW_LETGO + 1.0, t)) - out_ + 60.0 * n1;
    return vec2<f32>(f, wet);
}
fn fb_on_land(colIn: vec3<f32>, v: vec3<f32>, q: vec2<f32>, rho: f32, far: f32, rd: f32, t: f32, S: vec2<f32>, gq: vec3<f32>, g: FwBend, at: vec3<f32>) -> vec3<f32> {
    var col = colIn;
    let px = frame.view_params.w / frame.resolution.y;
    let c = fb_creep(q, rho, rd, t, S);
    if (c.y < -40.0 && c.x < -90.0) {
        return col;
    }
    let lum = luminance(col);
    let rh = q / rho;
    // ---- the wet: a shine on the land ahead of it ----------------------------------------------------------------------------
    let fl = fb_flow(q, t, px * far);
    let f = c.x + 64.0 * (0.22 - lum);
    let w = fw_ss(-40.0, 6.0, c.y + 40.0 * (0.22 - lum));
    if (w > 0.0) {
        let n = normalize(fd_returned(normalize(vec3<f32>(-fl.y * 0.6, -1.0, -fl.z * 0.6)), g, at));
        col = col * (1.0 - 0.4 * w) + fb_chrome(v, v * far, n, gq, 1.0) * 0.2 * w;
    }
    // ---- the metal, thinning to nothing: it ends in smears and thin runs. Long thin ones along the way it is going, and it keeps to the low ground (lum) ------
    let run = fbm(rh * 30.0 + vec2<f32>(rho * 0.0045, -rho * 0.0031)) - 0.5;
    let run2 = fbm(rh * 83.0 + vec2<f32>(-rho * 0.006, rho * 0.0042)) - 0.5;
    let smear = fbm(q * 0.047 + rh * 3.0 + 5.0) - 0.5;
    let f2 = f + (170.0 * run + 70.0 * run2 + 60.0 * smear) * (1.0 - fw_ss(30.0, 130.0, f)) - 16.0;
    let a = fw_ss(0.0, 26.0, f2);
    let thick = fw_ss(14.0, 90.0, f);
    let gr = fl.yz * (2.2 - 1.4 * thick) + rh * 0.6 * (1.0 - thick) * sin(f * 0.17 + 0.03 * (q.x - q.y));
    if (a > 0.0) {
        let n = normalize(fd_returned(normalize(vec3<f32>(-gr.x, -1.0, -gr.y)), g, at));
        let ch = fb_chrome(v, v * far, n, gq, 1.0);
        // (thin, it is a film on the land: the land's own colours in it)
        col = mix(col, mix(col * 0.75 + ch * (0.22 + 1.1 * col), ch, thick), a);
    }
    return col;
}
fn fb_boil(colIn: vec3<f32>, v: vec3<f32>, far: f32, t: f32, mq: vec3<f32>, gq: vec3<f32>, g: FwBend, at: vec3<f32>) -> vec3<f32> {
    var col = colIn;
    let o = fd_unturn(mq + vec3<f32>(0.0, FW_EYE, 0.0), g, at, true);
    let d = fd_unturn(v, g, at, false);
    let rim = fw_roll(g.edge, 0.0, g).xy;
    let rd = rim.x;
    let y0 = rim.y + FB_UP;
    let px = frame.view_params.w / frame.resolution.y;
    let Rd = fb_R(g.d);
    let S0 = fb_source(g);
    // ---- what has crept out on to the land ---------------------------------------------------------------------------------------
    if (far < 1.0e6) {
        let P = o + d * far;
        let rho = length(P.xz);
        if (rho > 0.7 * rd && rho < rd + 300.0 && P.y > y0 - 320.0) {
            col = fb_on_land(col, v, P.xz, rho, far, rd, t, S0, gq, g, at);
        }
    }
    // ---- the plate and the metal on it ---------------------------------------------------------------------------------------
    if (d.y > 0.05) {
        let s = (y0 - o.y) / d.y;
        let q = o.xz + d.xz * s;
        let r = length(q);
        if (s > 0.0 && s < far + 8.0 && r < rd * FB_FIT) {
            let S = S0;
            let ps = px * s;
            let th = atan2(q.y, q.x);
            // (not vnoise: its cells don't quite meet on some drivers, which on an edge this clean shows as square cuts)
            let wn0p = q * 0.0135 + vec2<f32>(4.0, 1.0);
            let wn0 = 0.3 * sin(wn0p.x + 1.4 * sin(wn0p.y * 0.9 + 1.0)) + 0.2 * sin(wn0p.y * 1.7 - 1.2 * sin(wn0p.x * 1.3 + 2.0));
            // (thick, so its edge wanders in lobes, with no fray to it)
            let wp = q * 0.041 + vec2<f32>(0.35 * t + 0.5 * fb_ramp(34.5, 36.0, t), -0.27 * t);
            let wn1 = 0.3 * sin(wp.x + 1.6 * sin(wp.y * 1.3)) + 0.2 * sin(wp.y * 1.9 - 1.3 * sin(wp.x * 1.5 + 1.0));
            let mt = fb_metal(q, t, S, rd);
            // (its edge wanders, a skin of it thin at the very edge)
            let wr = fw_ss(34.2, 35.8, t) * (1.0 - fw_ss(FB_SEAL, FB_SEAL + 0.3, t));
            var edge = -mt.d + 44.0 * wn0 + (24.0 + 30.0 * wr) * wn1;
            // (and it doesn't start as a ring: it comes up over the land's end from one side, round to the other)
            let la = fb_late(q / max(r, 1.0), S);
            edge = edge - 80.0 * (1.0 - fw_ss(FB_MELT + 1.1 * la, FB_MELT + 1.1 + 1.5 * la, t));
            var soft = max(ps, 3.0);
            // (the seethe: at the fronts and round the pockets, in a band that widens as they close. It lifts the edge itself)
            var se = vec3<f32>(0.0);
            let bu = fw_ss(33.4, 35.2, t) * (1.0 - fw_ss(FB_SEAL - 0.05, 37.5, t));
            let wide = 130.0 + 190.0 * fw_ss(34.8, 36.1, t);
            // (and it comes in knots, not evenly)
            let knot = fw_ss(-0.35, 0.75, sin(q.x * 0.0127 + 0.2 * t + 2.0 * sin(q.y * 0.0091)) + 0.7 * sin(q.y * 0.0173 - 0.15 * t + 1.0));
            let am = bu * fw_ss(-90.0, -20.0, edge) * (1.0 - fw_ss(0.5 * wide, wide, edge)) * (0.5 + 0.5 * knot);
            if (am > 0.002) {
                se = fb_seethe(q, t, am * (0.55 + 0.75 * fw_ss(34.5, 35.9, t)), edge);
                edge = edge + 2.0 * se.x * fw_ss(150.0, 40.0, edge);
            }
            if (t > FW_LETGO) {
                // (it tears: a ragged edge that wanders, runs and grain in it, thin metal first)
                let open = fb_opened(t, rd) * (1.0 + 0.055 * sin(th * 2.0 + 1.0 + 1.3 * sin(th * 3.0 - t * 2.0)) + 0.03 * sin(th * 5.0 - 0.7 + 0.9 * sin(th * 2.0 + t)));
                let rag = fbm(q * 0.031 + vec2<f32>(t * 0.6, 2.0)) - 0.5;
                let grain = fbm(q * 0.16 + 7.0) - 0.5;
                edge = min(edge, r - open + 110.0 * wn0 + 90.0 * rag + 34.0 * grain);
                soft = max(ps, 7.0);
            }
            let cov = saturate(edge / soft + 0.5);
            if (cov > 0.0) {
                let fl = fb_flow(q, t, ps);
                let m = max(edge, 0.0);
                let ex = exp(-m / FB_EDGE);
                let gr = mt.g * (-FB_THICK / FB_EDGE * ex) + fl.yz * (1.0 - 0.75 * ex) * 0.8 + fb_bubbles(q, t, S, rd) + se.yz;
                let n = normalize(fd_returned(normalize(vec3<f32>(-gr.x, -1.0, -gr.y)), g, at));
                // (the lip is too steep to see the land in: it would only be its grain)
                col = mix(col, fb_chrome(v, v * s, n, gq, 1.0 - ex), cov);
            }
        }
    }
    // ---- the bulge, the bead and its neck ----------------------------------------------------------------------------------
    if (t > FB_PIN - 1.6 && t < FB_PIN + 2.6 && d.y > 0.05) {
        let P = fb_pool(t, Rd);
        let D = fb_drop_at(vec2<f32>(0.0), P.R, mix(1.0, fb_wobble(0.0), fw_ss(FB_PIN - 0.46, FB_PIN, t)));
        let bot = -(max(P.L, P.top) + 1.5 * P.R + 4.0);
        let a = (y0 + bot - o.y) / d.y;
        let b = (y0 + 3.0 - o.y) / d.y;
        let bound = max(3.0 * P.w, 2.6 * P.R);
        let s0 = o.xz + d.xz * a;
        let s1 = o.xz + d.xz * b;
        let sd = s1 - s0;
        let cl = s0 + sd * clamp(-dot(s0, sd) / max(dot(sd, sd), 1.0e-4), 0.0, 1.0);
        if (dot(cl, cl) < bound * bound && a > 0.0) {
            var s = a;
            var best = 1.0e9;
            var sb = s;
            var hit = false;
            for (var i = 0; i < 44; i += 1) {
                let e = fb_sdf(o + d * s, y0, P, D);
                let rel = e / (px * s);
                if (rel < best) {
                    best = rel;
                    sb = s;
                }
                if (rel < 0.15) {
                    hit = true;
                    sb = s + e;
                    break;
                }
                s += max(e, 0.15 * px * s);
                if (s > b) {
                    break;
                }
            }
            let cov = saturate(1.0 - best);
            if (cov > 0.0 && sb < far) {
                let q = o + d * sb;
                let n0 = fb_normal(q, y0, P, D);
                let fl = fb_flow(q.xz, t, px * sb);
                let keep = fw_ss(-12.0, -2.0, q.y - y0);
                let n = normalize(fd_returned(normalize(n0 - vec3<f32>(fl.y, 0.0, fl.z) * 0.8 * keep), g, at));
                // (only what really hangs: the rest is the surface's, drawn above)
                col = mix(col, fb_chrome(v, v * sb, n, gq, 1.0), cov * fw_ss(-0.4, -3.5, q.y - y0));
            }
        }
    }
    // ---- the drop, let go ---------------------------------------------------------------------------------------------------
    if (t >= FB_PIN && t < FD_BEAT + 0.16) {
        let x = t - FB_PIN;
        let w = fb_wobble(x);
        // (its tip swaying a little, and a little off the plumb line on the way, on it as it lands)
        let D = fb_drop_at(vec2<f32>(sin(x * 4.3 + 0.4), cos(x * 3.1)) * 0.04 * exp(-x / 1.1), Rd, w);
        let cy = y0 - fb_fall(x, y0, Rd);
        let off_ = clamp(FD_BEAT - t, 0.0, 1.0);
        let c = vec3<f32>(1.6 * sin(x * 1.9 + 0.5) * off_, cy, 1.1 * sin(x * 1.4 + 2.1) * off_);
        let bc = c + vec3<f32>(0.0, 0.36 * Rd, 0.0) - o;
        let rb = 1.9 * Rd * max(w, 1.0 / sqrt(w));
        let bcd = dot(bc, d);
        let miss = length(bc - d * bcd);
        // (a bright point the eye can stay on, as long as it is small, and a little soft light round it all the way down)
        if (bcd > 0.0) {
            let ang = miss / bcd;
            let close = fw_ss(0.05, 0.012, Rd / bcd);
            col = col + vec3<f32>(0.92, 0.96, 1.05) * (exp(-ang / (0.0016 + 0.25 * Rd / bcd * (1.0 - close))) * 0.5 * (0.35 + 0.65 * close) + exp(-ang / 0.014) * 0.07);
        }
        if (miss < rb && bcd > 0.0) {
            var s = max(bcd - rb, 0.05);
            var best = 1.0e9;
            var sb = s;
            for (var i = 0; i < 40; i += 1) {
                let e = fd_bead(o + d * s - c, D);
                let rel = e / (px * s);
                if (rel < best) {
                    best = rel;
                    sb = s;
                }
                if (rel < 0.1) {
                    sb = s + e + fd_bead(o + d * (s + e) - c, D);
                    break;
                }
                s += max(e, 0.15 * px * s);
                if (s > bcd + rb) {
                    break;
                }
            }
            let cov = saturate(1.0 - best);
            if (cov > 0.0 && sb < far + 0.4) {
                let n = normalize(fd_returned(fd_bead_n(o + d * sb - c, D), g, at));
                col = mix(col, fb_chrome(v, v * sb, n, gq, 1.0), cov);
            }
        }
    }
    return col;
}
// ---- the hit: on the land, where it lands. A little crown of the metal thrown up and out and falling back, a ring of it running out over the land, a splash that soaks in.
const FB_SPLASH: i32 = 14;
fn fb_hit(colIn: vec3<f32>, v: vec3<f32>, far: f32, off: vec3<f32>, sky0: bool, t: f32, mq: vec3<f32>, gq: vec3<f32>, g: FwBend, at: vec3<f32>) -> vec3<f32> {
    var col = colIn;
    let a = t - FD_BEAT;
    let Rd = fb_R(g.d);
    let o = fd_unturn(mq + vec3<f32>(0.0, FW_EYE, 0.0), g, at, true);
    let d = fd_unturn(v, g, at, false);
    // ---- before it: its shadow on the land, closing up as it comes down, as the first droplet's did ------------------------------------
    if (a < 0.0) {
        if (!sky0) {
            let P = o + d * far;
            let hh = -a * (140.0 + 200.0 * -a);
            let sr = Rd * (1.5 + 0.05 * hh);
            col = col * (1.0 - exp(-dot(P.xz, P.xz) / (sr * sr)) * 0.6 * exp(-abs(P.y) / 12.0) * fd_ss(420.0, 30.0, hh));
        }
        return col;
    }
    // ---- on the land ------------------------------------------------------------------------------------------------------
    if (!sky0) {
        let P = o + d * far;
        let r = length(P.xz);
        if (abs(P.y) < 26.0 && r < 90.0) {
            let front = Rd * 0.6 + 46.0 * (1.0 - exp(-a / 0.2));
            let x = (r - front) / (1.0 + 2.4 * a);
            let fade = exp(-a / 0.3);
            col = col + vec3<f32>(0.85, 0.92, 1.05) * exp(-x * x) * fade * 0.75 * saturate(a / 0.02);
            // (the splash: chrome on the land, thrown out with the ring, soaking in by the time the metal lets go)
            let wet = Rd * (0.4 + 1.5 * (1.0 - exp(-a / 0.09))) * (1.0 + 0.12 * sin(atan2(P.z, P.x) * 5.0 + 1.0) + 0.08 * sin(atan2(P.z, P.x) * 11.0));
            let dry = wet * fw_ss(0.5, 1.0, a);
            let edge = min(wet - r, r - dry);
            let cov = saturate(edge / (0.0016 * far) + 0.5);
            if (cov > 0.0) {
                let nr = 0.5 * fw_ss(0.0, 2.0, edge) * 0.0 + 0.8 * fw_ss(2.5, 0.0, min(edge, 2.5)) * sign(wet - r - (r - dry));
                let rh = P.xz / max(r, 0.01);
                let n = normalize(fd_returned(normalize(vec3<f32>(rh.x * nr + 0.25 * sin(r * 1.6 - a * 26.0) * exp(-a / 0.25) * rh.x, 1.0, rh.y * nr + 0.25 * sin(r * 1.6 - a * 26.0) * exp(-a / 0.25) * rh.y)), g, at));
                col = mix(col, fd_chrome(v, v * far, n, gq, 0.8), cov);
            }
        }
    }
    // ---- the crown --------------------------------------------------------------------------------------------------------
    if (a < 0.95) {
        let px = frame.view_params.w / frame.resolution.y;
        let bc = -o;
        let bcd = dot(bc, d);
        if (length(bc - d * bcd) < 90.0 && bcd > 0.0) {
            for (var i = 0; i < FB_SPLASH; i += 1) {
                let h = hash21(vec2<f32>(f32(i), 3.0));
                let h2 = fract(h * 19.3);
                let an = (f32(i) + 0.8 * h) * 6.2831853 / f32(FB_SPLASH);
                let vo = 16.0 + 26.0 * h2;
                let vu = 30.0 + 34.0 * fract(h * 7.1);
                let life = a - 0.03 * h;
                if (life <= 0.0) {
                    continue;
                }
                let y = vu * life - 62.0 * life * life;
                if (y < -1.0) {
                    continue;
                }
                let c = vec3<f32>(cos(an) * (Rd * 0.5 + vo * life), y, sin(an) * (Rd * 0.5 + vo * life));
                let rb = (0.35 + 0.5 * h) * 0.2 * Rd * (1.0 - 0.3 * life);
                let oc = c - o;
                let b = dot(oc, d);
                let miss = length(oc - d * b);
                let cov = saturate((rb - miss) / (px * b) + 0.5);
                if (cov > 0.0 && b - rb < far + 1.0) {
                    let z = sqrt(max(rb * rb - miss * miss, 0.0));
                    let n = normalize(fd_returned(normalize(d * (b - z) - oc), g, at));
                    col = mix(col, fd_chrome(v, v * (b - z), n, gq, 0.8), cov);
                }
            }
        }
    }
    return col;
}
fn fd_tau(t: f32) -> f32 {
    return fw_tau(t);
}
// Where the branch's tip ends: fold_warp.wgsl's fw_seat and fw_turned with the sphere shut, the same (`the_warp_keeps_the_beats`).
fn fd_radius(d: f32, y: f32) -> f32 {
    return max(max(d * 1.3, 170.0), y * 1.15);
}
fn fd_rim(d: f32) -> f32 {
    return max(620.0, d + 480.0);
}
const FD_PI: f32 = 3.14159265;
const FD_TUBE_W: f32 = 0.5933;     // fold_warp.wgsl's: the tube as it holds
const FD_TUBE_R0: f32 = 0.352;
const FD_LEN: f32 = 480.0;
fn fd_seat(d: f32, mh: f32) -> vec3<f32> {
    let S = fd_radius(d, mh);
    let rim = fd_rim(d);
    let r0 = (max(FD_LEN, d) + 170.0) * FD_TUBE_R0;
    let rc = mix(700.0, S, FD_TUBE_W);
    let fm = mix(3.2, FD_PI, FD_TUBE_W);
    let u = d - r0;
    if (u <= 0.0) {
        return vec3<f32>(d, mh, 0.0);
    }
    let e = u / (rc * fm);
    let x = e * 1.5707963;
    let ex = exp(-e);
    let f = min(fm * mix(1.0 - ex, 0.63662 * atan(x), FD_TUBE_W), 3.3);
    let lip = 34.0 * FD_TUBE_W * pow(fd_ss(rim * 0.8, rim, d), 2.0);
    let yy = mh * mix(ex, 1.0 / (1.0 + x * x), FD_TUBE_W) - lip;
    let s = sin(f);
    let c = cos(f);
    return vec3<f32>(r0 + (rc - yy) * s, rc * (1.0 - c) + yy * c, f);
}
fn fd_turned(du: f32, dy: f32, at: vec3<f32>, d: f32, mh: f32) -> vec2<f32> {
    let c = cos(at.z);
    let s = sin(at.z);
    return vec2<f32>(d + du * c + dy * s, -du * s + dy * c + mh);
}

@fragment
fn fs_main(in: StageIn) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let t = now();
    let cam = frame.camera_position.xyz;
    let tgt = target_pos();
    let res = frame.resolution.xy;
    let aspect = res.x / res.y;
    let me = frame.mod_params[3].xyz;
    let dist = length(me.xz - tgt.xz);
    let gq = (tgt - cam) - camera_rest();
    let d0 = depth_at(uv);
    let sky0 = is_sky(d0);
    let off = world_offset(uv, select(d0, 0.5, sky0));
    let v = normalize(off);
    let far = select(length(off), 1.0e7, sky0);

    // ---- where the branch's tip has gone at the touch: on the far side of the sphere's floor, the frame the sphere is in going
    // with the player. The eye never moves in that frame: it is where it stood as they fired, whatever they have done since -------
    let mh = me.y - tgt.y;
    let te = (me.xz - tgt.xz) / max(dist, 0.001);
    let at = fd_seat(dist, mh);
    let tip = fd_turned(-at.x, -at.y, at, dist, mh);
    let pt = project_rel(tgt - me + vec3<f32>(te.x * tip.x, tip.y - 1.62, te.y * tip.x));

    var col = fd_sample(uv);

    // ---- the void: the sky going out as the land closes, and under the land where it has left ------------------------------
    if (sky0 && t > FD_FOLD - 0.5) {
        let tau = fd_tau(t);
        let dark = fd_ss(FD_FOLD + 3.0, 30.0, tau);
        let under = fd_ss(0.03, -0.015, v.y) * fd_ss(FD_FOLD, FD_FOLD + 1.2, t) * (1.0 - fd_ss(FD_SLAM4, FD_SLAM4 + 0.2, t));
        col = mix(col, fd_stars(v), max(dark, under));
        // ---- land that isn't there. Far land not loaded leaves gaps in what the sheet carries, which would show the void: the stars belong to the
        // tears and the hole in the roof. A gap the land closes round takes the land's colours round it, but for the hole: a ray that comes near
        // the axis, on which the hole's mouth lies however far down it has come ------------------------------------------------------------
        if (t < FD_SLAM4) {
            var near = vec3<f32>(0.0);
            var found = 0.0;
            let step = res.y / 1440.0;
            for (var i = 0; i < 8; i += 1) {
                let ang = f32(i) * 0.7853982 + 0.3;
                let dir = vec2<f32>(cos(ang), sin(ang)) * step / res;
                for (var j = 0; j < 3; j += 1) {
                    let uv2 = uv + dir * (22.0 + 44.0 * f32(j * (j + 1)));
                    if (!is_sky(depth_at(uv2))) {
                        near += fd_sample(uv2);
                        found += 1.0;
                        break;
                    }
                }
            }
            // (the axis, turned as the land is: how near this ray comes to it. Filled, a hole under the rays' reach grew an averaged star)
            let ax0 = tgt - me + vec3<f32>(te.x * tip.x, tip.y - 1.62, te.y * tip.x);
            let u1 = fd_turned(-at.x, 1000.0 - at.y, at, dist, mh);
            let ax = normalize(vec3<f32>(te.x * (u1.x - tip.x), u1.y - tip.y, te.y * (u1.x - tip.x)));
            let cr = cross(v, ax);
            let miss = abs(dot(ax0, cr)) / max(length(cr), 0.001);
            let hole = fd_ss(27.0, 29.0, tau) * fd_ss(1100.0, 800.0, miss);
            if (found > 5.5) {
                col = mix(col, near / found, fd_ss(5.5, 7.5, found) * (1.0 - hole));
            }
        }
    }

    // ---- the droplet, and its smoke for as long as that lasts ---------------------------------------------------------------
    if (t < FD_GONE) {
        let side = normalize(vec2<f32>(-gq.z, gq.x) + vec2<f32>(0.0, 1.0e-4));
        let d = fd_drop(t, dist, side);
        let li = fd_light();
        let jit = ign(in.position.xy);
        var land = vec4<f32>(0.0);
        if (!sky0) {
            let P = off - gq;
            land = vec4<f32>(clamp(P.y, -40.0, 40.0), 0.0, P.xz);
            // (its shadow on the land, closing up as it comes down)
            let sr = d.R * (1.6 + 0.06 * d.h);
            let shadow = exp(-dot(P.xz, P.xz) / (sr * sr)) * 0.62 * exp(-abs(P.y) / 12.0) * fd_ss(420.0, 60.0, d.h) * (1.0 - fd_ss(FD_TOUCH, FD_MELD, t));
            col = col * (1.0 - shadow);
            // (the fire's light on the land under it, coming up as it does, and going out with the air that hits the land)
            let lr = d.h * 0.8 + 6.0;
            let fl = fd_ss(FD_STOP - 0.7, FD_STOP, t) * exp(-max(t - FD_STOP, 0.0) / 0.16) / (1.0 + dot(P.xz, P.xz) / (lr * lr));
            col = col + col * vec3<f32>(2.6, 1.15, 0.4) * fl * (14.0 / (lr + 20.0)) * exp(-max(abs(P.y) - 6.0, 0.0) / 16.0);
        }
        // (to the player's side: the same side whatever they do)
        let way = vec2<f32>(-te.y, te.x);
        let H = fd_arc(d.h - d.stop_h);
        let C = gq + vec3<f32>(way.x * H, d.h, way.y * H);
        // (what the land has reached up inside the drop is taken into it, not seen through it)
        // (until the land has closed over it: a pixel of land in it melts from drop to land as that happens, and has little of the
        // join's light, or the drop's own pixels burn white)
        let swallowed = t >= FD_TOUCH + FD_MEET && t < FD_MELD && !sky0 && fd_bead(off - C, d) < 0.0;
        let under = col;
        col = fd_droplet(under, t, v, gq, C, d, way, far, uv, aspect, land, li, jit);
        var lit = select(0.0, 1.0, !sky0);
        if (swallowed) {
            let closing = fd_ss(FD_MELD - 0.16, FD_MELD, t);
            col = mix(fd_droplet(under, t, v, gq, C, d, way, 1.0e7, uv, aspect, land, li, jit), col, closing);
            lit = mix(0.12, 1.0, closing * closing * closing);
        }
        col = fd_glow(col, t, v, gq, off - gq, lit, far, d);
    }

    // ---- the boil, and what falls from it ---------------------------------------------------------------------------------------
    if (t > FB_MELT && t < FW_LETGO + 1.0) {
        let tau = fd_tau(t);
        let mq = me - tgt;
        let e2 = select(vec2<f32>(1.0, 0.0), mq.xz / max(dist, 0.001), dist > 0.5);
        let g = fw_bend(tau, t, FW_LEN, mq, e2, max(FW_END_K * clamp(frame.view_params.z, 480.0, 20000.0) - dist, 300.0), 0.0);
        let at_ = fw_roll(g.d, g.pin, g);
        col = fb_boil(col, v, far, t, mq, gq, g, at_);
        if (t > 39.2) {
            col = fb_hit(col, v, far, off, sky0, t, mq, gq, g, at_);
        }
    }
    // ---- the touch: a tiny light at the point the moment the tip reaches it, there while it holds, gone as it lets go -----
    let dd = length((uv - pt.xy) * vec2<f32>(aspect, 1.0));
    if (t >= FD_BEAT && t < FD_REL + 0.6 && pt.z > 0.0) {
        let on = fd_ss(FD_BEAT, FD_BEAT + 0.04, t) * (1.0 - fd_ss(FD_REL + 0.42, FD_REL + 0.6, t));
        let g = 0.0022;
        col = col + vec3<f32>(1.0, 0.97, 0.92) * (exp(-dd / g) * 2.6 + exp(-dd / (g * 6.0)) * 0.3) * on;
    }

    // ---- the slams: a ring of dust running out from each ring as it lands ---------------------------------------------------
    if (!sky0 && t > FD_SLAM0 && t < FD_SLAM4 + 3.0) {
        let P = off + (cam + camera_rest() - tgt);
        let dpix = length(P.xz);
        for (var i = 0; i < 5; i += 1) {
            let age = t - fd_slam(i);
            if (age > 0.0 && age < 3.0) {
                let front = fd_ring(i) * 0.9 + 140.0 * pow(age, 0.6);
                let w = 16.0 + 26.0 * age;
                let x = (dpix - front) / w;
                let n = fd_ss(0.42, 0.8, fbm(P.xz * 0.035 + vec2<f32>(age * 0.5, -age * 0.3)));
                let a = exp(-x * x) * pow(1.0 - age / 3.0, 2.0) * n * 0.55;
                col = mix(col, vec3<f32>(0.2, 0.18, 0.16), clamp(a, 0.0, 0.7));
            }
        }
    }
    // ---- the dust the last slam drove out of the ground -------------------------------------------------------------------
    let fdb_a = t - FD_ERUPT;
    if (fdb_a > 0.0 && fdb_a < FDB_LEN) {
        col = fd_erupt(col, -gq, v, far, fdb_a, hash21(uv * res), uv);
        col = fd_blast(col, -gq, v, far, fdb_a, hash21(uv * res));
    }
    return vec4<f32>(linear_to_srgb(max(col, vec3<f32>(0.0))), 1.0);
}
