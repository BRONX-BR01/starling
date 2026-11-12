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

// Orbital Laser's post pass for the Sinkhole (laser 8). Like the Crystal Bloom's, the mod builds it from
// shaders/strike.wgsl up to its fs_main (the helpers: the noise, rot_axis, project_rel, mh, ign) less the other lasers'
// own functions, followed by this file, and sets it for a sinkhole strike only. Validate with tools/check-shader.sh.

// ---- laser 8: the sinkhole ----------------------------------------------------------------------------------------
// No beam, nothing from the sky. The land round the target trembles, birds go up off it, hairline cracks race out over
// it, radiating and branching; a patch in the middle gives (real blocks), the cracks round the slabs it will break into
// open; then it caves in from the middle out, ring by ring: each slab of land (grass over dirt over stone) strains,
// tilts and drops away into the pit, the dust boiling up out of it and rolling out low over the land, and the pit is
// left: dark, sheer, down to bedrock, water pouring over its edge where it cut a river or a lake.
// strike/sinkhole.rs cuts the same rings and slabs (ShGeo) and hands them over as the table below (sh_table); it digs
// each slab's land SH_DIG_AHEAD before it lets go, while this pass already draws the slab over it, so nothing is seen
// open before it falls: keep the SH_* and the table in step.
const SH_R: f32 = 112.0;           // the pit's mean radius at the top (the rim wanders, sh_rim)
const SH_GIVE: f32 = 6.0;          // the middle gives,
const SH_SAG: f32 = 7.3;           // sags,
const SH_C0: f32 = 8.6;            // and the collapse sets out from the middle (sh_front)
const SH_LEAD: f32 = 0.45;         // a slab drawn this long before it lets go, straining in place,
const SH_FALL: f32 = 3.2;          // and gone this long after, deep in the pit
const SH_DEEP0: f32 = 16.0;        // the pit dug on down to bedrock from here (until then it is 25 deep)
const SH_END: f32 = 34.0;          // the dust gone
const SH_LEN: f32 = 40.0;          // the strike's length (lasers.rs): the pit's dark fades out over its last SH_FADE
const SH_FADE: f32 = 9.0;
const SH_DIG: f32 = 0.1;           // a slab's land dug this long before it lets go (sinkhole.rs's SH_DIG_AHEAD)
const SH_SPURTS: i32 = 10;         // the cracks race out in spurts (sinkhole.rs's sh_spurts), each over SH_SPURT
const SH_SPURT: f32 = 0.2;
const SH_BIRDS: i32 = 28;

// ---- the table (strike/sinkhole.rs's sh_table): see SH_RG.. there ----------------------------------------------
const SH_RG: u32 = 8u;
const SH_RW: u32 = 5u;
const SH_WF: u32 = 64u;
const SH_SB: u32 = 96u;
const SH_SW: u32 = 24u;
const SH_MAT: u32 = 7936u;         // the materials (sh_land.rs's MATS), two words each
const SH_GRID: u32 = 8192u;        // the land's columns (sh_land.rs): SH_GW by SH_GW from the target's less SH_G
const SH_G: i32 = 134;
const SH_GW: i32 = 269;
fn sh_w(i: u32) -> f32 {
    if (i < arrayLength(&mod_data)) {
        return bitcast<f32>(mod_data[i]);
    }
    return 0.0;
}
fn sh_count() -> i32 {
    if (arrayLength(&mod_data) < SH_SB) {
        return 0;
    }
    return i32(sh_w(0u));
}
fn sh_rim(a: f32) -> f32 {
    return SH_R * (1.0 + 0.07 * sin(3.0 * a + sh_w(2u)) + 0.04 * sin(5.0 * a + sh_w(3u)) + 0.025 * sin(11.0 * a + sh_w(4u))
        + 0.012 * sin(23.0 * a + sh_w(5u)));
}
fn sh_ring_r(j: i32, a: f32, rim: f32) -> f32 {
    let nr = i32(sh_w(1u));
    if (j <= 0) {
        return 0.0;
    }
    if (j >= nr) {
        return rim;
    }
    let b = SH_RG + u32(j) * SH_RW;
    return sh_w(b) * rim / SH_R + 2.0 * sin(7.0 * a + sh_w(b + 1u));
}
// When the collapse reaches r out (sinkhole.rs's sh_front), and how far out it has reached at `t` (its inverse).
fn sh_front(r: f32) -> f32 {
    if (r < 30.0) {
        return SH_C0 + 0.9 * r / 30.0;
    }
    return SH_C0 + 2.0 + 4.4 * pow(clamp((r - 30.0) / (SH_R - 30.0), 0.0, 1.4), 0.75);
}
fn sh_reached(t: f32) -> f32 {
    if (t < SH_C0) {
        return 0.0;
    }
    if (t < SH_C0 + 0.9) {
        return 30.0 * (t - SH_C0) / 0.9;
    }
    if (t < SH_C0 + 2.0) {
        return 30.0;
    }
    return 30.0 + (SH_R - 30.0) * pow((t - SH_C0 - 2.0) / 4.4, 1.0 / 0.75);
}
// The slab the land at polar (r, a) from the middle is part of (-1 outside the rim), and the distances from it to its
// ring's edges and its sector's (in blocks): x the ring's slab index, y its edges' nearest, z when it lets go.
fn sh_slab_at(r: f32, a: f32, rim: f32, seed: u32) -> vec3<f32> {
    if (r >= rim) {
        return vec3<f32>(-1.0, r - rim, 0.0);
    }
    let nr = i32(sh_w(1u));
    var j = 0;
    loop {
        if (j + 1 >= nr || r < sh_ring_r(j + 1, a, rim)) {
            break;
        }
        j = j + 1;
    }
    let r0 = sh_ring_r(j, a, rim);
    let r1 = sh_ring_r(j + 1, a, rim);
    let b = SH_RG + u32(j) * SH_RW;
    let n = i32(sh_w(b + 2u));
    let th0 = sh_w(b + 3u);
    let off = i32(sh_w(b + 4u));
    let u = fract((a - th0) / TAU) * f32(n);
    let m0 = min(i32(floor(u)), n - 1);
    let jit0 = 0.35 * (mh(u32(m0 % n), seed, 0x710u + u32(j)) - 0.5);
    let jit1 = 0.35 * (mh(u32((m0 + 1) % n), seed, 0x710u + u32(j)) - 0.5);
    var m = m0;
    var e0 = f32(m0) + jit0;
    var e1 = f32(m0 + 1) + jit1;
    if (u < e0) {
        m = (m0 + n - 1) % n;
        e1 = e0;
        e0 = f32(m0 - 1) + 0.35 * (mh(u32((m0 + n - 1) % n), seed, 0x710u + u32(j)) - 0.5);
    } else if (u >= e1) {
        m = (m0 + 1) % n;
        e0 = e1;
        e1 = f32(m0 + 2) + 0.35 * (mh(u32((m0 + 2) % n), seed, 0x710u + u32(j)) - 0.5);
    }
    let side = min(u - e0, e1 - u) / f32(n) * TAU * r;
    let ring = select(min(r - r0, r1 - r), r1 - r, j == 0);
    let k = off + m;
    return vec3<f32>(f32(k), min(side, ring), sh_w(SH_SB + u32(k) * SH_SW + 6u));
}

// ---- a slab: a convex block of land (its corners' quad, grown to cover its curved edges; its ground's plane on top;
//      flat underneath), moving as it strains, tilts and falls -----------------------------------------------------------
struct ShPose {
    o: vec3<f32>,      // its ground's middle where it now is, relative to the camera
    pv: vec3<f32>,     // the edge it tips over, relative to the camera, before it moves
    er: vec3<f32>,     // out from the pit's middle, and along its ring
    et: vec3<f32>,
    phi: f32,          // how far it has tipped (its inner edge down), and turned about its own up
    psi: f32,
    drop: vec3<f32>,   // how far it has dropped and slid in
}
fn sh_corner(r: f32, th: f32) -> vec2<f32> {
    return vec2<f32>(cos(th), sin(th)) * max(r, 0.6);
}
// Slab k's pose `s` seconds after it lets go (s < 0: straining in place), C the pit's middle relative to the camera.
fn sh_pose(b: u32, k: i32, s: f32, C: vec3<f32>) -> ShPose {
    let c0 = sh_corner(sh_w(b + 2u), sh_w(b));
    let c1 = sh_corner(sh_w(b + 3u), sh_w(b + 1u));
    let c2 = sh_corner(sh_w(b + 5u), sh_w(b + 1u));
    let c3 = sh_corner(sh_w(b + 4u), sh_w(b));
    let m = (c0 + c1 + c2 + c3) * 0.25;
    let am = 0.5 * (sh_w(b) + sh_w(b + 1u));
    let er2 = vec2<f32>(cos(am), sin(am));
    var p: ShPose;
    p.er = vec3<f32>(er2.x, 0.0, er2.y);
    p.et = vec3<f32>(-er2.y, 0.0, er2.x);
    let ytop = sh_w(b + 7u);
    let thick = sh_w(b + 10u);
    let half_r = 0.5 * (0.5 * (sh_w(b + 4u) + sh_w(b + 5u)) - 0.5 * (sh_w(b + 2u) + sh_w(b + 3u)));
    let O = C + vec3<f32>(m.x, ytop, m.y);
    p.pv = O + p.er * half_r - vec3<f32>(0.0, thick, 0.0);
    let fk = f32(k);
    if (s < 0.0) {
        // dug out under it, still in place: exactly where the land it stands in for was (the hand-off unseen)
        p.phi = 0.0;
        p.psi = 0.0;
        p.drop = vec3<f32>(0.0);
    } else {
        // let go: a lurch, then tipping in over its outer edge faster and faster as it drops, sliding in, turning a
        // little
        let l = smoothstep(0.0, 0.3, s);
        p.phi = min(0.03 * l + 0.5 * sh_w(b + 12u) * s * s, 1.5);
        p.psi = sh_w(b + 13u) * s * s;
        p.drop = vec3<f32>(0.0, -0.45 * l - 0.5 * sh_w(b + 11u) * s * s, 0.0) - p.er * sh_w(b + 14u) * s * s;
    }
    p.o = O;
    return p;
}
// Into the slab's own frame (its ground's middle at the origin, along the world's axes as it lay): a point relative to
// the camera, and a direction.
fn sh_to(p: ShPose, x: vec3<f32>) -> vec3<f32> {
    let q = rot_axis(x - p.drop - p.pv, p.et, -p.phi) + p.pv - p.o;
    return rot_axis(q, vec3<f32>(0.0, 1.0, 0.0), -p.psi);
}
fn sh_from(p: ShPose, q: vec3<f32>) -> vec3<f32> {
    return rot_axis(rot_axis(q, vec3<f32>(0.0, 1.0, 0.0), p.psi) + p.o - p.pv, p.et, p.phi) + p.pv + p.drop;
}
fn sh_dir_to(p: ShPose, v: vec3<f32>) -> vec3<f32> {
    return rot_axis(rot_axis(v, p.et, -p.phi), vec3<f32>(0.0, 1.0, 0.0), -p.psi);
}
fn sh_dir_from(p: ShPose, v: vec3<f32>) -> vec3<f32> {
    return rot_axis(rot_axis(v, vec3<f32>(0.0, 1.0, 0.0), p.psi), p.et, p.phi);
}
// The view ray (o + t d, in the slab's frame) through slab b: x where it enters, y where it leaves, z which face it
// enters by (0 top, 1 bottom, 2.. the sides), w unused.
fn sh_hit(b: u32, o: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    let c = array<vec2<f32>, 4>(sh_corner(sh_w(b + 2u), sh_w(b)), sh_corner(sh_w(b + 3u), sh_w(b + 1u)),
        sh_corner(sh_w(b + 5u), sh_w(b + 1u)), sh_corner(sh_w(b + 4u), sh_w(b)));
    let m = (c[0] + c[1] + c[2] + c[3]) * 0.25;
    var t0 = -1.0e9;
    var t1 = 1.0e9;
    var face = -1.0;
    // the top: its ground's plane; the bottom: flat
    let sx = sh_w(b + 8u);
    let sz = sh_w(b + 9u);
    let nt = vec3<f32>(-sx, 1.0, -sz);
    let thick = sh_w(b + 10u);
    for (var i = 0; i < 6; i = i + 1) {
        var n = nt;
        var w = 0.0;
        if (i == 1) {
            n = vec3<f32>(0.0, -1.0, 0.0);
            w = thick;
        } else if (i >= 2) {
            let a = c[i - 2] - m;
            let e = c[(i - 1) % 4] - m - a;
            var n2 = normalize(vec2<f32>(e.y, -e.x) + vec2<f32>(1.0e-7));
            if (dot(n2, a) < 0.0) {
                n2 = -n2;
            }
            let grow = 1.0 + select(0.0, sh_w(b + 16u), i == 2) + select(0.0, sh_w(b + 17u), i == 4);
            n = vec3<f32>(n2.x, 0.0, n2.y);
            w = dot(n2, a) + grow;
        }
        let den = dot(n, d);
        let num = w - dot(n, o);
        if (abs(den) < 1.0e-7) {
            if (num < 0.0) {
                return vec3<f32>(1.0, 0.0, -1.0);
            }
            continue;
        }
        let tt = num / den;
        if (den < 0.0) {
            if (tt > t0) {
                t0 = tt;
                face = f32(i);
            }
        } else {
            t1 = min(t1, tt);
        }
    }
    return vec3<f32>(t0, t1, face);
}

// A column's top as the land's colours make it (sRGB, as lit at full light), and how high it is over its ground's top:
// the leaves over it where a tree stands, else its block's top, tinted, or snow.
fn sh_top_albedo(w: vec3<u32>) -> vec4<f32> {
    let leaf = (w.y >> 16u) & 63u;
    if (leaf > 0u) {
        var m = sh_mat(leaf);
        if (m.tint == 2u) {
            m.top = m.top * sh_565(w.z >> 16u, vec3<f32>(0.467, 0.671, 0.184));
        }
        return vec4<f32>(m.top * 0.82, f32((w.y >> 26u) & 15u));
    }
    return vec4<f32>(sh_ground_albedo(w), 0.0);
}
fn sh_ground_albedo(w: vec3<u32>) -> vec3<f32> {
    if (((w.x >> 30u) & 1u) == 1u) {
        return vec3<f32>(0.95, 0.98, 0.99);
    }
    var m = sh_mat((w.x >> 9u) & 63u);
    if (m.tint == 1u) {
        m.top = m.top * sh_565(w.z & 0xffffu, vec3<f32>(0.569, 0.741, 0.349));
    }
    return m.top;
}
// How the real land beside slab b is lit this frame, channel by channel (xyz: the scene's colour over the land's
// model of it; w: how many of its dozen columns were seen), from the tops of the columns just out past its outer edge
// (the next ring's, or past the rim: ground still standing, in the land read), each kept only where the scene shows
// that very top (its depth where it should be), and not under water.
fn sh_calib(b: u32, C: vec3<f32>, dy0: f32) -> vec4<f32> {
    let am = 0.5 * (sh_w(b) + sh_w(b + 1u));
    let span = sh_w(b + 1u) - sh_w(b);
    let ro = 0.5 * (sh_w(b + 4u) + sh_w(b + 5u));
    var acc = vec3<f32>(0.0);
    var n = 0.0;
    for (var j = 0; j < 16; j = j + 1) {
        let a = am + (f32(j % 4) / 3.0 - 0.5) * span * 1.1;
        let r = ro + 2.5 + 3.0 * f32(j / 4);
        let ci = i32(floor(r * cos(a) + 0.5)) + SH_G;
        let ck = i32(floor(r * sin(a) + 0.5)) + SH_G;
        let w = sh_colw(ci, ck);
        if (w.x >> 31u == 0u || ((w.y >> 30u) & 1u) == 1u) {
            continue;
        }
        let alb = sh_top_albedo(w);
        let top = C + vec3<f32>(f32(ci - SH_G), f32(sh_col_h(w)) - dy0 + alb.w, f32(ck - SH_G));
        let P = project_rel(top);
        if (P.z < 0.0 || P.x < 0.0 || P.y < 0.0 || P.x > 1.0 || P.y > 1.0) {
            continue;
        }
        let d = depth_at(P.xy);
        if (is_sky(d)) {
            continue;
        }
        let seen = world_offset(P.xy, d);
        if (length(seen - top) > 1.0 + 0.008 * length(top)) {
            continue;
        }
        let sc = textureSampleLevel(scene_color, linear_sampler, P.xy, 0.0).rgb;
        acc = acc + clamp(sc / max(alb.xyz, vec3<f32>(0.03)), vec3<f32>(0.0), vec3<f32>(1.6));
        n = n + 1.0;
    }
    return vec4<f32>(acc / max(n, 1.0), n);
}

// The view ray (o + t d, in slab b's frame) through the blocks of the land it carries (slab k's columns of the land's
// square, `off` taking its frame into the square's), from tn to tf: x the distance to the block it hits (1e9 none),
// yzw the face's normal in its frame; and the block's colour (sRGB) and the pixel's size there for `pw0` a pixel's
// angle.
struct ShVox {
    t: f32,
    n: vec3<f32>,
    c: vec3<f32>,
}
fn sh_vox(b: u32, k: i32, o: vec3<f32>, d: vec3<f32>, off: vec3<f32>, t_max: f32, px_a: f32) -> ShVox {
    var v: ShVox;
    v.t = 1.0e9;
    let lo = vec3<f32>(sh_w(b + 18u), sh_w(b + 22u), sh_w(b + 19u));
    let hi = vec3<f32>(sh_w(b + 20u) + 1.0, sh_w(b + 23u), sh_w(b + 21u) + 1.0);
    let P = o + off;
    let inv = 1.0 / select(d, vec3<f32>(1.0e-7), abs(d) < vec3<f32>(1.0e-7));
    let ta = (lo - P) * inv;
    let tb = (hi - P) * inv;
    let tn3 = min(ta, tb);
    let tf3 = max(ta, tb);
    let tn = max(max(tn3.x, tn3.y), max(tn3.z, 0.0));
    let tf = min(min(tf3.x, tf3.y), min(tf3.z, t_max));
    if (tf <= tn) {
        return v;
    }
    let ylo = sh_w(b + 22u);
    var t = tn + 1.0e-4;
    let p0 = P + d * t;
    var cell = floor(p0);
    let stp = sign(d);
    let tdel = abs(inv);
    var tnext = (cell + max(stp, vec3<f32>(0.0)) - P) * inv;
    // (which axis it last stepped along: the face it enters by; at the start, the box's face it came in by)
    var axis = 1;
    if (tn3.x >= tn3.y && tn3.x >= tn3.z) {
        axis = 0;
    } else if (tn3.z >= tn3.y) {
        axis = 2;
    }
    var lastc = vec2<i32>(-99999);
    var w = vec3<u32>(0u);
    for (var i = 0; i < 160; i = i + 1) {
        if (t > tf) {
            break;
        }
        let cc = vec2<i32>(i32(cell.x), i32(cell.z));
        if (any(cc != lastc)) {
            w = sh_colw(cc.x, cc.y);
            lastc = cc;
        }
        if (w.x != 0u) {
            let blk = sh_cell(w, k, cell, ylo);
            if (blk.x != 0u) {
                var n = vec3<f32>(0.0);
                if (axis == 0) {
                    n.x = -stp.x;
                } else if (axis == 1) {
                    n.y = -stp.y;
                } else {
                    n.z = -stp.z;
                }
                v.t = t;
                v.n = n;
                let f = P + d * t - cell;
                v.c = sh_block_col(blk, w, cell, n, clamp(f, vec3<f32>(0.0), vec3<f32>(0.9999)), t * px_a);
                return v;
            }
        }
        // (on to the next cell)
        if (tnext.x < tnext.y && tnext.x < tnext.z) {
            t = tnext.x;
            tnext.x = tnext.x + tdel.x;
            cell.x = cell.x + stp.x;
            axis = 0;
        } else if (tnext.y < tnext.z) {
            t = tnext.y;
            tnext.y = tnext.y + tdel.y;
            cell.y = cell.y + stp.y;
            axis = 1;
        } else {
            t = tnext.z;
            tnext.z = tnext.z + tdel.z;
            cell.z = cell.z + stp.z;
            axis = 2;
        }
    }
    return v;
}

// The land's colours, a block at a time: grass, its side, dirt, stone in strata, deepslate deep down, broken rock under.
fn sh_block_tint(q: vec3<f32>, k: f32) -> f32 {
    return 0.86 + 0.28 * fh31(floor(q) + vec3<f32>(k * 17.0, 0.0, 0.0));
}
fn sh_earth(dtop: f32, face: f32, q: vec3<f32>, k: f32, day: f32) -> vec3<f32> {
    let bt = sh_block_tint(q, k);
    if (face < 0.5) {
        let g = vec3<f32>(0.17, 0.31, 0.11) * (0.85 + 0.3 * fvnoise(q.xz * 0.25 + vec2<f32>(k)));
        return g * bt;
    }
    if (face > 0.5 && face < 1.5) {
        return vec3<f32>(0.11, 0.10, 0.095) * bt;
    }
    if (dtop < 0.9) {
        return select(vec3<f32>(0.25, 0.18, 0.12), vec3<f32>(0.19, 0.3, 0.1), dtop < 0.3 + 0.25 * fh21(floor(q.xz))) * bt;
    }
    if (dtop < 4.0 + 1.5 * fh21(floor(q.xz) + vec2<f32>(k))) {
        return vec3<f32>(0.27, 0.19, 0.13) * bt;
    }
    // stone, in bands (andesite, tuff, granite now and then), deepslate under it
    let band = floor((dtop + 0.7 * fvnoise(q.xz * 0.2)) / 3.0);
    let hb = fh21(vec2<f32>(band, k * 0.37));
    var st = vec3<f32>(0.40, 0.395, 0.385);
    if (hb > 0.82) {
        st = vec3<f32>(0.46, 0.33, 0.28);
    } else if (hb > 0.66) {
        st = vec3<f32>(0.33, 0.34, 0.31);
    } else if (hb < 0.15) {
        st = vec3<f32>(0.5, 0.5, 0.49);
    }
    let ore = step(0.985, fh31(floor(q) + vec3<f32>(3.0, k, 1.0)));
    st = mix(st, vec3<f32>(0.08, 0.08, 0.08), ore);
    return mix(st, vec3<f32>(0.2, 0.2, 0.22), smoothstep(10.0, 16.0, dtop)) * bt;
}

// ---- the cracks: a network racing out over the land from the middle, branching, and the slabs' outlines opening up
//      before they go (a Voronoi of cells stretched out along the radius, so most run out from the middle) ------------
fn sh_net(q: vec2<f32>, er: vec2<f32>) -> vec2<f32> {
    // in a frame along the radius and across it, cells longer along it
    let u = vec2<f32>(dot(q, er), dot(q, vec2<f32>(-er.y, er.x))) * vec2<f32>(0.075, 0.14);
    let w = u + 0.35 * vec2<f32>(fvnoise(u * 1.7 + vec2<f32>(3.1, 1.2)), fvnoise(u * 1.7 + vec2<f32>(7.4, 5.3)));
    let i = floor(w);
    let f = w - i;
    var d1 = 9.0;
    var d2 = 9.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            let g = vec2<f32>(f32(x), f32(y));
            let h = vec2<f32>(fh21(i + g), fh21(i + g + vec2<f32>(19.7, 4.1)));
            let d = length(g + h - f);
            if (d < d1) {
                d2 = d1;
                d1 = d;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }
    // (the distance to the nearest edge, in blocks, roughly; and a value along it)
    return vec2<f32>((d2 - d1) * 6.0, fh21(i));
}

// ---- the land as it really is (sh_land.rs): each column's ground, the blocks on it, under it and deeper, the snow on
//      it, the trunk and leaves of a tree standing on it, and the slab it is part of ------------------------------------
// Column (ci, ck) of the land's square: its three words (0s: not read, or outside it).
fn sh_colw(ci: i32, ck: i32) -> vec3<u32> {
    if (ci < 0 || ck < 0 || ci >= SH_GW || ck >= SH_GW) {
        return vec3<u32>(0u);
    }
    let i = SH_GRID + 3u * u32(ck * SH_GW + ci);
    if (i + 2u >= arrayLength(&mod_data)) {
        return vec3<u32>(0u);
    }
    return vec3<u32>(mod_data[i], mod_data[i + 1u], mod_data[i + 2u]);
}
// A 5-6-5 colour (sRGB), or `def` for 0 (not known).
fn sh_565(c: u32, def: vec3<f32>) -> vec3<f32> {
    if (c == 0u) {
        return def;
    }
    return vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0);
}
// Its ground's top, from the target's ground (one above its highest ground block).
fn sh_col_h(w: vec3<u32>) -> i32 {
    return i32(w.x & 511u) - 256;
}
// A material's colours (sRGB): x its top's, y its sides'; and its kind (0 plain, 1 leaves, 2 log, 3 water, 4 grassy) and
// how much each block of it varies.
struct ShMat {
    top: vec3<f32>,
    side: vec3<f32>,
    kind: u32,
    tint: u32,
    var_: f32,
}
fn sh_mat(m: u32) -> ShMat {
    var o: ShMat;
    let i = SH_MAT + 2u * m;
    var a = 0x00646e7au;
    var b = 0x2e646e7au;
    if (i + 1u < arrayLength(&mod_data)) {
        a = mod_data[i];
        b = mod_data[i + 1u];
    }
    o.top = vec3<f32>(f32(a & 255u), f32((a >> 8u) & 255u), f32((a >> 16u) & 255u)) / 255.0;
    o.side = vec3<f32>(f32(b & 255u), f32((b >> 8u) & 255u), f32((b >> 16u) & 255u)) / 255.0;
    o.kind = (a >> 24u) & 7u;
    o.tint = (a >> 27u) & 3u;
    o.var_ = f32(b >> 24u) / 255.0;
    return o;
}
// What block of slab k is at cell c of the land's square (y from the target's ground), given its column's words and its
// underside `ylo`: 0 none; else 1 + the material, the second the cell's part (0 ground's top block, 1 deeper ground,
// 2 trunk, 3 leaves).
fn sh_cell(w: vec3<u32>, k: i32, c: vec3<f32>, ylo: f32) -> vec2<u32> {
    if (w.x >> 31u == 0u || i32((w.x >> 21u) & 511u) != k + 1) {
        return vec2<u32>(0u);
    }
    let y = i32(c.y);
    let g = sh_col_h(w) - 1;
    // (its underside broken, a block or two either way)
    let lo = i32(ylo) + i32(fh21(c.xz) * 2.5);
    if (y < lo) {
        return vec2<u32>(0u);
    }
    if (y <= g) {
        let dd = g - y;
        if (dd == 0) {
            return vec2<u32>(1u + ((w.x >> 9u) & 63u), 0u);
        }
        if (dd <= 3) {
            return vec2<u32>(1u + ((w.x >> 15u) & 63u), 1u);
        }
        if (dd <= 7) {
            return vec2<u32>(1u + (w.y & 63u), 1u);
        }
        // (deeper: stone, deepslate deeper still)
        return vec2<u32>(select(13u, 19u, dd > 16 + i32(fh21(c.xz + vec2<f32>(5.0)) * 4.0)), 1u);
    }
    let up = y - g;
    let log = (w.y >> 6u) & 63u;
    if (log > 0u && up <= i32((w.y >> 12u) & 15u)) {
        return vec2<u32>(1u + log, 2u);
    }
    let leaf = (w.y >> 16u) & 63u;
    if (leaf > 0u && up >= i32((w.y >> 22u) & 15u) && up <= i32((w.y >> 26u) & 15u)) {
        // (leaves, ragged: a few gaps in them)
        if (fh31(c + vec3<f32>(0.0, 31.0, 0.0)) < 0.16) {
            return vec2<u32>(0u);
        }
        return vec2<u32>(1u + leaf, 3u);
    }
    return vec2<u32>(0u);
}
// A block's colour on face `fn` (its normal, along an axis) at `f` within it (0..1 each way), at cell `c`, as the game's
// own blocks look: the material's colour varying a little block to block and texel to texel (the texels fading out
// once they are smaller than a pixel: `pw` a pixel's size, in blocks), the grass's fringe on the sides of its block,
// snow on it, bark streaks and log rings. sRGB.
fn sh_block_col(cell: vec2<u32>, w: vec3<u32>, c: vec3<f32>, fnrm: vec3<f32>, f: vec3<f32>, pw: f32) -> vec3<f32> {
    var m = sh_mat(cell.x - 1u);
    // (tinted as the game tints it there: grass by the biome's grass colour, leaves by its foliage colour)
    if (m.tint == 1u) {
        m.top = m.top * sh_565(w.z & 0xffffu, vec3<f32>(0.569, 0.741, 0.349));
    } else if (m.tint == 2u) {
        m.top = m.top * sh_565(w.z >> 16u, vec3<f32>(0.467, 0.671, 0.184));
        m.side = m.top;
    }
    let topf = fnrm.y > 0.5;
    var col = select(m.side, m.top, topf || fnrm.y < -0.5);
    // (the texel it is in on that face)
    var uv = f.xz;
    if (abs(fnrm.x) > 0.5) {
        uv = f.zy;
    } else if (abs(fnrm.z) > 0.5) {
        uv = f.xy;
    }
    let tx = floor(uv * 16.0);
    let tex = fh31(vec3<f32>(tx, 7.0) + c * vec3<f32>(1.31, 2.17, 0.73)) - 0.5;
    let texk = 1.0 - smoothstep(0.03, 0.09, pw);
    if (m.kind == 4u && cell.y == 0u && !topf && fnrm.y > -0.5) {
        // (grassy: its sides the dirt, with the grass's fringe hanging over the top)
        let fringe = 0.82 - 0.12 * step(0.5, fh21(vec2<f32>(tx.x, c.x + c.z * 3.0)));
        if (uv.y > fringe) {
            col = m.top;
        }
    }
    if (m.kind == 2u && !(topf || fnrm.y < -0.5)) {
        // (bark: streaks up the log)
        col = col * (0.85 + 0.3 * fh21(vec2<f32>(tx.x, c.x * 7.0 + c.z)) * texk + 0.15 * (1.0 - texk));
    }
    if (cell.y == 0u && (w.x >> 30u & 1u) == 1u) {
        // (snow lying on it: its top white, a rim of white down its sides)
        if (topf || uv.y > 0.86) {
            col = vec3<f32>(0.95, 0.98, 0.99);
        }
    }
    let blockv = (fh31(c) - 0.5) * m.var_;
    let leafk = select(1.0, 1.8, m.kind == 1u);
    // (leaves: the darker inside of the tree showing through their gaps)
    let leafd = select(1.0, 0.82, m.kind == 1u);
    return col * leafd * (1.0 + blockv + tex * m.var_ * 0.9 * leafk * texk);
}

// ---- the cracks: they race out from the middle in spurts (sinkhole.rs's sh_spurts), along the lines the slabs will
//      break on, thin at first, widening into dark gaps as the slab each side is about to go ----------------------------
fn sh_spurt_t(i: i32, seed: u32) -> f32 {
    return 1.0 + 6.4 * (f32(i) + 0.15 + 0.7 * mh(u32(i), seed, 0x7c0u)) / f32(SH_SPURTS);
}
fn sh_spurt_r(i: i32) -> f32 {
    return SH_R * 1.3 * pow(f32(i + 1) / f32(SH_SPURTS), 0.85);
}
// When the cracks reach `rr` out (the radius over the lag at that angle): in the spurt that runs over it, slowing as it
// stops.
fn sh_crack_at(rr: f32, seed: u32) -> f32 {
    let u = pow(clamp(rr / (SH_R * 1.3), 0.0, 1.0), 1.0 / 0.85) * f32(SH_SPURTS);
    let i = clamp(i32(ceil(u)) - 1, 0, SH_SPURTS - 1);
    let r0 = select(0.0, sh_spurt_r(i - 1), i > 0);
    let f = saturate((rr - r0) / max(sh_spurt_r(i) - r0, 1.0e-3));
    return sh_spurt_t(i, seed) + SH_SPURT * (1.0 - sqrt(1.0 - f));
}
// The nearest edge of the slab at polar (r, a), as sh_slab_at finds it: x the slab (-1 outside the rim), y the distance
// to the edge, z which side of the edge its slab is (1: the side that drops first), w along the edge (in blocks); and
// the edge's normal (xz).
struct ShEdge {
    k: f32,
    d: f32,
    first: f32,
    along: f32,
    n: vec2<f32>,
    t: f32,
}
fn sh_edge(r: f32, a: f32, rim: f32, seed: u32) -> ShEdge {
    var e: ShEdge;
    e.k = -1.0;
    if (r >= rim) {
        return e;
    }
    let nr = i32(sh_w(1u));
    var j = 0;
    loop {
        if (j + 1 >= nr || r < sh_ring_r(j + 1, a, rim)) {
            break;
        }
        j = j + 1;
    }
    let r0 = sh_ring_r(j, a, rim);
    let r1 = sh_ring_r(j + 1, a, rim);
    let b = SH_RG + u32(j) * SH_RW;
    let n = i32(sh_w(b + 2u));
    let th0 = sh_w(b + 3u);
    let off = i32(sh_w(b + 4u));
    let u = fract((a - th0) / TAU) * f32(n);
    let m0 = min(i32(floor(u)), n - 1);
    let jit0 = 0.35 * (mh(u32(m0 % n), seed, 0x710u + u32(j)) - 0.5);
    let jit1 = 0.35 * (mh(u32((m0 + 1) % n), seed, 0x710u + u32(j)) - 0.5);
    var m = m0;
    var e0 = f32(m0) + jit0;
    var e1 = f32(m0 + 1) + jit1;
    if (u < e0) {
        m = (m0 + n - 1) % n;
        e1 = e0;
        e0 = f32(m0 - 1) + 0.35 * (mh(u32((m0 + n - 1) % n), seed, 0x710u + u32(j)) - 0.5);
    } else if (u >= e1) {
        m = (m0 + 1) % n;
        e0 = e1;
        e1 = f32(m0 + 2) + 0.35 * (mh(u32((m0 + 2) % n), seed, 0x710u + u32(j)) - 0.5);
    }
    let ds0 = (u - e0) / f32(n) * TAU * r;
    let ds1 = (e1 - u) / f32(n) * TAU * r;
    let din = select(1.0e4, r - r0, j > 0);
    let dout = r1 - r;
    let k = off + m;
    e.k = f32(k);
    e.t = sh_w(SH_SB + u32(k) * SH_SW + 6u);
    let er = vec2<f32>(cos(a), sin(a));
    let et = vec2<f32>(-er.y, er.x);
    e.d = min(min(ds0, ds1), min(din, dout));
    if (e.d == dout) {
        // (its outer edge: the slab inside goes first)
        e.n = er;
        e.first = 1.0;
        e.along = a * r1;
    } else if (e.d == din) {
        e.n = er;
        e.first = 0.0;
        e.along = a * r0;
    } else {
        // (a side: which side drops first, the edge's own)
        let edge = select(m + 1, m, ds0 < ds1);
        let lead = step(0.5, mh(u32(edge % n), seed, 0x7c5u + u32(j)));
        e.n = et;
        e.first = select(1.0 - lead, lead, ds0 < ds1);
        e.along = r + 37.0 * f32(edge);
    }
    return e;
}

// ---- dust: what the collapse throws up out of the pit and rolls out low over the land, and the puff of the give --
fn sh_dust(p: vec3<f32>, time: f32, rimm: f32) -> f32 {
    let r = length(p.xz);
    var d = 0.0;
    // the give's puff, then the sag's
    let tg = time - SH_GIVE;
    if (tg > 0.0 && tg < 6.0) {
        let rr = 14.0 + 10.0 * (1.0 - exp(-tg * 1.5));
        d = d + exp(-tg * 0.7) * smoothstep(rr, rr * 0.5, r) * smoothstep(10.0 + 6.0 * tg, 0.0, p.y + 4.0) * 0.9;
    }
    let tc = time - SH_C0;
    if (tc > 0.0) {
        let env = smoothstep(0.0, 1.5, tc) * (1.0 - smoothstep(12.0, SH_END - SH_C0, tc));
        // out of the pit: boiling up where the land has gone, higher and higher, thinning as it climbs
        let reach = min(sh_reached(time), SH_R * 1.12) + 6.0;
        let H = 18.0 + 75.0 * (1.0 - exp(-tc / 6.0));
        let plume = smoothstep(reach, reach - 25.0, r) * smoothstep(H, H * 0.3, p.y) * smoothstep(-70.0, -20.0, p.y);
        // rolling out over the land, low, from the rim
        let out = rimm + 90.0 * (1.0 - exp(-max(time - (SH_C0 + 3.0), 0.0) / 6.0));
        let hk = 5.0 + 7.0 * smoothstep(rimm, out, r);
        let skirt = smoothstep(rimm - 20.0, rimm, r) * smoothstep(out, out - 40.0, r) * smoothstep(hk, 0.0, p.y) * step(-2.0, p.y) * (1.0 - 0.6 * smoothstep(rimm, out, r));
        let late = 1.0 - smoothstep(4.0, 14.0, tc) * smoothstep(-10.0, 30.0, p.y) * 0.7;
        d = d + env * late * (plume * 1.0 + skirt * 0.6);
    }
    if (d < 0.003) {
        return 0.0;
    }
    let q = p * 0.045 + vec3<f32>(0.0, -time * 0.18, 0.0) + vec3<f32>(time * 0.05, 0.0, 0.0);
    let n = 0.62 * fvnoise3(q) + 0.38 * fvnoise3(q * 2.3 + vec3<f32>(5.1, 1.3 - time * 0.2, 7.7));
    return d * smoothstep(0.32, 0.8, n) * 2.0;
}

fn sinkhole(in: StageIn) -> vec4<f32> {
    let uv = in.uv;
    let time = now();
    let cam = frame.camera_position.xyz;
    let k = intensity_v();
    let seed = u32(seed_v());
    let px_a = frame.view_params.w / frame.resolution.y;      // (the angle a pixel spans)
    let anc = anchor_xz();
    let gy = target_y();
    let C = vec3<f32>(anc.x, gy, anc.y) - cam;              // the pit's middle, on the target's ground
    let n_slabs = sh_count();
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);

    let d = depth_at(uv);
    let sky = is_sky(d);
    let rel = world_offset(uv, select(d, 0.5, sky));
    var scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv, 0.5));
    let scene = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb);
    var col = scene;
    let Q = rel - C;                                          // the scene's point from the pit's middle
    let rq = length(Q.xz);
    let aq = atan2(Q.z, Q.x);
    let rimq = sh_rim(aq);
    let Ls = normalize(select(vec3<f32>(0.3, 1.0, 0.2), sun, sun.y > 0.05));
    let amb = mix(vec3<f32>(0.03, 0.035, 0.05), vec3<f32>(0.32, 0.36, 0.44), day);
    let sunc = vec3<f32>(1.25, 1.18, 1.05) * day;

    // (a pixel's footprint on the land, from the derivatives of where it is: here, in uniform control flow)
    let dQx = dpdx(Q);
    let dQy = dpdy(Q);
    // (the surface's normal there, from them, towards the eye)
    var nQ = normalize(cross(dQx, dQy) + vec3<f32>(0.0, 1.0e-9, 0.0));
    if (dot(nQ, rel) > 0.0) {
        nQ = -nQ;
    }
    let dy0 = gy - (block_y() + 1.0);                         // the target's ground over its block's top
    let fade = 1.0 - smoothstep(SH_LEN - SH_FADE, SH_LEN, time);
    let fade_e = fade * fade * (3.0 - 2.0 * fade);

    // ---- on the land: the cracks, and the pit's darkness where it has been dug -----------------------------------
    if (!sky && n_slabs > 0 && rq < SH_R * 1.4) {
        let pw = scene_len * px_a;
        // (the land's column here, looked up a little inside the block the pixel is on, so a pixel on a block's face
        // never flips between the columns either side of it; is this its ground's top? With a tolerance that grows
        // with the distance, as the depth's precision falls, and softly, so nothing flickers; only on top faces, and
        // never across water)
        let Qs = Q - nQ * 0.08;
        let cw = sh_colw(i32(floor(Qs.x + 0.5)) + SH_G, i32(floor(Qs.z + 0.5)) + SH_G);
        var gw = 1.0 - smoothstep(2.5, 3.5, abs(Q.y));
        if (cw.x >> 31u == 1u) {
            let hy = f32(sh_col_h(cw)) - dy0;
            let tol = 0.15 + scene_len * 0.004;
            gw = (1.0 - smoothstep(hy + tol, hy + 2.0 * tol + 0.1, Qs.y)) * smoothstep(hy - 1.1 - tol, hy - 0.95, Qs.y)
                * select(1.0, 0.0, ((cw.y >> 30u) & 1u) == 1u);
        }
        gw = gw * smoothstep(0.5, 0.8, nQ.y);
        let on_ground = gw > 0.01;
        // the cracks, along the slabs' edges, from 1 s, racing out in spurts, the fingers running ahead here and
        // lagging there; thin at first, widening, then gaping as the slabs each side are about to go
        if (time > 0.9 && on_ground && time < sh_front(rq) + 0.2) {
            let e = sh_edge(rq, aq, rimq, seed);
            let lag = 0.8 + 0.45 * fvnoise(vec2<f32>(cos(aq), sin(aq)) * 2.3 + vec2<f32>(f32(seed % 97u) * 0.37));
            let age = time - sh_crack_at(rq / lag, seed);
            if (e.k >= 0.0 && age > 0.0 && time < e.t - SH_DIG + 0.02) {
                let o = smoothstep(e.t - 1.9, e.t - 0.1, time);
                var w = 0.06 + 0.42 * pow(saturate(age / 2.2), 0.7) + 0.2 * smoothstep(SH_GIVE - 0.5, SH_GIVE + 1.5, time) + 0.8 * o * o;
                // (the footprint across the crack, from the derivatives; at a silhouette it is huge, and it fades out)
                let n3 = vec3<f32>(e.n.x, 0.0, e.n.y);
                let fp = max(length(vec2<f32>(dot(dQx, n3), dot(dQy, n3))), pw * 0.35);
                // (its edges broken and wandering, less so where a pixel is wider than the wander)
                let wq = Q.xz + vec2<f32>(f32(seed % 61u) * 7.3, 0.0);
                let jag = (fvnoise(wq * 0.42) - 0.5) * (0.5 + 0.9 * w) + (fvnoise(wq * 1.6 + vec2<f32>(4.1, 9.3)) - 0.5) * (0.25 + 0.5 * w) * saturate(1.5 - fp * 1.5);
                let d = e.d + jag;
                // (never thinner on screen than most of a pixel: drawn wider and fainter instead, so it neither
                // breaks up nor shimmers; and faded out far off)
                let wd = max(w, 0.7 * fp);
                let cov = saturate((wd - d) / fp + 0.5) * sqrt(w / wd) * (1.0 - smoothstep(1.5, 4.0, fp)) * (1.0 - smoothstep(380.0, 650.0, scene_len));
                // (the side that drops first stepped down a little, in shadow beside the gap)
                let drop = (0.25 + 0.7 * o) * e.first;
                let band = saturate((w + drop - d) / fp + 0.5) * (1.0 - cov) * step(0.01, drop) * (1.0 - smoothstep(1.5, 4.0, fp));
                // (dust puffing up out of it as it opens, a second or so)
                let puff = exp(-age * 1.6) * saturate((w * 2.5 + 1.5 - e.d) / 1.5);
                col = mix(col, vec3<f32>(0.22, 0.19, 0.16) * (amb + sunc * 0.5), 0.35 * puff * k * gw);
                col = col * (1.0 - 0.45 * band * k * gw);
                col = mix(col, vec3<f32>(0.006, 0.005, 0.005), 0.94 * cov * k * gw);
            }
        }
        // and round the rim once it has gone: the land there torn along it
        let sl = sh_slab_at(rq, aq, rimq, seed);
        if (sl.x < 0.0 && time > sh_front(rimq) && sl.y < 14.0 && on_ground) {
            let wq = Q.xz * 0.08;
            let wob = (fvnoise(wq + vec2<f32>(3.0)) - 0.5) * 5.0;
            let dd = abs(fract((sl.y + wob) / 4.6 + 0.3) - 0.5) * 4.6;
            let w = 0.12 * fvnoise(Q.xz * 0.15 + vec2<f32>(9.0)) * smoothstep(14.0, 4.0, sl.y);
            let fp = max(length(vec2<f32>(length(dQx.xz), length(dQy.xz))) * 0.7, pw * 0.35);
            let wd = max(w, 0.7 * fp);
            let crack = saturate((wd - dd) / fp + 0.5) * (w / max(wd, 1.0e-4)) * (1.0 - smoothstep(1.5, 4.0, fp));
            col = col * (1.0 - 0.88 * crack * k * fade_e * gw);
        }
        // the pit, where it has been dug: dark, darker the deeper, a cold haze down in it; and, until it is dug on down,
        // its floor 25 down hidden in murk; fading slowly away over the strike's last seconds (the real pit's walls
        // darken with depth on their own)
        let into = rimq + 7.0 - rq;
        if (into > 0.0 && Q.y < -2.5 && time > sh_front(rq) - SH_DIG) {
            let dep = -Q.y;
            var dark = pow(smoothstep(2.0, 108.0, dep), 0.7);
            dark = max(dark, smoothstep(13.0, 24.0, dep) * 0.93 * (1.0 - smoothstep(SH_DEEP0 + 2.0, SH_DEEP0 + 7.0, time)));
            let haze = mix(vec3<f32>(0.012, 0.012, 0.014), vec3<f32>(0.05, 0.05, 0.055), day);
            col = mix(col, haze, dark * 0.97 * k * fade_e);
        }
    }

    // ---- the slabs: solid, the nearest drawn, hidden by anything nearer; each from the moment its land is dug, in its
    //      place, as the land it stands in for was (the land's own blocks, when it was read), then letting go ---------
    var hit_t = 1.0e9;
    var hit_c = vec3<f32>(0.0);
    var hit_b = 0u;
    var hit_base = vec3<f32>(0.0);
    var hit_below = 0.0;
    if (n_slabs > 0 && time > SH_C0 - SH_DIG - 0.1 && time < 16.6 + SH_FALL) {
        for (var i = 0; i < n_slabs; i = i + 1) {
            let b = SH_SB + u32(i) * SH_SW;
            let s = time - sh_w(b + 6u);
            if (s < -SH_DIG || s > SH_FALL) {
                continue;
            }
            let ps = sh_pose(b, i, s, C);
            let real = sh_w(b + 15u) > 0.5;
            // (a sphere round it first: round the land it carries, or round its block of ground)
            var cc = ps.o + ps.drop;
            var rad = 0.5 * length(vec2<f32>(sh_w(b + 5u) - sh_w(b + 2u), (sh_w(b + 1u) - sh_w(b)) * sh_w(b + 5u))) + sh_w(b + 10u) + 4.0;
            // (its frame into the land's square)
            let mq = (sh_corner(sh_w(b + 2u), sh_w(b)) + sh_corner(sh_w(b + 3u), sh_w(b + 1u)) + sh_corner(sh_w(b + 5u), sh_w(b + 1u))
                + sh_corner(sh_w(b + 4u), sh_w(b))) * 0.25;
            let off = vec3<f32>(mq.x + 0.5 + f32(SH_G), sh_w(b + 7u) + dy0, mq.y + 0.5 + f32(SH_G));
            if (real) {
                let lo = vec3<f32>(sh_w(b + 18u), sh_w(b + 22u), sh_w(b + 19u));
                let hi = vec3<f32>(sh_w(b + 20u) + 1.0, sh_w(b + 23u), sh_w(b + 21u) + 1.0);
                cc = sh_from(ps, 0.5 * (lo + hi) - off);
                rad = 0.5 * length(hi - lo) + 1.0;
            }
            let tc = dot(cc, rd);
            if (dot(cc, cc) - tc * tc > rad * rad || tc + rad < 0.0 || tc - rad > min(hit_t, scene_len + 1.0)) {
                continue;
            }
            let o = sh_to(ps, vec3<f32>(0.0));
            let dl = sh_dir_to(ps, rd);
            var t_hit = 1.0e9;
            var nl = vec3<f32>(0.0, 1.0, 0.0);
            var base = vec3<f32>(0.0);
            if (real) {
                let vx = sh_vox(b, i, o, dl, off, min(hit_t, scene_len + 0.3), px_a);
                if (vx.t >= 1.0e8) {
                    continue;
                }
                t_hit = vx.t;
                nl = vx.n;
                base = vx.c;
            } else {
                // (its land not read: a block of ground, grass over dirt over stone, its top its ground's plane)
                let h = sh_hit(b, o, dl);
                if (h.y <= h.x || h.x <= 0.0 || h.x >= hit_t || h.x > scene_len + 0.7) {
                    continue;
                }
                t_hit = h.x;
                let q = o + dl * h.x;
                let sx = sh_w(b + 8u);
                let sz = sh_w(b + 9u);
                let dtop = sx * q.x + sz * q.z - q.y;
                nl = normalize(vec3<f32>(-sx, 1.0, -sz));
                if (h.z > 0.5 && h.z < 1.5) {
                    nl = vec3<f32>(0.0, -1.0, 0.0);
                } else if (h.z > 1.5) {
                    let c = array<vec2<f32>, 4>(sh_corner(sh_w(b + 2u), sh_w(b)), sh_corner(sh_w(b + 3u), sh_w(b + 1u)),
                        sh_corner(sh_w(b + 5u), sh_w(b + 1u)), sh_corner(sh_w(b + 4u), sh_w(b)));
                    let fi = i32(h.z) - 2;
                    let e = c[(fi + 1) % 4] - c[fi];
                    var n2 = normalize(vec2<f32>(e.y, -e.x) + vec2<f32>(1.0e-7));
                    let m = (c[0] + c[1] + c[2] + c[3]) * 0.25;
                    if (dot(n2, c[fi] - m) < 0.0) {
                        n2 = -n2;
                    }
                    nl = vec3<f32>(n2.x, 0.0, n2.y);
                }
                base = linear_to_srgb(sh_earth(dtop, h.z, q + ps.o + cam, f32(i), day));
            }
            hit_t = t_hit;
            // (lit as the game lights its blocks: by the face, the top brightest, the sides less, the underside least,
            // turning with the slab; and by the time of day)
            let nw = sh_dir_from(ps, nl);
            let shade = 0.6 * nw.x * nw.x + 0.8 * nw.z * nw.z + select(0.5, 1.0, nw.y > 0.0) * nw.y * nw.y;
            // (the sky's light by the time of day, as the game darkens it towards night: 0.25 is noon)
            hit_b = b;
            hit_base = base * shade;
            hit_below = (gy + sh_w(b + 7u)) - (cam + rd * t_hit).y;
        }
    }
    if (hit_t < 1.0e8) {
        // lit as the real land round it is lit, this frame: the scene's own colour of the tops of a dozen columns of
        // untouched ground beside where the slab lay (in the land read, seen, and where they are expected), over what
        // the land's colours make of them, channel by channel; whatever the hour, the weather, the brightness
        // setting or a torch near. Where none is seen, by the sky's light for the time of day (0.25 noon).
        let cal = sh_calib(hit_b, C, dy0);
        let skyk = saturate(cos((frame.time.y - 0.25) * TAU) * 2.0 + 0.5);
        let light = mix(vec3<f32>(mix(0.2, 1.0, skyk)), cal.xyz, smoothstep(1.0, 4.0, cal.w));
        var c = srgb_to_linear(saturate(hit_base * light));
        // (lit as the land round it while it tips and is still at the rim; into the pit's shadow only as it sinks
        // below where its ground was, and its dark deeper still, by how deep, eased)
        let shadow = smoothstep(3.0, 22.0, hit_below);
        c = mix(c, c * 0.3, shadow * shadow * (3.0 - 2.0 * shadow) * 0.7);
        let pit = smoothstep(12.0, 75.0, hit_below);
        c = mix(c, vec3<f32>(0.012, 0.012, 0.014), pit * pit * (3.0 - 2.0 * pit) * 0.95);
        hit_c = c;
        col = mix(col, hit_c, k);
        scene_len = hit_t;
    }

    // ---- water pouring over the rim where the pit cut a river or a lake: from the water's own surface, over the
    //      rim as it wanders, curving over a lip and falling faster and faster, a little out from the wall; in strands
    //      of the water's own blue (the biome's tint) with darker gaps between, breaking up into white lower down, mist
    //      where it goes into the dark ---------------------------------------------------------------------------------
    let nwf = i32(sh_w(SH_WF));
    if (n_slabs > 0 && nwf > 0) {
        let wt = SH_WF + 1u < arrayLength(&mod_data);
        var tint = vec3<f32>(0.247, 0.463, 0.894);
        if (wt && mod_data[SH_WF + 1u] != 0u) {
            let c = mod_data[SH_WF + 1u];
            tint = vec3<f32>(f32((c >> 16u) & 255u), f32((c >> 8u) & 255u), f32(c & 255u)) / 255.0;
        }
        // (the game's water: its grey texture tinted, darker for the depth showing through)
        let blue = srgb_to_linear(tint * 0.62);
        for (var w = 0; w < min(nwf, 6); w = w + 1) {
            let b = SH_WF + 4u + u32(w) * 4u;
            let ac = sh_w(b);
            let hw = sh_w(b + 1u);
            let ytop = sh_w(b + 2u) - 0.12;
            let s = time - sh_w(b + 3u);
            if (s < 0.0) {
                continue;
            }
            // (its front falling, faster and faster)
            let fall = min(0.5 * 30.0 * s * s, 160.0);
            // the sheet: r = the rim there, less how far it has come out from the wall by the depth it has fallen
            // (a lip over the edge, then a slight outward arc); met by a few steps from where the ray meets the
            // cylinder through the rim at its middle, on both sides of it
            let R0 = sh_rim(ac) - 0.8;
            let a2 = max(dot(rd.xz, rd.xz), 1.0e-8);
            let bb = -dot(rd.xz, C.xz);
            let cc2 = dot(C.xz, C.xz) - R0 * R0;
            let disc = bb * bb - a2 * cc2;
            if (disc <= 0.0) {
                continue;
            }
            for (var side = 0; side < 2; side = side + 1) {
                var t = (-bb + select(-1.0, 1.0, side == 1) * sqrt(disc)) / a2;
                if (t <= 0.0) {
                    continue;
                }
                for (var it = 0; it < 4; it = it + 1) {
                    let X = rd * t - C;
                    let d = max(ytop - X.y, 0.0);
                    let rr = sh_rim(atan2(X.z, X.x)) + 0.35 - 0.9 * sqrt(d) - 0.04 * d;
                    let f = length(X.xz) - rr;
                    // (the ray's rate across the sheet, roughly: along the radius)
                    let dr = dot(normalize(X.xz), rd.xz);
                    t = t - f / select(dr, sign(dr) * 0.05, abs(dr) < 0.05);
                }
                if (t <= 0.0 || t > scene_len + 0.2) {
                    continue;
                }
                let X = rd * t - C;
                let a = atan2(X.z, X.x);
                let da = abs(atan2(sin(a - ac), cos(a - ac)));
                let d = ytop - X.y;
                let along = (a - ac) * sh_rim(ac);
                let edge = hw * (0.85 + 0.2 * fvnoise(vec2<f32>(d * 0.08, f32(w) * 3.0)) + 0.25 * (fvnoise(vec2<f32>(d * 0.5 - time * 3.0, f32(w) * 7.0 + sign(a - ac))) - 0.5));
                if (da > edge || d < -0.05 || d > fall) {
                    continue;
                }
                // (strands of different widths, sliding down faster as it falls; their gaps darker, showing through)
                let q = 4.0 * sqrt(max(d, 0.0)) - time * 5.5;
                let pwf = t * px_a;
                let st1 = fvnoise(vec2<f32>(along * 0.9, q * 0.35));
                let st2 = fvnoise(vec2<f32>(along * 2.6 + 7.0, q * 0.9));
                let st3 = fvnoise(vec2<f32>(along * 6.0 + 3.0, q * 2.2)) * saturate(1.5 - pwf * 3.0);
                let strand = 0.5 * st1 + 0.32 * st2 + 0.18 * (st3 + 0.5 * (1.0 - saturate(1.5 - pwf * 3.0)));
                let body = smoothstep(0.28, 0.62, strand);
                // (white where it breaks up, lower down, and on the strands' crests; mist lower still)
                let foam = smoothstep(6.0, 40.0, d) * smoothstep(0.55, 0.8, strand) + 0.35 * smoothstep(0.7, 0.9, st3) * smoothstep(1.0, 8.0, d);
                let lip = 1.0 - smoothstep(0.0, 1.2, d);
                let shade = mix(0.75, 1.0, lip);
                var wc = mix(blue * shade, vec3<f32>(0.85, 0.88, 0.9) * 0.9, saturate(foam)) * (amb * 1.4 + sunc * 0.75);
                // (into the pit's dark, and spray where it goes)
                let deep = pow(smoothstep(4.0, 110.0, d), 0.7);
                wc = mix(wc, vec3<f32>(0.03, 0.035, 0.04), deep * 0.85 * fade_e);
                var alpha = mix(0.35, 0.85, body) * smoothstep(edge, edge * 0.6, da);
                // (its front ragged as it first pours, and mist where it thins out deep down)
                alpha = alpha * smoothstep(fall, fall - 6.0 - 4.0 * st1, d) * (1.0 - 0.5 * smoothstep(60.0, 140.0, d));
                col = mix(col, wc, saturate(alpha) * k * fade_e);
                let mist = smoothstep(30.0, 120.0, d) * 0.25 * (0.5 + st2);
                col = mix(col, vec3<f32>(0.5, 0.52, 0.55) * (amb + sunc * 0.3), mist * k * fade_e * smoothstep(edge * 1.3, edge * 0.5, da));
            }
        }
    }

    // ---- the birds going up off the land as it starts to shake, scattering away from it ------------------------------
    if (time > 0.8 && time < 10.0) {
        for (var i = 0; i < SH_BIRDS; i = i + 1) {
            let h = vec3<f32>(mh(u32(i), seed, 0x7b0u), mh(u32(i), seed, 0x7b1u), mh(u32(i), seed, 0x7b2u));
            let t0 = 1.0 + 1.6 * h.x + 0.6 * h.z;
            let s = time - t0;
            if (s < 0.0) {
                continue;
            }
            let a = h.y * TAU;
            let dir = vec3<f32>(cos(a), 0.0, sin(a));
            let start = C + dir * (25.0 + 110.0 * h.z) + vec3<f32>(0.0, 4.0 + 6.0 * h.x, 0.0);
            let pos = start + dir * (9.0 * s) + vec3<f32>(0.0, 6.0 * s - 0.25 * s * s + 1.5 * sin(s * 2.0 + h.x * 6.0), 0.0);
            let dist = length(pos);
            if (dist > scene_len) {
                continue;
            }
            let P = project_rel(pos);
            if (P.z < 0.0) {
                continue;
            }
            let span = max(0.45 / (dist * px_a), 1.2);
            let pxl = (uv - P.xy) * frame.resolution.xy;
            let flap = sin(time * (13.0 + 4.0 * h.x) + h.z * 20.0);
            let wx = abs(pxl.x) / span;
            let yv = pxl.y / span + (0.35 + 0.35 * flap) * (1.0 - wx) - 0.2;
            let m = step(wx, 1.0) * saturate(1.0 - abs(yv) * 1.8 / max(0.25, 1.0 / span));
            // (one passing close to the eye left out: it would be a black scrawl across the view)
            col = mix(col, vec3<f32>(0.03, 0.03, 0.035), m * 0.9 * k * (1.0 - smoothstep(7.0, 10.0, time)) * smoothstep(12.0, 30.0, dist));
        }
    }

    // ---- the dust, marched along the view ray through where it can be -------------------------------------------
    if (time > SH_GIVE && time < SH_END) {
        let Rb = SH_R * 1.15 + 95.0;
        let a2 = max(dot(rd.xz, rd.xz), 1.0e-8);
        let bb = -dot(rd.xz, C.xz);
        let cc2 = dot(C.xz, C.xz) - Rb * Rb;
        let disc = bb * bb - a2 * cc2;
        if (disc > 0.0) {
            var t0 = (-bb - sqrt(disc)) / a2;
            var t1 = (-bb + sqrt(disc)) / a2;
            let y0 = -70.0;
            let y1 = 100.0;
            if (abs(rd.y) > 1.0e-5) {
                let ya = (C.y + y0) / rd.y;
                let yb = (C.y + y1) / rd.y;
                t0 = max(t0, min(ya, yb));
                t1 = min(t1, max(ya, yb));
            }
            t0 = max(t0, 0.0);
            t1 = min(t1, scene_len);
            if (t1 > t0) {
                let N = 22;
                let dt = (t1 - t0) / f32(N);
                var tr = 1.0;
                var acc = vec3<f32>(0.0);
                let j = ign(in.position.xy + vec2<f32>(fract(time * 7.0) * 61.0, 0.0));
                let rimm = SH_R;
                for (var i = 0; i < N; i = i + 1) {
                    let t = t0 + dt * (f32(i) + j);
                    let p = rd * t - C;
                    let den = sh_dust(p, time, rimm);
                    if (den <= 0.0) {
                        continue;
                    }
                    let a = 1.0 - exp(-den * dt * 0.025);
                    // (lit from above, darker low down and deep in the pit)
                    let up = smoothstep(-40.0, 40.0, p.y);
                    let dc = mix(vec3<f32>(0.05, 0.043, 0.036), vec3<f32>(0.5, 0.44, 0.36), up) * (amb * 1.3 + sunc * 0.55 * up);
                    acc = acc + tr * a * dc;
                    tr = tr * (1.0 - a);
                    if (tr < 0.02) {
                        break;
                    }
                }
                col = mix(col, col * tr + acc, k);
            }
        }
    }

    // ---- a faint dimming of the light while the dust is up -------------------------------------------------------
    let murk = smoothstep(SH_C0, SH_C0 + 3.0, time) * (1.0 - smoothstep(20.0, SH_END, time)) * fade_e;
    col = col * (1.0 - 0.12 * murk * k);
    let srgb = linear_to_srgb(max(col, vec3<f32>(0.0)));
    if (capture() > 2.5) {
        let sp = floor(in.position.xy);
        let chk = fract((sp.x + sp.y) * 0.5);
        let ycc_y = srgb.g * 0.5 + (srgb.r + srgb.b) * 0.25;
        let ycc_co = srgb.r - srgb.b;
        let ycc_cg = srgb.g - (srgb.r + srgb.b) * 0.5;
        return vec4<f32>(ycc_y, select(ycc_cg, ycc_co, chk < 0.25) * 0.5 + 0.5, 0.0, 1.0);
    }
    return vec4<f32>(srgb, 1.0);
}

@fragment
fn fs_main(in: StageIn) -> @location(0) vec4<f32> {
    return sinkhole(in);
}
