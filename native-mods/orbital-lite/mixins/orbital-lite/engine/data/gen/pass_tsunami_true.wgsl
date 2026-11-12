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

// Orbital Laser's post pass for the Tsunami (laser 14). Like the Hurricane's, the mod builds it from shaders/strike.wgsl
// up to its fs_main (the helpers: the noise, hash, pcg) less the other lasers' own functions, followed by this file, and
// sets it for a tsunami strike only. Validate with tools/check-shader.sh.

// ---- laser 14: the tsunami ----------------------------------------------------------------------------------------
// No beam. A wave of dark, debris-laden water 130 blocks high and nearly three kilometres wide rises on the horizon and
// crosses the land at about 100 blocks a second: everything in its way is swept up in its foam, it towers over the
// player and washes over them, then drains away leaving mud and wreckage.
// The whole wave is closed-form, a function of where (s, u: along its way and across it) and when, so nothing is kept
// from frame to frame and a strike started part way in lands where it should: the front reaches a point at `ts_arr`,
// the water there rises over `ts_rise`, holds, then drains. strike/tsunami.rs keeps the TS_* and these functions in
// step (the model: the arrival, the envelope, the profile) and hands the pass its table (render.set-data).
const TS_LEN: f32 = 42.0;       // the strike's length (lasers.rs)
const TS_T: f32 = 9.0;          // when the front crosses the target
const TS_V0: f32 = 100.0;       // its speed there, blocks a second, slowing past it
const TS_C: f32 = 1.07e-5;      // (time to s: s / V0 + C s^2)
const TS_SEA: f32 = 100.0;      // the level the wave rises from, under the target's ground
const TS_A: f32 = 420.0;        // how far over that it stands at full strength, far out: 320 over the target's ground
const TS_FACE: f32 = 105.0;     // the face's width, blocks
const TS_HOLD: f32 = 6.5;       // seconds the water holds at its height, then
const TS_DRAIN: f32 = 14.0;     // drains away over
const TS_LOW: f32 = 0.15;       // how far the water behind the crest sits under it (a share)

fn ts_sq(x: f32) -> f32 { return x * x; }

struct TsG {
    m: vec2<f32>,      // the way it moves (towards the player), on the ground
    n: vec2<f32>,      // across it
    dp: f32,           // how far the player stood from the target as it fired
    send: f32,         // how far past the target it runs before it is spent
    sd: f32,           // the strike's seed
}
fn ts_geo() -> TsG {
    var g: TsG;
    let a = wing_a();
    g.m = vec2<f32>(cos(a), sin(a));
    g.n = vec2<f32>(-g.m.y, g.m.x);
    let me = vec2<f32>(frame.mod_params[3].x, frame.mod_params[3].z) - anchor_xz();
    g.dp = length(me);
    g.send = min(g.dp + 160.0, 720.0);
    g.sd = fract(seed_v() * 0.6180339) * 40.0;
    return g;
}
// How long the front takes to reach distance s past the target.
fn ts_tau(s: f32) -> f32 {
    let sp = max(s, 0.0);
    return s / TS_V0 + TS_C * sp * sp;
}
// The front's speed at s, blocks a second.
fn ts_vel(s: f32) -> f32 {
    return 1.0 / (1.0 / TS_V0 + 2.0 * TS_C * max(s, 0.0));
}
// Where the middle of the front is at `t` (the inverse of ts_tau).
fn ts_front(t: f32) -> f32 {
    let tt = t - TS_T;
    if (tt < 0.0) {
        return tt * TS_V0;
    }
    let b = 1.0 / TS_V0;
    return (-b + sqrt(b * b + 4.0 * TS_C * tt)) / (2.0 * TS_C);
}
// The front's lead or lag along its length (seconds): bowed back at its flanks, in lobes that run ahead along some
// stretches of it. (Sines, not noise: this is asked for hundreds of times a pixel.)
fn ts_lag(s: f32, u: f32, sd: f32) -> f32 {
    let c = 3.0e-7 * u * u;
    return c + (0.34 * sin(u * 0.0043 + sd + s * 0.0011) + 0.13 * sin(u * 0.0127 + sd * 1.7 - s * 0.0023) + 0.05 * sin(u * 0.0331 + sd * 0.6 + s * 0.0041)) * smoothstep(-650.0, -150.0, s);
}
fn ts_arr(s: f32, u: f32, sd: f32) -> f32 {
    return TS_T + ts_tau(s) + ts_lag(s, u, sd);
}
// How far the wave has stood up out of the sea at (s, u), 0 to 1: over its first four seconds, a swell first, the wall
// building on it, not all at once along its length (stretches of it get up ahead of the rest).
fn ts_rise(s: f32, u: f32, sd: f32) -> f32 {
    if (s > -380.0) {
        return 1.0;
    }
    return smoothstep(-950.0, -600.0, s + 20.0 * sin(u * 0.0031 + sd * 2.1) + 12.0 * sin(u * 0.0083 + sd * 0.7));
}
// How strong the wave is where (s, u): stood up out of the sea in the first second and a bit (the horizon rising), at its
// tallest far out, losing height as it breaks and runs in over the land, spent at its end, weaker towards its flanks, its
// crest uneven along the front. 1 at full strength.
fn ts_env(s: f32, u: f32, g: TsG) -> f32 {
    let up = 0.22 + 0.78 * ts_rise(s, u, g.sd);
    let dec = 1.0 - 0.345 * smoothstep(-640.0, -40.0, s);
    let run = 1.0 - 0.13 * smoothstep(0.0, g.send, s);
    let end = 1.0 - smoothstep(g.send - 80.0, g.send + 30.0, s);
    let lat = 1.0 - smoothstep(1900.0, 3300.0, abs(u));
    let lump = 1.0 + 0.028 * sin(u * 0.0063 + g.sd * 1.7 + s * 0.0016) + 0.024 * sin(u * 0.0171 + g.sd * 0.9 - s * 0.0031) + 0.016 * sin(u * 0.0419 + g.sd * 2.3 + s * 0.0047);
    return up * dec * run * end * lat * lump;
}
// Where along the crest it is breaking at (s, u), 0 a smooth dark shoulder, 1 its lip thrown out and avalanching down the
// face: stretches a few hundred blocks long that move along the crest as it comes. Only the pass has this.
fn ts_break(s: f32, u: f32, sd: f32) -> f32 {
    return smoothstep(-0.25, 0.7, sin(u * 0.0094 + sd + s * 0.0037) + 0.6 * sin(u * 0.0231 - s * 0.0083 + sd * 3.1) + 0.3 * sin(u * 0.0577 + s * 0.011 + sd * 1.3));
}
// How far it has drained at `s` at `t`, 0 to 1. All the land's water goes together, not in the order it came: it starts when
// the player's has held long enough, the seaward side a little first, so the whole sheet tilts away and runs back.
fn ts_t0(s: f32, g: TsG) -> f32 {
    return TS_T + ts_tau(g.dp) + TS_FACE / ts_vel(g.dp) + TS_HOLD + 0.0016 * (s - g.dp);
}
fn ts_x(t: f32, s: f32, g: TsG) -> f32 {
    return clamp((t - ts_t0(s, g)) / TS_DRAIN, 0.0, 1.0);
}
// The water's height over its sea (0 to 1) `tau` seconds after the front reached a point whose front is `s` out: up the
// concave face to its crest, down behind it to where it holds.
fn ts_prof(tau: f32, s: f32) -> f32 {
    if (tau <= 0.0) {
        return 0.0;
    }
    let tr = TS_FACE / ts_vel(s);
    let rr = clamp(tau / tr, 0.0, 1.0);
    return pow(rr, 1.7) * (1.0 - TS_LOW * smoothstep(tr, tr * 3.0, tau));
}
// The level `lv` (over the target's ground) as it drains, `x`: down hard at first, slowing as it nears the land (hilltops
// out first, the plains under a few blocks of running water for a while, the hollows last).
fn ts_fall(lv: f32, x: f32) -> f32 {
    if (x <= 0.0) {
        return lv;
    }
    let e = smoothstep(0.0, 0.42, x);
    return mix(lv, 12.0 - 118.0 * x * x, e);
}
// How long the land holds back the foot of the wave at (s, u), seconds, `gy` the land's height there: it climbs slowly on high
// ground and runs on up the low ground, so its foot wraps the hills and tongues up the valleys. Only its foot: the wave over
// it comes on regardless. Little enough that the land's edits, which go by the front's plain arrival, stay under water, and
// none round the player, whose engulfing the sounds and the carry have to the moment.
fn ts_toe_e(s: f32, u: f32, g: TsG) -> f32 {
    if (s < -320.0 || s > 700.0 || abs(u) > 345.0) {
        return 0.0;
    }
    return smoothstep(-320.0, -230.0, s) * (1.0 - smoothstep(610.0, 700.0, s)) * (1.0 - smoothstep(270.0, 345.0, abs(u))) * smoothstep(45.0, 150.0, length(vec2<f32>(s - g.dp, u)));
}
fn ts_toe(s: f32, u: f32, gy: f32, g: TsG) -> f32 {
    return clamp(gy * 0.012, -0.55, 0.42) * ts_toe_e(s, u, g);
}

// Where the camera is, for what it must not be shaken by.
var<private> ts_cam: vec3<f32>;

// The water's surface function at a point (relative to the target's ground): negative inside the water, positive in the
// air above it, and a big number where there is none. The crest leans out over the face, more where it is breaking.
fn ts_f(pa: vec3<f32>, t: f32, g: TsG) -> f32 {
    let s = dot(pa.xz, g.m);
    let u = dot(pa.xz, g.n);
    let env = ts_env(s, u, g);
    if (env < 0.03) {
        return 1.0e4;
    }
    let a = TS_A * env;
    let yb = clamp((pa.y + TS_SEA) / a, 0.0, 1.0);
    let y2 = yb * yb;
    // (a straight line out at sea; it starts to tear and pitch forward as it comes in)
    let inb = smoothstep(-560.0, -160.0, s);
    let lean = (0.1 + 0.34 * ts_break(s, u, g.sd) * inb) * y2 * y2 * yb;
    var tau = t - ts_arr(s, u, g.sd) + lean;
    // (its foot held back by the high ground, let run by the low)
    if (tau > -0.7 && tau < 2.4 && pa.y < 170.0) {
        let e = ts_toe_e(s, u, g);
        if (e > 0.0) {
            let gy = ts_ground(s, u);
            let k = 1.0 - smoothstep(gy + 6.0, gy + 75.0, pa.y);
            tau = tau - clamp(gy * 0.012, -0.55, 0.42) * e * k;
        }
    }
    let p = ts_prof(tau, s);
    let x = ts_x(t, s, g);
    if (p <= 0.0 || x >= 1.0) {
        return 1.0e4;
    }
    // (the crest torn along its length)
    let tear = (fvnoise(vec2<f32>(u * 0.052 + g.sd, t * 0.9 + s * 0.01)) - 0.5) * (5.0 + 11.0 * inb) * smoothstep(0.8, 1.0, yb);
    var lv = ts_fall(a * p - TS_SEA + tear, x);
    // (the torrent is lumps of water, not a level sheet: out of the way of the camera, which rides it)
    if (x > 0.03 && x < 0.97) {
        let k = smoothstep(0.03, 0.2, x) * (1.0 - smoothstep(0.7, 0.95, x)) * smoothstep(10.0, 55.0, length(pa.xz - ts_cam.xz));
        if (k > 0.0) {
            let r = s + t * 30.0;
            lv = lv + k * (0.85 * sin(r * 0.17 + u * 0.06) * sin(u * 0.11 - r * 0.04 + 1.3) + 0.45 * sin(r * 0.37 - u * 0.21 + 2.1) * sin(u * 0.29 + r * 0.13));
        }
    }
    return pa.y - lv;
}

struct TsHit {
    t: f32,
    hit: bool,
}
// The first place the ray (from `ro`, relative to the target's ground) is in the water, between t0 and t1: marched down
// the way to the front's reach, with steps of a seventh of the way to the surface, then bisected.
fn ts_march(ro: vec3<f32>, rd: vec3<f32>, t0: f32, t1: f32, time: f32, g: TsG, j: f32) -> TsHit {
    var h: TsHit;
    h.hit = false;
    h.t = t1;
    let s0 = dot(ro.xz, g.m);
    let rs = dot(rd.xz, g.m);
    // (the wave lies behind its front, a little ahead of it where a lobe runs on: a ray that starts ahead of that and
    // heads away from it never meets it)
    let sf = ts_front(time) + 240.0;
    var tin = t0;
    if (s0 > sf) {
        if (rs >= -1.0e-4) {
            return h;
        }
        tin = max(tin, (s0 - sf) / -rs);
    }
    let ytop = TS_A * 1.12 - TS_SEA + 30.0;
    if (ro.y > ytop) {
        if (rd.y >= -1.0e-4) {
            return h;
        }
        tin = max(tin, (ro.y - ytop) / -rd.y);
    }
    var t = tin + j * 2.0;
    var tp = tin;
    for (var i = 0; i < 90; i = i + 1) {
        if (t > t1) {
            break;
        }
        let f = ts_f(ro + rd * t, time, g);
        if (f < 0.0) {
            // (bisected between the last step and this one)
            var a = tp;
            var b = t;
            for (var k = 0; k < 7; k = k + 1) {
                let mid = 0.5 * (a + b);
                if (ts_f(ro + rd * mid, time, g) < 0.0) {
                    b = mid;
                } else {
                    a = mid;
                }
            }
            h.t = b;
            h.hit = true;
            return h;
        }
        tp = t;
        // (over the water behind the front the surface is nearly level, and a ray going over it can stride)
        let far_back = dot((ro + rd * t).xz, g.m) < sf - 480.0;
        t = t + clamp(f * select(0.14, 0.7, far_back), 0.7 + t * 0.0012, 60.0);
    }
    return h;
}
fn ts_normal(p: vec3<f32>, t: f32, g: TsG) -> vec3<f32> {
    let e = 1.5;
    let k = vec2<f32>(1.0, -1.0);
    return normalize(k.xyy * ts_f(p + k.xyy * e, t, g) + k.yyx * ts_f(p + k.yyx * e, t, g) + k.yxy * ts_f(p + k.yxy * e, t, g) + k.xxx * ts_f(p + k.xxx * e, t, g) + vec3<f32>(1.0e-5));
}

fn ts_vn3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(fh31(i), fh31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(fh31(i + vec3<f32>(0.0, 1.0, 0.0)), fh31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(fh31(i + vec3<f32>(0.0, 0.0, 1.0)), fh31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(fh31(i + vec3<f32>(0.0, 1.0, 1.0)), fh31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}
fn ts_fbm3(p: vec3<f32>, oct: i32) -> f32 {
    var a = 0.5;
    var q = p;
    var s = 0.0;
    var n = 0.0;
    for (var i = 0; i < oct; i = i + 1) {
        s = s + a * ts_vn3(q);
        n = n + a;
        a = a * 0.5;
        // (turned a little between octaves so no octave's grid lines up with the last's)
        q = vec3<f32>(q.x * 0.8 - q.z * 0.6, q.y, q.x * 0.6 + q.z * 0.8) * 2.07 + vec3<f32>(5.1, 1.3, 7.7);
    }
    return s / n;
}

// What the light is: matched to the scene's, as the Hurricane's.
struct TsLight {
    L: vec3<f32>,
    amb: vec3<f32>,
    sunc: vec3<f32>,
    skyl: vec3<f32>,
    fogl: vec3<f32>,
    day: f32,
    // (a floor under the night's light, so the water and its foam still read by the moon)
    nightw: vec3<f32>,
}


// The water's surface over (s, u) at `t`, relative to the target's ground (a big negative number where there is none).
fn ts_surf_y(s: f32, u: f32, t: f32, g: TsG) -> f32 {
    var hold = 0.0;
    if (ts_toe_e(s, u, g) > 0.0) {
        hold = ts_toe(s, u, ts_ground(s, u), g);
    }
    return ts_surf_h(s, u, t + -hold, t, g);
}
// (`ta` the moment for the front, `t` for the drain: the plain surface, not held back by the land, is `ta` = `t`)
fn ts_surf_h(s: f32, u: f32, ta: f32, t: f32, g: TsG) -> f32 {
    let env = ts_env(s, u, g);
    if (env < 0.03) {
        return -1.0e4;
    }
    let tau = ta - ts_arr(s, u, g.sd);
    let p = ts_prof(tau, s);
    let x = ts_x(t, s, g);
    if (p <= 0.0 || x >= 1.0) {
        return -1.0e4;
    }
    return ts_fall(TS_A * env * p - TS_SEA, x);
}

// ---- the debris: the land the wave swept up, in the game's own block textures ---------------------------------------
// Logs, planks, cobblestone, wool, hay, leaves, soil: tumbling pieces riding the face and the foam, and past the camera
// under the water. What kinds follow the land it is over (a map in the table: the share of each 16 by 16 cell with trees
// and with buildings), so a wood throws up logs and leaves, a village planks, stone and glass. Each is a box, a block or a
// few (a log four long), turning; each cell of a grid in the wave's own frame holds at most one.
@group(0) @binding(8) var block_sprites: texture_2d_array<f32>;
@group(0) @binding(9) var block_sampler: sampler;
const TSB: u32 = 64u;           // the block types' words (tsunami.rs's TS_KINDS, TSBW words each)
const TSBW: u32 = 12u;
const TSM: u32 = 384u;          // the map of what the land has on it
const TSM_S: u32 = 64u;
const TSM_U: u32 = 44u;

fn ts_ud(i: u32) -> u32 {
    if (i >= arrayLength(&mod_data)) {
        return 0u;
    }
    return mod_data[i];
}
fn ts_have() -> bool {
    return arrayLength(&mod_data) > TSM + TSM_S * TSM_U;
}
fn ts_565(c: u32) -> vec3<f32> {
    return srgb_to_linear(vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0));
}
fn ts_lod(t: f32) -> f32 {
    let px = 2.0 * tan(0.5 * frame.view_params.w) * frame.resolution.w;
    return log2(max(t * px * 16.0, 1.0e-4));
}
fn ts_face_st(m: u32, uv: vec2<f32>) -> vec2<f32> {
    let q = vec3<f32>(vec3<u32>(m, m >> 2u, m >> 4u) & vec3<u32>(3u)) - 1.0;
    let r = vec3<f32>(vec3<u32>(m >> 6u, m >> 8u, m >> 10u) & vec3<u32>(3u)) - 1.0;
    return fract(vec2<f32>(q.x + uv.x * q.z + uv.y * r.y, q.y + uv.x * r.x + uv.y * r.z) * 0.99999 + 0.000005);
}
fn ts_tint(c: u32) -> vec3<f32> {
    if (c == 0xFFFFu) {
        return vec3<f32>(1.0);
    }
    return vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0);
}
// The colour of block type `bk`'s face `face` (0 top, 1 bottom, 2 a side) at `uv` on it, linear: the game's own texture where
// the table has it (its overlay laid over it), else its average.
fn ts_face(bk: u32, face: u32, uv: vec2<f32>, lod: f32) -> vec3<f32> {
    let o = TSB + bk * TSBW;
    let a = ts_ud(o);
    let b = ts_ud(o + 1u);
    let avg = ts_565(select(select(a >> 16u, b & 0xFFFFu, face == 1u), a & 0xFFFFu, face == 0u));
    let f0 = ts_ud(o + 2u + 3u * face);
    if ((f0 & 1u) == 0u || lod > 3.5) {
        return avg;
    }
    let st = ts_face_st(ts_ud(o + 4u + 3u * face), uv);
    let lv = clamp(lod, 0.0, f32(textureNumLevels(block_sprites) - 1));
    let c0 = textureSampleLevel(block_sprites, block_sampler, st, i32((f0 >> 2u) & 0x1FFFu), lv);
    var rgb = srgb_to_linear(c0.rgb * ts_tint(f0 >> 16u));
    if ((f0 & 2u) != 0u && c0.a < 0.5) {
        rgb = avg * 0.3;
    }
    let f1 = ts_ud(o + 3u + 3u * face);
    if ((f1 & 1u) != 0u) {
        let c1 = textureSampleLevel(block_sprites, block_sampler, st, i32((f1 >> 2u) & 0x1FFFu), lv);
        rgb = mix(rgb, srgb_to_linear(c1.rgb * ts_tint(f1 >> 16u)), c1.a);
    }
    return rgb;
}
// What the land holds under the wave at (s, u): the share of trees (x) and of buildings (y).
fn ts_map(s: f32, u: f32) -> vec2<f32> {
    if (!ts_have()) {
        return vec2<f32>(0.5, 0.12);
    }
    let i = i32(floor((s + 320.0) / 16.0));
    let j = i32(floor((u + 352.0) / 16.0));
    if (i < 0 || j < 0 || i >= 64 || j >= 44) {
        return vec2<f32>(0.25, 0.0);
    }
    let w = ts_ud(TSM + u32(j) * TSM_S + u32(i));
    return vec2<f32>(f32(w & 255u), f32((w >> 8u) & 255u)) / 255.0;
}
// The land's height over the target's ground at (s, u), from the same map (bilinear), 0 where it hasn't been read.
fn ts_gcell(i: i32, j: i32) -> f32 {
    if (i < 0 || j < 0 || i >= 64 || j >= 44) {
        return 0.0;
    }
    // (ts_ground has seen the table is there, and i, j are on it: this runs hundreds of times a pixel at the foot)
    let w = mod_data[TSM + u32(j) * TSM_S + u32(i)] >> 16u;
    return select(f32(w) - 2048.0, 0.0, w == 0u);
}
fn ts_ground(s: f32, u: f32) -> f32 {
    if (!ts_have()) {
        return 0.0;
    }
    let x = (s + 320.0) / 16.0 - 0.5;
    let y = (u + 352.0) / 16.0 - 0.5;
    let i = i32(floor(x));
    let j = i32(floor(y));
    let f = vec2<f32>(x - floor(x), y - floor(y));
    return mix(mix(ts_gcell(i, j), ts_gcell(i + 1, j), f.x), mix(ts_gcell(i, j + 1), ts_gcell(i + 1, j + 1), f.x), f.y);
}
// A kind (TS_KINDS' order) for a roll `r` (0 to 1) and a second `r2`, by the land's trees `tr` and buildings `bd`.
fn ts_kind(r: f32, r2: f32, tr: f32, bd: f32) -> u32 {
    let wl = 3.0 * tr + 0.25;
    let wp = 2.6 * bd + 0.12;
    let ws = 2.2 * bd + 0.05;
    let wo = 1.4 * bd;
    let wf = 3.5 * tr + 0.1;
    let wd = 1.7;
    var x = r * (wl + wp + ws + wo + wf + wd);
    if (x < wl) {
        return u32(r2 * 4.0) % 4u;
    }
    x = x - wl;
    if (x < wp) {
        return select(select(4u, 5u, r2 > 0.4), 22u, r2 > 0.85);
    }
    x = x - wp;
    if (x < ws) {
        return select(select(6u, 7u, r2 > 0.35), select(8u, 18u, r2 > 0.9), r2 > 0.65);
    }
    x = x - ws;
    if (x < wo) {
        return 9u + u32(r2 * 6.0) % 6u;
    }
    x = x - wo;
    if (x < wf) {
        return 12u + u32(r2 * 2.0) % 2u;
    }
    return select(select(14u, 15u, r2 > 0.3), select(16u, 17u, r2 > 0.8), r2 > 0.55);
}
fn ts_rodrigues(ax: vec3<f32>, a: f32) -> mat3x3<f32> {
    let c = cos(a);
    let s = sin(a);
    let k = 1.0 - c;
    return mat3x3<f32>(
        vec3<f32>(c + ax.x * ax.x * k, ax.y * ax.x * k + ax.z * s, ax.z * ax.x * k - ax.y * s),
        vec3<f32>(ax.x * ax.y * k - ax.z * s, c + ax.y * ax.y * k, ax.z * ax.y * k + ax.x * s),
        vec3<f32>(ax.x * ax.z * k + ax.y * s, ax.y * ax.z * k - ax.x * s, c + ax.z * ax.z * k));
}
struct TsPieceHit {
    t: f32,
    rgb: vec3<f32>,
    hit: bool,
    // (its albedo and its face's normal, for the water's own light on what is under it)
    alb: vec3<f32>,
    nw: vec3<f32>,
}
// The ray against one piece: a box of half-sizes `h` at `c`, turned by `m`, a block type `kind`, lit by the pass's light.
fn ts_piece_hit(ro: vec3<f32>, rd: vec3<f32>, c: vec3<f32>, h: vec3<f32>, m: mat3x3<f32>, kind: u32, li: TsLight, wet: f32) -> TsPieceHit {
    var out: TsPieceHit;
    out.hit = false;
    let mt = transpose(m);
    let o = mt * (ro - c);
    let d = mt * rd;
    let inv = 1.0 / (d + vec3<f32>(select(1.0e-6, -1.0e-6, d.x < 0.0), select(1.0e-6, -1.0e-6, d.y < 0.0), select(1.0e-6, -1.0e-6, d.z < 0.0)));
    let t1 = (-h - o) * inv;
    let t2 = (h - o) * inv;
    let tn = min(t1, t2);
    let tf = max(t1, t2);
    let tnear = max(max(tn.x, tn.y), tn.z);
    let tfar = min(min(tf.x, tf.y), tf.z);
    if (tnear >= tfar || tfar <= 0.0 || tnear <= 0.0) {
        return out;
    }
    let p = o + d * tnear;
    // (which face: the axis it entered through)
    var nl = vec3<f32>(0.0);
    var uv = vec2<f32>(0.0);
    var face = 2u;
    // (a log's grain runs its length: its long axis, local z, is a log block's up, so the end grain goes on its two ends
    // and the bark, running along it, on its four long sides, block after block)
    if (kind < 4u) {
        if (tnear == tn.z) {
            nl.z = -sign(d.z);
            uv = fract(p.xy + h.xy);
            face = select(1u, 0u, nl.z > 0.0);
        } else if (tnear == tn.x) {
            nl.x = -sign(d.x);
            uv = fract(vec2<f32>(p.y + h.y, 1.0 - (p.z + h.z)));
        } else {
            nl.y = -sign(d.y);
            uv = fract(vec2<f32>(p.x + h.x, 1.0 - (p.z + h.z)));
        }
    } else if (tnear == tn.y) {
        nl.y = -sign(d.y);
        uv = fract(p.xz + h.xz);
        face = select(1u, 0u, nl.y > 0.0);
    } else if (tnear == tn.x) {
        nl.x = -sign(d.x);
        uv = fract(vec2<f32>(p.z + h.z, 1.0 - (p.y + h.y)));
    } else {
        nl.z = -sign(d.z);
        uv = fract(vec2<f32>(p.x + h.x, 1.0 - (p.y + h.y)));
    }
    let nw = m * nl;
    let alb = ts_face(kind, face, uv, ts_lod(tnear));
    let dif = saturate(dot(nw, li.L));
    // (wet through and coated in what it came through: wet wood and wool go dark, and however pale a thing was it is the
    // colour of the water it is in, in patches along it)
    let mud = smoothstep(0.32, 0.62, ts_vn3((p + vec3<f32>(f32(kind) * 3.1, 0.0, 0.0)) * vec3<f32>(0.9, 0.9, 0.45)));
    let wetc = mix(alb, pow(alb, vec3<f32>(1.35)) * vec3<f32>(0.62, 0.56, 0.47) * 0.9, wet);
    let albw = mix(wetc, vec3<f32>(0.085, 0.062, 0.042), wet * 0.62 * mud);
    let ambw = mix(li.amb, vec3<f32>(luminance(li.amb)), 0.7);
    var rgb = albw * (ambw * (1.15 + 0.5 * nw.y) + li.sunc * dif * 0.6 + vec3<f32>(0.02));
    // (a wet shine across it, the sky's)
    let fr = pow(1.0 - saturate(dot(nw, -rd)), 4.0);
    rgb = rgb + mix(ts_skyr(reflect(rd, nw), li), vec3<f32>(luminance(li.skyl)), 0.7) * fr * 0.14 * wet;
    out.t = tnear;
    out.rgb = rgb;
    out.hit = true;
    out.alb = alb;
    out.nw = nw;
    return out;
}
// A piece from the hash `hh` at `ctr`, spinning with `time`, grown from nothing by `grow` (0 to 1); the nearest hit of the ray
// with it. `tr`, `bd` the land's trees and buildings there. `rest`: when its tumbling dies away, for one that comes to lie
// on the water (`flat` going to 1).
fn ts_piece(ro: vec3<f32>, rd: vec3<f32>, hh: u32, ctr: vec3<f32>, time: f32, grow: f32, scale: f32, tr: f32, bd: f32, li: TsLight, wet: f32, flat: f32, longest: f32, rest: f32) -> TsPieceHit {
    let h2 = pcg(hh ^ 0x68E31DA4u);
    let h3 = pcg(h2 + 0x1B873593u);
    let r = vec4<f32>(vec4<u32>(hh & 0xFFFFu, hh >> 16u, h2 & 0xFFFFu, h2 >> 16u)) / 65536.0;
    let r2 = vec3<f32>(vec3<u32>(h3 & 0x3FFu, (h3 >> 10u) & 0x3FFu, (h3 >> 20u) & 0x3FFu)) / 1024.0;
    let kind = ts_kind(r.x, r2.x, tr, bd);
    let log = kind < 4u;
    // (their sizes: a trunk five to twelve blocks long, a clump of leaves, a panel of planks, a lump of stone, a slab of earth)
    var half = vec3<f32>(0.5);
    if (log) {
        half = vec3<f32>(0.5, 0.5, 2.5 + 3.5 * r2.y);
    } else if (kind == 12u || kind == 13u) {
        half = vec3<f32>(0.7 + 0.5 * r2.y, 0.5 + 0.4 * r2.z, 0.8 + 0.5 * r2.x);
    } else if (kind == 4u || kind == 5u || kind == 22u) {
        half = select(vec3<f32>(1.5, 0.5, 1.0 + 0.5 * r2.y), vec3<f32>(1.0, 1.0, 0.5), r2.z > 0.6);
    } else if (kind == 6u || kind == 7u || kind == 8u || kind == 18u) {
        half = select(vec3<f32>(0.5), vec3<f32>(1.0, 0.5, 0.5 + 0.5 * r2.y), r2.z > 0.45);
    } else if (kind == 14u || kind == 15u || kind == 16u || kind == 17u || kind == 23u) {
        half = vec3<f32>(1.3 + 0.4 * r2.y, 0.6, 1.3 + 0.4 * r2.z);
    }
    half = half * grow * scale;
    // (never longer than the cells it is looked for in can show whole)
    half.z = min(half.z, longest);
    let ax = normalize(vec3<f32>(r.y - 0.5, r.z - 0.5, r.w - 0.5) + vec3<f32>(0.001, 0.002, 0.003));
    // (the tumbling slows to nothing over the two seconds round `rest`, and its angle is taken to the nearest whole turn from
    // where it ends, the same way round: scaling the angle by 1 - flat then settles it by half a turn at most. Scaling the
    // whole angle wound a piece back through every turn it had made since the strike began, several a second.)
    let rate = (0.35 + 1.2 * r2.x) * select(1.0, 0.4, log);
    let slow = clamp((time - (rest - 1.0)) / 2.0, 0.0, 1.0);
    let spun = min(time, rest - 1.0) + 2.0 * (slow - 0.5 * slow * slow);
    let ang = r2.z * 6.2831853 + rate * spun - round((r2.z * 6.2831853 + rate * rest) / 6.2831853) * 6.2831853;
    var m = ts_rodrigues(ax, ang * (1.0 - flat));
    // (afloat: lying on the water, turning very slowly, rocked by it, each about its own line)
    if (flat > 0.0) {
        let rock = ts_rodrigues(vec3<f32>(cos(r.x * 6.283), 0.0, sin(r.x * 6.283)), flat * 0.09 * sin(time * (0.9 + 0.7 * r.w) + r.x * 6.283));
        let turn = (r.w - 0.5) * 6.283 + (time - rest) * (0.03 + 0.09 * r2.y) * select(-1.0, 1.0, r2.x > 0.5);
        m = ts_rodrigues(vec3<f32>(0.0, 1.0, 0.0), flat * turn) * rock * m;
    }
    return ts_piece_hit(ro, rd, ctr, half, m, kind, li, wet);
}
// The drift of the water's own parcels from where the front found them: about four fifths of the front's speed while it
// rises, slowing as it holds, back the way it came as it drains (the integral of surge.rs's flow).
fn ts_ism(a: f32, b: f32, x: f32) -> f32 {
    let u = clamp((x - a) / (b - a), 0.0, 1.0);
    let inside = (b - a) * (u * u * u - 0.5 * u * u * u * u);
    return inside + max(x - b, 0.0);
}
fn ts_drift(s: f32, u: f32, time: f32, g: TsG) -> f32 {
    let tau = max(time - ts_arr(s, u, g.sd), 0.0);
    let v = ts_vel(s);
    let tr = TS_FACE / v;
    let d1 = 0.8 * v * (tau - 0.85 * ts_ism(tr, tr + TS_HOLD, tau));
    let t1 = tr + TS_HOLD;
    let d2 = 24.0 * (ts_ism(t1, t1 + TS_DRAIN, tau) - ts_ism(t1 + TS_DRAIN, t1 + TS_DRAIN + 3.0, tau));
    return d1 - d2;
}
// Pieces riding the face and the foam near where the ray met the water at `hp`: the cells of the wave's frame round that
// point, one piece in a cell at most, on the surface (partly sunk in it), the more the nearer the front.
// (the water's height over the ground at (s, u): for the foot, where the debris is thickest)
fn a_h_y(s: f32, u: f32, time: f32, g: TsG) -> f32 {
    return max(ts_surf_h(s, u, time, time, g), 0.0);
}
fn ts_deb_ext(ro: vec3<f32>, rd: vec3<f32>, hp: vec3<f32>, t_hit: f32, time: f32, g: TsG, li: TsLight) -> TsPieceHit {
    var best: TsPieceHit;
    best.hit = false;
    best.t = 1.0e9;
    if (t_hit > 900.0) {
        return best;
    }
    let sfm = ts_front(time);
    // (the cells ride with the front till the water starts back, then with the water, going back the way it came)
    let t0 = TS_T + ts_tau(g.dp) + TS_FACE / ts_vel(g.dp) + TS_HOLD;
    let dt_d = max(time - t0, 0.0);
    let fr = ts_front(min(time, t0)) - 26.0 * (dt_d - (1.0 - exp(-dt_d)));
    let cs = 7.0;
    let a_h = dot(hp.xz, g.m) - fr;
    let u_h = dot(hp.xz, g.n);
    let ia0 = i32(floor(a_h / cs));
    let iu0 = i32(floor(u_h / cs));
    for (var di = -1; di <= 1; di = di + 1) {
        for (var dj = -1; dj <= 1; dj = dj + 1) {
            let ia = ia0 + di;
            let iu = iu0 + dj;
            let hc = pcg(u32(ia * 7919 + 100003) ^ pcg(u32(iu * 104729 + 7)));
            for (var k = 0u; k < 2u; k = k + 1u) {
                let hh = pcg(hc + k * 0x7F4A7C15u);
                let r0 = f32(hh & 0xFFFFu) / 65536.0;
                let r1 = f32(hh >> 16u) / 65536.0;
                let h2 = pcg(hh + 0x9E3779B9u);
                let r2 = f32(h2 & 0xFFFFu) / 65536.0;
                let r3 = f32(h2 >> 16u) / 65536.0;
                // (drifting back along the wave's way through its cell, shrunk away at the ends so none pops)
                let f = fract(r1 + time * 0.2);
                let grow = smoothstep(0.0, 0.16, f) * smoothstep(1.0, 0.84, f);
                let a_c = (f32(ia) + f) * cs;
                let u_c = (f32(iu) + r2) * cs;
                let s_c = fr + a_c;
                let tau_c = time - ts_arr(s_c, u_c, g.sd);
                let x_c = ts_x(time, s_c, g);
                let dens = 0.5 * smoothstep(0.0, 0.4, tau_c) * (1.0 - smoothstep(35.0, 130.0, sfm - s_c)) * (1.0 - smoothstep(10.0, 42.0, a_h_y(s_c, u_c, time, g))) + 0.012 + 0.07 * smoothstep(0.02, 0.2, x_c);
                if (r0 > dens || grow < 0.05) {
                    continue;
                }
                let lvl = ts_surf_y(s_c, u_c, time, g);
                if (lvl < -1000.0) {
                    continue;
                }
                // (afloat low in the water, most of it under; in the wave anywhere in the churn)
                // (settled by the time the player's head breaks the surface, so nothing is seen coming to rest)
                let flat = smoothstep(-1.8, 0.7, time - ts_t0(s_c, g));
                let y_c = lvl + mix(-0.8 + (r3 - 0.4) * 3.0, -0.3 - 0.4 * r3, flat);
                let ctr = vec3<f32>(g.m.x * s_c + g.n.x * u_c, y_c, g.m.y * s_c + g.n.y * u_c);
                let mp = ts_map(s_c, u_c);
                let ph = ts_piece(ro, rd, pcg(hh ^ h2), ctr, time, grow, mix(1.2 + clamp(t_hit / 200.0, 0.0, 2.0), 1.0 + clamp(t_hit / 500.0, 0.0, 1.0), flat), mp.x, mp.y, li, 0.55 + 0.4 * flat, flat, 6.8, ts_t0(g.dp, g) - 0.8);
                if (ph.hit && ph.t < best.t && ph.t < t_hit + 5.0) {
                    best = ph;
                }
            }
        }
    }
    return best;
}
// Pieces in the water the camera is in: a grid of cells riding the water's own drift, sampled along the ray as far as it
// can be seen through the murk; the camera's carry and the flow past it make them rush by.
fn ts_deb_under(ro: vec3<f32>, rd: vec3<f32>, lw: f32, time: f32, cs: f32, cu: f32, g: TsG, li: TsLight, j: f32) -> TsPieceHit {
    var best: TsPieceHit;
    best.hit = false;
    best.t = 1.0e9;
    let dr = ts_drift(cs, cu, time, g);
    let rop = ro - vec3<f32>(g.m.x * dr, 0.0, g.m.y * dr);
    // (cell by cell along the ray, nearest first: each cell's pieces stay inside it, so nothing is cut at a cell's wall and
    // the first hit is the nearest)
    let cell = 14.0;
    let mp = ts_map(cs, cu);
    let reach = min(lw, 46.0);
    var ic = vec3<i32>(floor(rop / cell));
    let st = vec3<i32>(sign(rd));
    let inv = 1.0 / (abs(rd) + vec3<f32>(1.0e-5));
    var tm = ((vec3<f32>(ic) + 0.5 + 0.5 * vec3<f32>(st) - rop / cell) * sign(rd)) * cell * inv;
    let td = cell * inv;
    var tc = 0.0;
    for (var i = 0; i < 9; i = i + 1) {
        if (tc > reach) {
            break;
        }
        if (ic.y >= -7) {
            let hh = pcg(u32(ic.x * 73856 + 5) ^ pcg(u32(ic.y * 19349 + 11) ^ pcg(u32(ic.z * 83492 + 3))));
            for (var k = 0u; k < 2u; k = k + 1u) {
                let hk = pcg(hh + k * 0x7F4A7C15u);
                if (f32(hk & 0xFFFFu) / 65536.0 > 0.72) {
                    continue;
                }
                let h2 = pcg(hk + 0x85EBCA6Bu);
                let jit = vec3<f32>(f32(h2 & 255u), f32((h2 >> 8u) & 255u), f32((h2 >> 16u) & 255u)) / 255.0 - 0.5;
                // (the first any size, the other small and free to sit anywhere)
                let ctr = (vec3<f32>(ic) + vec3<f32>(0.5)) * cell + jit * select(1.6, 7.0, k == 1u);
                let ph = ts_piece(rop, rd, pcg(hk ^ h2), ctr, time, 1.0, select(1.0, 0.5, k == 1u), mp.x, mp.y, li, 0.3, 0.0, 6.0, TS_LEN + 60.0);
                if (ph.hit && ph.t < best.t) {
                    best = ph;
                }
            }
            if (best.hit && best.t < tc + td.x + td.y + td.z) {
                return best;
            }
        }
        if (tm.x < tm.y && tm.x < tm.z) {
            tc = tm.x;
            tm.x = tm.x + td.x;
            ic.x = ic.x + st.x;
        } else if (tm.y < tm.z) {
            tc = tm.y;
            tm.y = tm.y + td.y;
            ic.y = ic.y + st.y;
        } else {
            tc = tm.z;
            tm.z = tm.z + td.z;
            ic.z = ic.z + st.z;
        }
    }
    return best;
}

// Cauliflower: round lumps of boiling water packed together, the height of the highest over `p` (a cell a lump).
fn ts_puff(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    var h = 0.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            let c = vec2<i32>(i32(i.x) + x, i32(i.y) + y);
            let hh = pcg(u32(c.x * 8191 + 100003) ^ pcg(u32(c.y * 131071 + 7)));
            let o = vec2<f32>(f32(hh & 0xFFFFu), f32(hh >> 16u)) / 65536.0;
            let r = vec2<f32>(f32(x), f32(y)) + o - f;
            let rad = 0.5 + 0.5 * o.x * o.y + 0.25 * o.y;
            h = max(h, sqrt(max(rad * rad - dot(r, r), 0.0)));
        }
    }
    return h;
}
fn ts_boil(p: vec2<f32>) -> f32 {
    return ts_puff(p) + 0.42 * ts_puff(p * 2.7 + vec2<f32>(11.3, 4.7)) + 0.16 * ts_puff(p * 7.1 + vec2<f32>(3.1, 9.2));
}

// The sum of a few directional waves, sharpened at their crests: the height's slope (x along `p.x`, y along `p.y`).
// `f` fades the small ones with distance (0 only the biggest, 1 all).
fn ts_ripple(p: vec2<f32>, t: f32, f: f32) -> vec2<f32> {
    var g = vec2<f32>(0.0);
    var a = 1.0;
    var w = 0.11;
    var ang = 0.7;
    for (var i = 0; i < 6; i = i + 1) {
        let d = vec2<f32>(cos(ang), sin(ang));
        let ph = dot(d, p) * w + t * sqrt(w * 9.8) * 1.6 + f32(i) * 1.9;
        // (sin raised to a power rounds the troughs and points the crests)
        let c = 0.5 + 0.5 * sin(ph);
        let k = a * pow(c, 2.0) * cos(ph);
        g = g + d * k;
        let fade = clamp(f * 6.0 - f32(i), 0.0, 1.0);
        a = a * 0.72 * fade;
        w = w * 1.62;
        ang = ang + 2.399;
    }
    return g;
}
// Value noise on a plane and its slope: z the value, xy the slope.
fn ts_vnd(p: vec2<f32>) -> vec3<f32> {
    let i = floor(p);
    let f = p - i;
    let e = f * f * (3.0 - 2.0 * f);
    let de = 6.0 * f * (1.0 - f);
    // (one round of the hash a corner: this runs by the dozen in a pixel)
    let q = bitcast<vec2<u32>>(vec2<i32>(i)) * vec2<u32>(0x9E3779B1u, 0x85EBCA6Bu);
    let a = f32(pcg(q.x ^ q.y) >> 16u) / 65535.0;
    let b = f32(pcg((q.x + 0x9E3779B1u) ^ q.y) >> 16u) / 65535.0;
    let c = f32(pcg(q.x ^ (q.y + 0x85EBCA6Bu)) >> 16u) / 65535.0;
    let d = f32(pcg((q.x + 0x9E3779B1u) ^ (q.y + 0x85EBCA6Bu)) >> 16u) / 65535.0;
    let k = a - b - c + d;
    return vec3<f32>(de.x * (b - a + k * e.y), de.y * (c - a + k * e.x), a + (b - a) * e.x + (c - a) * e.y + k * e.x * e.y);
}
struct TsChop {
    h: f32,         // the height of it, about nothing
    g: vec2<f32>,   // its slope
}
// Chop all the way down: sharp-crested wavelets from thirty blocks long to a few pixels, however close the eye is, so the
// nearer it gets the more there is to see. Each size runs at its own speed (`v`, the way the water runs) and is folded by
// the bigger ones. `px`: how many blocks a pixel covers.
fn ts_chop(p: vec2<f32>, v: f32, time: f32, px: f32) -> TsChop {
    var c: TsChop;
    c.h = 0.0;
    c.g = vec2<f32>(0.0);
    let l0 = 17.0;
    let top = log2(l0 / max(2.8 * px, 0.015));
    let first = max(i32(ceil(top)) - 6, 0);
    var q = p;
    var sum = 0.0;
    var i = first;
    loop {
        let fi = f32(i);
        if (fi >= top) {
            break;
        }
        let l = l0 / exp2(fi);
        let ca = cos(fi * 1.37 + 0.4);
        let sa = sin(fi * 1.37 + 0.4);
        let m = q + vec2<f32>(fi * 17.3, -time * v * (1.0 - 0.07 * fi));
        // (squashed along the way it runs: the crests lie across it, a little)
        let r = vec2<f32>(ca * m.x + sa * m.y, -sa * m.x + ca * m.y) * vec2<f32>(1.0, 1.5) / l;
        let n = ts_vnd(r);
        let e = 2.0 * n.z - 1.0;
        // (a crest broken into short lengths by a second ridge across it: chop, not contour lines)
        let br = 0.5 + 0.5 * sin(r.y * 2.3 + r.x * 1.1 + 5.0 * n.z + fi);
        let w = (1.0 - abs(e)) * (0.3 + 0.7 * br);
        let wg = (2.0 * w) * -2.0 * sign(e) * n.xy * (0.3 + 0.7 * br) * vec2<f32>(1.0, 1.5);
        // (the finest comes in as there is room for it, and the biggest goes when the seven are all too small for it)
        let a = saturate(top - fi) * select(1.0, 1.0 - saturate(top - 5.0 - fi), i == first && first > 0);
        c.h = c.h + a * (w * w - 0.36) * exp2(-0.55 * fi);
        sum = sum + a * exp2(-0.55 * fi);
        let gl = vec2<f32>(ca * wg.x - sa * wg.y, sa * wg.x + ca * wg.y) * a * (0.55 + 0.14 * fi);
        c.g = c.g + gl;
        q = q + gl * l * 0.022;
        i = i + 1;
    }
    c.h = c.h / max(sum, 0.2);
    c.g = c.g * 0.3;
    return c;
}
// The walls of cells of froth: how far `p` is from the nearest wall, in cells (a wall at 0). `p` in cells.
fn ts_web(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    var d1 = 9.0;
    var d2 = 9.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            let c = vec2<i32>(i32(i.x) + x, i32(i.y) + y);
            let hh = pcg(u32(c.x) * 0x9E3779B1u ^ u32(c.y) * 0x85EBCA6Bu);
            let r = vec2<f32>(f32(x), f32(y)) + vec2<f32>(f32(hh & 0xFFFFu), f32(hh >> 16u)) / 65536.0 - f;
            let d = dot(r, r);
            if (d < d1) {
                d2 = d1;
                d1 = d;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }
    return sqrt(d2) - sqrt(d1);
}
// Foam over coverage `cov` (0 to 1): a lace of thin walls in a few sizes, its cells closing up as there is more of it,
// `q` in blocks, `px` blocks a pixel. Far off, where the walls are too fine to see, the coverage itself.
fn ts_lace(q: vec2<f32>, cov: f32, px: f32) -> f32 {
    if (cov <= 0.002) {
        return 0.0;
    }
    let far_ = smoothstep(1.2, 3.5, px);
    if (far_ >= 1.0) {
        return cov;
    }
    let c1 = 13.0;
    let c2 = 4.3;
    let w1 = ts_web(q / c1 + vec2<f32>(31.7, 11.1));
    let w2 = ts_web(q / c2 + vec2<f32>(7.3, 3.9));
    let aa1 = 1.5 * px / c1;
    let aa2 = 1.5 * px / c2;
    var f = max(1.0 - smoothstep(0.0, aa1 + 0.03, w1 - cov * 0.72 + 0.03), 1.0 - smoothstep(0.0, aa2 + 0.05, w2 - cov * 0.95 + 0.28));
    if (px < 0.1) {
        let c3 = 1.4;
        let w3 = ts_web(q / c3 + vec2<f32>(1.3, 8.9));
        let k3 = 1.0 - smoothstep(0.05, 0.1, px);
        f = max(f, k3 * (1.0 - smoothstep(0.0, 1.5 * px / c3 + 0.08, w3 - cov * 0.95 + 0.42)));
    }
    return mix(saturate(f), cov, far_);
}

// The sky a reflected ray sees, or the dark land and water under it.
fn ts_skyr(r: vec3<f32>, li: TsLight) -> vec3<f32> {
    let hor = mix(li.fogl, li.skyl, smoothstep(0.0, 0.5, r.y));
    return mix(vec3<f32>(0.012, 0.03, 0.03) * (0.3 + li.day), hor, smoothstep(-0.12, 0.04, r.y));
}

// The wave's surface where the ray met it: its colour (linear). `hg` how far over the land under it this is (a big number
// over the sky), `path` how far the ray runs on through the water to the land.
fn ts_surface(p: vec3<f32>, rd: vec3<f32>, ht: f32, time: f32, g: TsG, li: TsLight, hg: f32, j: f32) -> vec3<f32> {
    let nrm0 = ts_normal(p, time, g);
    let s = dot(p.xz, g.m);
    let u = dot(p.xz, g.n);
    let env = ts_env(s, u, g);
    let a = TS_A * env;
    let tau = time - ts_arr(s, u, g.sd);
    let vel = ts_vel(s);
    let w = tau * vel;
    let ybar = clamp((p.y + TS_SEA) / a, 0.0, 1.05);
    let dtop = max(a - TS_SEA - p.y, 0.0);
    let bk = ts_break(s, u, g.sd);
    // how many blocks a pixel covers here: what is too fine for it fades out
    let px = ht * 2.0 * tan(0.5 * frame.view_params.w) * frame.resolution.w;
    let near = 1.0 - smoothstep(0.4, 2.4, px);
    let mid = 1.0 - smoothstep(2.0, 10.0, px);
    let face = 1.0 - smoothstep(0.35, 0.8, nrm0.y);
    // (the coordinate along the water's way: up the face on the face, along the flow behind it)
    let v = p.y - w;
    let warp = ts_fbm3(vec3<f32>(u * 0.016, v * 0.012, time * 0.13 + g.sd), 2 + i32(mid * 2.0));
    let warp2 = ts_fbm3(vec3<f32>(u * 0.06 + 3.0, v * 0.03, time * 0.25), 2);
    // (how close: what only shows close by, the chop that goes on getting finer. It cuts every edge below too: no edge
    // here is a soft one, however near the eye is)
    let ck = 1.0 - smoothstep(90.0, 380.0, ht);
    var ch: TsChop;
    ch.h = 0.0;
    ch.g = vec2<f32>(0.0);
    if (ck > 0.0) {
        ch = ts_chop(vec2<f32>(u + 9.0 * warp2, v * 0.8), 36.0, time, px);
    }

    // ---- the white water: only the lip, torn; here and there a short fall of it under a part that is breaking ------------
    let drop = 38.0;
    let vd = v + drop * time;
    // (the lip frays into threads)
    let fray = ts_fbm3(vec3<f32>(u * 0.21, vd * 0.012, 3.0), 2 + i32(mid));
    let reach = (5.0 + 9.0 * env) + (a - TS_SEA) * 0.17 * bk * bk * bk * smoothstep(-520.0, -180.0, s) * smoothstep(0.3, 0.7, warp);
    let wc = 1.0 - dtop / reach + (warp2 - 0.5) * 0.7 + (fray - 0.5) * 0.9 + ch.h * 1.1 * ck;
    var white = smoothstep(0.0, 0.5, wc) * mix(smoothstep(0.36, 0.6, fray) * 0.7, 1.0, smoothstep(0.25, 0.75, wc)) * smoothstep(-20.0, 90.0, w + 60.0);
    // (the foot: a brown bore where the face meets the land, boiling in lumps)
    let sharp = 1.0 - smoothstep(0.5, 2.4, px);
    let boil = ts_fbm3(vec3<f32>(u * 0.024, (p.y + time * 15.0) * 0.03, s * 0.017 - time * 0.5), 2 + i32(mid * 2.0));
    // (and it climbs what it runs into: the white rides up rising ground)
    let climbk = saturate((ts_ground(s + 18.0, u) - ts_ground(s - 18.0, u)) / 36.0 * 2.2);
    let foot = (1.0 - smoothstep(5.0 + (22.0 + 50.0 * climbk) * boil, 15.0 + (38.0 + 60.0 * climbk) * boil, hg + 14.0 * (fray - 0.5))) * smoothstep(-700.0, -420.0, s);
    white = max(white, foot);
    // (the last of it, right in front of the eye: whatever part of the face this is, it is coming apart and thrown at them)
    let rush = 1.0 - smoothstep(2.0, 30.0, ht);
    var rushn = 0.0;
    if (rush > 0.0) {
        rushn = ts_fbm3(vec3<f32>(u * 0.1, (p.y + time * 60.0) * 0.05, time * 1.5), 3) + ch.h * 0.42;
        // (not a sheet: a web of it thrown over the dark water, which stays dark and sharp until the blow itself)
        white = max(white, 0.21 * smoothstep(0.0, 0.3, rush) * smoothstep(0.6 - 0.2 * rush, 0.72 - 0.2 * rush, rushn));
    }
    // ---- the relief of what is white: the lip's threads; the foot's lumps ------------------------------------------------
    // (close by the chop has taken over from this)
    let oct = min(clamp(i32(log2(5.0 / max(px, 0.05))) + 1, 1, 5), select(5, 2, ck > 0.8));
    let de = 0.35;
    var b0 = 0.0;
    var bx = 0.0;
    var by = 0.0;
    if (foot < 0.99) {
        let bq = vec3<f32>(u * 0.075, vd * 0.013, time * 0.3);
        b0 = ts_fbm3(bq, oct);
        bx = ts_fbm3(bq + vec3<f32>(de, 0.0, 0.0), oct);
        by = ts_fbm3(bq + vec3<f32>(0.0, de, 0.0), oct);
    }
    let tn = vec3<f32>(g.n.x, 0.0, g.n.y);
    let tu = normalize(cross(nrm0, tn));
    var bump = (b0 - bx) * tn + (b0 - by) * tu;
    var lump = 0.5;
    if (foot > 0.01 && sharp > 0.01) {
        let fq = vec2<f32>(u * 0.13 + 4.0 * warp + 2048.0, (p.y + time * 15.0) * 0.13 + 4.0 * warp2 + 2048.0);
        let f0 = ts_boil(fq);
        let fx = ts_boil(fq + vec2<f32>(0.06, 0.0));
        let fy = ts_boil(fq + vec2<f32>(0.0, 0.06));
        // (and the broken froth over the lumps)
        let froth = ts_fbm3(vec3<f32>(u * 0.55, (p.y + time * 18.0) * 0.5, s * 0.3), 3);
        lump = mix(0.5, saturate((f0 - 0.2) / 1.05 + (froth - 0.5) * 0.7), sharp);
        bump = mix(bump, ((f0 - fx) * tn + (f0 - fy) * tu) * 0.8 + (froth - 0.5) * tu * 0.5, foot * sharp);
    }
    // (close by the small relief is the chop's: the coarse noise's cells would show)
    let wn = normalize(nrm0 + bump * (1.2 + (2.2 + 6.0 * foot) * mid) * (1.0 - 0.85 * ck * (1.0 - foot)) + (tn * ch.g.x + tu * ch.g.y) * 0.5 * ck);
    let bdif = saturate(dot(wn, li.L));
    let cav = mix(0.62, smoothstep(0.3, 0.66, b0), 0.15 + 0.85 * (1.0 - smoothstep(0.4, 2.2, px)));
    // ---- the dark water's own surface -------------------------------------------------------------------------------
    let rp = vec2<f32>(u, v + 30.0 * time);
    let sl = ts_ripple(rp * vec2<f32>(1.0, 0.5), time, near + 0.35 * mid);
    let stretch = (0.09 + 0.2 * mid) * (0.2 + 0.8 * (1.0 - smoothstep(220.0, 800.0, ht)));
    var nrm = normalize(nrm0 + (tn * sl.x + tu * sl.y) * stretch + (tn * ch.g.x + tu * ch.g.y) * 0.62 * ck);
    if (dot(nrm, rd) > -0.02) {
        nrm = normalize(nrm + rd * (dot(nrm, rd) + 0.02) * -1.0);
    }
    let cosv = saturate(dot(nrm, -rd));
    let fresnel = 0.035 + 0.965 * pow(1.0 - cosv, 5.0);
    let refl = reflect(rd, nrm);
    let skyc = ts_skyr(refl, li);
    // (a grey sky's light on it, whatever colour the sky is)
    let skyg = mix(skyc, vec3<f32>(luminance(skyc)) * vec3<f32>(0.92, 1.0, 0.98), 0.75);
    // the water's own colour: grey-green going to black in the deep of the face, a little green where it thins at the crest
    let thin = exp(-dtop / 40.0);
    let thin2 = exp(-dtop / 11.0);
    let deep = mix(vec3<f32>(0.0075, 0.012, 0.0105), vec3<f32>(0.016, 0.027, 0.023), smoothstep(0.25, 0.9, ybar));
    // (the water takes the sun's colour only a little, however red it goes)
    let sunw = mix(li.sunc, vec3<f32>(luminance(li.sunc)), 0.65);
    let lightw = li.amb * 1.3 + sunw * (0.22 + 0.5 * saturate(dot(nrm, li.L))) + li.nightw;
    // (the folds of the water, its heave, show as it turns to the sky and from it)
    var body = deep * lightw * 2.4 * (1.0 + 1.6 * clamp(sl.y * stretch * 2.2, -0.7, 1.4));
    // (and the chop that covers all of it: fine, broken, drawn out the way it is running)
    let chopv = v - 30.0 * time;
    let chop = ts_fbm3(vec3<f32>(u * 0.22 + 2.0 * warp2, chopv * 0.07, time * 0.5), 2 + i32(near) + i32(mid));
    let chop2 = ts_vn3(vec3<f32>(u * 0.8, chopv * 0.3, time * 1.2));
    let fine_c = mix((chop - 0.5) * (0.5 + 0.5 * mid) + (chop2 - 0.5) * 0.55 * near, ch.h * 1.1, ck);
    let fine_far = 1.0 - smoothstep(120.0, 520.0, ht);
    body = body * (1.0 + 1.5 * fine_c * fine_far);
    body = body + vec3<f32>(0.014, 0.052, 0.04) * thin * thin * (li.amb * 2.0 + sunw * 0.6 + li.nightw * 2.0);
    // (the sun through the thinnest of it: looking towards it, the lip lights up)
    let tra = pow(saturate(dot(rd, li.L) * 0.5 + 0.5), 4.0);
    body = body + vec3<f32>(0.05, 0.3, 0.2) * sunw * tra * thin2 * (0.7 + 0.6 * warp);
    // (the mud it is tearing up, towards its foot)
    let mudk = (1.0 - smoothstep(6.0, 60.0, hg)) * smoothstep(-500.0, -200.0, s);
    body = mix(body, vec3<f32>(0.045, 0.034, 0.022) * lightw * 1.3, mudk * 0.8);
    // (under the lip it overhangs: the sky is shut out)
    let lip = smoothstep(0.05, -0.55, nrm0.y);
    body = body * (1.0 - 0.75 * lip);
    // (the sun on it: glitter, not a lamp)
    let rl = saturate(dot(refl, li.L));
    let spk = smoothstep(0.42, 0.62, ts_vn3(vec3<f32>(u * 0.9, v * 0.5 + time * 7.0, time * 2.0))) * near + (1.0 - near) * 0.5;
    let spec = min(pow(rl, 420.0) * 1.5, 1.1) * li.sunc * (0.15 + 1.3 * spk) + pow(rl, 40.0) * li.sunc * 0.05;
    // (the toe of the face looks at the shut-out sky under the wave's own shoulder)
    let shut = (1.0 - 0.8 * lip) * (0.2 + 0.4 * smoothstep(0.1, 0.8, ybar));
    var wet = mix(body, skyg * shut, saturate(fresnel * (1.0 - 0.4 * face) + 0.4 * saturate(sl.y * 0.5) * stretch + 0.35 * saturate(fine_c) * mid * fine_far)) + spec;
    // ---- foam on the dark water: long thin streaks drawn up the face along the way it runs, curving, broken --------------
    let vr = v - 46.0 * time;
    // (they fan and curve slowly across the face; a shear of the coordinate, gentle enough never to fold)
    let ang = 0.5 * sin(u * 0.0071 + g.sd) + 0.26 * sin(u * 0.0173 - p.y * 0.003 + 1.7);
    let su = u + ang * (p.y + 60.0) * 0.55;
    let s1 = ts_vn3(vec3<f32>(su * 0.13, vr * 0.0052, 1.0));
    let s2 = ts_vn3(vec3<f32>(su * 0.27, vr * 0.0115, 3.0));
    var lace = smoothstep(0.66, 0.86, s1) * 0.5 + smoothstep(0.64, 0.84, s2) * 0.34 * mid;
    // (patches of it, the dark water between; thicker towards the lip and where it is being dragged out of the foot)
    let back = smoothstep(0.82, 0.96, nrm0.y) * smoothstep(40.0, 130.0, w);
    let lacek = smoothstep(0.5, 0.68, warp + 0.2 * smoothstep(0.6, 1.0, ybar) + 0.12 * mudk + 0.2 * back);
    let cov0 = saturate(lace * lacek * (0.5 + 0.5 * smoothstep(0.3, 0.9, ybar)));
    // (near to, what far off is a streak is a lace of fine foam, flowing up the face with the chop)
    let lq = vec2<f32>(su + 5.0 * warp2 + 14.0 * ch.g.x * ck, (vr + 12.0 * ch.g.y * ck) * 0.45);
    // (and the crests of the chop itself going white, flecks all over it, more in the patches)
    let fleck = smoothstep(0.34, 0.5, ch.h + 0.3 * (warp2 - 0.5) + 0.25 * smoothstep(0.35, 0.8, ybar) - 0.12);
    let foamthin = mix(cov0, max(ts_lace(lq, saturate(cov0 * 1.15 + 0.4 * ch.h * cov0), px), fleck * 0.9), ck);
    // ---- all together ----------------------------------------------------------------------------------------------
    let ambw = mix(li.amb, vec3<f32>(luminance(li.amb)), 0.6);
    let shade = ambw * (1.5 + 0.5 * wn.y) * (0.45 + 0.75 * cav) + mix(sunw, li.sunc, 0.4) * bdif * (0.6 + 0.4 * cav) + li.nightw * 2.6 * (0.6 + 0.6 * cav);
    var whitec = vec3<f32>(0.86, 0.88, 0.87) * shade * (1.0 - 0.34 * ck);
    // (the foot: dirty, nearly black in the creases, cream on its lumps; at a distance one mud-grey)
    let sh2 = ambw * (1.4 + 0.5 * wn.y) + mix(sunw, li.sunc, 0.3) * (0.15 + 0.85 * bdif) + li.nightw * 2.4;
    let crest = smoothstep(0.2, 0.62, lump);
    let cream = vec3<f32>(0.62, 0.57, 0.48);
    let mudd = vec3<f32>(0.05, 0.038, 0.027);
    let footc = mix(mix(mudd, cream, 0.1 + 0.34 * boil), mix(mudd, cream, crest * crest), sharp) * sh2 * (0.72 + 0.28 * smoothstep(0.0, 26.0, hg));
    whitec = mix(whitec, footc, foot);
    // (the crevices of the white water go grey-green: light that has come through water)
    whitec = whitec + vec3<f32>(0.0, 0.016, 0.014) * (1.0 - cav) * (li.amb + li.sunc * 0.25) * (1.0 - foot);
    // (close by the white is froth too: a mass of cells with the dark coming through, not a smooth sheet)
    let cover0 = saturate(white * (0.8 + 0.45 * b0));
    let cover = mix(cover0, mix(ts_lace(lq * 0.8 + vec2<f32>(5.0, 2.0), saturate(cover0 * 1.05 + ch.h * 0.5 * cover0), px), cover0, foot), ck);
    var c = mix(wet, vec3<f32>(0.62, 0.66, 0.64) * shade * 0.9, foamthin * (1.0 - cover) * 0.8);
    c = mix(c, whitec, cover);
    return c;
}

// The water as it drains: a brown torrent going back the way it came, broken all over, cream foam in clumps and rafts riding
// it, lines of it where it breaks, wreck in it, and a line of scum round whatever stands out of it. `hg`: how deep it is here.
// (Everything here runs at one speed, with the shape of the flow fixed in the land: a speed that changes from place to place
// shears a pattern further each second, into marbled bands.)
fn ts_torrent(p: vec3<f32>, rd: vec3<f32>, ht: f32, time: f32, g: TsG, li: TsLight, hg: f32) -> vec3<f32> {
    let s = dot(p.xz, g.m);
    let u = dot(p.xz, g.n);
    let px = ht * 2.0 * tan(0.5 * frame.view_params.w) * frame.resolution.w;
    let tn = vec3<f32>(g.n.x, 0.0, g.n.y);
    let tm = vec3<f32>(g.m.x, 0.0, g.m.y);
    let w0 = ts_fbm3(vec3<f32>(s * 0.009, u * 0.012, 2.0), 2) - 0.5;
    let run = s + time * 30.0 + 24.0 * w0;
    let cross_ = u + 34.0 * w0;
    let ch = ts_chop(vec2<f32>(cross_, run * 0.85), 11.0, time, px);
    // (the big heave of it: lumps of water, not bands)
    let sl = ts_ripple(vec2<f32>(cross_, run), time * 1.2, 1.0 - smoothstep(1.0, 6.0, px));
    var nrm = normalize(ts_normal(p, time, g) + (tn * sl.x + tm * sl.y) * 0.1 + (tn * ch.g.x + tm * ch.g.y) * 0.5);
    if (dot(nrm, rd) > -0.02) {
        nrm = normalize(nrm - rd * (dot(nrm, rd) + 0.02));
    }
    let cosv = saturate(dot(nrm, -rd));
    let fresnel = 0.03 + 0.5 * pow(1.0 - cosv, 5.0);
    let refl = reflect(rd, nrm);
    let dif = saturate(dot(nrm, li.L));
    let ambg = mix(li.amb, vec3<f32>(luminance(li.amb)), 0.8);
    let lw = ambg * 1.25 + li.sunc * (0.22 + 0.55 * dif) + li.nightw;
    // (thick with mud: a body you can't see into, lighter in the lumps that catch the light)
    let shade = ts_fbm3(vec3<f32>(cross_ * 0.05, run * 0.04, time * 0.2), 2);
    var c = mix(vec3<f32>(0.04, 0.027, 0.016), vec3<f32>(0.1, 0.068, 0.04), saturate(shade + 1.3 * ch.h + 0.25 * sl.y)) * lw;
    c = mix(c, ts_skyr(refl, li) * vec3<f32>(0.5, 0.45, 0.36), fresnel);
    let rl = saturate(dot(refl, li.L));
    c = c + min(pow(rl, 240.0) * 1.2, 0.8) * li.sunc + pow(rl, 26.0) * li.sunc * 0.04;
    // what is white on it: rafts of foam and clumps, drawn out a little along the flow, with lines where it breaks over itself
    let raft = ts_fbm3(vec3<f32>(cross_ * 0.05, run * 0.017, time * 0.1), 3);
    let clump = ts_fbm3(vec3<f32>(cross_ * 0.17, run * 0.06, time * 0.2 + 4.0), 3);
    let broke = ts_fbm3(vec3<f32>(cross_ * 0.012, (run - time * 8.0) * 0.07, 9.0), 2);
    // (a thin web of it everywhere, thickening into clumps, closing up only in the middles of the rafts)
    var cov = 0.07 + 0.26 * smoothstep(0.48, 0.64, raft) + 0.32 * smoothstep(0.56, 0.68, clump + 0.3 * (raft - 0.5));
    cov = max(cov, 0.5 * smoothstep(0.6, 0.65, broke + 0.3 * (clump - 0.5)));
    // (scum and white water where it breaks round what stands out of it)
    cov = max(cov, 0.9 * (1.0 - smoothstep(0.3, 2.2 + 2.6 * shade, hg)));
    let q = vec2<f32>(cross_ + 6.0 * ch.g.x, run * 0.42 + 4.0 * ch.g.y);
    // (its edge gnawed at by the chop at every size, close to and far off)
    let foam = ts_lace(q, saturate(cov + cov * ch.h * 1.6), px);
    // (the foam stands proud, lit on the side to the sun, its creases brown)
    let cn = normalize(vec3<f32>(0.0, 1.0, 0.0) + (tn * ch.g.x + tm * ch.g.y) * 1.1);
    let fd = saturate(dot(cn, li.L));
    let foamc = mix(vec3<f32>(0.3, 0.24, 0.17), vec3<f32>(0.6, 0.52, 0.39), saturate(0.7 + 2.0 * ch.h)) * (ambg * 1.55 + li.sunc * (0.3 + 0.5 * fd) + li.nightw * 2.4);
    c = mix(c, foamc, saturate(foam));
    // wreck carried in it: splinters, sticks and bits of plank, thick where the foam is, too small to be anything else
    if (px < 0.5) {
        let sp = 3.4;
        let cq = vec2<f32>(cross_, run) / sp;
        let ci = floor(cq);
        let hh = pcg(u32(i32(ci.x) + 40000) * 0x9E3779B1u ^ u32(i32(ci.y) + 40000) * 0x85EBCA6Bu);
        let r = vec4<f32>(f32(hh & 255u), f32((hh >> 8u) & 255u), f32((hh >> 16u) & 255u), f32(hh >> 24u)) / 255.0;
        if (r.x < 0.08 + 0.34 * saturate(cov)) {
            let a = r.y * 6.283;
            let d = (cq - ci - vec2<f32>(0.5)) * sp + (r.zw - 0.5) * 1.1;
            let l = vec2<f32>(cos(a) * d.x + sin(a) * d.y, -sin(a) * d.x + cos(a) * d.y);
            let b = abs(l) - vec2<f32>(0.3 + 0.85 * r.z, 0.08 + 0.13 * r.w);
            let e = max(b.x, b.y);
            let m = 1.0 - smoothstep(-px, px, e);
            let wood = mix(vec3<f32>(0.055, 0.04, 0.028), vec3<f32>(0.16, 0.115, 0.07), r.w);
            c = mix(c, wood * lw, m);
        }
    }
    return c;
}

// The flow's velocity at (s, u) at `t` (blocks a second, on the ground, along the wave's way positive): fast as the
// face goes over, slowing as it holds, back the way it came as it drains (surge.rs's flow, kept in step: the carry holds
// the player at half of it, so what the water carries goes past them at about the other half).
fn ts_flow(s: f32, u: f32, t: f32, g: TsG) -> f32 {
    let tau = t - TS_T - ts_tau(s);
    let tr = TS_FACE / ts_vel(s);
    let rise = 0.25 * ts_vel(s) * (1.0 - 0.8 * smoothstep(tr, tr + TS_HOLD, tau));
    let x = ts_x(t, s, g);
    let dr = smoothstep(0.0, 0.5, x);
    return rise * (1.0 - dr) - 24.0 * dr * (1.0 - smoothstep(0.8, 1.0, x));
}

// What the wave took and carries whole past the camera: a tree, its trunk and crown, and a corner of a house, walls, floor,
// a window and a piece of its roof, each a few boxes of the game's own textures turning slowly as one.
const TS_BIGN: i32 = 3;
fn ts_bigbox(w: i32, i: i32) -> vec4<f32> {
    // xyz: the box's middle in the object, w: its kind
    if (w == 1) {
        switch i {
            case 0: { return vec4<f32>(0.0, -3.0, 0.0, 5.0); }    // a wall of planks
            case 1: { return vec4<f32>(-5.5, -3.0, 4.5, 4.0); }   // the wall round the corner
            case 2: { return vec4<f32>(0.0, -7.0, 2.0, 6.0); }    // the footing, cobble
            case 3: { return vec4<f32>(2.0, -2.5, -0.1, 9.0); }   // its window
            case 4: { return vec4<f32>(0.0, 3.0, 4.0, 8.0); }     // the roof, brick
            default: { return vec4<f32>(-3.0, 5.0, 3.0, 8.0); }
        }
    }
    switch i {
        case 0: { return vec4<f32>(0.0, 0.0, 0.0, 0.0); }         // the trunk, along z
        case 1: { return vec4<f32>(0.0, 0.0, 9.0, 12.0); }        // the crown
        case 2: { return vec4<f32>(2.2, 1.5, 6.0, 12.0); }
        case 3: { return vec4<f32>(-2.0, -1.5, 11.0, 12.0); }
        case 4: { return vec4<f32>(0.0, 2.0, 12.0, 13.0); }
        default: { return vec4<f32>(0.6, -2.0, 5.0, 13.0); }
    }
}
fn ts_bighalf(w: i32, i: i32) -> vec3<f32> {
    if (w == 1) {
        switch i {
            case 0: { return vec3<f32>(6.0, 3.0, 0.5); }
            case 1: { return vec3<f32>(0.5, 3.0, 5.0); }
            case 2: { return vec3<f32>(6.5, 1.0, 5.5); }
            case 3: { return vec3<f32>(1.0, 1.0, 0.56); }
            case 4: { return vec3<f32>(7.0, 0.5, 5.5); }
            default: { return vec3<f32>(4.0, 1.0, 3.5); }
        }
    }
    switch i {
        case 0: { return vec3<f32>(1.0, 1.0, 13.0); }
        case 1: { return vec3<f32>(3.5, 3.5, 3.0); }
        case 2: { return vec3<f32>(2.5, 2.5, 2.5); }
        case 3: { return vec3<f32>(3.0, 2.5, 3.0); }
        case 4: { return vec3<f32>(2.5, 2.0, 2.5); }
        default: { return vec3<f32>(2.0, 2.0, 2.0); }
    }
}
// The big pieces at the moments the sounds have them (`el` seconds after the water closed over the camera): each comes
// down the flow from well ahead and goes by close.
fn ts_bigs(ro: vec3<f32>, rd: vec3<f32>, el: f32, g: TsG, li: TsLight) -> TsPieceHit {
    var best: TsPieceHit;
    best.hit = false;
    best.t = 1.0e9;
    for (var k = 0; k < TS_BIGN; k = k + 1) {
        // (when it passes, what it is, how far to the side and up it goes by)
        var tp = 2.55;
        var w = 0;
        var off = vec2<f32>(11.0, 3.0);
        if (k == 1) {
            tp = 3.75;
            w = 1;
            off = vec2<f32>(-15.0, -1.0);
        } else if (k == 2) {
            tp = 5.3;
            w = 0;
            off = vec2<f32>(-7.0, 7.0);
        }
        let dt = el - tp;
        if (abs(dt) > 1.6) {
            continue;
        }
        // (fast by us, slowing a little after)
        let along = -dt * 52.0;
        let side = vec3<f32>(g.n.x, 0.0, g.n.y);
        let c = ro - vec3<f32>(g.m.x, 0.0, g.m.y) * along + side * off.x + vec3<f32>(0.0, off.y + dt * 1.5, 0.0);
        let oc = c - ro;
        let br = 24.0;
        let b = dot(oc, rd);
        if (dot(oc, oc) - b * b > br * br || b < -br) {
            continue;
        }
        let ax = normalize(vec3<f32>(0.5, 0.25 + 0.5 * f32(k), -0.6));
        let m = ts_rodrigues(ax, 0.9 * el + 1.7 * f32(k) + 0.5);
        for (var i = 0; i < 6; i = i + 1) {
            let bx = ts_bigbox(w, i);
            let ph = ts_piece_hit(ro, rd, c + m * bx.xyz, ts_bighalf(w, i), m, u32(bx.w), li, 0.3);
            if (ph.hit && ph.t < best.t) {
                best = ph;
            }
        }
    }
    return best;
}

// The camera in the water. First the blow: a white flash, then seconds of foam thrown past at a violent speed, billows of
// it with dark water between, which thin as it is dragged under. Then the water itself: green over brown, bright overhead,
// silt and bubbles streaming by, light coming down through it, wreckage going past, the broken surface above. `scene` is what
// the game drew at the pixel (the land, or the sky), `rd` the view ray, the camera at `ro` (relative to the target's ground).
fn ts_under(ro: vec3<f32>, rd: vec3<f32>, scene_len: f32, scene: vec3<f32>, time: f32, el: f32, g: TsG, li: TsLight, j: f32, sky: bool) -> vec3<f32> {
    let cs = dot(ro.xz, g.m);
    let cu = dot(ro.xz, g.n);
    let surf_c = ts_surf_y(cs, cu, time, g);
    let dep_c = max(surf_c - ro.y, 0.0);
    // where the ray leaves the water (up through its surface, or out of the front or the back of it)
    var t_exit = 1.0e9;
    var tp = 0.0;
    for (var i = 0; i < 26; i = i + 1) {
        let fi = f32(i) + j;
        let t = 0.5 + fi * fi * 0.19;
        if (t > scene_len) {
            break;
        }
        if (ts_f(ro + rd * t, time, g) > 0.0) {
            var a = tp;
            var b = t;
            for (var k = 0; k < 6; k = k + 1) {
                let mid = 0.5 * (a + b);
                if (ts_f(ro + rd * mid, time, g) > 0.0) {
                    b = mid;
                } else {
                    a = mid;
                }
            }
            t_exit = b;
            break;
        }
        tp = t;
    }
    var lw = min(min(scene_len, t_exit), 150.0);
    // (a piece of what the wave swept up, nearer than all that, rushing by)
    var deb = ts_deb_under(ro, rd, lw, time, cs, cu, g, li, j);
    let big = ts_bigs(ro, rd, el, g, li);
    if (big.hit && big.t < deb.t) {
        deb = big;
    }
    var piece = false;
    if (deb.hit && deb.t < lw) {
        lw = deb.t;
        piece = true;
    }
    // how far it can be seen: the water thick with silt, the red going last, but clear enough to see what passes
    let sig = vec3<f32>(0.034, 0.038, 0.052);
    let tr = exp(-sig * lw);
    let day = max(li.day, 0.0);
    let night = 1.0 - smoothstep(0.1, 0.55, li.day);
    // the light down here: brighter nearer the surface, and always some, so it reads on a phone
    let lit = (0.5 + 0.5 * exp(-dep_c / 55.0)) * (0.5 + 0.5 * day);
    let up = smoothstep(-0.7, 0.9, rd.y);
    var waterc = mix(vec3<f32>(0.052, 0.058, 0.03), mix(vec3<f32>(0.1, 0.16, 0.085), vec3<f32>(0.3, 0.42, 0.27), up * up), smoothstep(0.1, 0.9, up));
    waterc = mix(waterc, mix(vec3<f32>(0.014, 0.024, 0.04), vec3<f32>(0.04, 0.085, 0.13), up), night);
    // the flow past the camera: much faster in the first seconds
    let fl = (ts_flow(cs, cu, time, g) * 2.4 + 70.0 * exp(-max(el, 0.0) / 1.1));
    let vel = vec3<f32>(g.m.x * fl, 0.0, g.m.y * fl);
    let tn = vec3<f32>(g.n.x, 0.0, g.n.y);
    let swirl = 1.7 * time;
    // ---- what the water holds, marched along the ray: billows of foam, then silt; bubbles over them ----------------------
    let th = 0.46 + 0.16 * smoothstep(0.1, 2.6, el);
    let reach = mix(36.0, 90.0, smoothstep(0.3, 3.0, el));
    var acc = vec3<f32>(0.0);
    var trf = 1.0;
    var bub = 0.0;
    let foamlit = mix(vec3<f32>(0.92, 0.94, 0.92), vec3<f32>(0.24, 0.24, 0.15), smoothstep(0.12, 1.5, el)) * (0.42 + 0.58 * day) + li.nightw * 2.0;
    for (var i = 0; i < 12; i = i + 1) {
        let t = (f32(i) + 0.5 + (j - 0.5) * 0.3) * reach / 12.0;
        let q = ro + rd * t;
        var w = q - vel * time;
        // (streamed out along the flow, and rolling round it)
        let al = dot(w.xz, g.m);
        let ac = dot(w.xz, g.n);
        let ca = cos(swirl + al * 0.012);
        let sa = sin(swirl + al * 0.012);
        let wr = vec3<f32>(ac * ca - w.y * sa, ac * sa + w.y * ca, al * 0.38);
        if (t > lw) {
            break;
        }
        // (big rolling masses of it, cut up small: water full of air is never smooth)
        let big0 = ts_fbm3(wr * 0.035, 2);
        let fine = ts_fbm3(wr * 0.3 + vec3<f32>(big0 * 3.0), 3);
        let n = big0 * 0.62 + fine * 0.38;
        let bl = smoothstep(th - 0.03, th + 0.2, n);
        if (bl > 0.0) {
            let a = 1.0 - exp(-bl * reach / 12.0 * (0.018 + 0.34 * (1.0 - smoothstep(0.1, 1.5, el))));
            // (the air in it white, dark where the mass is deep)
            let shade = 0.55 + 0.75 * smoothstep(0.3, 0.68, fine) * smoothstep(0.32, 0.6, big0 + 0.1);
            acc = acc + trf * a * foamlit * shade * exp(-t * 0.016);
            trf = trf * (1.0 - a);
        }
        bub = bub + exp(-t * 0.05) * smoothstep(0.8, 0.9, ts_vn3(vec3<f32>(wr.x, wr.y + time * 12.0, wr.z) * 0.62));
    }
    bub = bub / 12.0;
    // the light's shafts down through it, off the broken surface
    var shaft = 0.0;
    for (var i = 0; i < 8; i = i + 1) {
        let t = (f32(i) + j) * min(lw, 70.0) / 8.0;
        let q = ro + rd * t;
        let sd = max(surf_c - q.y, 0.0);
        let dsun = q.xz + li.L.xz / max(li.L.y, 0.2) * sd;
        let pat = smoothstep(0.42, 0.72, ts_vn3(vec3<f32>(dsun.x * 0.05, dsun.y * 0.05, time * 0.6)));
        shaft = shaft + pat * exp(-sd / 80.0) * (1.0 / 8.0);
    }
    var ins = waterc * lit;
    ins = ins + vec3<f32>(0.42, 0.5, 0.34) * li.sunc * shaft * 0.34 * lit;
    ins = ins + vec3<f32>(0.75, 0.8, 0.72) * bub * 0.55 * lit;
    // what is at the end of it: the land, the sky through the surface, or the surface seen from below
    var far_col = scene * (0.45 + 0.55 * lit);
    if (piece) {
        // (it has no light of its own: what comes down through the water, from above, the sun's a little near the surface;
        // on its underside only the murk's own glow. The water's colour has it)
        let wup = 0.5 + 0.5 * deb.nw.y;
        // (each face its own: what makes a dark shape a thing with a top and sides)
        let wside = 0.72 + 0.28 * abs(deb.nw.x * g.m.x + deb.nw.z * g.m.y);
        let down = mix(vec3<f32>(0.13, 0.16, 0.1), vec3<f32>(0.72, 0.88, 0.62), wup * wup) * lit * wside;
        let sunk = li.sunc * vec3<f32>(0.5, 0.62, 0.42) * saturate(dot(deb.nw, li.L)) * exp(-dep_c / 45.0) * 0.4 * day;
        far_col = deb.alb * (down * (0.5 + 0.5 * day) + sunk + li.nightw * 0.9);
    } else if (t_exit < scene_len) {
        let w_up = saturate(-0.0 + rd.y);
        let window = smoothstep(0.35, 0.75, w_up);
        let pe = ro + rd * t_exit;
        let ns = ts_fbm3(vec3<f32>(pe.x * 0.07, pe.z * 0.07, time * 0.9), 3);
        let skyc = mix(li.fogl, li.skyl, 0.6) * (0.75 + 0.9 * ns) + li.sunc * pow(saturate(dot(rd, li.L)), 12.0) * 1.4;
        let foamb = smoothstep(0.52, 0.72, ns) * 0.8;
        far_col = mix(ins * 1.5, skyc * (0.6 + 0.5 * day), window) + vec3<f32>(0.75, 0.78, 0.7) * foamb * (0.2 + 0.8 * day) * (0.3 + 0.7 * window);
    }
    // (what floats in it goes into the water sooner than the land does: silt between it and the eye)
    let trp = select(tr, tr * exp(-vec3<f32>(0.013, 0.011, 0.01) * lw), piece);
    var out = far_col * trp + ins * (1.0 - trp);
    out = out * trf + acc;
    // the blow itself: a white flash, the picture blown out for a moment
    let e = max(el, 0.0);
    out = out + vec3<f32>(1.5, 1.5, 1.45) * exp(-e / 0.075) * (0.25 + 0.75 * day);
    return out;
}

// The spray and the mist: a torn veil blown up off the crest and back over it, far taller where the wave is still out at
// sea and breaking, and a skirt of mist along the ground ahead of the face, marched in the band the wave's front lies in,
// over the water's own surface only, up to `t1` (what is in front of the surface or the land). rgb premultiplied, a the
// light left (1 none).
fn ts_spray(ro: vec3<f32>, rd: vec3<f32>, t0: f32, t1: f32, time: f32, g: TsG, li: TsLight, j: f32) -> vec4<f32> {
    let s0 = dot(ro.xz, g.m);
    let rs = dot(rd.xz, g.m);
    let sf = ts_front(time);
    // the band: from 330 behind the front to 300 ahead
    var ta = t0;
    var tb = t1;
    if (abs(rs) > 1.0e-4) {
        let ca = (sf - 330.0 - s0) / rs;
        let cb = (sf + 300.0 - s0) / rs;
        ta = max(ta, min(ca, cb));
        tb = min(tb, max(ca, cb));
    } else if (s0 < sf - 330.0 || s0 > sf + 300.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    // (and under the plume's top)
    let ytop = TS_A * 1.1 - TS_SEA + 110.0;
    if (rd.y > 1.0e-4) {
        tb = min(tb, (ytop - ro.y) / rd.y);
    } else if (rd.y < -1.0e-4 && ro.y > ytop) {
        ta = max(ta, (ro.y - ytop) / -rd.y);
    } else if (ro.y > ytop) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    if (tb <= ta) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    // (as many steps as the way wants: right up against the face there are only a few blocks of it to march)
    let n = clamp(i32((tb - ta) / 16.0) + 4, 4, 18);
    let dt = (tb - ta) / f32(n);
    let jj = 0.5 + (j - 0.5) * 0.35;
    var tr = 1.0;
    var acc = vec3<f32>(0.0);
    let ambn = vec3<f32>(luminance(li.amb));
    let lightc = ambn * 1.7 + li.sunc * 0.62 + li.nightw * 2.2;
    for (var i = 0; i < n; i = i + 1) {
        let t = ta + (f32(i) + jj) * dt;
        let p = ro + rd * t;
        let s = dot(p.xz, g.m);
        let u = dot(p.xz, g.n);
        let env = ts_env(s, u, g);
        if (env < 0.12) {
            continue;
        }
        let tau = time - ts_arr(s, u, g.sd);
        // (how far ahead of the crest this is)
        let dc = (TS_FACE / ts_vel(s) - tau) * ts_vel(s);
        // (it comes off the crest as it stands now: ahead of the front the wave hasn't stood up yet)
        // (once it has stood up, that is just the wave's strength here)
        var rise = 1.0;
        var lc = TS_A * env - TS_SEA;
        if (sf < -380.0) {
            rise = ts_rise(min(s, sf), u, g.sd);
            lc = TS_A * ts_env(min(s, sf), u, g) - TS_SEA;
        }
        let ls = ts_surf_h(s, u, time, time, g);
        if (p.y < ls) {
            continue;
        }
        let bk = ts_break(s, u, g.sd);
        // (out at sea it throws a great curtain up; over the land less)
        let tall = (26.0 + 44.0 * (1.0 - smoothstep(-650.0, -120.0, s))) * (0.55 + 0.45 * bk) * (0.2 + 0.8 * smoothstep(0.45, 1.0, rise));
        let hc = max(p.y - lc, 0.0);
        let plume = exp(-pow(hc / tall, 1.6)) * smoothstep(-300.0, -60.0, dc - hc * 0.9) * (1.0 - smoothstep(0.0, 70.0 + hc * 0.12, dc - hc * 0.5)) * smoothstep(0.6 * lc, 0.97 * lc, p.y);
        // (the skirt: mist rolling ahead of the face, near the ground)
        let gr = ts_ground(s, u);
        let over = p.y - gr;
        let skirt = smoothstep(-8.0, 6.0, over) * (1.0 - smoothstep(14.0, 72.0, over)) * exp(-max(dc, 0.0) / 120.0) * smoothstep(-110.0, 0.0, dc);
        if (plume + skirt < 0.004) {
            continue;
        }
        // (torn into wisps blown back and up)
        let nz = ts_fbm3(vec3<f32>(u * 0.012, (p.y - time * 16.0) * 0.016, (s - sf + time * 12.0) * 0.012), 3);
        let wisp = ts_fbm3(vec3<f32>(u * 0.024, (p.y - time * 30.0) * 0.011, (s - sf + time * 34.0) * 0.024), 2);
        let dens = plume * 1.1 * smoothstep(0.4, 0.74, nz * 0.75 + wisp * 0.45) * smoothstep(0.3, 0.85, rise) + skirt * (0.26 + 0.5 * (1.0 - rise)) * smoothstep(0.3, 0.68, nz);
        if (dens < 0.001) {
            continue;
        }
        // (near to, a veil is no good: it is torn right down, and what is left is thin)
        let pn = smoothstep(240.0, 60.0, t);
        var cut = 1.0;
        if (pn > 0.0) {
            let dt0 = ts_vn3(vec3<f32>(u * 0.19, (p.y - time * 34.0) * 0.14, (s + time * 20.0) * 0.19));
            cut = mix(1.0, smoothstep(0.48, 0.66, dt0) * 0.75, pn);
        }
        let ext = dens * cut * dt * 0.024 * smoothstep(0.1, 0.3, env) * smoothstep(0.0, 1.5, time);
        let a = 1.0 - exp(-ext);
        // (brighter high up where the sun has it, darker low in its own shade)
        let lit = 0.5 + 0.6 * smoothstep(0.3 * lc, lc + 40.0, p.y) ;
        acc = acc + tr * a * lightc * lit * mix(vec3<f32>(0.62, 0.58, 0.52), vec3<f32>(0.86, 0.88, 0.88), smoothstep(gr, gr + 60.0, p.y));
        tr = tr * (1.0 - a);
        if (tr < 0.02) {
            break;
        }
    }
    return vec4<f32>(acc, tr);
}

// Spray exploding up where the front hits something (the map's trees and buildings, and now and then anything): rooster
// tails, drawn on planes across the wave's way at the rows of land the front has just reached, each row split into cells a
// tail at most. Nearest row first. rgb premultiplied, a the light left. `t1`: what is in front of them.
fn ts_tails(ro: vec3<f32>, rd: vec3<f32>, t1: f32, tmore: f32, time: f32, g: TsG, li: TsLight) -> vec4<f32> {
    let rs = dot(rd.xz, g.m);
    let s0 = dot(ro.xz, g.m);
    // (only from ahead of it, looking back at it: behind it there is nothing left to throw them up)
    if (rs > -0.12 || s0 < ts_front(time)) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let row = 58.0;
    let cell = 120.0;
    let k0 = floor(ts_front(time) / row);
    let ambn = mix(li.amb, vec3<f32>(luminance(li.amb)), 0.7);
    let lightc = ambn * 1.7 + li.sunc * 0.75 + li.nightw * 2.4;
    var tr = 1.0;
    var acc = vec3<f32>(0.0);
    // (the camera ahead of it looks back along m: the rows nearest it first; behind it, the other way)
    for (var i = 0; i < 4; i = i + 1) {
        let k = k0 - f32(i);
        let sr = k * row;
        // (the plane leans forward with the flow as it climbs)
        let t = (sr - s0 - 0.4 * ro.y) / (rs - 0.4 * rd.y);
        if (t <= 0.5 || t > t1 + tmore || t > 460.0) {
            continue;
        }
        let p = ro + rd * t;
        let u = dot(p.xz, g.n);
        let ci = floor(u / cell);
        let cu = (ci + 0.38 + 0.24 * fract(ci * 0.61803 + k * 0.4142)) * cell;
        let hh = pcg(u32(i32(ci) + 8192) * 7919u ^ pcg(u32(i32(k) + 8192) * 104729u));
        let r = vec3<f32>(f32(hh & 1023u), f32((hh >> 10u) & 1023u), f32((hh >> 20u) & 1023u)) / 1024.0;
        let mp = ts_map(sr, cu);
        if (r.z > 0.3 + 0.6 * saturate(mp.x * 1.4 + mp.y * 2.0 + (ts_ground(sr + 20.0, cu) - ts_ground(sr - 20.0, cu)) * 0.06) || ts_env(sr, cu, g) < 0.3) {
            continue;
        }
        let age = time - ts_arr(sr, cu, g.sd) - 0.15 - ts_toe(sr, cu, ts_ground(sr, cu), g);
        if (age <= 0.0 || age > 4.2) {
            continue;
        }
        let gb = ts_ground(sr, cu);
        let hg = p.y - gb;
        // (where the ground rises against it, it is thrown up much harder)
        let hit = saturate((ts_ground(sr + 20.0, cu) - ts_ground(sr - 20.0, cu)) / 40.0 * 2.6);
        let hb = (38.0 + 96.0 * r.x * r.x + 70.0 * hit) * sqrt(min(age / 0.8, 1.0));
        let climb = max(hg, 0.0);
        // (a fan of jets out of the one place it struck, each thrown off to one side, tearing up as it goes)
        let lean = (r.y - 0.5) * 0.7;
        let fan = (u - cu) / (climb + 5.0) - lean;
        let width = 0.62 * (0.55 + 0.45 * min(age, 1.4));
        if (abs(fan) > width || hg > hb * 1.9 || hg < -11.0) {
            continue;
        }
        let n = ts_fbm3(vec3<f32>(fan * 7.0 + r.z * 9.0, (climb - time * 46.0) * 0.022, k * 1.7), 3);
        let fine = ts_fbm3(vec3<f32>(fan * 26.0, (climb - time * 70.0) * 0.07, k * 3.1), 3);
        let fray = hg / max(hb, 1.0) + (n - 0.5) * 0.8;
        // (the fan: wide, its edges all jets; gone to droplets by the top)
        let body = (1.0 - smoothstep(0.35, 1.0, abs(fan) / width)) * smoothstep(-3.0, 8.0, hg + 8.0 * (n - 0.5));
        let top = 1.0 - smoothstep(0.55, 1.02, fray);
        let jets = smoothstep(0.42, 0.56, n * 0.62 + fine * 0.5 - 0.5 * (abs(fan) / width) * (abs(fan) / width) + 0.16);
        // (the drops it comes apart into, sharp and small, thinning out above it)
        let dp = vec2<f32>(u * 5.3 + 13.0 * fine, (p.y - time * 60.0) * 2.4 + 19.0 * n);
        let drops = smoothstep(0.72, 0.8, ts_vnd(dp).z) * smoothstep(0.42, 0.56, fine) * (1.0 - smoothstep(0.75, 1.5, fray)) * smoothstep(0.3, 0.8, fray);
        let fade = 1.0 - smoothstep(1.3, 4.0, age);
        let edge = smoothstep(0.5, 0.36, abs(u / cell - ci - 0.5));
        // (close by only: a long way off they would be puffs on a line; and melting into what stands behind them)
        let a = edge * (1.0 - smoothstep(240.0, 450.0, t)) * (1.0 - smoothstep(t1 + 0.2 * tmore, t1 + tmore, t)) * saturate(fade * body * (top * jets * 0.95 + drops * 0.55));
        if (a > 0.003) {
            let c = lightc * mix(vec3<f32>(0.46, 0.41, 0.34), vec3<f32>(0.93, 0.93, 0.91), smoothstep(0.32, 0.62, fine) * (0.45 + 0.55 * saturate(hg / 30.0)));
            acc = acc + tr * a * c;
            tr = tr * (1.0 - a);
        }
    }
    return vec4<f32>(acc, tr);
}

// How much of the sky's light the wave shuts out where the camera is (0 to 1): the sky turning as it comes, more the nearer.
fn ts_dim(cs: f32, time: f32) -> f32 {
    let dist = cs - ts_front(time);
    return (0.5 * smoothstep(0.2, 2.2, time) + 0.34 * (1.0 - smoothstep(30.0, 620.0, dist))) * (1.0 - 0.5 * smoothstep(130.0, 500.0, -dist)) * (1.0 - smoothstep(33.0, 41.0, time));
}

// How long the water has been over a point at height y (blocks over the target's ground) at (s, u): negative before it
// got there. The inverse of the face's rise.
fn ts_closed(y: f32, s: f32, u: f32, time: f32, g: TsG) -> f32 {
    let a = TS_A * ts_env(s, u, g);
    let x = pow(clamp((y + TS_SEA) / max(a, 1.0), 0.0, 1.0), 1.0 / 1.7);
    return time - ts_arr(s, u, g.sd) - x * TS_FACE / ts_vel(s);
}

// One of the two differences from a pixel to its neighbours, the shorter: it stays on the pixel's own face at a block's edge.
fn ts_face_d(uv: vec2<f32>, du: vec2<f32>, rel: vec3<f32>) -> vec3<f32> {
    let a = world_offset(uv + du, depth_at(uv + du)) - rel;
    let b = rel - world_offset(uv - du, depth_at(uv - du));
    return select(b, a, dot(a, a) < dot(b, b));
}

// What standing water shows along `r` from the land at `rel` (off the camera): the picture itself, as far as a few steps out
// along the ray can find it there (alpha how sure), so the stumps and the hills stand in the pools.
fn ts_mirror(rel: vec3<f32>, r: vec3<f32>) -> vec4<f32> {
    var t = 0.7;
    for (var i = 0; i < 12; i++) {
        let p = rel + r * t;
        let q = project_rel(p);
        if (q.z < 0.0 || q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) {
            break;
        }
        let d = depth_at(q.xy);
        if (!is_sky(d)) {
            let lp = length(p);
            let over = lp - length(world_offset(q.xy, d));
            if (over > 0.0 && over < t * 0.75 + 1.0) {
                let e = min(min(q.x, 1.0 - q.x), min(q.y, 1.0 - q.y));
                return vec4<f32>(srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, q.xy, 0.0).rgb), smoothstep(0.0, 0.06, e));
            }
        }
        t = t * 1.55;
    }
    return vec4<f32>(0.0);
}

// Land the water has been over. It is painted onto the blocks' own pixels, a sixteenth of a block each, so it looks part of
// them: the land dark and deep in colour, drying in blotches; a dull damp sheen on it; pools lying in the level ground with
// the sky and what stands round them in them; and thin dark runs of water down the slopes and the blocks' sides, the way
// the water went. `reach` how far it lies under the high water. The land dries in patches, the pools last.
fn ts_wet(col: vec3<f32>, pl: vec3<f32>, rel: vec3<f32>, uv: vec2<f32>, rd: vec3<f32>, time: f32, reach: f32, g: TsG, li: TsLight) -> vec3<f32> {
    // (the block face's normal from the depth round it)
    let px = frame.resolution.zw;
    var nrm = normalize(cross(ts_face_d(uv, vec2<f32>(0.0, px.y), rel), ts_face_d(uv, vec2<f32>(px.x, 0.0), rel)));
    if (dot(nrm, rd) > 0.0) {
        nrm = -nrm;
    }
    let top = smoothstep(0.5, 0.8, nrm.y);
    let dist = length(rel);
    let fine = 1.0 - smoothstep(60.0, 220.0, dist);
    // (the pixel of the block it is on: the top's, or the side's, along the face)
    let wp = pl + vec3<f32>(fract(anchor_x()), 0.0, fract(anchor_z()));
    let across = select(wp.x, wp.z, abs(nrm.x) > abs(nrm.z));
    let tx = (floor(select(vec2<f32>(across, wp.y), wp.xz, top > 0.5) * 16.0 + 0.002) + 0.5) / 16.0;
    let s = select(tx.x, dot(tx, g.m), top > 0.5);
    let u = select(tx.y, dot(tx, g.n), top > 0.5);
    let bits = pcg(u32(i32(floor(tx.x * 16.0))) * 0x9E3779B1u ^ pcg(u32(i32(floor(tx.y * 16.0)))));
    let grain = (f32(bits & 0xFFFFu) / 65536.0 - 0.5) * (1.0 - smoothstep(25.0, 70.0, dist));
    // (how level the land is here, from the land's map: water doesn't stand on a hillside)
    let ps = dot(pl.xz, g.m);
    let pu = dot(pl.xz, g.n);
    let g0 = ts_ground(ps, pu);
    let level = 1.0 - smoothstep(0.1, 0.3, length(vec2<f32>(ts_ground(ps + 10.0, pu) - g0, ts_ground(ps, pu + 10.0) - g0)) / 10.0);
    let lowest = 1.0 - smoothstep(1.2, 2.8, pl.y - g0);
    // (blotches over the land: what stays wet longest, and where the pools lie, stretched a little along the flow)
    let wob = fvnoise(vec2<f32>(s * 0.021, u * 0.034) + vec2<f32>(3.1, 7.7)) - 0.5;
    let n1 = fvnoise(vec2<f32>(s * 0.06 + 4.0 * wob, u * 0.095 - 3.0 * wob));
    let n2 = fvnoise(vec2<f32>(s * 0.21, u * 0.26) + vec2<f32>(11.0, 5.0));
    let blot = saturate(0.65 * n1 + 0.35 * n2 + 0.1 * grain);
    // (a lake's own water is no part of this: its surface lies a ninth of a block under the block's top, the land's tops on it)
    let height = abs(fract(pl.y + 0.5) - 0.5);
    let on_block = 1.0 - smoothstep(0.03, 0.05, height - 0.05 * saturate(dist / 400.0));
    let land = mix(1.0, max(on_block, smoothstep(250.0, 400.0, dist)), top);
    let pool = smoothstep(0.585, 0.615, blot + 0.09 * (level - 1.0)) * top * level * lowest * on_block * (1.0 - smoothstep(180.0, 340.0, dist));
    // (it dries in patches from 33 s, the pools going last, all of it gone by 41.5 s)
    let dry = saturate(blot * 1.1 - 0.05 + 0.45 * pool);
    let k = (1.0 - smoothstep(33.0 + 6.0 * dry, 35.5 + 6.0 * dry, time)) * smoothstep(0.0, 5.0, reach + 3.0 * (n2 - 0.3)) * land;
    // (the runs of water: thin dark lines down the slopes, a few on the level; sheets down the blocks' sides)
    let w0 = fvnoise(vec2<f32>(s * 0.03, u * 0.05));
    let line = fvnoise(vec2<f32>(u * 0.6 + 6.0 * w0, (s + time * 9.0) * 0.05));
    let rtop = smoothstep(0.93, 0.985, 1.0 - abs(2.0 * line - 1.0) + 0.05 * grain) * mix(1.0, 0.25, level);
    let sheet = fvnoise(vec2<f32>(s * 0.8, (u + time * 7.0) * 0.09));
    let rside = smoothstep(0.6, 0.68, sheet + 0.12 * grain) * (1.0 - smoothstep(20.0, 70.0, dist));
    let rill = mix(rside * 0.7, rtop, top) * fine * (1.0 - pool);
    // (soaked ground: darker and deeper in colour, unevenly)
    let lum = luminance(col);
    let deep = max(vec3<f32>(lum) + (col - vec3<f32>(lum)) * 1.3, vec3<f32>(0.0));
    let soak = mix(0.74, 0.5, smoothstep(0.34, 0.6, blot + 0.3 * grain)) * mix(1.0, 0.72, rill);
    let tint = vec3<f32>(soak * 1.03, soak, soak * 0.92);
    var c = mix(col, deep * tint, k);
    // (a dull sheen on the damp ground, broad and weak: added, so the blocks' pixels show through it)
    let nv = saturate(dot(nrm, -rd));
    let fr = pow(1.0 - nv, 5.0);
    let refl = reflect(rd, nrm);
    let sky_r = ts_skyr(vec3<f32>(refl.x, abs(refl.y), refl.z), li);
    let sheen = (0.02 + 0.13 * fr) * (0.35 + 0.65 * level) * (0.55 + 0.9 * saturate(grain + n2 * 0.6)) * top;
    c = c + sky_r * sheen * k;
    c = c + sky_r * rill * (0.03 + 0.16 * fr) * k;
    // (the pools: a skin of still water, trembling a little, the world upside down in it)
    let pk = pool * k;
    if (pk > 0.003) {
        let tr = vec2<f32>(fvnoise(vec2<f32>(wp.x * 1.3 + time * 0.5, wp.z * 1.3)), fvnoise(vec2<f32>(wp.x * 1.3, wp.z * 1.3 - time * 0.4))) - vec2<f32>(0.5);
        let rn = normalize(vec3<f32>(tr.x * 0.05, 1.0, tr.y * 0.05));
        let rr = reflect(rd, rn);
        let m = ts_mirror(rel, rr);
        let seen = mix(ts_skyr(rr, li), m.rgb, m.a);
        let f = 0.03 + 0.97 * pow(1.0 - saturate(dot(rn, -rd)), 5.0);
        // (shallow and silty: the ground dim under it, the rim of it darker still)
        let under = c * vec3<f32>(0.55, 0.5, 0.42);
        c = mix(c, mix(under, seen, saturate(f + 0.12)), pk);
        c = c + li.sunc * pow(saturate(dot(rr, li.L)), 400.0) * 1.6 * pk * (1.0 - m.a);
    }
    return c;
}

fn tsunami(in: StageIn) -> vec4<f32> {
    var uv = in.uv;
    let time = now();
    let k = intensity_v();
    let cam = frame.camera_position.xyz;
    let anc = anchor_xz();
    let gy = block_y() + 1.0;
    // (off the camera without its f32 rounding: far from the origin the camera moves in 1/128 block steps)
    let C = (vec3<f32>(anc.x, gy, anc.y) - cam) - camera_rest();
    let g = ts_geo();
    let ro = -C;
    ts_cam = ro;
    let cs0 = dot(ro.xz, g.m);
    let cu0 = dot(ro.xz, g.n);
    let inw = ts_f(ro, time, g) < 0.0;
    let el = ts_closed(ro.y, cs0, cu0, time, g);
    // (in its grip the whole picture is thrown round, and rocks after that)
    if (inw) {
        let ee = max(el, 0.0);
        let aspect = frame.resolution.x * frame.resolution.w;
        let ang = 0.62 * sin(ee * 3.1 + 0.5) * exp(-ee / 1.1) + 0.05 * sin(time * 1.1) + 0.03 * sin(time * 2.3 + 1.0);
        let zoom = 1.0 - 0.14 * exp(-ee / 1.4) * (0.5 + 0.5 * sin(ee * 7.0 + 1.0)) - 0.03;
        let c = (uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0);
        let r = vec2<f32>(c.x * cos(ang) - c.y * sin(ang), c.x * sin(ang) + c.y * cos(ang)) * zoom;
        uv = r / vec2<f32>(aspect, 1.0) + vec2<f32>(0.5);
    }
    let d = depth_at(uv);
    let sky = is_sky(d);
    let rel = world_offset(uv, select(d, 0.5, sky));
    let scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv, 0.5));
    let scene = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb);
    var col = scene;

    let sun = frame.sun.xyz;
    var li: TsLight;
    li.day = saturate(sun.y * 2.5 + 0.35);
    let sun_up = smoothstep(-0.12, 0.06, sun.y);
    let warm = (1.0 - smoothstep(0.02, 0.4, sun.y)) * smoothstep(-0.2, -0.02, sun.y);
    li.L = normalize(select(-sun, sun, sun.y > -0.04) + vec3<f32>(0.0, 0.03, 0.0));
    li.skyl = srgb_to_linear(frame.sky_color.rgb);
    li.fogl = srgb_to_linear(frame.fog_color.rgb);
    li.amb = mix(vec3<f32>(0.02, 0.025, 0.035), li.skyl * 0.6 + vec3<f32>(0.03), li.day);
    li.sunc = mix(vec3<f32>(1.25, 1.18, 1.05), vec3<f32>(1.4, 0.62, 0.3), warm) * sun_up + vec3<f32>(0.05, 0.07, 0.11) * (1.0 - sun_up);
    li.nightw = vec3<f32>(0.03, 0.045, 0.075) * (1.0 - smoothstep(0.1, 0.55, li.day));

    let pj = vec2<u32>(floor(in.position.xy));
    let j = f32(pcg(pj.x * 0x9E3779B1u ^ pcg(pj.y * 0x85EBCA6Bu ^ u32(time * 60.0))) & 0xFFFFu) / 65536.0;

    let cs = cs0;
    let sf = ts_front(time);
    let dim = ts_dim(cs, time);
    // (the water sees the same dying sky)
    li.skyl = li.skyl * (1.0 - 0.55 * dim);
    li.fogl = li.fogl * (1.0 - 0.6 * dim);
    li.amb = li.amb * (1.0 - 0.5 * dim);
    // ---- the light going as it comes: the world dims and cools, and the sky over it goes the colour of a bruise ----------
    if (sky) {
        // (towards the wave the dark climbs the sky first)
        let tow = saturate(0.5 - 0.5 * dot(rd.xz, g.m));
        let band = (0.5 + 0.5 * tow) * (1.0 - smoothstep(0.0, 0.5 + 0.35 * dim, rd.y - 0.15 * tow));
        let lum = luminance(col);
        // (a dark grey weather, torn, climbing out of the sea behind it)
        let cl = ts_fbm3(vec3<f32>(rd.x * 2.2 / (abs(rd.y) + 0.25) + time * 0.02, rd.z * 2.2 / (abs(rd.y) + 0.25), 1.0), 4);
        let storm = vec3<f32>(0.2, 0.235, 0.26) * (lum + 0.05) * (1.4 + 1.7 * cl);
        col = mix(col, storm * 0.62, saturate(dim * 1.25) * (0.6 + 0.4 * band));
    } else {
        let lum = luminance(col);
        col = mix(col, mix(vec3<f32>(lum), col, 0.6) * vec3<f32>(0.62, 0.68, 0.76), saturate(dim * 1.35));
        // (the wave's own shadow on the land ahead of it: towards the sun the ray climbs over it or doesn't)
        let pl = ro + rel;
        let ps = dot(pl.xz, g.m);
        let ahead = ps - (sf + 0.0);
        if (ahead > -60.0 && ahead < 900.0) {
            let Ls = dot(li.L.xz, g.m);
            var sh = 0.0;
            if (Ls < -0.02) {
                let tc = (ahead + 60.0) / -Ls;
                let top = TS_A * ts_env(ps - ahead, dot(pl.xz, g.n), g) - TS_SEA + 20.0;
                sh = 1.0 - smoothstep(top - 40.0, top + 40.0, pl.y + tc * li.L.y);
            }
            // (and the sky itself shut out close under it, whatever the sun)
            let close = 1.0 - smoothstep(0.0, 170.0, ahead);
            let dark = max(sh * 0.72, close * 0.55) * (0.4 + 0.6 * li.day);
            col = col * (1.0 - dark);
        }
        // (what the water has been over, as it comes out from under it)
        let pu = dot(pl.xz, g.n);
        let tau_p = time - ts_arr(ps, pu, g.sd);
        let reach = TS_A * ts_env(ps, pu, g) - TS_SEA - pl.y;
        if (tau_p > 1.0 && reach > -3.0 && time < 41.5) {
            col = ts_wet(col, pl, rel, uv, rd, time, reach, g, li);
        }
    }

    if (inw) {
        col = ts_under(ro, rd, scene_len, scene, time, el, g, li, j, sky);
        return vec4<f32>(linear_to_srgb(max(col, vec3<f32>(0.0))), 1.0);
    }
    let h = ts_march(ro, rd, 0.0, min(scene_len, 6000.0), time, g, j);
    var t_front = min(scene_len, 6000.0);
    if (h.hit) {
        t_front = h.t;
        let pw = ro + rd * h.t;
        // (how far over the land it is: the land's map under the wave, the scene's own depth for the shallows)
        let hg0 = pw.y - ts_ground(dot(pw.xz, g.m), dot(pw.xz, g.n));
        var hg = hg0;
        var hgs = 1.0e4;
        if (!sky && rd.y < -0.02) {
            hgs = max(scene_len - h.t, 0.0) * -rd.y;
        }
        // (the wave, or what is left of it going back)
        let ps_h = dot(pw.xz, g.m);
        let trh = TS_FACE / ts_vel(ps_h);
        let dr = max(smoothstep(0.0, 0.12, ts_x(time, ps_h, g)), smoothstep(trh + 0.8, trh + 3.0, time - ts_arr(ps_h, dot(pw.xz, g.n), g.sd)));
        var sf_c = vec3<f32>(0.0);
        if (dr < 1.0) {
            sf_c = ts_surface(pw, rd, h.t, time, g, li, hg, j);
        }
        if (dr > 0.0) {
            sf_c = mix(sf_c, ts_torrent(pw, rd, h.t, time, g, li, hgs), dr);
        }
        // (thin water over the land lets it show through, tinted: the film the drain leaves, a shallow edge)
        var a = 1.0;
        var under = col;
        if (!sky) {
            let path = max(scene_len - h.t, 0.0);
            a = 1.0 - exp(-path / 5.0);
            under = col * exp(-vec3<f32>(0.10, 0.12, 0.16) * path);
        }
        col = mix(under, sf_c, a);
        // (what the wave has swept up, riding its face and its foam)
        // (looked for a little back along the ray: at a low angle what stands on the water is a long way short of the point
        // the ray meets it)
        let deb = ts_deb_ext(ro, rd, ro + rd * (h.t - min(0.7 / max(-rd.y, 0.01), 7.0)), h.t, time, g, li);
        var t_see = h.t;
        if (deb.hit) {
            // (the part under the surface seen through it, and gone a little way down)
            let sunk = saturate(1.0 - exp(-max(deb.t - h.t, 0.0) * -rd.y * 2.4));
            col = mix(deb.rgb, col, sunk);
            t_see = deb.t;
        }
        // (the haze of the distance, thin: the wave is a dark mass, not a pale one)
        let haze = 1.0 - exp(-t_see * 0.00013);
        col = mix(col, li.fogl * 0.72 * (1.0 - 0.5 * dim), haze * 0.75);
    }
    // (a tail stands in front of the water it came out of, whichever way the front bows)
    let tl = ts_tails(ro, rd, t_front, select(0.0, 70.0, h.hit), time, g, li);
    col = col * tl.a + tl.rgb;
    let sp = ts_spray(ro, rd, 0.0, t_front, time, g, li, j);
    col = col * sp.a + sp.rgb;
    return vec4<f32>(linear_to_srgb(max(col, vec3<f32>(0.0))), 1.0);
}

@fragment
fn fs_main(in: StageIn) -> @location(0) vec4<f32> {
    return tsunami(in);
}
