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

// Orbital Laser's post pass for the Supervolcano (laser 14), built as the Nuke's: strike.wgsl up to its fs_main, then
// this file and volcano_mount.wgsl. Validate with tools/check-shader.sh.

// ---- laser 14: the supervolcano ----
// A satellite's beam melting a hole (`vc_opening`), the tremor, the mount rising round it (volcano_mount.wgsl), then one
// soft volume: a density falling off through a surface bulged by lumps on lumps (`vc_sdf`, sphere-traced only over empty air), lit by looks towards the light. The blast
// (`vc_col`), the shock (`vc_shells`, `vc_dust`), rock (`vc_spray`); fire in the trunk (`vc_heat`); bombs on ropes of
// smoke (`vc_bombs_smoke`); the umbrella over the sky, lightning in it (`vc_umb`, `vc_flash`, `vc_bolts`); noon gone dark
// (`vc_dim`). The column falls back (`VC_COLLAPSE`) into a wall of ash (`vc_flow`) that engulfs the player and lifts into
// a ceiling; then a dim world and a blood-red sun as the ash thins, gone by VC_LEN.
// Keep the VC_* beats in step with strike/volcano.rs's, which gives the table: the bombs, the land's height.
const VC_LEN: f32 = 88.0;
const VC_HIT: f32 = 4.5;           // the satellite's beam fires (the opening: vc_opening)
const VC_CRACK: f32 = 6.0;         // the ring cracks through
const VC_ERUPT: f32 = 18.0;        // the eruption
const VC_LIGHT: f32 = 26.0;        // the plume's lightning
const VC_DARK: f32 = 36.0;         // the umbrella out over the land
const VC_COLLAPSE: f32 = 50.0;     // the column falls back, the flows set off from the ring
const VC_LIFT: f32 = 66.0;         // the flows lift into new clouds
const VC_RED: f32 = 80.0;          // the ash thinning round a red sun
const VC_RING: f32 = 280.0;        // the ring of vents' radius
const VC_SPREAD: f32 = 28.0;       // the head reaches the ceiling and starts to spread
const VC_P: f32 = 6.0;             // how long the lumps are carried before they are let go
const VC_HU: f32 = 1500.0;         // the umbrella's middle over the land
const VC_V: f32 = 343.0;           // the pressure ring's speed (the sound's)
const VC_DM: f32 = 190.0;          // the most the lumps stand out of a smooth body
const VC_DUST: f32 = 8.0;          // the dust the shock lifts has settled
const VC_ST: f32 = 1.35;           // the march's stride
const VC_ST_AIR: f32 = 2.5;        // and through the air the wall has emptied
const VC_HOLD: f32 = 0.3;          // the big lumps kept for this share of the way off the surface
const VC_BOMB: u32 = 16u;          // the table: the bombs from here, VC_BW words each
const VC_BW: u32 = 8u;
const VC_G: f32 = 28.0;
const VC_HF: u32 = 1024u;          // the land's height (volcano.rs's vc_hf_pack)

// gnoise3 with one hash a corner.
fn vc_gc(hx: u32, hy: u32, hz: u32, f: vec3<f32>) -> f32 {
    let h = pcg(hx ^ hy ^ hz);
    let g = vec3<f32>(f32(h >> 21u), f32((h >> 10u) & 2047u), f32(h & 1023u)) * vec3<f32>(2.0 / 2047.0, 2.0 / 2047.0, 2.0 / 1023.0) - 1.0;
    return dot(g, f);
}
fn vc_gn3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let c = bitcast<vec3<u32>>(vec3<i32>(i));
    let x0 = c.x * 73856093u;
    let x1 = x0 + 73856093u;
    let y0 = c.y * 19349663u;
    let y1 = y0 + 19349663u;
    let z0 = c.z * 83492791u;
    let z1 = z0 + 83492791u;
    let e = vec3<f32>(1.0, 0.0, 0.0);
    let n000 = vc_gc(x0, y0, z0, f);
    let n100 = vc_gc(x1, y0, z0, f - e.xyy);
    let n010 = vc_gc(x0, y1, z0, f - e.yxy);
    let n110 = vc_gc(x1, y1, z0, f - e.xxy);
    let n001 = vc_gc(x0, y0, z1, f - e.yyx);
    let n101 = vc_gc(x1, y0, z1, f - e.xyx);
    let n011 = vc_gc(x0, y1, z1, f - e.yxx);
    let n111 = vc_gc(x1, y1, z1, f - e.xxx);
    let a = mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y);
    let b = mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y);
    return mix(a, b, u.z) * 0.75 + 0.5;
}
fn vc_w(i: u32) -> f32 {
    if (i >= arrayLength(&mod_data)) {
        return 0.0;
    }
    return bitcast<f32>(mod_data[i]);
}
// The land at q (level, from the vent): its height over the vent's ground, smoothly between the heightfield's cells.
var<private> vc_hf_n: f32;
var<private> vc_hf_r: f32;
fn vc_land_set() {
    vc_hf_n = vc_w(VC_HF);
    vc_hf_r = vc_w(VC_HF + 1u);
    let n = u32(vc_hf_n + 0.5);
    if (vc_hf_n < 2.0 || arrayLength(&mod_data) < VC_HF + 8u + n * n) {
        vc_hf_n = 0.0;
    }
}
fn vc_land(q: vec2<f32>) -> f32 {
    let nf = vc_hf_n;
    if (nf < 2.0) {
        return 0.0;
    }
    let n = u32(nf + 0.5);
    let R = vc_hf_r;
    let step = 2.0 * R / (nf - 1.0);
    let fc = clamp((q + R) / step, vec2<f32>(0.0), vec2<f32>(nf - 1.001));
    let i0 = vec2<u32>(floor(fc));
    let t = fc - floor(fc);
    let base = VC_HF + 8u + i0.y * n + i0.x;
    let h = vec4<f32>(f32(mod_data[base] & 0xffffu), f32(mod_data[base + 1u] & 0xffffu), f32(mod_data[base + n] & 0xffffu), f32(mod_data[base + n + 1u] & 0xffffu));
    return mix(mix(h.x, h.y, t.x), mix(h.z, h.w, t.x), t.y) / 8.0 - 512.0;
}

// ---- the story's state at this moment, worked out once a pixel ----
struct VcS {
    t: f32,
    a: f32,      // since the eruption
    c: f32,      // since the collapse (under 0 before it)
    H: f32,      // the column's head over the land
    Hb: f32,     // the top of what is still standing of it, as it falls back
    Rt: f32,     // its radius at its head
    Rb: f32,     // the blast's radius over the land (the column's foot, later)
    Hd: f32,     // and its height
    dRb: f32,    // how fast the blast is spreading
    Ru: f32,     // the umbrella's radius
    dRu: f32,    // how fast it is spreading
    hu: f32,     // its middle: spreading out of the head under its top, rising to VC_HU
    rf: f32,     // the wall of ash's radius
    rfm: f32,    // and past it nothing
    dRf: f32,    // how fast it comes on
    ftop: f32,   // nothing of the flows stands over this
    cov: f32,    // how much of the light the umbrella stops
    thin: f32,   // 0 to 1: the ash thinning away at the end
    px: f32,     // the angle a pixel spans
    fine: f32,   // the march's pixel, in the picture's (2 at half size)
}
var<private> vs: VcS;
var<private> vc_px: vec2<f32>;

fn vc_front(c: f32) -> f32 {
    return VC_RING + 25.0 * c + 490.0 * (1.0 - exp(-c / 14.0));
}
fn vc_rr(hy: f32) -> f32 {
    return VC_RING - 155.0 * smoothstep(0.0, 190.0, hy);
}
fn vc_ww(hy: f32) -> f32 {
    return 76.0 + 0.52 * min(hy, 190.0) + 0.13 * clamp(hy - 190.0, 0.0, 330.0) + 0.24 * max(hy - 520.0, 0.0);
}
fn vc_set_state(time: f32) {
    var s: VcS;
    s.t = time;
    s.a = time - VC_ERUPT;
    s.c = time - VC_COLLAPSE;
    let a = max(s.a, 0.0);
    // (the blast: out fast and low, wider than it is tall, drawing in a little as the column takes it over)
    s.Rb = (300.0 + 400.0 * (1.0 - exp(-a / 2.8))) * (1.0 - 0.1 * smoothstep(10.0, 28.0, a));
    s.dRb = 143.0 * exp(-a / 2.8);
    s.Hd = 130.0 + 270.0 * (1.0 - exp(-a / 3.0));
    // (the column breaking up out of its middle a few seconds on)
    s.H = s.Hd + 1560.0 * (1.0 - exp(-max(a - 4.0, 0.0) / 7.5));
    s.Rt = 470.0 + 0.2 * min(s.H, 1500.0);
    s.Hb = s.H - 0.5 * 26.0 * max(s.c, 0.0) * max(s.c, 0.0) - 8.0 * max(s.c, 0.0);
    // (a gravity current: quick as the head first spreads, slowing as it thins; out past the horizon by the collapse)
    let u = max(time - VC_SPREAD, 0.0);
    s.Ru = 620.0 * smoothstep(0.0, 3.0, u) + 130.0 * pow(u, 1.28);
    s.dRu = 166.0 * pow(max(u, 0.01), 0.28);
    s.hu = VC_HU - 420.0 * (1.0 - smoothstep(VC_SPREAD - 1.0, VC_SPREAD + 7.0, time));
    s.rf = vc_front(max(s.c, 0.0));
    s.dRf = 25.0 + 35.0 * exp(-max(s.c, 0.0) / 14.0);
    s.rfm = s.rf + 230.0;
    s.ftop = 340.0 + 760.0 * smoothstep(VC_LIFT - 4.0, VC_RED - 2.0, time);
    s.thin = pow(smoothstep(VC_RED, VC_LEN - 0.6, time), 1.3);
    s.cov = smoothstep(2.0, 16.0, u) * (1.0 - s.thin);
    s.px = frame.view_params.w / frame.resolution.y;
    s.fine = 1.0;
    vs = s;
    vc_land_set();
}

// ---- the shapes: each one's smooth body, as a distance ----
fn vc_smax(a: f32, b: f32, k: f32) -> f32 {
    let h = max(k - abs(a - b), 0.0) / k;
    return max(a, b) + h * h * k * 0.25;
}
fn vc_smin(a: f32, b: f32, k: f32) -> f32 {
    let h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}
// The steam before the eruption: thin jets along the ring's crack. (The mount's hook.)
fn vc_steam(hy: f32, rho: f32, ang: f32) -> f32 {
    let st = saturate((vs.t - VC_CRACK) / (VC_ERUPT - VC_CRACK));
    let Hs = 12.0 + 50.0 * st;
    var W = 2.0 + 7.0 * st;
    let jets = smoothstep(0.0, 34.0, hy) * (1.0 - smoothstep(60.0, 240.0, hy));
    if (jets > 0.0) {
        let sc = 0.5 + 0.5 * cos(13.0 * ang + 2.0 * sin(3.0 * ang + 0.7) + hy * 0.004);
        W = W * mix(1.0, 0.72 + 0.5 * sc * sc, jets);
    }
    return vc_smax(abs(rho - VC_RING) - W, hy - Hs, 34.0) * 0.82;
}
// The eruption's body, solid: the blast, an ellipsoid over the land far wider than it is tall, and out of its middle a
// trunk half its width, flaring into the head that feeds the umbrella. After the collapse the trunk falls back on
// itself and the blast's foot sinks into the flows.
fn vc_col(q: vec3<f32>, rho: f32, ang: f32, land: f32) -> f32 {
    if (vs.t < VC_CRACK) {
        return 1.0e5;
    }
    // (its foot on the land, not at the vent's height: the land may lie well above or below it)
    var hy = q.y;
    if (hy < 700.0) {
        hy = hy - land * (1.0 - smoothstep(120.0, 700.0, hy));
    }
    if (vs.a < 0.0) {
        return vc_steam(hy, rho, ang);
    }
    let c = max(vs.c, 0.0);
    // (no lathe turned this: pushed out unevenly round its foot, its trunk lobed and twisting as it climbs)
    // (bursting out harder one way than another)
    let br = 0.12 * sin(2.0 * ang + 1.0) + 0.09 * sin(5.0 * ang + 0.4) + 0.05 * sin(11.0 * ang + 2.1);
    let Rb = vs.Rb * (1.0 + br);
    let tall = 0.34 * sin(3.0 * ang + 2.0) + 0.24 * sin(7.0 * ang + 0.6) + 0.16 * sin(13.0 * ang + 4.0);
    let Hd = vs.Hd * (1.0 - 0.96 * smoothstep(3.0, 15.0, c)) * (1.0 + tall * (1.0 - smoothstep(6.0, 16.0, vs.a)));
    let e = vec2<f32>(rho / Rb, hy / Hd);
    let k0 = length(e);
    let k1 = max(length(vec2<f32>(rho / (Rb * Rb), hy / (Hd * Hd))), 1.0e-5);
    // (bounded at its rim: squashed flat, the estimate is the height over all the land, and lumps stood dark puffs on it)
    var d = max(k0 * (k0 - 1.0) / k1, (rho - Rb) * 0.8);
    // (its foot running on ahead of it: the base surge, gone as the column falls)
    if (c < 9.0) {
        let sr = 1.22 * Rb;
        let sh = 0.36 * vs.Hd;
        let es = vec2<f32>(rho / sr, hy / sh);
        let s0 = length(es);
        let s1 = max(length(vec2<f32>(rho / (sr * sr), hy / (sh * sh))), 1.0e-5);
        d = vc_smin(d, max(s0 * (s0 - 1.0) / s1, (rho - sr) * 0.8) + 300.0 * smoothstep(2.0, 9.0, c), 130.0);
    }
    let H = vs.H;
    if (H > vs.Hd + 15.0 && vs.Hb > 0.0) {
        // (bellied at the head while it climbs, flaring into the umbrella once there, thinning as it falls)
        let lobe = 0.17 * sin(3.0 * ang + hy * 0.0016 + 1.0) + 0.11 * sin(5.0 * ang - hy * 0.0021 + 2.2);
        let Rs0 = (540.0 + 200.0 * smoothstep(820.0, 1500.0, hy) * smoothstep(1000.0, 1500.0, H)) * (1.0 + lobe);
        let hd = (hy - (H - 0.72 * vs.Rt)) / (0.62 * vs.Rt);
        // (born narrow out of the blast's top, widening as it climbs: never a wide skirt at once)
        let gw = 0.3 + 0.7 * smoothstep(4.0, 10.0, vs.a);
        let Rs = (Rs0 + 0.2 * vs.Rt * exp(-hd * hd) * (1.0 - smoothstep(1200.0, 1600.0, H))) * (1.0 - 0.3 * smoothstep(0.0, 11.0, c)) * gw;
        let Rd = vs.Rt * gw;
        let dome = 0.5 * Rd * min(rho * rho / (Rd * Rd), 1.6);
        var top = hy - (min(H, vs.Hb + 60.0) - dome);
        if (c > 0.0) {
            // (the top of what is left, rounded)
            top = vc_smax(top, hy - vs.Hb, 60.0);
        }
        d = vc_smin(d, vc_smax((rho - Rs) * 0.85, top, 90.0), 260.0);
    }
    return d;
}
// The ripple running out through the umbrella (Hunga Tonga's gravity waves): trains of waves leaving the head as it
// bobs, their height over the sheet.
fn vc_ripple(r: f32) -> f32 {
    let f = vs.t - VC_SPREAD - 2.0;
    if (f <= 0.0) {
        return 0.0;
    }
    let R = 290.0 * f;                                       // the first wave's front
    let ph = (R - r) / 210.0;
    return 26.0 * sin(ph * TAU) * smoothstep(-0.2, 1.0, ph) * exp(-max(ph, 0.0) / 4.5) * smoothstep(300.0, 900.0, r);
}
// The umbrella: a sheet with real bulk, thick over the head, thinning out to a rounded rolling head at its nose (a
// gravity current's).
fn vc_umb(q: vec3<f32>, r0: f32) -> f32 {
    if (vs.Ru < 10.0) {
        return 1.0e5;
    }
    let hy = q.y;
    // (never a clean disc: pushed out unevenly round its edge, more so as it grows)
    let cs = q.x / max(r0, 1.0);
    let sn = q.z / max(r0, 1.0);
    let r = r0 * (1.0 + 0.11 * (4.0 * cs * cs * cs - 3.0 * cs) + 0.075 * (2.0 * sn * cs) + 0.05 * (1.0 - 2.0 * sn * sn) * cs);
    let e = saturate((vs.Ru - r) / 520.0);
    let prof = sqrt(e * (2.0 - e));
    let core = exp(-r * r / (1200.0 * 1200.0));
    let nose = exp(-pow((vs.Ru - r - 300.0) / 280.0, 2.0));
    // (thin while young: it spreads out of the head, under its top, not over it)
    let g = saturate(vs.Ru / 1300.0);
    let th = (210.0 + 240.0 * core + 120.0 * nose) * prof * g;
    let hm = vs.hu + 30.0 * (1.0 - prof);
    let bot = hm - 0.9 * th - 230.0 * exp(-r * r / (800.0 * 800.0)) * g;
    let tp = hm + 2.2 * vc_ripple(r) + 0.9 * th + 140.0 * core * g;
    return vc_smax(vc_smax(hy - tp, bot - hy, 60.0) * 0.8, (r - vs.Ru) * 0.8, 120.0);
}
// The wall of ash and what it leaves: over the land (`land`), behind its front; .x the distance, .y how far behind the
// front (0 at it). Its front runs on in lobes along the land's lows, parted by clefts.
fn vc_n1(x: f32, per: u32, k: u32) -> f32 {
    let i = floor(x);
    let f = x - i;
    let u = f * f * (3.0 - 2.0 * f);
    let n = u32(i32(i)) % per;
    let a = f32(pcg(n ^ k) & 0xffffu) / 65535.0;
    let b = f32(pcg(((n + 1u) % per) ^ k) & 0xffffu) / 65535.0;
    return mix(a, b, u);
}
fn vc_lobes(ang: f32, rho: f32) -> f32 {
    // (long fingers running out from the ring, parted by narrow clefts: noise round the circle, wandering as it goes out)
    let u = (ang + 3.1415927 + 0.00022 * rho + 0.2 * sin(rho * 0.0031)) / TAU + 1.0;
    let n = 0.6 * vc_n1(u * 9.0, 9u, 0x71u) + 0.28 * vc_n1(u * 23.0, 23u, 0x72u) + 0.12 * vc_n1(u * 61.0, 61u, 0x73u);
    let cl = vc_n1(u * 17.0, 17u, 0x74u);
    return n - 0.5 - 0.3 * (1.0 - smoothstep(0.0, 0.16, abs(cl - 0.5)));
}
fn vc_flow(q: vec3<f32>, rho: f32, ang: f32, land: f32) -> vec2<f32> {
    let c = vs.c;
    if (c <= 0.0) {
        return vec2<f32>(1.0e5, -1.0e5);
    }
    let lob = vc_lobes(ang, rho);
    // (its lobes grow from nothing as it leaves the ring; high land holds it back)
    let e = vs.rf - rho - min(4.0 * (vs.rf - VC_RING) + 30.0, 520.0) * lob - 2.6 * max(land, 0.0);
    let h = q.y - land;
    let ep = max(e, 0.0);
    // (a steep rounded head, then a body thickening behind it)
    let nose = 235.0 * (1.0 - exp(-ep / 75.0)) * smoothstep(0.0, 2.0, c);
    var top = nose + 0.10 * min(ep, 700.0);
    // (the new clouds rising off it, once it has slowed and lost its load)
    let lift = smoothstep(VC_LIFT - 8.0, VC_RED, vs.t);
    if (lift > 0.0) {
        let tw = gnoise2(vec2<f32>(ang * 3.3, rho / 600.0));
        top = top + 560.0 * lift * smoothstep(120.0, 620.0, ep) * smoothstep(0.34, 0.74, tw + 0.5 * lob);
    }
    let d = vc_smax((h - top) * 0.75, -e * 0.85, 70.0);
    return vec2<f32>(d, e);
}

// What a stage of the march knows of a point: the distances, and how far along the ray nothing can stand.
struct VcB {
    d: f32,
    dc: f32,
    du: f32,
    df: f32,
    e: f32,
    land: f32,
    rho: f32,
    ang: f32,
}
fn vc_base(q: vec3<f32>) -> VcB {
    var b: VcB;
    let rho = length(q.xz);
    b.rho = rho;
    b.ang = atan2(q.z, q.x);
    let fl = vs.c > 0.0 && q.y < vs.ftop + VC_DM && rho < vs.rfm + VC_DM;
    b.land = 0.0;
    if (fl || q.y < 700.0) {
        b.land = vc_land(q.xz);
    }
    b.dc = vc_col(q, rho, b.ang, b.land);
    b.du = vc_umb(q, rho);
    b.df = 1.0e5;
    b.e = -1.0e5;
    if (fl) {
        let f = vc_flow(q, rho, b.ang, b.land);
        b.df = f.x;
        b.e = f.y;
    } else {
        // (the rest of the march reads it only under the flows)
        b.land = 0.0;
    }
    b.d = vc_smin(vc_smin(b.dc, b.du, 120.0), b.df, 60.0);
    return b;
}
// The base alone, for the light's looks along the way to the sun.
fn vc_dist(q: vec3<f32>) -> f32 {
    return vc_base(q).d;
}
// How far the ray may go with no smooth body nearer than the lumps reach: the sheet and the flows' layer are flat, so a
// low ray is carried straight to them, not crept up on.
fn vc_skip(q: vec3<f32>, rd: vec3<f32>, b: ptr<function, VcB>) -> f32 {
    let dm = VC_DM + 10.0;
    var s = (*b).dc - dm;
    // (the umbrella's layer)
    if (vs.Ru > 10.0) {
        let lo = vs.hu - 720.0 - dm;
        let hi = vs.hu + 680.0 + dm;
        var su = 1.0e6;
        if (q.y < lo) {
            su = select(1.0e6, (lo - q.y) / rd.y, rd.y > 1.0e-4);
        } else if (q.y > hi) {
            su = select(1.0e6, (q.y - hi) / -rd.y, rd.y < -1.0e-4);
        } else {
            su = (*b).du - dm;
        }
        s = min(s, su);
    }
    if (vs.c > 0.0) {
        let hi = vs.ftop + dm;
        var sf = 1.0e6;
        if (q.y > hi) {
            sf = select(1.0e6, (q.y - hi) / -rd.y, rd.y < -1.0e-4);
        } else {
            sf = max((*b).rho - vs.rfm - dm, (*b).df - dm);
        }
        s = min(s, sf);
    }
    return s;
}

// ---- the lumps: domes over a jittered lattice (as the Nuke's pl_dome) ----
fn vc_dome(p: vec3<f32>) -> f32 {
    let b = floor(p - 0.5);
    var hmax = 0.0;
    for (var c = 0u; c < 8u; c = c + 1u) {
        let o = vec3<f32>(f32(c & 1u), f32((c >> 1u) & 1u), f32(c >> 2u));
        let cell = b + o;
        let q = bitcast<vec3<u32>>(vec3<i32>(cell));
        let h = pcg(q.x ^ pcg(q.y ^ pcg(q.z + 0x51u)));
        let jit = vec3<f32>(f32(h & 1023u), f32((h >> 10u) & 1023u), f32((h >> 20u) & 1023u)) * (0.7 / 1023.0) + 0.15;
        let sz = 0.7 + 0.55 * f32(pcg(h) & 1023u) / 1023.0;
        let e = cell + jit - p;
        hmax = max(hmax, sz * sqrt(saturate(1.0 - dot(e, e) * 1.7 / (sz * sz))));
    }
    return hmax;
}
const VC_R1: mat3x3<f32> = mat3x3<f32>(-0.0014, 0.9977, -0.0674, -0.2224, -0.0660, -0.9727, -0.9750, 0.0136, 0.2220);
const VC_R2: mat3x3<f32> = mat3x3<f32>(-0.6616, 0.1124, 0.7414, -0.4826, -0.8205, -0.3063, 0.5739, -0.5605, 0.5971);
const VC_R3: mat3x3<f32> = mat3x3<f32>(-0.9891, -0.1223, 0.0816, 0.0968, -0.9594, -0.2651, 0.1107, -0.2543, 0.9608);

// What carries the lumps at q: .xyz blocks a second, .w the rate all of it swells out from the axis (the blast and sheet
// spreading, as a stretch, which can't fold over as a speed would). Carried a while and let go (`vc_lump`): only ever the
// flow here and now, so nothing winds up into streaks.
fn vc_vel(q: vec3<f32>, rho: f32, wc: f32, wu: f32, wf: f32) -> vec4<f32> {
    let hy = q.y;
    let r = max(rho, 1.0);
    var vr = 0.0;
    var vy = 0.0;
    var gr = 0.0;
    if (wc > 0.0) {
        // (up the trunk, slowing under the head, which spreads over its own top; the blast's top its head till the trunk
        // climbs out, let go slowly, or every lump jumps)
        var uy = 10.0 + 66.0 * (1.0 - smoothstep(900.0, 1750.0, hy));
        let hh = max(saturate((hy - (vs.H - 460.0)) / 460.0), saturate((hy - (vs.Hd - 460.0)) / 460.0) * (1.0 - smoothstep(4.0, 14.0, vs.a)));
        var ur = 52.0 * hh * smoothstep(0.0, 0.8 * vs.Rt, r);
        // (and the blast rolling round a ring inside its edge: up its inside, out over its top, down its front, in under
        // it; carried out as it spreads)
        let uv = vec2<f32>(r - 0.72 * vs.Rb, hy - 0.5 * vs.Hd);
        let rr = 0.9 * vs.Hd;
        let wr = exp(-dot(uv, uv) / (rr * rr));
        ur = mix(ur, 0.13 * uv.y, wr);
        uy = mix(uy, -0.13 * uv.x, wr);
        if (vs.c > 0.0) {
            // (once it has lost its buoyancy all of it comes down, faster and faster, spreading at its foot)
            let fall = smoothstep(0.0, 3.0, vs.c);
            uy = mix(uy, -30.0 - 16.0 * vs.c, fall * smoothstep(0.0, 200.0, hy));
            ur = ur + 40.0 * fall * (1.0 - smoothstep(0.0, 300.0, hy));
        }
        vr = vr + wc * ur;
        vy = vy + wc * uy;
        gr = gr + wc * min(vs.dRb / vs.Rb, 0.075) * (1.0 - smoothstep(0.8 * vs.Hd, 1.4 * vs.Hd, hy));
    }
    if (wu > 0.0) {
        gr = gr + wu * min(vs.dRu / max(vs.Ru, 300.0), 0.075);
    }
    if (wf > 0.0) {
        // (the wall's head rolling forward over itself)
        vr = vr + wf * vs.dRf;
        vy = vy + wf * 14.0;
    }
    return vec4<f32>(q.x / r * vr, vy, q.z / r * vr, gr);
}
// The small lumps at q: each size faded in by how near the surface is (`rest`, less the big lumps) and its size in pixels:
// a size that simply starts draws a contour. Uses vc_lump's vc_lw, vc_lsy. .x how far out, .y of a dome, .z the fray.
var<private> vc_lw: vec4<f32>;
var<private> vc_cq: vec4<f32>;
var<private> vc_cb: vec4<f32>;
var<private> vc_cw: vec4<f32>;
var<private> vc_cy: f32;
var<private> vc_cs: f32;
var<private> vc_lsy: vec2<f32>;
fn vc_fine(q: vec3<f32>, rest: f32, foot: f32) -> vec3<f32> {
    var o = vec3<f32>(0.0, 1.0, 0.5);
    let g3 = saturate((120.0 - rest) / 40.0) * saturate((28.0 - foot) / 12.0);
    if (g3 <= 0.0) {
        return o;
    }
    let gain = vc_lw.w;
    let qf = vec3<f32>(q.x, q.y * vc_lsy.x, q.z) - vec3<f32>(0.0, 16.0 * vs.t * vc_lsy.y, 0.0) + vc_lw.xyz * 0.5;
    // (smooth noise from here down, not domes: a dome's sharp crease this small reads as cracked mud)
    let n3 = vc_gn3(VC_R3 * (qf * (1.0 / 44.0) + vec3<f32>(1.7, 0.0, -2.1)));
    let bl3 = sqrt((2.0 * n3 - 1.0) * (2.0 * n3 - 1.0) + 0.012);
    o.x = g3 * (6.0 + 26.0 * gain) * (0.9 * (n3 - 0.5) + 1.1 * (bl3 - 0.3));
    let g4 = saturate((90.0 - rest) / 30.0) * saturate((11.0 - foot) / 5.0);
    if (g4 > 0.0) {
        let n4 = vc_gn3(VC_R1 * (qf * (1.0 / 19.0) + vec3<f32>(-4.7, 2.0, 0.3)));
        let bl4 = sqrt((2.0 * n4 - 1.0) * (2.0 * n4 - 1.0) + 0.012);
        o.x = o.x + g4 * 22.0 * (bl4 - 0.3);
        let g5 = saturate((70.0 - rest) / 25.0) * saturate((4.5 - foot) / 2.0);
        if (g5 > 0.0) {
            let n5 = vc_gn3(VC_R2 * (qf * (1.0 / 7.0)) + vec3<f32>(0.3, 0.0, 0.25 * vs.t));
            o.x = o.x + g5 * 9.0 * (n5 - 0.5);
            o.z = mix(0.5, n5, g5);
        }
    }
    return o;
}
// The lumps on the bodies, lumps on lumps: rough cauliflower, its big lumps carried by the flow two sets at a time, half a
// turn apart, each fading in as the other goes (the Nuke's roll), the small ones drifting over them. `d1` how far off the
// body is (small lumps only close to it). `fine` false: the light's look.
// .x how far it stands out, .y how far up a dome (1 a crown, 0 a crease), .z unused, .w the fray.
fn vc_lump(q: vec3<f32>, b: ptr<function, VcB>, d1: f32, foot: f32, fine: bool) -> vec4<f32> {
    let dc = (*b).dc;
    let du = (*b).du;
    let df = (*b).df;
    let wc0 = saturate(1.0 + (min(du, df) - dc) / 70.0);
    let wu0 = saturate(1.0 + (min(dc, df) - du) / 70.0);
    let wf0 = saturate(1.0 + (min(dc, du) - df) / 70.0);
    let sum = max(wc0 + wu0 + wf0, 1.0e-3);
    let wc = wc0 / sum;
    let wu = wu0 / sum;
    let wf = wf0 / sum;
    // (the big lumps looked up again only every few blocks along the ray: they change slowly and cost the most)
    let dq = q - vc_cq.xyz;
    let hold = 4.0 + 0.6 * foot + VC_HOLD * vc_cs;
    var out_ = 0.0;
    var top = 0.0;
    var warp = vc_cw.xyz;
    var gain = vc_cw.w;
    var sy = vc_cy;
    if (fine && dot(dq, dq) < hold * hold) {
        out_ = vc_cb.x;
        top = vc_cb.y;
    } else {
    let rho = (*b).rho;
    let v = vc_vel(q, rho, wc, wu, wf);
    // (the sheet's lumps broad and flat, pouches under it, roughest at its nose; the wall's hug its face, not run ahead)
    gain = (wc + 0.62 * wf * smoothstep(-110.0, 10.0, (*b).e)) * mix(0.13, 1.0, smoothstep(0.0, 0.5, vs.a));
    sy = 1.0 + 0.28 * wf;
    if (wu > 0.0) {
        let nose = exp(-max(vs.Ru - rho, 0.0) / 520.0);
        let under = 1.0 - smoothstep(VC_HU - 260.0, VC_HU - 40.0, q.y);
        let core = exp(-rho * rho / (1800.0 * 1800.0));
        gain = gain + wu * (0.3 + 0.4 * core + 0.55 * nose + 0.85 * under);
        sy = sy + wu * mix(0.8, 0.25, under);
    }
    let q0 = vec3<f32>(q.x, q.y * sy, q.z);
    // (the lattice folded by two sizes of noise, so no cell shows)
    let w = vc_gn3(VC_R2 * q0 * (1.0 / 470.0));
    var w2 = 0.5;
    if (fine) {
        w2 = vc_gn3(VC_R3 * q0 * (1.0 / 180.0) + vec3<f32>(4.0, 0.0, 0.06 * vs.t));
    }
    warp = vec3<f32>(w - 0.5, w2 - 0.5, w2 - w) * 170.0;
    let ph = fract(vs.t / VC_P);
    let wA = 1.0 - abs(2.0 * ph - 1.0);
    let kd = select(1, 0, wA >= 0.5);
    var b1 = 0.0;
    var b2 = 0.0;
    var ws = 0.0;
    for (var k = select(kd, 0, fine); k < select(kd + 1, 2, fine); k = k + 1) {
        let wk = select(1.0 - wA, wA, k == 0);
        let tk = fract(ph + 0.5 * f32(k)) * VC_P;
        let cy = floor(vs.t / VC_P + 0.5 * f32(k));
        let st = 1.0 - exp(-v.w * tk);
        let qk = q0 - vec3<f32>(v.x * tk + q.x * st, v.y * sy * tk, v.z * tk + q.z * st) + warp;
        let o = vec3<f32>(3.1 + 7.3 * cy, 2.9 * f32(k), 7.7 - 4.1 * cy);
        b1 = b1 + wk * vc_dome(VC_R1 * (qk * (1.0 / 310.0) + o));
        if (fine) {
            b2 = b2 + wk * vc_dome(VC_R2 * (qk * (1.0 / 122.0) + o * 1.7));
        }
        ws = ws + wk;
    }
    b1 = b1 / max(ws, 1.0e-3);
    b2 = select(0.62, b2 / max(ws, 1.0e-3), fine);
    if (fine) {
        // (two half sets added are evener than one: their spread put back)
        let sp = 1.0 / sqrt(wA * wA + (1.0 - wA) * (1.0 - wA));
        b1 = 0.62 + (b1 - 0.62) * sp;
        b2 = 0.62 + (b2 - 0.62) * sp;
    }
    out_ = gain * (165.0 * (b1 - 0.56) + 74.0 * (b2 - 0.56) + 70.0 * (w - 0.5));
    if (wu > 0.0 && out_ < 0.0) {
        out_ = out_ * (1.0 - 0.72 * wu);
    }
    top = saturate(0.1 + 0.9 * b1 * (0.45 + 0.55 * b2));
    if (fine) {
        vc_cq = vec4<f32>(q, 1.0);
        vc_cb = vec4<f32>(out_, top, 0.0, 0.0);
        vc_cw = vec4<f32>(warp, gain);
        vc_cy = sy;
    }
    }
    var fray = 0.5;
    vc_lw = vec4<f32>(warp, gain);
    vc_lsy = vec2<f32>(sy, wc);
    if (fine) {
        let f = vc_fine(q, d1 - out_, foot);
        out_ = out_ + f.x;
        top = top * f.y;
        fray = f.z;
    }
    return vec4<f32>(out_, top, 0.0, fray);
}
// The surface at q: the smooth bodies (b) bulged out by the lumps. .x the distance, .y how far up a dome, .w the fray.
fn vc_sdf(q: vec3<f32>, b: ptr<function, VcB>, foot: f32, fine: bool) -> vec4<f32> {
    let l = vc_lump(q, b, (*b).d, foot, fine);
    // (the lumps' height capped smoothly, so nothing stands out past what the march allows)
    let bp = max(l.x, 0.0);
    let bump = l.x - bp + bp / sqrt(sqrt(1.0 + pow(bp / VC_DM, 4.0)));
    let d = (*b).d - bump;
    if (fine) {
        vc_cs = min(abs(d), 120.0);
    }
    return vec4<f32>(d, l.y, l.z, l.w);
}

// ---- the light ----
// How much of the sun's light gets past the umbrella to q: where the way to the sun crosses its sheet.
fn vc_sun_t(q: vec3<f32>, L: vec3<f32>) -> f32 {
    if (vs.cov <= 0.0 || L.y < 0.01) {
        return 1.0;
    }
    let up = VC_HU - 120.0 - q.y;
    if (up < 0.0) {
        return 1.0;
    }
    let h = q.xz + L.xz * (up / L.y);
    let r = length(h);
    return 1.0 - vs.cov * (1.0 - smoothstep(vs.Ru - 700.0, vs.Ru - 100.0, r)) * smoothstep(0.0, 160.0, up);
}
// How much of the sky's light does: the share of the sky the sheet leaves open over q.
fn vc_sky_t(q: vec3<f32>) -> f32 {
    if (vs.cov <= 0.0) {
        return 1.0;
    }
    let d = max(VC_HU - q.y, 60.0);
    let r = length(q.xz);
    let l = max(vs.Ru - r, 0.0);
    return 1.0 - vs.cov * (1.0 - d / sqrt(d * d + l * l)) * 0.97;
}
// The picture's darkening over land or sky at q (level with it, `far` for sky): noon gone dark, what glows left glowing.
fn vc_dim(c: vec3<f32>, q: vec3<f32>, L: vec3<f32>, sun_up: f32) -> vec3<f32> {
    let st = mix(1.0, vc_sun_t(q, L), sun_up);
    let sk = vc_sky_t(q);
    let lit = (0.72 * st + 0.28) * (0.05 + 0.95 * pow(sk, 1.3));
    // (bright and saturated: fire, lava, torches; or simply bright, a lamp)
    let mx = max(c.r, max(c.g, c.b));
    let sat = (mx - min(c.r, min(c.g, c.b))) / max(mx, 1.0e-3);
    let glow = smoothstep(0.45, 0.95, mx) * (0.06 + 0.94 * sat);
    let k = mix(lit, 1.0, glow);
    // (and what light is left, browned by the ash in the air)
    let g = dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
    return mix(c, vec3<f32>(g) * vec3<f32>(1.12, 0.92, 0.74), 0.9 * vs.cov * (1.0 - glow)) * k;
}

// ---- the lightning, as the Hurricane's hu_flashes: a slot of 0.13 s, a few alive at once. When, where and how strong
// (0x901 to 0x906, 0x908) vc_sound.rs's `flashes` copies for its thunder: keep them in step. Another hash says what: a
// third bolts to the land (most where the player sees them), a third channels out of the cloud, the rest in it (a third
// of those faint); strokes as the Hurricane's: a cloud's flickers over 0.3 s, a bolt's leader, return stroke, re-strokes.
const VC_BOLTS_AHEAD: f32 = 0.5;
const VC_BOLTS_ASIDE: f32 = 0.13;
const VC_CHANNELS: f32 = 0.76;     // (and up to here of the same hash, a channel out of the cloud)
const VC_LEAD: f32 = 0.075;
const VC_FL_END: f32 = 0.39;       // (three slots' worth: a flash is gone by the time its slot is dropped)
// (ten times the Hurricane's bolts: thicker, kinkier, a wider pool on the land)
const VC_BEAM_R: f32 = 13.0;
const VC_CHAN_W: f32 = 4.0;
const VC_KINK_LEN: f32 = 260.0;
const VC_THRU: f32 = 0.55;         // (how much of a channel shows through the ash under the cloud's face: its core the square of it, a blur of light)
const VC_FOOT_R2: f32 = 6000.0;
struct VcFlash {
    p: vec3<f32>,      // where, from the vent
    k: f32,            // how bright now, on the cloud round it
    ring: f32,         // 1 in the umbrella's rings, 0 in the plume
    id: f32,
    a: f32,            // seconds since it began
    n: u32,            // its strokes' hash
    kind: u32,         // 0 in the cloud alone, 1 a bolt to the land, 2 a channel out of the cloud
}
struct VcFlashes {
    f: array<VcFlash, 3>,
}
// The strokes of a flash in the cloud (the Supercell's sc_stroke, as hu_stroke): 1 at a stroke's peak.
fn vc_strokes(a: f32, n: u32) -> f32 {
    let count = 1u + n % 4u;
    var s = 0.0;
    var ts = 0.0;
    for (var k = 0u; k <= count; k = k + 1u) {
        let h = f32(pcg(n * 13u + k) & 1023u) / 1023.0;
        ts = ts + select(0.04 + 0.09 * h, 0.0, k == 0u);
        s = s + select(0.5 + 0.4 * h, 1.0, k == 0u) * exp(-max(a - ts, 0.0) / 0.04) * step(ts, a);
    }
    return (s + 0.08 * exp(-a / 0.25)) * (1.0 - smoothstep(0.3, VC_FL_END, a));
}
// A bolt's timing (hu_beam_k, hu_lead_k): a jagged leader flickering ~75 ms, new every two frames; the return stroke, drawn
// up off the land from 0.17 s, gone by 0.27; then a re-stroke or two, a frame or two each.
fn vc_flick(a: f32, n: u32, k: u32) -> f32 {
    return f32(pcg(n * 31u + k * 7u + u32(max(a, 0.0) * 30.0)) & 1023u) / 1023.0;
}
fn vc_beam_k(a: f32, n: u32) -> f32 {
    return smoothstep(0.05, VC_LEAD, a) * (1.0 - smoothstep(0.19, 0.27, a)) * (0.88 + 0.12 * vc_flick(a, n, 1u));
}
fn vc_lead_k(a: f32, n: u32) -> f32 {
    if (a < VC_LEAD) {
        return 0.55 + 0.45 * vc_flick(a, n, 2u);
    }
    let r0 = 0.28 + 0.03 * f32(n & 7u) / 7.0;
    let r1 = 0.335 + 0.03 * f32((n >> 3u) & 7u) / 7.0;
    return 0.8 * (step(r0, a) * step(a, r0 + 0.034) + 0.7 * step(r1, a) * step(a, r1 + 0.018));
}
fn vc_bolt_stroke(a: f32, n: u32) -> f32 {
    return (max(vc_beam_k(a, n), 0.6 * vc_lead_k(a, n)) + 0.12 * exp(-a / 0.15)) * (1.0 - smoothstep(0.34, VC_FL_END, a));
}
// (where the player is, off the vent)
fn vc_me() -> vec2<f32> {
    return vec2<f32>(frame.mod_params[3].x - anchor_xz().x, frame.mod_params[3].z - anchor_xz().y);
}
fn vc_flash(i: i32, seed: u32) -> VcFlash {
    var o: VcFlash;
    let t = vs.t;
    let dt = 0.13;
    let sl = floor(t / dt) - f32(i);
    let slot = u32(max(sl, 0.0));
    o.id = sl;
    let t0 = sl * dt;
    let age = t - t0;
    let h = mh(slot, seed, 0x901u);
    let on = smoothstep(VC_LIGHT - 2.0, VC_LIGHT + 8.0, t0) * (1.0 - smoothstep(VC_COLLAPSE + 10.0, VC_RED, t0));
    if (h > 0.62 * on + 0.03 * step(VC_LIGHT, t0) * on) {
        return o;
    }
    let th = TAU * mh(slot, seed, 0x902u);
    let ring = mh(slot, seed, 0x903u) < smoothstep(VC_DARK - 4.0, VC_DARK + 4.0, t0);
    if (ring) {
        // (out through the sheet in rings, running out with the ripple)
        let n = floor(mh(slot, seed, 0x904u) * 3.0);
        let R = (0.3 + 0.28 * n) * min(vs.Ru, 5200.0);
        o.p = vec3<f32>(cos(th) * R, VC_HU - 90.0, sin(th) * R);
        o.ring = 1.0;
    } else {
        let hy = 380.0 + 1100.0 * mh(slot, seed, 0x905u);
        let R = (vc_rr(hy) + vc_ww(hy)) * (0.75 + 0.2 * mh(slot, seed, 0x906u));
        o.p = vec3<f32>(cos(th) * R, min(hy, max(vs.Hb, 60.0)), sin(th) * R);
    }
    // (bolts where the player can see them, ahead of the column, not behind it; fewer in the rest of the sky)
    let me = vc_me();
    let way = normalize(-me + vec2<f32>(1.0e-3, 0.0));
    let ahead = dot(normalize(o.p.xz - me), way);
    let hidden = smoothstep(0.35, 0.8, dot(o.p.xz, way) / max(length(o.p.xz), 1.0)) * (1.0 - smoothstep(700.0, 1100.0, abs(o.p.x * way.y - o.p.z * way.x)));
    let what = mh(slot, seed, 0x921u);
    let bolt = what < mix(VC_BOLTS_ASIDE, VC_BOLTS_AHEAD, smoothstep(0.45, 0.75, ahead) * (1.0 - hidden));
    o.kind = select(select(0u, 2u, what < VC_CHANNELS), 1u, bolt);
    o.a = age;
    o.n = u32(mh(slot, seed, 0x907u) * 65535.0);
    let br = select(vc_strokes(age, o.n), vc_bolt_stroke(age, o.n), bolt);
    let faint = select(1.0, 0.3, !bolt && mh(slot, seed, 0x922u) < 0.34);
    // (a bolt lights the cloud round its root less than a flash in the cloud does)
    o.k = br * select(1.0, 0.6, bolt) * faint * (0.5 + 0.8 * mh(slot, seed, 0x908u));
    return o;
}
fn vc_flashes(seed: u32) -> VcFlashes {
    var o: VcFlashes;
    o.f[0] = vc_flash(0, seed);
    o.f[1] = vc_flash(1, seed);
    o.f[2] = vc_flash(2, seed);
    return o;
}

// ---- the lava bombs: on ballistic arcs off the ring (volcano.rs's vc_bombs, each down where it meets the land) ----
struct VcBomb {
    p0: vec3<f32>,
    v: vec3<f32>,
    t0: f32,
    tl: f32,
}
fn vc_bomb(i: u32) -> VcBomb {
    let b = VC_BOMB + VC_BW * i;
    var o: VcBomb;
    o.t0 = vc_w(b);
    o.p0 = vec3<f32>(vc_w(b + 1u), vc_w(b + 2u), vc_w(b + 3u));
    o.v = vec3<f32>(vc_w(b + 4u), vc_w(b + 5u), vc_w(b + 6u));
    o.tl = vc_w(b + 7u);
    return o;
}
fn vc_bomb_at(b: VcBomb, t: f32) -> vec3<f32> {
    let s = t - b.t0;
    return b.p0 + b.v * s - vec3<f32>(0.0, 0.5 * VC_G * s * s, 0.0);
}
// The trail where the bomb passed at time `s`, by now: the arc itself wandering smoothly as the smoke drifts and rises.
fn vc_rope_at(b: VcBomb, ph: f32, s: f32) -> vec3<f32> {
    let age = max(vs.t - s, 0.0);
    let g = 1.0 - exp(-age / 2.6);
    let w = vec3<f32>(sin(s * 1.1 + ph) + 0.5 * sin(s * 2.7 + ph * 1.7), 0.6 * sin(s * 1.7 + ph * 2.3), cos(s * 1.3 + ph * 0.7) + 0.5 * sin(s * 3.1 + ph));
    return vc_bomb_at(b, s) + w * (9.0 * g) + vec3<f32>(0.0, 1.5 * age, 0.0);
}
// A stretch of smoke as a soft billowing tube: `X` where the ray passes it (fixed in the world, so the billows stay
// where they were laid), `ax` the axis nearest it, `w` its radius, `age` its seconds. .x its cover, .y how much of the
// sun's light its face takes.
fn vc_tube(X: vec3<f32>, ax: vec3<f32>, rd: vec3<f32>, L: vec3<f32>, w: f32, age: f32, sz: f32) -> vec2<f32> {
    let r = X - ax;
    let n1 = vc_gn3(X * (1.0 / sz) + vec3<f32>(0.0, -0.08 * vs.t, 0.06 * vs.t));
    let n2 = vc_gn3(VC_R1 * X * (3.0 / sz) + vec3<f32>(0.16 * vs.t, 3.0, 0.0));
    let x = length(r) / w;
    let xe = x + 0.85 * (0.26 - abs(2.0 * n1 - 1.0)) + 0.38 * (n2 - 0.5);
    let cov = 1.0 - smoothstep(0.35, 1.0, xe);
    // (its face: round the axis towards the eye, its billows tipping it)
    let n = normalize(r / w + -rd * sqrt(max(1.0 - x * x, 0.05)) + 0.8 * vec3<f32>(n1 - 0.5, n2 - 0.5, n1 - n2));
    return vec2<f32>(cov, saturate(0.5 + 0.5 * dot(n, L)));
}
// Smoke `al` of colour `sc` at `t` laid under the cloud: hidden as much as the cloud in front hides it (vc_ctr, from where
// the march's light fell past 0.9, 0.6, 0.3, 0.1: vc_tk), hiding the part of the cloud behind it (vc_cm).
var<private> vc_tk: vec4<f32>;
var<private> vc_tx: vec2<f32>;
var<private> vc_cm: f32;
fn vc_ctr(t: f32) -> f32 {
    let k = vc_tk;
    var r = mix(1.0, 0.9, saturate((t - k.x) / 24.0 + 1.0));
    r = mix(r, 0.6, saturate((t - k.x) / max(k.y - k.x, 1.0)));
    r = mix(r, 0.3, saturate((t - k.y) / max(k.z - k.y, 1.0)));
    r = mix(r, 0.1, saturate((t - k.z) / max(k.w - k.z, 1.0)));
    r = mix(r, 0.0, saturate((t - k.w) / 16.0));
    return max(1.0 - (1.0 - saturate((r - 0.051) / 0.949)) * vc_tx.x, vc_tx.y);
}
fn vc_lay(c: ptr<function, vec3<f32>>, tr: ptr<function, f32>, tm: ptr<function, f32>, al: f32, sc: vec3<f32>, t: f32) {
    let v = vc_ctr(t);
    *c = *c + *tr * al * v * sc;
    *tr = *tr * (1.0 - al);
    vc_cm = vc_cm * (1.0 - al * saturate((v - vc_tx.y) / max(1.0 - vc_tx.y, 1.0e-3)));
    if (v > 0.5) {
        *tm = min(*tm, t);
    }
}
// Their smoke (half size): .rgb what it adds (premultiplied), .a what it leaves; `tm` how far off the nearest is.
fn vc_bombs_smoke(C: vec3<f32>, rd: vec3<f32>, tmax: f32, l: VcLight, amb0: vec3<f32>, tm: ptr<function, f32>) -> vec4<f32> {
    let n = u32(vc_w(1u));
    let time = vs.t;
    var c = vec3<f32>(0.0);
    var tr = 1.0;
    if (time < VC_ERUPT + 1.0 || time > VC_COLLAPSE + 14.0) {
        return vec4<f32>(c, tr);
    }
    let brown = vec3<f32>(0.13, 0.095, 0.07);
    let amb = mix(amb0, vec3<f32>(dot(amb0, vec3<f32>(0.2126, 0.7152, 0.0722))) * vec3<f32>(1.3, 0.8, 0.5), vs.cov);
    for (var i = 0u; i < n; i = i + 1u) {
        let b = vc_bomb(i);
        if (b.t0 >= time) {
            break;
        }
        let late = time - b.tl;
        if (late > 16.0) {
            continue;
        }
        let ph = f32(i) * 2.399;
        let size = 0.7 + 0.6 * mh(i, 7u, 0x35u);
        let te = min(time, b.tl);
        let ts = max(b.t0 + 0.2, te - 10.0);
        let T = te - ts;
        if (T > 0.0) {
            let a = vc_bomb_at(b, ts) + C;
            let e = vc_bomb_at(b, te) + C;
            let sag = 0.125 * VC_G * T * T;
            let g = pl_ray_seg(rd, a, e, 0.0, 1.0);
            let wmax = 34.0 * size;
            // (near the arc at all: then along it for where the ray passes nearest, by steps and then by Gauss-Newton, so
            // the rope is one smooth curve however it is seen)
            if (g.x < sag + wmax + 14.0 + g.y * vs.px * 3.0) {
                var sb = ts;
                var db = 1.0e12;
                for (var k = 0; k <= 8; k = k + 1) {
                    let s = ts + T * f32(k) / 8.0;
                    let pk = vc_rope_at(b, ph, s) + C;
                    let tk = max(dot(pk, rd), 0.0);
                    let dk = pk - rd * tk;
                    let d2 = dot(dk, dk);
                    if (d2 < db) {
                        db = d2;
                        sb = s;
                    }
                }
                for (var k = 0; k < 3; k = k + 1) {
                    let pk = vc_rope_at(b, ph, sb) + C;
                    let dp = b.v - vec3<f32>(0.0, VC_G * (sb - b.t0), 0.0);
                    let pp = pk - rd * dot(pk, rd);
                    let dd = dp - rd * dot(dp, rd);
                    sb = clamp(sb - dot(pp, dd) / max(dot(dd, dd), 1.0), ts, te);
                }
                let P = vc_rope_at(b, ph, sb) + C;
                let tc = dot(P, rd);
                let age = time - sb;
                // (thick from the first, swelling with age, thinning; brown smoke, hot at its head)
                let w = size * (5.0 + 6.2 * sqrt(age));
                let wv = max(w, tc * vs.px * 1.5);
                if (tc > 2.0 && tc < tmax + wv && length(P - rd * tc) < 1.9 * wv) {
                    let q = rd * tc - C;
                    let f = vc_tube(q, P - C, rd, l.L, wv, age, 26.0 * size);
                    // (a rope passing close to the eye thinned away: it would only be a smear across the picture)
                    let al = smoothstep(30.0, 240.0, tc) * saturate((tmax - tc + wv) / wv) * f.x * saturate(0.9 * exp(-age / 5.5) * (w / wv)) * (1.0 - smoothstep(te - ts - 0.5, te - ts, age) * smoothstep(9.0, 10.0, age)) * smoothstep(0.0, 0.5, age + 0.2);
                    if (al > 0.003) {
                        let hot = exp(-age / 0.22) * f.x;
                        let sun = l.sunc * vc_sun_t(q, l.L) * f.y * f.y * 1.1;
                        let sc = brown * (amb * (0.5 + 0.6 * f.y) + sun) + vec3<f32>(1.3, 0.34, 0.05) * hot * hot * hot;
                        vc_lay(&c, &tr, tm, al, sc, tc);
                    }
                }
            }
        }
        // (the black plume it throws up where it comes down, fed for a moment, then rising away and thinning)
        if (late > 0.0) {
            let P = vc_bomb_at(b, b.tl) + C;
            let Hp = size * 150.0 * (1.0 - exp(-late / 2.6));
            let sg = pl_ray_seg(rd, P, P + vec3<f32>(0.0, Hp, 0.0), 0.0, 1.0);
            let w = size * (5.0 + 15.0 * sqrt(late)) * (0.45 + 0.75 * sg.z);
            let wv = max(w, sg.y * vs.px * 1.5);
            if (sg.y > 2.0 && sg.x < 1.9 * wv && sg.y < tmax + 2.0 * wv) {
                let q = rd * sg.y - C;
                let ax = P + vec3<f32>(0.0, Hp * sg.z, 0.0) - C;
                let f = vc_tube(q, ax, rd, l.L, wv, late, 34.0 * size);
                let al = saturate((tmax - sg.y + 2.0 * wv) / (2.0 * wv)) * f.x * saturate(1.1 * exp(-late / 5.0) * (w / wv)) * (1.0 - 0.5 * sg.z * (1.0 - exp(-late / 2.0)));
                if (al > 0.003) {
                    let sun = l.sunc * vc_sun_t(q, l.L) * f.y * f.y * 0.5;
                    let sc = vec3<f32>(0.036, 0.032, 0.03) * (amb * (0.4 + 0.6 * f.y) + sun) + vec3<f32>(0.9, 0.2, 0.03) * exp(-late / 0.35) * (1.0 - sg.z);
                    vc_lay(&c, &tr, tm, al, sc, sg.y);
                }
            }
        }
    }
    return vec4<f32>(c, tr);
}
// Their glowing heads (sharp, at full size): what they add at this pixel. Behind the cloud (`ct`, `ca` what it leaves) a
// soft glow through it, dimmer the deeper.
fn vc_bombs_heads(C: vec3<f32>, rd: vec3<f32>, tmax: f32, ct: f32, ca: f32) -> vec3<f32> {
    let n = u32(vc_w(1u));
    let time = vs.t;
    var c = vec3<f32>(0.0);
    if (time < VC_ERUPT + 1.0 || time > VC_COLLAPSE + 2.0) {
        return c;
    }
    let focal = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
    for (var i = 0u; i < n; i = i + 1u) {
        let b = vc_bomb(i);
        if (b.t0 >= time) {
            break;
        }
        if (time > b.tl + 0.5) {
            continue;
        }
        let te = min(time, b.tl);
        let p = vc_bomb_at(b, te) + C;
        let t = dot(p, rd);
        if (t < 0.0 || t > tmax + 8.0) {
            continue;
        }
        let s = vc_bomb_at(b, te - 0.02) + C;
        let sg = pl_ray_seg(rd, s, p, 0.0, 1.0);
        let ppx = sg.x * focal / max(t, 1.0);
        let sz = (1.0 + 1.6 * mh(i, 3u, 0x31u)) * focal / max(t, 1.0);
        let rpx = clamp(sz, 0.9, 3.2);
        let occ = smoothstep(ct + 10.0, ct + 50.0, t) * (1.0 - ca);
        let hr = max(4.0 * rpx, 22.0 * focal / max(t, 1.0));
        if (ppx > select(14.0 * rpx + 4.0, 5.0 * hr, occ > 0.0)) {
            continue;
        }
        let cool = saturate((time - b.t0) / 12.0);
        let hc = mix(vec3<f32>(3.2, 1.6, 0.4), vec3<f32>(2.0, 0.46, 0.08), cool);
        let core = saturate(rpx + 0.6 - ppx) * min(sz / rpx, 1.0) + 0.0;
        let glow = 0.08 / (1.0 + pow(ppx / (rpx * 3.0), 2.0));
        var land = 1.0;
        if (time > b.tl) {
            land = 2.0 * (1.0 - (time - b.tl) / 0.5);
        }
        c = c + hc * ((core * 1.6 + glow) * (1.0 - occ) + occ * 0.1 * exp(-max(t - ct, 0.0) / 150.0) / (1.0 + pow(ppx / hr, 2.0))) * land;
    }
    return c;
}

// ---- the spray of rock thrown out of the blast: chunks flung radially out of the fireball, dark against it, hot where they
// show against the sky (sharp, at full size). .rgb what it adds, .a what it leaves of what is behind.
fn vc_spray(C: vec3<f32>, rd: vec3<f32>, tmax: f32, seed: u32) -> vec4<f32> {
    var c = vec3<f32>(0.0);
    var tr = 1.0;
    let focal = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
    for (var i = 0u; i < 56u; i = i + 1u) {
        let t0 = 0.8 + 6.5 * mh(i, seed, 0x941u);
        let s = vs.a - t0;
        if (s <= 0.0 || s > 13.0) {
            continue;
        }
        let th = TAU * mh(i, seed, 0x942u);
        let el = 0.12 + 1.15 * mh(i, seed, 0x943u);
        let dir = vec3<f32>(cos(th) * cos(el), sin(el), sin(th) * cos(el));
        let v = dir * (150.0 + 210.0 * mh(i, seed, 0x944u));
        let p0 = dir * vec3<f32>(320.0, 160.0, 320.0);
        // (slowing in the air, so it comes down, and not somewhere past the edge of the world)
        let e = exp(-s / 4.0);
        let p = p0 + v * 4.0 * (1.0 - e) - vec3<f32>(0.0, 0.5 * VC_G * s * s, 0.0);
        if (p.y < 0.0) {
            continue;
        }
        let vn = v * e - vec3<f32>(0.0, VC_G * s, 0.0);
        let a = p + C;
        let b = a - vn * 0.05;
        let sg = pl_ray_seg(rd, a, b, 0.0, 1.0);
        if (sg.y <= 1.0 || sg.y > tmax + 30.0) {
            continue;
        }
        let px = sg.x * focal / sg.y;
        let rpx = clamp((2.0 + 3.0 * mh(i, seed, 0x945u)) * focal / sg.y, 0.8, 6.0);
        if (px > 3.0 * rpx) {
            continue;
        }
        let core = saturate(1.0 - px / rpx);
        let hot = exp(-s / 3.0);
        c = c + tr * core * (vec3<f32>(0.03, 0.022, 0.018) + vec3<f32>(1.5, 0.42, 0.06) * hot * hot * (1.0 - sg.z * 0.8));
        tr = tr * (1.0 - core);
    }
    return vec4<f32>(c, tr);
}

// ---- the bolts themselves: what of a flash is seen as lightning, sharp, at full size ----
// Where a flash's channel runs: from f.p along this, in blocks. A bolt out of the column's flank or down out of the sheet
// to the land; in the plume out of its side, down and across; in the sheet running along under it, forking.
fn vc_flash_way(f: VcFlash, seed: u32) -> vec3<f32> {
    let sid = u32(f.id);
    let th = TAU * mh(sid, seed, 0x911u);
    let h = mh(sid, seed, 0x912u);
    let out = atan2(f.p.z, f.p.x) + 1.1 * (mh(sid, seed, 0x913u) - 0.5);
    if (f.kind == 1u) {
        var foot = f.p.xz + vec2<f32>(cos(th), sin(th)) * (120.0 + 320.0 * h);
        if (f.ring < 0.5) {
            // (clear of the blast's foot and of what the flows have covered)
            foot = vec2<f32>(cos(out), sin(out)) * max(max(vs.Rb, vs.rf), length(f.p.xz)) * (1.45 + 0.6 * h);
        }
        // (a bolt near the player comes down between them and the cloud: past the column it would never be seen)
        let me = vc_me();
        if (length(f.p.xz - me) < 1500.0) {
            let w = normalize(-me + vec2<f32>(1.0e-3, 0.0));
            let across = vec2<f32>(-w.y, w.x);
            foot = me + w * clamp(dot(f.p.xz - me, w) - 60.0 - 140.0 * h, 190.0, 560.0) + across * (0.8 * dot(f.p.xz - me, across) + 300.0 * (mh(sid, seed, 0x914u) - 0.5));
        }
        return vec3<f32>(foot.x, vc_land(foot), foot.y) - f.p;
    }
    if (f.ring > 0.5) {
        return vec3<f32>(cos(th) * 720.0, -40.0 - 50.0 * h, sin(th) * 720.0);
    }
    return vec3<f32>(cos(out) * 320.0, -200.0 - 280.0 * h, sin(out) * 320.0);
}
// A channel on the picture (hu_lin, hu_kink, hu_channel: the Supercell's), kinked at every scale, sharp bends, never smooth.
fn vc_lin(x: f32, s: f32) -> f32 {
    let i = floor(x);
    return mix(fh21(vec2<f32>(i, s)), fh21(vec2<f32>(i + 1.0, s)), x - i) * 2.0 - 1.0;
}
// (.x all of it, .y its large scales alone)
fn vc_kink(u: f32, s: f32, fq: f32) -> vec2<f32> {
    let v = u * fq;
    let big = 0.11 * vc_lin(v * 4.0, s) + 0.05 * vc_lin(v * 11.0, s + 1.7);
    return vec2<f32>(big + 0.024 * vc_lin(v * 29.0, s + 3.1) + 0.011 * vc_lin(v * 70.0, s + 5.3), big) / sqrt(fq);
}
fn vc_channel(px: vec2<f32>, sa: vec2<f32>, sb: vec2<f32>, s: f32, w: f32, pin: bool, fq: f32, jag: f32) -> vec3<f32> {
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let ap = px - sa;
    let u = clamp(dot(ap, dir) / L, 0.0, 1.0);
    let env = select(1.0, sqrt(max(1.0 - u, 0.0)) * 1.15, pin) * smoothstep(0.0, 0.04, u);
    let k0 = vc_kink(u, s, fq) * env * jag;
    let k1 = vc_kink(u + 0.002, s, fq).x * env * jag;
    let slope = (k1 - k0.x) / 0.002;
    let along = dot(ap, dir) - u * L;
    let off = (dot(ap, nrm) - k0.x * L) / sqrt(1.0 + slope * slope);
    let d = length(vec2<f32>(off, along));
    // (the bloom round its large scales only: the fine kinks, a row of pixels each, would comb it into stripes)
    let dg = length(vec2<f32>(dot(ap, nrm) - k0.y * L, along));
    let g = 1.0 / (1.0 + pow(dg / (w * 9.0), 2.0));
    return vec3<f32>(exp(-pow(d / w, 2.0)), g * g, u);
}
// How much is seen of what is `dm` off along the ray: hidden by the land (`near`) and the cloud (`ct` its distance, `ca`
// what shows through it), but a little through the ash just under the cloud's face.
fn vc_seen(dm: f32, near: f32, ct: f32, ca: f32) -> f32 {
    if (near < dm - 3.0) {
        return 0.0;
    }
    if (dm <= ct) {
        return 1.0;
    }
    return max(ca, VC_THRU * (1.0 - smoothstep(100.0, 900.0, dm - ct)));
}
// (a and b, camera-relative, brought in front of the eye: a bolt overhead has its root behind it)
fn vc_clip_w(p: vec3<f32>) -> f32 {
    return (frame.projection * (frame.view * vec4<f32>(p, 1.0))).w;
}
fn vc_near_end(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    let wa = vc_clip_w(a);
    let wb = vc_clip_w(b);
    if (wa >= 1.0 || wb <= wa) {
        return a;
    }
    return mix(a, b, (1.0 - wa) / (wb - wa));
}
// A jagged channel from a to b (camera-relative) on the picture, three forks off it (hu_bolt): x its core, y its bloom.
fn vc_bolt(px: vec2<f32>, a: vec3<f32>, b: vec3<f32>, seed: f32, near: f32, ct: f32, ca: f32) -> vec2<f32> {
    let pa = project_rel(a);
    let pb = project_rel(b);
    if (pa.z < 0.0 || pb.z < 0.0) {
        return vec2<f32>(0.0);
    }
    let res = frame.resolution.xy;
    let sa = pa.xy * res;
    let sb = pb.xy * res;
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let la = length(a);
    let lb = length(b);
    let focal = res.y / (2.0 * tan(frame.view_params.w * 0.5));
    let w = clamp(VC_CHAN_W * focal / (0.5 * (la + lb)), 1.2, 4.0);
    let u0 = saturate(dot(px - sa, ab) / (L * L));
    if (length(px - (sa + ab * u0)) > 0.5 * L + 40.0 * w) {
        return vec2<f32>(0.0);
    }
    // (kinked for its length in blocks: this cloud's bolts run ten times the Hurricane's, so its scales are larger too)
    let fq = max(length(a - b) / VC_KINK_LEN, 1.0);
    var core = 0.0;
    var glow = 0.0;
    if (length(px - (sa + ab * u0)) < 0.2 * L + 40.0 * w) {
        let m = vc_channel(px, sa, sb, seed, w, true, fq, 1.35);
        let seen = vc_seen(mix(la, lb, m.z), near, ct, ca);
        core = m.x * seen * seen;
        glow = m.y * seen;
    }
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    for (var k = 0; k < 3; k = k + 1) {
        let fk = f32(k);
        let u = 0.15 + 0.55 * fract(seed * 0.618 + fk * 0.377);
        let root = sa + ab * u + nrm * vc_kink(u, seed, fq).x * sqrt(1.0 - u) * 1.15 * 1.35 * L;
        let side = select(-1.0, 1.0, fract(seed * 0.71 + fk * 0.53) > 0.5);
        let bdir = normalize(dir + nrm * side * (0.55 + 0.6 * fract(seed * 1.3 + fk * 0.7)));
        let lf = L * (0.16 + 0.26 * fract(seed * 0.9 + fk * 0.77));
        let end = root + bdir * lf;
        // (only near it: no fork's work over the whole of the bolt's box)
        let uf = saturate(dot(px - root, bdir) / lf);
        if (length(px - root - bdir * uf) > 0.22 * lf + 40.0 * w * 0.6) {
            continue;
        }
        let f = vc_channel(px, root, end, seed + 7.0 + fk * 3.3, w * 0.6, false, fq, 1.6);
        let fs = vc_seen(mix(la, lb, u), near, ct, ca) * pow(1.0 - f.z, 1.6);
        core = core + f.x * fs * fs;
        glow = glow + f.y * fs * 0.7;
    }
    return vec2<f32>(core, glow);
}
// The return stroke's column from a to b (camera-relative) on the picture (hu_beam): a thick soft rod of light, straight
// but for a gentle wave, drawn up off the land from `ue` (1: down to b, 0: none), its foot a point: x its core, y its halo.
fn vc_beam(px: vec2<f32>, a: vec3<f32>, b: vec3<f32>, seed: f32, ue: f32, near: f32, ct: f32, ca: f32) -> vec2<f32> {
    let pa = project_rel(a);
    let pb = project_rel(b);
    if (pa.z < 0.0 || pb.z < 0.0 || ue <= 0.01) {
        return vec2<f32>(0.0);
    }
    let res = frame.resolution.xy;
    let sa = pa.xy * res;
    let sb = pb.xy * res;
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let la = length(a);
    let lb = length(b);
    let focal = res.y / (2.0 * tan(frame.view_params.w * 0.5));
    let ap = px - sa;
    let u = clamp(dot(ap, dir) / L, 0.0, 1.0);
    let dm = mix(la, lb, u);
    let wc = max(VC_BEAM_R * focal / max(dm, 1.0), 1.4);
    let off0 = dot(ap, nrm);
    if (abs(off0) > 0.12 * L + 14.0 * wc) {
        return vec2<f32>(0.0);
    }
    // (a gentle wave, the large scales of the leader's kinks only)
    let wave = (0.03 * vc_lin(u * 3.0, seed) + 0.015 * vc_lin(u * 8.0, seed + 1.7)) * L * smoothstep(0.0, 0.05, u);
    let along = dot(ap, dir) - u * L;
    let d = length(vec2<f32>(off0 - wave, along));
    // (drawn up: thinning to a point at its foot)
    let taper = sqrt(saturate((ue - u) / 0.18)) * smoothstep(0.0, 0.03, u);
    let r = wc * taper;
    let seen = vc_seen(dm, near, ct, ca) * step(u, ue);
    let core = exp(-pow(d / max(r * 0.7, 0.6), 2.0)) * step(0.001, taper);
    let halo = 1.0 / (1.0 + pow(d / max(r * 2.2, 1.0), 2.0)) * taper;
    return vec2<f32>(core * seen, halo * halo) * seen;
}
// The bolts of the flashes under way, on the picture (hu_bolts): `near` how far the land is.
fn vc_bolts(fl: VcFlashes, C: vec3<f32>, seed: u32, near: f32, ct: f32, ca: f32, pxy: vec2<f32>) -> vec3<f32> {
    var c = vec3<f32>(0.0);
    for (var i = 0; i < 3; i = i + 1) {
        let f = fl.f[i];
        if (f.kind == 0u) {
            continue;
        }
        let dv = vc_flash_way(f, seed);
        var root = f.p;
        if (f.kind == 2u && f.ring > 0.5) {
            // (along under the sheet, out of the cloud: its underside as vc_umb has it)
            let r = length(f.p.xz);
            root.y = VC_HU - 0.9 * (210.0 + 240.0 * exp(-r * r / 1.44e6)) - 230.0 * exp(-r * r / 6.4e5) - 30.0;
        }
        let a = f.a;
        let n = f.n;
        let s0 = f32(pcg(u32(f.id) ^ seed) & 1023u) * 0.37;
        var tip = C + root + dv;
        var lk = vc_lead_k(a, n);
        var shape = f32(u32(a * 30.0));
        if (f.kind == 2u) {
            // (a channel alone: one shape from the leader's on, it stands while a return stroke would)
            lk = max(lk, vc_beam_k(a, n));
            shape = select(0.0, shape, a < VC_LEAD || a > 0.27);
        } else if (a > VC_LEAD && (n & 16u) != 0u) {
            // (a re-stroke now and then across the cloud instead, out of the root sideways)
            let side = normalize(vec3<f32>(-root.z, 0.0, root.x)) * select(-1.0, 1.0, (n & 32u) != 0u);
            tip = C + root + side * (340.0 + 260.0 * f32((n >> 6u) & 7u) / 7.0) - vec3<f32>(0.0, 120.0, 0.0);
        }
        let top = vc_near_end(C + root, tip);
        if (lk > 0.0) {
            let m = vc_bolt(pxy, top, tip, s0 + shape * 5.3, near, ct, ca);
            c = c + (vec3<f32>(1.0, 0.98, 1.0) * m.x * 2.4 + vec3<f32>(0.62, 0.6, 1.0) * m.y * 0.6) * lk;
        }
        if (f.kind == 1u) {
            // (the return stroke's column)
            let bk = vc_beam_k(a, n);
            if (bk > 0.0) {
                let ue = 1.0 - smoothstep(0.17, 0.27, a);
                let m = vc_beam(pxy, top, C + root + dv, s0, ue, near, ct, ca);
                c = c + (vec3<f32>(1.0, 0.98, 1.0) * m.x * 3.0 + vec3<f32>(0.66, 0.64, 1.0) * m.y * 1.1) * bk;
            }
        }
    }
    return c;
}
// A bolt's column lighting the land round its foot (`q` off the vent: hu_flash_at).
fn vc_flash_land(fl: VcFlashes, q: vec3<f32>, seed: u32) -> f32 {
    var e = 0.0;
    for (var i = 0; i < 3; i = i + 1) {
        let f = fl.f[i];
        if (f.kind == 1u) {
            let k = vc_beam_k(f.a, f.n) + 0.4 * vc_lead_k(f.a, f.n);
            let d = q - f.p - vc_flash_way(f, seed);
            e = e + 2.4 * k / (1.0 + dot(d, d) / VC_FOOT_R2);
        }
    }
    return e;
}

// ---- what hangs in the air round the eye: flakes of ash coming down, embers driven past (as the Hurricane's rain: strung
// along lines the way they move, the lines' feet on a grid across it, layers out from the eye on coarser grids) ----
fn vc_specks(rd: vec3<f32>, cq: vec3<f32>, vel: vec3<f32>, near: f32, time: f32, thin: f32, wpx0: f32) -> f32 {
    let spd = length(vel);
    let w = vel / max(spd, 1.0e-3);
    let e1 = normalize(cross(w, select(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(1.0, 0.0, 0.0), abs(w.x) < 0.9)));
    let e2 = cross(w, e1);
    let c2 = vec2<f32>(dot(cq, e1), dot(cq, e2));
    let r2 = vec2<f32>(dot(rd, e1), dot(rd, e2));
    let rr = dot(r2, r2);
    let rw = dot(rd, w);
    let aw0 = dot(cq, w);
    let focal = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
    var sum = 0.0;
    for (var k = 0; k < 3; k = k + 1) {
        let fk = f32(k);
        let cell = 1.1 * pow(2.2, fk);
        let ta = 2.0 * pow(2.2, fk);
        let tb = min(ta * 2.2, near);
        if (ta >= tb) {
            break;
        }
        let pa = c2 + r2 * ta;
        let pb = c2 + r2 * tb;
        var last = vec2<f32>(1.0e9);
        for (var n = 0; n < 4; n = n + 1) {
            let g = floor(mix(pa, pb, (f32(n) + 0.5) / 4.0) / cell);
            if (all(g == last)) {
                continue;
            }
            last = g;
            let hb = pcg(bitcast<u32>(i32(g.x)) * 0x9E3779B1u ^ pcg(bitcast<u32>(i32(g.y)) * 0x85EBCA6Bu ^ u32(k) * 0x27D4EB2Fu));
            if (f32(hb & 0xFFFFu) / 65535.0 > thin) {
                continue;
            }
            let hc = pcg(hb);
            let p = (g + vec2<f32>(0.15) + 0.7 * vec2<f32>(f32(hc & 0xFFFFu), f32(hc >> 16u)) / 65535.0) * cell;
            let ts = clamp(select(0.5 * (ta + tb), dot(p - c2, r2) / rr, rr > 1.0e-6), ta, tb);
            let d = length(c2 + r2 * ts - p);
            let px = d * focal / ts;
            let wpx = wpx0 / (1.0 + 0.4 * fk);
            if (px > 3.0 * wpx) {
                continue;
            }
            let hd = pcg(hc ^ 0x51u);
            let period = cell * (2.5 + 3.5 * f32(hd & 255u) / 255.0);
            let len = cell * 0.09;
            let x0 = (aw0 + rw * ts - spd * time) / period + f32(hd >> 24u) / 255.0;
            let fx = fract(x0) / (len / period);
            let on = step(fx, 1.0) * (0.15 + 0.85 * fx * fx);
            sum = sum + on * exp(-px * px / (wpx * wpx)) * (0.3 + 0.9 * f32(hc & 255u) / 255.0);
        }
    }
    return sum;
}

// ---- the march ----
struct VcMarch {
    c: vec3<f32>,      // premultiplied colour
    tr: f32,           // transmittance
    t: f32,            // how far off, where it is most of it (1e9: none)
}
struct VcLight {
    L: vec3<f32>,
    sunc: vec3<f32>,
    skyl: vec3<f32>,
    amb: vec3<f32>,
    haze: vec3<f32>,
    day: f32,
    warm: f32,
    sun_up: f32,
    seed: u32,
    night: f32,
}
// Fire by temperature (0 to 1): a dull red, orange, yellow-white, as a flame's light.
fn vc_fire_c(T: f32) -> vec3<f32> {
    let a = mix(vec3<f32>(0.0), vec3<f32>(0.5, 0.05, 0.008), saturate(T * 3.2));
    let b = mix(a, vec3<f32>(1.25, 0.3, 0.035), saturate(T * 3.0 - 0.8));
    return mix(b, vec3<f32>(3.0, 1.75, 0.5), saturate(T * 2.2 - 1.05));
}
// How hot the smoke is at q, 0 to 1 (`top` how far up a dome it is): pockets of fire flaring and dying where a broad
// noise lets them, in the creases more than on the crowns; all of the blast at first, then (`old`) only low down near the
// vents as it cools into grey-brown ash. .y the broad glow round them, what the smoke nearby is lit by.
fn vc_heat(q: vec3<f32>, hy: f32, top: f32) -> vec2<f32> {
    let a = vs.a;
    if (a <= 0.0 || vs.c > 14.0) {
        return vec2<f32>(0.0);
    }
    // (how high it burns: nearly all the blast, then sinking to the column's foot, in to the vents)
    let old = smoothstep(10.0, 24.0, a);
    let hf = mix(0.62 * vs.Hd, 0.5 * min(vs.H, 1500.0), smoothstep(5.0, 15.0, a)) * mix(1.0, 0.2, old);
    var zone = (1.0 - smoothstep(0.45 * hf, 1.2 * hf, hy)) * (1.0 - smoothstep(4.0, 14.0, vs.c));
    if (a > 10.0) {
        zone = zone * (1.0 - smoothstep(10.0, 16.0, a) * smoothstep(VC_RING, VC_RING + 380.0, length(q.xz)));
    }
    if (zone <= 0.0) {
        return vec2<f32>(0.0);
    }
    let qf = q - vec3<f32>(0.0, 44.0 * vs.t, 0.0);
    let n1 = vc_gn3(VC_R1 * qf * (1.0 / 230.0) + vec3<f32>(0.0, 0.0, 0.14 * vs.t));
    let n2 = vc_gn3(VC_R2 * qf * (1.0 / 84.0) + vec3<f32>(1.7, 0.21 * vs.t, 0.0));
    let gate = vc_gn3(vec3<f32>(q.x, 0.5 * q.y, q.z) * (1.0 / 560.0) + vec3<f32>(0.0, -0.05 * vs.t, 0.19 * vs.t));
    let n = 0.6 * n1 + 0.4 * n2 + 0.42 * (gate - 0.5);
    let cool = smoothstep(1.5, 11.0, a);
    let thr = mix(0.5, 0.565, cool);
    let T = smoothstep(thr, thr + 0.1, n) * zone;
    // (tongues of flame in it, drawn up, soot between them: never a flat fill)
    let n3 = vc_gn3(VC_R3 * (q * vec3<f32>(1.0 / 26.0, 1.0 / 58.0, 1.0 / 26.0) - vec3<f32>(0.0, 2.0 * vs.t, 0.0)));
    let tongues = saturate(0.2 + 2.1 * (0.7 * n3 + 0.3 * n2) - 0.45);
    // (a crown's skin cools first: the fire shows between the lumps; less so while the blast is young)
    let cr = 1.0 - top;
    let skin = mix(mix(0.3 + 1.1 * cr * cr, 0.2 + 1.3 * cr * cr, cool), 1.5 * cr * cr, old);
    let hot = (0.8 - 0.16 * cool) * (0.5 + 0.75 * n1);
    let far = 1.0 - 0.7 * smoothstep(14.0, 28.0, a);
    return vec2<f32>(1.2 * pow(saturate(T * skin) * hot * tongues, 1.35 + 0.7 * old), mix(0.5, 1.0, cool) * smoothstep(0.46, 0.74, 0.7 * n1 + 0.5 * (gate - 0.2)) * zone * mix(1.0, zone, cool) * far * (0.45 + 0.9 * tongues));
}
// The air's colour along a ray: the sky's, gone dirty and red low down as the sheet closes over.
fn vc_band(rd: vec3<f32>) -> vec3<f32> {
    let e = saturate(rd.y * 3.2);
    return mix(vec3<f32>(0.46, 0.195, 0.08), vec3<f32>(0.16, 0.056, 0.03), smoothstep(0.0, 1.0, e));
}
fn vc_haze(rd: vec3<f32>, l: VcLight) -> vec3<f32> {
    let lum = dot(l.skyl, vec3<f32>(0.2126, 0.7152, 0.0722));
    return mix(l.haze, vec3<f32>(lum) * vc_band(rd), smoothstep(0.1, 0.7, vs.cov));
}
fn vc_march(C: vec3<f32>, rd: vec3<f32>, tmax: f32, j: f32, l: VcLight, fls: VcFlashes) -> VcMarch {
    var o: VcMarch;
    o.c = vec3<f32>(0.0);
    o.tr = 1.0;
    o.t = 1.0e9;
    vc_tk = vec4<f32>(1.0e9);
    vc_tx = vec2<f32>(1.0);
    vc_cm = 1.0;
    let t_end = min(tmax, 32000.0);
    let time = vs.t;
    if (time < VC_ERUPT + 0.9) {
        return o;
    }
    var t = 0.0;
    var tsun = 1.0;
    var ao = 1.0;
    var rim = 0.0;
    var below = 0.0;
    var inband = false;
    var face = 1.0;
    vc_cq = vec4<f32>(1.0e7);
    vc_cs = 0.0;
    var hs = pcg(u32(vc_px.x) ^ (u32(vc_px.y) << 13u) ^ (u32(fract(time * 7.0) * 1024.0) << 3u));
    var wmid = 0.0;
    var tmid = 0.0;
    // (the brightest flash lights the cloud: one, so the march keeps little in hand)
    var glw = fls.f[0];
    if (fls.f[1].k > glw.k) {
        glw = fls.f[1];
    }
    if (fls.f[2].k > glw.k) {
        glw = fls.f[2];
    }
    let gw = vc_flash_way(glw, l.seed);
    let gw2 = max(dot(gw, gw), 1.0);
    let ph = 0.75 + (0.45 + 1.3 * l.warm) * pow(saturate(dot(rd, l.L)), 5.0);
    // (two runs of one loop, the look at the light between them: a GPU's group pays for a branch at any step any of its
    // pixels takes it, and lasts as long as its slowest. Out here it looks once)
    var i = 0;
    var lq = vec3<f32>(0.0);
    var lb: VcB;
    var lsd = vec4<f32>(0.0);
    var lfoot = 0.0;
    for (var leg = 0; leg < 2; leg = leg + 1) {
    var look = false;
    for (; i < 132; i = i + 1) {
        if (t > t_end || o.tr < 0.05) {
            break;
        }
        let p = rd * t;
        let q = p - C;
        var b = vc_base(q);
        let foot = t * vs.px * vs.fine;
        if (b.d > VC_DM + 12.0) {
            let s = vc_skip(q, rd, &b);
            inband = false;
            if (s > 20.0) {
                t = t + s * 0.97;
                // (going away from everything: nothing more on this ray)
                if (s > 1.0e5) {
                    break;
                }
                continue;
            }
            t = t + max((b.d - VC_DM) * 0.6, 8.0);
            inband = false;
            continue;
        }
        // (every stride jittered by white noise, the first into the band too: a stride that lands alike from pixel to pixel
        // slices the smoke into contours, and a pattern of jitter shows as a halftone over thin smoke)
        hs = pcg(hs + u32(i));
        let jt = f32(hs & 0xffffu) / 65535.0;
        if (!inband) {
            inband = true;
            t = t + jt * max(4.0, t * 0.0034);
            continue;
        }
        let st = VC_ST * max(4.0, t * 0.0034) * (0.7 + 0.6 * jt) * (1.0 + 3.0 * vs.thin);
        // (still well off the surface: one set of the big lumps is enough to step by)
        if (b.d > 50.0) {
            let sc = vc_sdf(q, &b, foot, false).x;
            if (sc > 80.0) {
                t = t + 0.5 * (sc - 50.0);
                continue;
            }
        }
        let steam = (1.0 - smoothstep(-0.6, 0.0, vs.a)) * step(b.dc, min(b.df, b.du));
        // (the wall of ash torn into rolling banks behind its head, rolling past as it comes on, thinning to nothing a few
        // seconds behind the front, all but the clouds lifting off it)
        var ext = 0.15;
        var wb = 0.0;
        var torn = 1.0;
        if (b.df < 40.0) {
            let dir = q.xz / max(b.rho, 1.0);
            let hb = q.y - b.land;
            let qb = vec3<f32>(q.x - dir.x * vs.rf * 1.6, hb * 1.25 - 26.0 * time, q.z - dir.y * vs.rf * 1.6);
            let bank = 0.62 * vc_gn3(qb * (1.0 / 150.0) + vec3<f32>(0.0, 0.0, 0.11 * time)) + 0.38 * vc_gn3(VC_R2 * qb * (1.0 / 58.0));
            // (its head solid to the land; torn into banks, lifted off it, only behind)
            wb = smoothstep(40.0, 200.0, b.e);
            // (the ash lifting clear: the air under it empties, the land shows, a rolling ceiling over it)
            let lf = smoothstep(VC_LIFT - 8.0, VC_LIFT + 6.0, time) * smoothstep(150.0, 520.0, b.e);
            let base = lf * (250.0 + 340.0 * (bank - 0.5));
            let lifted = lf * smoothstep(180.0, 420.0, hb);
            let th = mix(mix(0.36, 0.56, smoothstep(40.0, 560.0, b.e)), 0.36, lifted);
            torn = smoothstep(base - 40.0, base + 110.0, hb + 150.0 * (1.0 - wb)) * mix(1.0, smoothstep(th - 0.08, th + 0.2, bank), wb);
            ext = mix(0.15, 0.05, wb);
            // (the air the wall has emptied)
            if (torn <= 0.0) {
                t = t + max(st * VC_ST_AIR, 14.0);
                continue;
            }
        }
        var den = 0.0;
        var sd = vec4<f32>(b.d, 0.5, 8.0, 0.5);
        if (b.d < -VC_DM - 8.0) {
            den = 1.0;
        } else {
            sd = vc_sdf(q, &b, foot, true);
            // (the smoke's edge crisp over a crown, loose and wispy in the creases; frayed where it is thin)
            let edge = mix(36.0, 9.0, saturate(sd.y * 1.25)) + foot * 1.6 + 160.0 * vs.thin;
            let ramp = saturate(-sd.x / edge);
            den = ramp * mix(saturate(0.22 + 1.5 * sd.w), 1.0, ramp);
        }
        den = den * torn;
        if (steam > 0.0) {
            ext = mix(ext, 0.016, steam);
        }
        if (den > 1.0e-4) {
            let hy = q.y;
            let hyl = hy - select(0.0, vc_land(q.xz), hy < 600.0);
            if (leg == 0) {
                look = true;
                lq = q;
                lb = b;
                lsd = sd;
                lfoot = foot;
                break;
            }
            // ---- its colour: charcoal and umber, pale steam over the blast, paler on the umbrella's top and the flows ---
            let wc = saturate(1.0 + (min(b.du, b.df) - b.dc) / 70.0);
            let wf = saturate(1.0 + (min(b.dc, b.du) - b.df) / 70.0);
            // (the sheet takes on its own colours as it spreads, out of the column's)
            let wu = saturate(1.0 + (min(b.dc, b.df) - b.du) / 70.0) * smoothstep(VC_SPREAD + 1.0, VC_SPREAD + 6.0, time);
            let mott = vc_gn3(q * (1.0 / 380.0) + vec3<f32>(3.0, -0.03 * time, 1.0));
            var alb = mix(vec3<f32>(0.075, 0.066, 0.06), vec3<f32>(0.2, 0.172, 0.15), smoothstep(0.3, 0.72, mott));
            // (a head of steam and pale ash riding the top of what is rising, going dark as it climbs and mixes)
            let crown = smoothstep(0.55 * vs.H - 40.0, 0.92 * vs.H, hy) * (1.0 - smoothstep(9.0, 23.0, vs.a)) * smoothstep(0.34, 0.6, mott + 0.3 * sd.y);
            alb = mix(alb, vec3<f32>(0.5, 0.48, 0.46), crown * step(0.0, vs.a));
            // (the sheet's sunlit top pale, as ash spread thin; its underside as dark as the column)
            alb = mix(alb, mix(vec3<f32>(0.115, 0.1, 0.09), vec3<f32>(0.25, 0.225, 0.2), smoothstep(VC_HU - 40.0, VC_HU + 180.0, hy)) * (0.8 + 0.4 * mott), wu);
            alb = mix(alb, vec3<f32>(0.115, 0.1, 0.092) * (0.72 + 0.56 * mott), wf);
            alb = mix(alb, vec3<f32>(0.75, 0.74, 0.72), steam);
            alb = alb * mix(1.0, 0.42, wc * (1.0 - smoothstep(0.35 * vs.H, 0.8 * vs.H, hy)) * (1.0 - crown));
            let sk = vc_sky_t(q);
            let sk_l = dot(l.skyl, vec3<f32>(0.2126, 0.7152, 0.0722));
            // (the sky's light, and under the sheet the brown light that gets in round its edge)
            let skyg = mix(mix(l.skyl, vec3<f32>(sk_l), 0.7), vec3<f32>(sk_l) * vec3<f32>(1.0, 0.72, 0.52), vs.cov);
            var c = alb * (skyg * (0.06 + 0.66 * ao) * (0.03 + 0.97 * sk * sk) + (l.sunc * (1.5 * tsun * ph) + vec3<f32>(0.9, 0.55, 0.32) * sk_l * rim * vs.cov * 0.8 * saturate(0.25 + 1.2 * b.rho / vs.Ru)) * face * mix(0.78, 1.12, sd.y));
            // ---- fire: pockets low in it, the smoke round them lit by them and from below ----
            let on = smoothstep(0.0, 0.4, vs.a);
            let ht = vc_heat(q, hyl, sd.y);
            var fire = vec3<f32>(0.0);
            if (ht.x > 0.0) {
                fire = vc_fire_c(ht.x) * on;
                // (fire under the skin outshines what falls on it)
                c = c * (1.0 - saturate(ht.x * 2.5));
            }
            // (the light of the fire on the smoke round it)
            let ash = min(alb, vec3<f32>(0.13));
            let cr = 1.0 - sd.y;
            c = c * (1.0 - 0.62 * ht.y * on);
            fire = fire + ash * vec3<f32>(2.5, 0.95, 0.15) * ht.y * (0.3 + 0.7 * cr) * on;
            // (from under: the land burning below what hangs over it)
            let fb = (1.0 - smoothstep(VC_COLLAPSE, VC_COLLAPSE + 6.0, time)) * on;
            fire = fire + ash * vec3<f32>(1.5, 0.42, 0.07) * below * below * (0.3 + 0.7 * cr) * exp(-max(hyl, 0.0) / 300.0) * fb;
            // (the vents' glow on the column's foot, fading with height)
            if (vs.a > 10.0 && time < VC_LIFT) {
                fire = fire + ash * vec3<f32>(4.0, 1.0, 0.16) * exp(-max(hyl, 0.0) / 130.0) * (1.0 - smoothstep(VC_RING, VC_RING + 520.0, b.rho)) * smoothstep(10.0, 18.0, vs.a) * (1.0 - smoothstep(VC_COLLAPSE, VC_LIFT, time)) * (0.4 + 0.6 * cr);
            }
            if (b.e > -60.0) {
                // (the flows, close behind the front and low down: the hot base of the cloud showing in its creases; inside the
                // wall, the banks lit red from under by what they have laid down)
                let h = hy - b.land;
                fire = fire + ash * vec3<f32>(1.5, 0.36, 0.09) * wb * (0.03 + exp(-max(h, 0.0) / 70.0)) * (1.0 - smoothstep(VC_LIFT, VC_RED, time));
                let crease = (1.0 - sd.y) * (1.0 - sd.y);
                let ember = exp(-max(h, 0.0) / 26.0) * (1.0 - smoothstep(380.0, 1400.0, b.rho)) * exp(-max(b.e, 0.0) / 170.0) * smoothstep(40.0, 200.0, t);
                fire = fire + vec3<f32>(1.0, 0.2, 0.03) * ember * crease * 1.6 * wf;
            }
            // (the sheet's underside: the fire's dull red on it round the column, its pouches catching it)
            if (wu > 0.0 && hy < VC_HU) {
                let glw = exp(-b.rho / 1100.0) * (0.15 + 0.85 * sd.y * sd.y) * (1.0 - smoothstep(VC_COLLAPSE + 2.0, VC_LIFT, time));
                fire = fire + vec3<f32>(0.2, 0.045, 0.01) * glw * smoothstep(0.0, 6.0, vs.a) * wu;
            }
            c = c + fire;
            // (the lightning in it: along its channel, lighting the cloud a long way round)
            var lg = 0.0;
            if (glw.k > 0.02) {
                let dd = q - glw.p - gw * saturate(dot(q - glw.p, gw) / gw2);
                lg = glw.k / (1.0 + dot(dd, dd) / (340.0 * 340.0));
            }
            c = c + (min(alb, vec3<f32>(0.2)) * 3.4 + 0.012) * vec3<f32>(0.72, 0.72, 1.0) * lg * 2.4;
            let al = 1.0 - exp(-den * ext * st);
            o.c = o.c + o.tr * al * c;
            tmid = tmid + o.tr * al * t;
            wmid = wmid + o.tr * al;
            o.tr = o.tr * (1.0 - al);
            vc_tk = min(vc_tk, select(vec4<f32>(1.0e9), vec4<f32>(t), vec4<f32>(o.tr) < vec4<f32>(0.9, 0.6, 0.3, 0.1)));
        }
        t = t + select(st, max(0.65 * sd.x, st * (0.5 + 0.03 * f32(i))), sd.x > 0.0);
    }
    if (!look) {
        break;
    }
    {
        let q = lq;
        var b = lb;
        let sd = lsd;
        let foot = lfoot;
        let hy = q.y;
        let hyl = hy - select(0.0, vc_land(q.xz), hy < 600.0);
            // (the light: looks on the way to the sun through the lumps, close and further, then through the bulk of the
            // cloud; in the sheet's shadow what light there is comes in low from the open sky round its edge)
            let st0 = vc_sun_t(q, l.L);
            let Lr = normalize(vec3<f32>(q.x, -0.4 * b.rho, q.z));
            let Lf = normalize(mix(Lr, l.L, smoothstep(0.15, 0.75, st0)));
            let f1q = q + Lf * 24.0;
            var fb1 = vc_base(f1q);
            let f1 = vc_sdf(f1q, &fb1, 40.0, false).x;
            let f2q = q + Lf * 78.0;
            var fb2 = vc_base(f2q);
            let f2 = vc_sdf(f2q, &fb2, 40.0, false).x;
            let o1 = saturate(0.5 - f1 / 40.0);
            let o2 = saturate(0.5 - f2 / 74.0);
            // (the sheet's underside, in its own shadow, needs no looks at the bulk: most of what fills the sky)
            let under = b.du < min(b.dc, b.df) && hy < VC_HU && st0 < 0.3;
            var s3 = 0.0;
            var s4 = 0.0;
            if (!under) {
                s3 = saturate((10.0 - vc_dist(q + Lf * 240.0)) / 120.0);
                s4 = saturate((10.0 - vc_dist(q + Lf * 560.0)) / 260.0);
            }
            let tau = 1.35 * o1 + 1.9 * o2 + 2.2 * s3 + 2.6 * s4;
            let lit = exp(-tau);
            // (and close to, the small lumps' own faces: which side of each looks at the light)
            face = 1.0;
            if (foot < 24.0) {
                let rs = sd.x + 40.0;
                face = 0.7 + 0.62 * saturate(0.5 - (vc_fine(q + Lf * 11.0, rs, foot).x - vc_fine(q, rs, foot).x) / 40.0);
            }
            tsun = lit * st0 * (1.0 - 0.5 * l.warm);
            rim = lit * (1.0 - smoothstep(0.15, 0.75, st0));
            // (the sky's light shut out from under what hangs over it and deep in it)
            let occ = select(saturate((10.0 - vc_dist(q + vec3<f32>(0.0, 190.0, 0.0))) / 150.0), 1.0, under);
            let deep = saturate(-sd.x / 90.0);
            ao = (0.4 + 0.6 * sd.y * sd.y) * (1.0 - 0.72 * occ) * (1.0 - 0.6 * deep);
            // (and open below it? the fire over the land lights what looks down on it)
            below = 0.0;
            if (hyl < 700.0 && time < VC_COLLAPSE + 6.0) {
                let dq = q - vec3<f32>(0.0, 46.0, 0.0);
                var db = vc_base(dq);
                below = saturate((vc_sdf(dq, &db, 40.0, false).x - vc_sdf(q, &b, 40.0, false).x + 6.0) / 64.0);
            }
    }
    }
    // (out of steps under the sheet, rising to it: it is met, so far off it is the haze. Else bands where steps ran out)
    let qe = rd * t - C;
    if (vs.Ru > 10.0 && i >= 132 && o.tr > 0.05 && rd.y > 0.0 && qe.y < VC_HU - 190.0) {
        let th = t + (VC_HU - 190.0 - qe.y) / rd.y;
        let k = o.tr * (1.0 - smoothstep(0.75 * vs.Ru, vs.Ru, length((rd * th - C).xz))) * (1.0 - smoothstep(0.7 * t_end, t_end, th));
        o.c = o.c + k * vc_haze(rd, l) * 0.75;
        tmid = tmid + k * th;
        wmid = wmid + k;
        o.tr = o.tr - k;
    }
    // (what the march left of the land behind it, once it stopped for being nearly opaque, is nothing)
    o.tr = saturate((o.tr - 0.051) / 0.949);
    // (thinning at the end: all of it lets the light through, more here and there, red as it goes; thinned in the
    // density, a cloud this deep would stay opaque, then clear along a hard edge)
    if (vs.thin > 0.0 && o.tr < 0.999) {
        let g = 0.6 * vc_gn3(rd * 2.3 + vec3<f32>(0.0, 0.0, time * 0.03)) + 0.4 * vc_gn3(VC_R1 * rd * 6.1 + vec3<f32>(time * 0.05));
        let x = 1.0 - smoothstep(0.0, 1.0, vs.thin * 1.2 + 0.55 * (g - 0.5) - 0.1);
        o.c = mix(o.c, vec3<f32>(0.1, 0.04, 0.026) * (1.0 - o.tr) * (0.2 + 0.8 * l.sun_up), 0.75 * vs.thin) * x;
        o.tr = 1.0 - (1.0 - o.tr) * x;
        vc_tx.x = x;
    }
    vc_tx.y = o.tr;
    if (o.tr < 0.999) {
        let dist = tmid / max(wmid, 1.0e-4);
        if (o.tr < 0.6) {
            o.t = dist;
        }
        // (the air's haze over it)
        let ap = 1.0 - exp(-max(dist - 1600.0, 0.0) / mix(9000.0, 1900.0, vs.cov));
        o.c = mix(o.c, vc_haze(rd, l) * (1.0 - o.tr), ap * mix(0.8, 1.0, vs.cov));
    }
    return o;
}

// The dust the shock lifts off the land: a thin low haze behind the pressure ring, three looks where the ray crosses it.
fn vc_dust(C: vec3<f32>, rd: vec3<f32>, tend: f32, col0: vec3<f32>, l: VcLight) -> vec3<f32> {
    let a = vs.a;
    let Rs = VC_RING + VC_V * a;
    let w = 46.0 + 0.2 * (Rs - VC_RING);
    let h = (18.0 + 14.0 * a) * (1.0 - smoothstep(VC_DUST - 4.0, VC_DUST, a));
    let o = -C.xz;
    let d = rd.xz;
    let aa = max(dot(d, d), 1.0e-6);
    let bq = dot(o, d) / aa;
    let oo = dot(o, o);
    let disc = bq * bq - (oo - Rs * Rs) / aa;
    if (disc <= 0.0) {
        return col0;
    }
    // (the air over the land the ray is in, and the ring's stretch of it, the near one if the ray is low enough there)
    let ry = select(1.0e-4, rd.y, abs(rd.y) > 1.0e-4);
    let y0 = -C.y;
    let t_a = (-14.0 - y0) / ry;
    let t_b = (h + 26.0 - y0) / ry;
    let lo = max(min(t_a, t_b), 0.0);
    let hi = min(max(t_a, t_b), tend);
    let sq = sqrt(disc);
    let Ri = max(Rs - 2.6 * w, 1.0);
    let di = bq * bq - (oo - Ri * Ri) / aa;
    let si = sqrt(max(di, 0.0));
    var ta = max(lo, -bq - sq);
    var tb = min(hi, select(-bq + sq, -bq - si, di > 0.0));
    if (tb <= ta && di > 0.0) {
        ta = max(lo, -bq + si);
        tb = min(hi, -bq + sq);
    }
    if (tb <= ta) {
        return col0;
    }
    let jt = f32(pcg(u32(vc_px.x) ^ (u32(vc_px.y) << 13u)) & 1023u) / 1023.0;
    let ds = (tb - ta) / 3.0;
    let lum = dot(l.skyl, vec3<f32>(0.2126, 0.7152, 0.0722));
    let tan_ = vec3<f32>(0.62, 0.55, 0.46) * (0.62 * lum + 0.5 * dot(l.sunc, vec3<f32>(0.33)));
    var col = col0;
    for (var i = 0; i < 3; i = i + 1) {
        let p = rd * (ta + (f32(i) + jt) * ds) - C;
        let v = (p.y - vc_land(p.xz)) / h;
        let u = (Rs - length(p.xz)) / w;
        let n = vc_gn3(vec3<f32>(p.x, p.y * 2.0 - 40.0 * a, p.z) * (1.0 / 95.0));
        let n2 = vc_gn3(VC_R1 * p * (1.0 / 340.0));
        let den = exp(-u * 1.1) * smoothstep(0.0, 0.2, u) * step(-0.2, v) * (1.0 - smoothstep(0.25, 1.0, v + 0.5 * (n - 0.5))) * smoothstep(0.34, 0.68, 0.5 * n + 0.5 * n2);
        col = mix(col, tan_, (1.0 - exp(-den * ds * 0.0055)) * (1.0 - smoothstep(4.0, VC_DUST, a) * 0.6) * smoothstep(60.0, 420.0, length(p + C)));
    }
    return col;
}
// The shock seen for a moment: a torn veil of condensation at the pressure ring's speed, two fainter behind, its amount
// from where the ray passes closest, so no line runs round it.
fn vc_shells(C: vec3<f32>, rd: vec3<f32>, tend: f32, col0: vec3<f32>, l: VcLight) -> vec3<f32> {
    var col = col0;
    let sy = 1.16;
    let o = vec3<f32>(-C.x, -C.y * sy, -C.z);
    let d = vec3<f32>(rd.x, rd.y * sy, rd.z);
    let aa = dot(d, d);
    let tca = -dot(o, d) / aa;
    let pc = o + d * tca;
    let b2 = dot(pc, pc);
    let b = sqrt(b2);
    let lum = dot(l.skyl, vec3<f32>(0.2126, 0.7152, 0.0722));
    let veil = vec3<f32>(0.9, 0.89, 0.87) * (0.55 * lum + 0.55 * dot(l.sunc, vec3<f32>(0.33)));
    for (var k = 0; k < 3; k = k + 1) {
        let born = 0.25 + 0.8 * f32(k);
        let s = vs.a - born;
        if (s <= 0.0 || s > 5.5) {
            continue;
        }
        let R = VC_RING + VC_V * s;
        let w = 12.0 + 0.03 * R;
        let in2 = R * R - b2;
        let hc = sqrt(max(in2, 0.0) / aa);
        var th = tca - hc;
        if (th <= 0.0) {
            th = tca + hc;
        }
        if (th <= 0.0 || th > tend) {
            continue;
        }
        let p = o + d * th;
        let dir = p / max(length(p), 1.0);
        let n = vc_gn3(dir * 5.0 + vec3<f32>(0.0, 0.14 * s, 1.7 * f32(k)));
        let n2 = vc_gn3(VC_R1 * dir * 15.0 + vec3<f32>(0.0, 0.0, 0.3 * s));
        let x = (b - R * (1.0 + 0.05 * (n - 0.5))) / w;
        let past = exp(-pow(max(x, 0.0), 2.0));
        let along = sqrt(R / (2.0 * w)) / sqrt(1.0 + max(-x, 0.0));
        let patch_ = smoothstep(0.4, 0.76, 0.68 * n + 0.32 * n2);
        let life = smoothstep(0.1, 0.7, s) * (1.0 - smoothstep(1.8, 5.5, s)) * (1.0 - 0.34 * f32(k));
        let al = saturate(0.075 * along * past * patch_ * life * smoothstep(0.03, 0.3, dir.y));
        col = mix(col, veil, al);
    }
    return col;
}

// ---- the opening: an orbital laser over the vent, its targeting beam, the beam, the hole it melts ----
// The satellite parks 7,000 up and 1,600 beyond the vent from the player (table words 2 and 3: the way to them), about
// 70 degrees up their sky, drawn bigger far off (`vc_sat_k`). Built of blocks (`vc_sat_hit`): seen from the ground nearly
// down its barrel, a dark cross with a glowing eye. It falls in down a steep slant, well off the vertical and turning,
// its thrusters swinging it round; lights its jets (VC_IGN) and brakes, hardest late, to a stop over the vent
// (VC_ARRIVE), heaved over and steadied by a control loop (`vc_sat_att`); its thrusters trim it onto the vent as it
// unrolls its arrays (`vc_sat_wing`), aims (VC_AIM), locks (VC_LOCK), its coils charge outside in and it fires (VC_HIT),
// melting a round hole (VC_HR); cut at VC_OFF, it rolls its arrays back in and lifts straight up on its jets (VC_BURN),
// dwindling into the haze. Steam surges off the hole (`vc_plume`) and the mount rises round it (vm_rest) until the eruption.
const VC_IGN: f32 = 1.3;
const VC_ARRIVE: f32 = 3.4;
const VC_AIM: f32 = 3.3;
const VC_LOCK: f32 = 4.0;
const VC_OFF: f32 = 7.1;
const VC_BURN: f32 = 8.6;
const VC_SAT_END: f32 = 12.0;
const VC_HR: f32 = 14.0;
// The way to the player, level.
fn vc_sat_dir() -> vec2<f32> {
    let d = vec2<f32>(vc_w(2u), vc_w(3u));
    if (dot(d, d) < 0.5) {
        return normalize(vc_me() + vec2<f32>(1.0e-3, 0.0));
    }
    return d;
}
// From the vent, parked (drifting slowly along its orbit); and how far it is from there: falling in down a steep slant
// from 1,900 higher, 1,000 along its orbit and 1,500 nearer the player (from below, seen falling down their sky), steadily to
// VC_IGN, then braking, hardest late, to a soft stop at VC_ARRIVE, sagging 40 past its station and back; gone straight
// back up from VC_BURN.
fn vc_sat0() -> vec3<f32> {
    let d = vc_sat_dir();
    let s = -1600.0 * d + vec2<f32>(-d.y, d.x) * 16.0 * (vs.t - VC_HIT);
    return vec3<f32>(s.x, 7000.0, s.y);
}
fn vc_sat_go() -> vec3<f32> {
    let t = vs.t;
    let d = vc_sat_dir();
    let x = saturate((t - VC_IGN) / (VC_ARRIVE - VC_IGN));
    let x3 = x * x * x;
    let r = (max(VC_IGN - t, 0.0) / (VC_ARRIVE - VC_IGN) + 9.0 / 14.0 - x + 0.5 * x3 * x - x3 * x3 * x / 7.0) / (VC_IGN / (VC_ARRIVE - VC_IGN) + 9.0 / 14.0);
    let q = max(t - 3.05, 0.0) / 0.35;
    let g = 2000.0 * pow(max(t - VC_BURN, 0.0), 2.5) - 40.0 * q * q * exp(2.0 - 2.0 * q);
    return vec3<f32>(-1000.0 * d.y + 1500.0 * d.x, 1900.0, 1000.0 * d.x + 1500.0 * d.y) * r + vec3<f32>(0.0, g, 0.0);
}
// How hard its jets burn (0-1): lit at VC_IGN, as hard as it brakes, out at VC_ARRIVE.
fn vc_sat_thr(t: f32) -> f32 {
    let x = saturate((t - VC_IGN) / (VC_ARRIVE - VC_IGN));
    return smoothstep(VC_IGN, VC_IGN + 0.2, t) * (0.3 + 2.15 * x * x * (1.0 - x * x * x)) * (1.0 - smoothstep(VC_ARRIVE - 0.25, VC_ARRIVE, t));
}
// Its tilt off the vent (.xy, radians, about `vc_sat_m`'s two axes) and what is turning it this tenth of a second (.zw,
// rad/s^2), as a control loop flies it (tools/vc_sat_motion.py writes VC_SAT_TAB: the tilt and its rate each tenth of a
// second to VC_LOCK, in thousandths). Never a smooth sine: it comes in 26 degrees off and turning further, its
// thrusters stop that and swing it slowly round as it falls; the burn's jets heave it over, a tenth late (they swing,
// the body follows), the ignition's kick, the thrust off its middle and the sloshing pushing back, so it overshoots
// unevenly; as the burn dies its thrusters trim it onto the vent in small pulses while its arrays unroll; held still
// from VC_LOCK.
const VC_SAT_TAB = array<vec4f, 41>(
    vec4f(400, -220, 70, -50), vec4f(407, -225, 70, -50), vec4f(414, -230, 70, -50), vec4f(421, -235, 70, -50),
    vec4f(428, -240, 70, -50), vec4f(435, -245, 70, -50), vec4f(438, -246, -10, 30), vec4f(433, -239, -90, 110),
    vec4f(420, -228, -170, 110), vec4f(403, -217, -170, 110), vec4f(386, -206, -170, 110), vec4f(369, -195, -170, 110),
    vec4f(352, -184, -170, 110), vec4f(335, -173, -170, 110), vec4f(319, -162, -141, 115), vec4f(307, -150, -119, 125),
    vec4f(295, -138, -117, 121), vec4f(281, -123, -159, 162), vec4f(263, -105, -204, 202), vec4f(242, -84, -220, 215),
    vec4f(220, -63, -213, 209), vec4f(199, -43, -197, 196), vec4f(180, -24, -181, 186), vec4f(163, -6, -164, 162),
    vec4f(149, 7, -129, 98), vec4f(138, 12, -81, 10), vec4f(132, 8, -40, -82), vec4f(129, -4, -22, -162),
    vec4f(126, -23, -34, -210), vec4f(121, -43, -69, -196), vec4f(112, -58, -117, -111), vec4f(97, -63, -170, 21),
    vec4f(79, -55, -203, 130), vec4f(58, -40, -212, 180), vec4f(39, -25, -168, 110), vec4f(24, -17, -124, 61),
    vec4f(14, -12, -79, 31), vec4f(8, -9, -57, 26), vec4f(3, -7, -36, 25), vec4f(0, -4, -18, 19),
    vec4f(-1, -3, 0, 0)
);
fn vc_sat_att(t: f32) -> vec4<f32> {
    let u = clamp(t, 0.0, 3.999) * 10.0;
    let i = u32(u);
    let f = u - f32(i);
    let a = VC_SAT_TAB[i] * 0.001;
    let b = VC_SAT_TAB[i + 1u] * 0.001;
    // (cubic Hermite through the tilts and rates)
    let p = a.xy * (1.0 + f * f * (2.0 * f - 3.0)) + b.xy * f * f * (3.0 - 2.0 * f) + 0.1 * f * (1.0 - f) * ((1.0 - f) * a.zw - f * b.zw);
    return vec4<f32>(p, (b.zw - a.zw) * 10.0 * step(t, VC_LOCK));
}
// How far a wing (`sd` its side) is unrolled: rolled up as it comes in, out as it is trimmed onto the vent (one side a
// little ahead of the other, eased to a soft stop), rolled back in before it burns off.
const VC_WING_OUT: f32 = 3.2;
const VC_WING_IN: f32 = 7.5;
fn vc_sat_wing(sd: f32) -> f32 {
    let lag = 0.08 * (sd + 1.0);
    let o = saturate((vs.t - VC_WING_OUT - lag) / 0.9);
    let i = saturate((vs.t - VC_WING_IN - lag) / 0.8);
    return (1.0 - pow(1.0 - o, 3.0)) * (1.0 - i * i * (3.0 - 2.0 * i));
}
// Its axes (columns): along its wings, across, down its barrel; `p` its tilt.
fn vc_sat_m(S: vec3<f32>, p: vec2<f32>) -> mat3x3<f32> {
    let d = vc_sat_dir();
    let a = normalize(-S);
    let k0 = normalize(cross(a, vec3<f32>(-d.y, 0.0, d.x)));
    let w = normalize(a + cross(k0, a) * tan(p.x) + k0 * tan(p.y));
    let k = normalize(k0 - w * dot(k0, w));
    return mat3x3<f32>(k, cross(w, k), w);
}
// How much bigger than itself it is drawn, seen from `P` off (where it parks, so it shrinks going off): as big as it
// would look from 2,700 (from 9,200 at the most).
fn vc_sat_k(P: vec3<f32>) -> f32 {
    return clamp(length(P) / 2700.0, 1.0, 3.4);
}
// Where the targeting spot is (level, from the vent): wandering in to the vent and still from VC_LOCK.
fn vc_spot() -> vec2<f32> {
    let w = pow(1.0 - smoothstep(VC_AIM, VC_LOCK, vs.t), 1.5);
    let t = vs.t;
    return vec2<f32>(sin(t * 3.1 + 0.4) + 0.6 * sin(t * 7.3), cos(t * 2.7 + 1.3) + 0.5 * sin(t * 6.1 + 2.0)) * 26.0 * w;
}
// The hole's radius now, in the land's own (rest) frame, and how hot it is (1 while the beam is on, the rim cooling after).
fn vc_hole_r() -> f32 {
    return VC_HR * pow(smoothstep(VC_HIT, VC_HIT + 1.6, vs.t), 0.6);
}
// A box `h` (half sizes) round the origin of a frame, the ray o + d s in it: .x where it is met (under 0: missed), .yzw
// the face's normal.
fn vc_box(o: vec3<f32>, d: vec3<f32>, h: vec3<f32>) -> vec4<f32> {
    let iv = 1.0 / select(d, vec3<f32>(1.0e-6), abs(d) < vec3<f32>(1.0e-6));
    let t0 = (-h - o) * iv;
    let t1 = (h - o) * iv;
    let tn = min(t0, t1);
    let tf = max(t0, t1);
    let a = max(max(tn.x, tn.y), tn.z);
    if (a > min(min(tf.x, tf.y), tf.z) || a < 0.0) {
        return vec4<f32>(-1.0);
    }
    return vec4<f32>(a, -sign(d) * step(tn.yzx, tn) * step(tn.zxy, tn));
}
// The satellite's blocks met by the ray o + d s (its own frame and size; `Ns` its panels' normal, to the sun): a
// gold-foiled bus, its engine, white radiators, a gold collar, the truss and its wings, an octagonal barrel ringed by
// four coils stepping in towards the emitter's housing, four prongs round it.
struct VcSh {
    t: f32,
    n: vec3<f32>,
    m: i32,      // 0 gold foil, 1 white, 2 gunmetal, 3 panel, 4 the emitter's housing, 5-8 the coils, 9 radiator; -1 none
}
fn vc_sb(h: ptr<function, VcSh>, o: vec3<f32>, d: vec3<f32>, z: f32, s: vec3<f32>, m: i32) {
    let b = vc_box(o - vec3<f32>(0.0, 0.0, z), d, s);
    if (b.x > 0.0 && b.x < (*h).t) {
        *h = VcSh(b.x, b.yzw, m);
    }
}
fn vc_sat_hit(o: vec3<f32>, d: vec3<f32>, Ns: vec3<f32>) -> VcSh {
    var h = VcSh(1.0e9, vec3<f32>(0.0), -1);
    vc_sb(&h, o, d, -46.0, vec3<f32>(24.0, 24.0, 24.0), 0);
    vc_sb(&h, o, d, -74.0, vec3<f32>(10.0, 10.0, 5.0), 2);
    // (the thruster quads on the bus's top corners)
    for (var j = 0; j < 4; j = j + 1) {
        let q = vec2<f32>(f32(j & 1), f32(j >> 1u)) * 2.0 - 1.0;
        vc_sb(&h, o - vec3<f32>(q * 25.0, 0.0), d, -68.0, vec3<f32>(3.0), 2);
    }
    vc_sb(&h, o, d, -52.0, vec3<f32>(18.0, 90.0, 1.0), 9);
    vc_sb(&h, o, d, -16.0, vec3<f32>(32.0, 32.0, 6.0), 0);
    vc_sb(&h, o, d, -16.0, vec3<f32>(175.0, 2.5, 2.5), 1);
    vc_sb(&h, o, d, 42.0, vec3<f32>(13.0, 9.0, 47.0), 2);
    vc_sb(&h, o, d, 42.0, vec3<f32>(9.0, 13.0, 47.0), 2);
    vc_sb(&h, o, d, 90.0, vec3<f32>(17.0, 17.0, 6.0), 4);
    for (var i = 0; i < 4; i = i + 1) {
        vc_sb(&h, o, d, 6.0 + 18.0 * f32(i), vec3<f32>(vec2<f32>(26.0 - 2.0 * f32(i)), 3.0), 5 + i);
        let q = select(vec2<f32>(0.0, 20.0), vec2<f32>(20.0, 0.0), (i & 1) == 0) * select(1.0, -1.0, i > 1);
        vc_sb(&h, o - vec3<f32>(q, 0.0), d, 108.0, vec3<f32>(3.5, 3.5, 12.0), 2);
    }
    // (the wings: roll-out arrays, each a plate turned to the sun about the truss, gaps between its panels, unrolled
    // from a drum at the collar's side out to its tip (`vc_sat_wing`); rolled up, only the drums)
    let b = cross(Ns, vec3<f32>(1.0, 0.0, 0.0));
    let ow = o + vec3<f32>(0.0, 0.0, 16.0);
    let lo = vec3<f32>(ow.x, dot(ow, b), dot(ow, Ns));
    let ld = vec3<f32>(d.x, dot(d, b), dot(d, Ns));
    for (var sd = -1.0; sd < 2.0; sd = sd + 2.0) {
        let L = 139.0 * vc_sat_wing(sd);
        let c = sd * (36.0 + 0.5 * L);
        let w = vc_box(lo - vec3<f32>(c, 0.0, 0.0), ld, vec3<f32>(0.5 * L + 0.01, 30.0, 0.7));
        let x = abs(lo.x + ld.x * w.x) - 36.0;
        if (L > 0.5 && w.x > 0.0 && w.x < h.t && fract(x / 46.33) < 0.92) {
            h = VcSh(w.x, vec3<f32>(w.y, 0.0, 0.0) + b * w.z + Ns * w.w, 3);
        }
        let r = vc_box(lo - vec3<f32>(sd * (38.0 + L), 0.0, 0.0), ld, vec3<f32>(3.2, 32.0, 3.2));
        if (r.x > 0.0 && r.x < h.t) {
            h = VcSh(r.x, vec3<f32>(r.y, 0.0, 0.0) + b * r.z + Ns * r.w, 1);
        }
    }
    return h;
}
// A jet of hot gas over the picture: from `A` (from the eye) along `D` for `L`, `w` wide at its mouth, `k` bright.
fn vc_jet(uv: vec2<f32>, A: vec3<f32>, D: vec3<f32>, L: f32, w: f32, k: f32, col: vec3<f32>) -> vec3<f32> {
    let res = frame.resolution.xy;
    let pa = project_rel(A);
    let pb = project_rel(A + D * L);
    if (k <= 0.0 || pa.z <= 0.0 || pb.z <= 0.0) {
        return vec3<f32>(0.0);
    }
    let a = pa.xy * res;
    let ab = pb.xy * res - a;
    let ap = uv * res - a;
    let f = saturate(dot(ap, ab) / max(dot(ab, ab), 1.0e-4));
    let e = length(ap - ab * f);
    let wp = max(w / (length(A) * vs.px), 0.8) * (1.0 + 2.5 * f);
    // (its mouth's glow less when it points at the eye, so a jet seen end on doesn't swallow what fires it)
    let side = saturate(length(ab) / (10.0 * wp));
    return col * k * pow(1.0 - f, 1.6) * (0.9 / (1.0 + e * e / (wp * wp)) + (0.15 + 0.45 * side) / (1.0 + dot(ap, ap) / (6.0 * wp * wp)));
}
// ---- the steam off the hole: vapour while the beam melts it, a surge as it is cut, then fed unevenly (`vc_feed`: .x as
// let go, .y its mean). As off a real vent: a narrow stem, clear just over the hole; a column growing in lumps, a puff a
// surge, necked in the lulls; leant over by the wind and carried off, mixing away to ragged lumps; never a cone. What was
// let go `a` s ago is at vc_path(a); a point takes the age of the nearest point on it, so its lumps ride it.
const VC_PH: f32 = 760.0;
const VC_PT: f32 = 8.0;
fn vc_feed(s: f32) -> vec2<f32> {
    let on = smoothstep(VC_HIT + 0.2, VC_HIT + 0.6, s) * 0.2;
    let c = smoothstep(VC_OFF - 0.1, VC_OFF + 0.35, s);
    let p = 0.1 + 0.6 * smoothstep(0.3, 0.72, vc_gn3(vec3<f32>(s * 0.9, 1.7, 4.2)));
    return vec2<f32>(max(on, c * mix(p, 1.0, exp((VC_OFF - max(s, VC_OFF)) / 0.7))), max(on, c * 0.55)) * (1.0 - smoothstep(VC_ERUPT - 4.0, VC_ERUPT - 0.5, s));
}
// Where and how fast: rising VC_PH (1 - e^(-a / VC_PT)), taken up by a wind of 34 a second.
fn vc_path(a: f32) -> mat2x3<f32> {
    let e = VC_PH * exp(-a / VC_PT);
    let g = exp(-a / 1.8);
    let w = vec3<f32>(32.3, 0.0, 10.5);
    return mat2x3<f32>(w * (a - 1.8 + 1.8 * g) + vec3<f32>(0.0, VC_PH - e, 0.0), w * (1.0 - g) + vec3<f32>(0.0, e / VC_PT, 0.0));
}
fn vc_plume(c0: vec3<f32>, C: vec3<f32>, rd: vec3<f32>, len: f32, tr: f32, l: VcLight, fire: f32, jit: f32) -> vec3<f32> {
    let t = vs.t;
    let age = t - VC_HIT - 0.2;
    let fade = tr * (1.0 - smoothstep(VC_ERUPT - 0.5, VC_ERUPT + 0.6, t));
    if (age <= 0.0 || fade <= 0.0) {
        return c0;
    }
    let B = C + vec3<f32>(0.0, select(0.0, vm_height(vec2<f32>(0.0)), vm.on), 0.0);
    let H = vc_path(age)[0];
    let rm = 40.0 + 0.55 * H.y + 20.0 * age;
    let inv = 1.0 / select(rd, vec3<f32>(1.0e-5), abs(rd) < vec3<f32>(1.0e-5));
    let t0 = (B + min(H, vec3<f32>(0.0)) - vec3<f32>(rm, 4.0, rm)) * inv;
    let t1 = (B + max(H, vec3<f32>(0.0)) + rm) * inv;
    let tn = min(t0, t1);
    let tf = max(t0, t1);
    let ta = max(max(tn.x, max(tn.y, tn.z)), 0.0);
    let tb = min(min(tf.x, min(tf.y, tf.z)), len);
    if (ta >= tb) {
        return c0;
    }
    let hg = 1.2 * fire + 0.45 - 0.3 * smoothstep(VC_OFF, VC_OFF + 5.0, t) + 0.35 * smoothstep(VC_CRACK, VC_ERUPT, t);
    var s = ta;
    var acc = vec3<f32>(0.0);
    var T = 1.0;
    for (var i = 0; i < 24; i = i + 1) {
        if (s > tb) {
            break;
        }
        let q = rd * s - B;
        // (the nearest point on the path: from the height, then Gauss-Newton)
        var a = clamp(-VC_PT * log(max(1.0 - q.y / VC_PH, 0.01)), 0.0, age);
        for (var k = 0; k < 3; k = k + 1) {
            let m = vc_path(a);
            a = clamp(a + dot(q - m[0], m[1]) / dot(m[1], m[1]), 0.0, age);
        }
        let m = vc_path(a);
        let sp = length(m[1]);
        let s0 = t - a;
        // (each part let go drifting its own way: the column wanders)
        let d = q - m[0] - a * vec3<f32>(2.5 * sin(s0 * 0.7), 1.5 * sin(s0 * 0.9 + 2.0), 2.5 * sin(s0 * 0.6 + 4.0));
        let rb = 12.0 + 0.2 * m[0].y + 5.2 * a;
        let rho = length(d);
        let ds = clamp(0.3 * rb, 2.0, 40.0);
        if (rho > 2.7 * rb) {
            // (on towards it, jittered afresh each time it comes back)
            s = s + max(0.8 * rho - 2.1 * rb, 0.2 * rb) + jit * ds;
            continue;
        }
        s = s + ds * (1.0 + select(0.0, jit, i == 0));
        // (what was let go together lies on a dome, so each puff is a rounded cap; surges and lulls merge as it spreads)
        let sr = s0 + min(0.9 * rb / sp, 1.6) * max(1.0 - rho * rho / (2.2 * rb * rb), 0.0);
        let F = vc_feed(sr);
        let f = mix(F.x, F.y, 1.0 - exp(-a / 5.0));
        let w = max(sr - VC_OFF + 0.3, 0.0);
        let rr = rb * (0.3 + 0.8 * sqrt(f)) * (1.0 + 0.3 * w * exp(1.0 - w - a / 6.0));
        if (f < 0.01 || rho > 1.75 * rr) {
            continue;
        }
        // (cauliflower, lumps on lumps: across it from its middle, along it by how far it was a moment ago, on a fixed
        // slant (a turning one swings the lattice); the moment let go of now and then, two such half a cycle apart)
        var b1 = 0.0;
        var b2 = 0.0;
        for (var p = 0; p < 2; p = p + 1) {
            let ph = t / 1.6 + 0.5 * f32(p);
            let wp = 1.0 - abs(2.0 * fract(ph) - 1.0);
            let c = d * (1.3 / rb) + vec3<f32>(3.2, 3.4, 1.05) * log(1.0 + max(a - fract(ph) * 1.6, 0.0) / 2.1) + vec3<f32>(17.0, 5.0, 9.0) * floor(ph);
            b1 = b1 + wp * vc_dome(VC_R1 * c);
            b2 = b2 + wp * vc_dome(VC_R2 * c * 2.6);
        }
        // (mixing away as it ages: its edge loosening, its biggest lumps left, then nothing)
        let fl = exp(-a / (4.0 + 4.0 * f));
        let th = 0.55 - 0.55 * fl;
        let k = (0.35 + 0.65 * f) * (0.5 + 0.5 * fl) * smoothstep(0.05, 0.35, fl) * mix(0.45, 1.0, smoothstep(VC_OFF - 0.1, VC_OFF + 0.5, sr));
        let den = smoothstep(th, th + 0.65 - 0.15 * fl - 0.3 * f, 0.525 - rho / rr + 0.7 * b1 + 0.25 * b2) * k * smoothstep(20.0, 50.0, q.y + 30.0 * b2);
        if (den < 0.003) {
            continue;
        }
        let al = 1.0 - exp(-den * ds * 0.5);
        // (the sun's way out through a ball round it, as thick as what lies that way along it, so a surge's cap under
        // thin vapour is lit; the creases between the lumps get less of the sky and the sun)
        let bb = dot(d, l.L);
        let ks = mix(0.25, 1.0, smoothstep(VC_OFF - 0.1, VC_OFF + 0.5, sr - dot(l.L, m[1]) * 1.6 * rb / (sp * sp))) * (0.5 + 0.5 * fl);
        let sun = exp(-0.05 * ks * max(sqrt(max(bb * bb - dot(d, d) + 2.56 * rb * rb, 0.0)) - bb, 0.0));
        let cr = saturate(0.3 + 0.3 * b1 + 0.3 * b1 * b2);
        let col = mix(vec3<f32>(0.5, 0.48, 0.46), vec3<f32>(0.9), smoothstep(10.0, 140.0, q.y)) * (l.skyl * (0.4 + 0.45 * cr) + l.sunc * l.sun_up * (0.13 + 0.77 * sun) * cr) + vec3<f32>(2.4, 0.6, 0.12) * hg * exp(-q.y / 60.0) * (0.8 - 0.5 * sun);
        acc = acc + T * al * col;
        T = T * (1.0 - al);
        if (T < 0.02) {
            break;
        }
    }
    return c0 * mix(1.0, T, fade) + acc * fade;
}
// The land, under its light: the targeting spot and its reticle, the hole (its far wall seen down it, white-hot deep in
// it), its molten rim cooling to crust, the land round it scorched and lit by it. `q` where the ray meets the land, `o`
// the eye (both from the vent).
fn vc_open_land(c0: vec3<f32>, q: vec3<f32>, rd: vec3<f32>, o: vec3<f32>) -> vec3<f32> {
    let t = vs.t;
    var c = c0;
    if (t < VC_AIM || t > VC_ERUPT + 0.5 || abs(q.y) > 600.0) {
        return c;
    }
    if (t < VC_HIT) {
        let e = length(q.xz - vc_spot());
        let on = smoothstep(VC_AIM + 0.1, VC_AIM + 0.2, t);
        if (e > 13.0) {
            return c + c0 * vec3<f32>(1.0, 0.1, 0.05) * 1.2 * on / (1.0 + e * e / 30.0);
        }
        let lk = smoothstep(VC_LOCK - 0.1, VC_LOCK + 0.15, t);
        let ring = mix(11.0, 5.5, lk);
        let ang = atan2(q.z, q.x) + t * mix(1.5, 0.0, lk);
        let ticks = step(0.7, fract(ang * 4.0 / TAU + 0.35)) * (1.0 - lk) + lk;
        let blink = mix(1.0, 0.6 + 0.4 * step(0.5, fract(t * 7.0)), lk);
        let red = vec3<f32>(1.6, 0.08, 0.04);
        c = mix(c, red, (1.0 - smoothstep(1.4, 2.2, e)) * on);
        c = mix(c, red, (1.0 - smoothstep(0.35, 0.8, abs(e - ring))) * ticks * on * blink);
        c = c + c0 * vec3<f32>(1.0, 0.1, 0.05) * 1.2 * on / (1.0 + e * e / 30.0);
        return c;
    }
    // (in the land's own frame: the mount spreads it as it grows)
    var rq = q.xz;
    if (vm.on) {
        rq = vm_rest(rq);
    }
    let r = length(rq);
    let R = vc_hole_r();
    let fire = smoothstep(VC_HIT, VC_HIT + 0.05, t) * (1.0 - smoothstep(VC_OFF, VC_OFF + 0.1, t));
    let cool = smoothstep(VC_OFF, VC_OFF + 5.0, t);
    let wake = smoothstep(VC_CRACK, VC_ERUPT, t);
    // (the light of it on the land round it: the beam's, then the hole's)
    let lr = max(r - R, 0.0);
    c = c + c0 * vec3<f32>(2.2, 0.75, 0.2) * (fire * 1.1 / (1.0 + lr * lr / 900.0) + (0.5 - 0.35 * cool + wake) / (1.0 + lr * lr / (R * R * 1.5 + 1.0)));
    // (scorched round it)
    c = c * (1.0 - 0.8 * (1.0 - smoothstep(R, 2.6 * R + 6.0, r)) * smoothstep(VC_HIT, VC_HIT + 1.5, t));
    if (r > 1.5 * R + 5.0) {
        return c;
    }
    if (r < R) {
        // (down it: the far wall where the ray leaves the hole's round, how far under the rim; the floor past its depth)
        let Rw = R * length(q.xz) / max(r, 1.0e-3);
        let b = dot(o.xz, rd.xz);
        let a2 = max(dot(rd.xz, rd.xz), 1.0e-6);
        let s2 = (-b + sqrt(max(b * b - a2 * (dot(o.xz, o.xz) - Rw * Rw), 0.0))) / a2;
        let dep = max(q.y - (o.y + rd.y * s2), 0.0);
        let D = 6.0 + 150.0 * smoothstep(VC_HIT, VC_OFF, t);
        let wx = o.xz + rd.xz * s2;
        let n = vc_gn3(vec3<f32>(atan2(wx.y, wx.x) * 5.0, min(dep, D) * 0.06 - t * 0.5, 2.0));
        // (orange at the lip, white-hot down it; the lip going dark as it cools, the depths staying hot)
        var T = (0.32 + 0.9 * saturate(dep / (14.0 + 40.0 * cool)) - 0.3 * cool * (1.0 - smoothstep(0.0, 6.0, dep))) * (0.85 + 0.35 * n);
        T = mix(T, 1.35, step(D, dep));
        T = T * (1.0 - 0.15 * cool) + 0.25 * wake + 0.25 * fire;
        c = vc_fire_c(T) + vec3<f32>(5.0, 4.2, 3.0) * saturate(T - 1.05) * 1.5;
    } else {
        // (the lip: molten, then a crust with the glow in its cracks)
        let lip = 1.0 - smoothstep(R, 1.5 * R + 3.0, r + 1.5 * vc_gn3(vec3<f32>(rq * 0.3, 7.0)));
        let n = vc_gn3(vec3<f32>(rq * 0.35, t * 0.2));
        let vein = 1.0 - smoothstep(0.0, 0.08, abs(n - 0.5));
        let T = lip * mix(0.95, 0.55 * vein + 0.12, cool) * (0.75 + 0.3 * n);
        c = mix(c, vec3<f32>(0.04, 0.035, 0.03), lip * smoothstep(VC_HIT + 0.5, VC_OFF + 2.0, t));
        c = c + vc_fire_c(T + 0.3 * wake * lip);
    }
    return c;
}
// The rest, over the picture (sharp, full size): the steam off the hole, the satellite, its beams, their light.
fn vc_opening(c0: vec3<f32>, C: vec3<f32>, rd: vec3<f32>, len: f32, tr: f32, uv: vec2<f32>, l: VcLight, sky: bool) -> vec3<f32> {
    let t = vs.t;
    var c = c0;
    if (t > VC_ERUPT + 1.0) {
        return c;
    }
    let k = intensity_v();
    let res = frame.resolution.xy;
    let fire = smoothstep(VC_HIT, VC_HIT + 0.05, t) * (1.0 - smoothstep(VC_OFF, VC_OFF + 0.08, t));
    c = vc_plume(c, C, rd, len, tr, l, fire, hash21(uv * res));
    if (t > VC_SAT_END) {
        return c;
    }
    // ---- the satellite: lit by the sun (shadowed by itself), the sky and the land under it; hazed by how far off ----
    let S = vc_sat0() + vc_sat_go();
    let at = vc_sat_att(t);
    let M = vc_sat_m(S, at.xy);
    let P = S + C;
    let sk = vc_sat_k(P - vc_sat_go());
    let E = P + M[2] * 96.0 * sk;
    let hz = 1.0 - exp(-pow(length(P) / 30000.0, 2.0));
    let show = smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(VC_SAT_END - 0.7, VC_SAT_END, t));
    let charge = smoothstep(VC_LOCK + 0.1, VC_HIT, t) * (1.0 - smoothstep(VC_HIT, VC_HIT + 0.1, t));
    let lens = mix(vec3<f32>(1.5, 0.05, 0.03) * smoothstep(VC_AIM - 0.2, VC_AIM, t), vec3<f32>(8.0, 6.0, 4.0), max(charge, fire)) * (1.0 - smoothstep(VC_OFF, VC_OFF + 0.6, t));
    let tp = dot(P, rd);
    if (tp > 0.0 && length(P - rd * tp) < 190.0 * sk && tp < len) {
        let tu = normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)));
        let tv = cross(tu, rd);
        let Lo = l.L * M;
        let Ns = normalize(vec3<f32>(0.0, Lo.y, Lo.z - 1.0e-3));
        let o = (-P * M) / sk;
        var acc = vec3<f32>(0.0);
        var cov = 0.0;
        for (var i = 0; i < 4; i = i + 1) {
            let off = (vec2<f32>(f32(i & 1), f32(i >> 1u)) - 0.5) * 0.5;
            let d = normalize(rd + (tu * off.x + tv * off.y) * vs.px) * M;
            let h = vc_sat_hit(o, d, Ns);
            if (h.m < 0) {
                continue;
            }
            let p = o + d * h.t;
            let n = h.n;
            // (blocks of 4 with their texels' grain)
            let cell = floor(p * 0.25) + f32(h.m) * 9.1;
            let hb = hash31(cell);
            let ht = hash31(floor(p) * 1.37);
            var alb = vec3<f32>(0.1, 0.1, 0.115) * (0.8 + 0.4 * hb);
            var sp = 0.8;
            var pw = 50.0;
            var nn = n;
            var em = vec3<f32>(0.0);
            if (h.m == 0) {
                // (gold foil, each block crinkled its own way)
                alb = vec3<f32>(0.9, 0.62, 0.2) * (0.7 + 0.3 * hb) * (0.85 + 0.3 * ht);
                nn = normalize(n + 0.4 * (vec3<f32>(hb, hash31(cell + 3.1), hash31(cell + 7.7)) - 0.5));
                sp = 2.0;
                pw = 24.0;
            } else if (h.m == 1) {
                alb = vec3<f32>(0.78, 0.78, 0.8) * (0.85 + 0.15 * hb) * (0.92 + 0.08 * ht);
                sp = 0.3;
                pw = 12.0;
            } else if (h.m == 3) {
                if (dot(n, Lo) > 0.0) {
                    let g = max(step(0.86, fract(p.x * 0.25)), step(0.86, fract(dot(p, cross(Ns, vec3<f32>(1.0, 0.0, 0.0))) * 0.25)));
                    alb = mix(vec3<f32>(0.025, 0.05, 0.15) * (0.8 + 0.4 * hb), vec3<f32>(0.5, 0.52, 0.55), g);
                    sp = 3.0;
                    pw = 90.0;
                } else {
                    alb = vec3<f32>(0.13, 0.13, 0.14) * (0.8 + 0.4 * step(0.75, fract(p.x * 0.125)));
                    sp = 0.2;
                }
            } else if (h.m == 4) {
                let e = max(max(abs(p.x), abs(p.y)), 0.75 * (abs(p.x) + abs(p.y)));
                em = lens * (1.0 - smoothstep(7.0, 8.5, e)) * step(0.5, n.z);
            } else if (h.m == 9) {
                alb = vec3<f32>(0.86, 0.86, 0.88) * (0.7 + 0.3 * step(0.3, fract(p.y * 0.25)));
                sp = 0.5;
                pw = 20.0;
            } else if (h.m >= 5) {
                // (a coil: lit red as it aims, white back to front as it charges, cooling after)
                let j = f32(h.m - 5);
                alb = vec3<f32>(0.5, 0.27, 0.13) * (0.8 + 0.4 * hb);
                sp = 1.2;
                pw = 40.0;
                let on = max(smoothstep(j * 0.22, j * 0.22 + 0.25, charge), fire * (0.85 + 0.15 * sin(t * 40.0 - j * 2.0)));
                let g = vec3<f32>(6.0, 4.2, 2.8) * on + vec3<f32>(0.6, 0.03, 0.02) * smoothstep(VC_AIM, VC_AIM + 0.3, t) * step(t, VC_HIT) + vc_fire_c(0.75 * exp(-(t - VC_OFF) / 1.4)) * step(VC_OFF, t);
                em = g * mix(0.12, 1.0, max(step(abs(p.z - 6.0 - 18.0 * j), 1.0) * step(abs(n.z), 0.5), step(24.7 - 2.0 * j, max(abs(p.x), abs(p.y))) * step(0.5, n.z)));
            }
            if (h.m == 2 && p.z > 95.0) {
                em = em + lens * 0.25 * saturate(-dot(n.xy, normalize(p.xy)));
            }
            let lit = select(0.0, 1.0, dot(n, Lo) > 0.0 && vc_sat_hit(p + n * 0.05, Lo, Ns).m < 0);
            let amb = l.skyl * mix(vec3<f32>(0.13, 0.14, 0.11), vec3<f32>(0.34), 0.5 + 0.5 * (M * n).y);
            acc = acc + alb * (amb + l.sunc * max(dot(nn, Lo), 0.0) * lit) + l.sunc * sp * lit * pow(max(dot(reflect(d, nn), Lo), 0.0), pw) + em;
            cov = cov + 0.25;
        }
        if (cov > 0.0) {
            c = mix(c, mix(acc / (cov * 4.0), c, hz), cov * show);
        }
    }
    // (its lights, the glint as it comes into view, its jets, the emitter charging and firing)
    let pe = project_rel(E);
    if (pe.z > 0.0) {
        let dd = (uv - pe.xy) * res;
        let r2 = dot(dd, dd);
        for (var s = -1.0; s < 2.0; s = s + 2.0) {
            let pn = project_rel(P + M[0] * 175.0 * sk * s);
            let dn = dot((uv - pn.xy) * res, (uv - pn.xy) * res);
            let bl = step(0.75, fract(t * 1.1 + 0.5 * s));
            c = c + select(vec3<f32>(0.1, 2.0, 0.3), vec3<f32>(2.0, 0.1, 0.05), s < 0.0) * bl * show * (1.0 - hz) / (1.0 + dn / 1.5);
        }
        let glw = exp(-pow((t - 0.45) / 0.14, 2.0));
        let star = 1.0 / (1.0 + r2 / 3.0) + 0.3 * (exp(-abs(dd.x) / 1.0) + exp(-abs(dd.y) / 1.0)) * exp(-sqrt(r2) / 22.0);
        c = c + vec3<f32>(2.0, 1.9, 1.7) * glw * star * show;
        // (four jets off the collar's corners fired down its barrel: dark as it falls, lit at VC_IGN with a kick, as hard
        // as it brakes, each gimballed by what the loop is turning it with (`vc_sat_att`'s .zw: they swing a tenth before
        // the body follows), out as it stops; lifting it away, a bright kick and then a long burn. The thrusters on the
        // bus's top corners (`vc_sat_hit`'s quads) fire as the loop does outside the burn, a tenth of a second at a time:
        // white bursts out of the corners on the side the barrel has to swing to, as hard as that push, in stuttering pulses)
        let thr = vc_sat_thr(t);
        let go = smoothstep(VC_BURN, VC_BURN + 0.3, t);
        let kj = thr * (1.0 + 1.5 * exp((VC_IGN - t) * 6.0)) + go * (1.0 + 2.0 * exp(-(t - VC_BURN) * 5.0)) * (1.0 - 0.6 * hz);
        let u = vec2<f32>(at.w, -at.z);
        let rcs = select(saturate(length(u) / 0.6), 0.0, thr > 0.2 || t > VC_LOCK - 0.2 || length(u) < 0.07);
        let ud = M[0] * u.x + M[1] * u.y;
        for (var j = 0; j < 4; j = j + 1) {
            let q = vec2<f32>(f32(j & 1), f32(j >> 1u)) * 2.0 - 1.0;
            if (kj > 0.0) {
                let dn = normalize(M[2] + 0.12 * (M[0] * q.x + M[1] * q.y) - 0.25 * step(0.2, thr) * ud);
                c = c + vc_jet(uv, P + (M * vec3<f32>(q * 30.0, -10.0)) * sk, dn, (30.0 + 190.0 * thr + 260.0 * go) * sk, (2.5 + 3.0 * go) * sk, kj * show, vec3<f32>(1.3, 1.6, 2.4));
            }
            let ph = fract(t * 10.0) / (0.45 + 0.3 * rcs);
            let k2 = rcs * saturate(dot(q, u) / (length(u) + 1.0e-4) + 0.2) * sqrt(saturate(1.0 - ph)) * show;
            if (k2 > 0.0) {
                c = c + vc_jet(uv, P + (M * vec3<f32>(q * 25.0, -68.0)) * sk, normalize(normalize(ud) - 0.25 * M[2]), (22.0 + 30.0 * rcs) * sk, 2.6 * sk, 1.4 * k2, vec3<f32>(1.25, 1.25, 1.3));
            }
        }
        let em = charge * 1.2 + fire * (1.6 + 0.4 * sin(t * 47.0));
        let flare = 1.0 / (1.0 + r2 / (5.0 + 18.0 * fire)) + 0.04 / (1.0 + r2 / 700.0) + 0.25 * exp(-abs(dd.y) / 1.5) * exp(-abs(dd.x) / (25.0 + 35.0 * fire));
        c = c + vec3<f32>(3.0, 2.1, 1.3) * em * flare * k;
    }
    // ---- the targeting beam: thin, solid, red, lit as the thing it is ----
    let sp = vc_spot();
    let G = C + vec3<f32>(sp.x, vc_land(sp), sp.y);
    if (t > VC_AIM && t < VC_HIT) {
        let B = mix(E, G, smoothstep(VC_AIM, VC_AIM + 0.18, t));
        let sg = pl_ray_seg(rd, E, B, 0.0, 1.0);
        let pw = sg.y * vs.px;
        let wv = max(1.1, 0.55 * pw);
        if (sg.y < len + 2.0 && sg.x < wv + pw) {
            let side = normalize(rd * sg.y - mix(E, B, sg.z) + vec3<f32>(1.0e-4));
            let shade = 0.25 + 0.9 * max(dot(side, l.L), 0.0) * l.sun_up + 0.35;
            let cv = saturate((wv - sg.x) / pw + 0.5) * max(1.1 / wv, 0.9);
            c = mix(c, vec3<f32>(0.85, 0.035, 0.02) * shade, cv * tr);
        }
    }
    // ---- the beam: a white-hot core in an orange sheath, coming down from the emitter in an instant, pulsing ----
    if (fire > 0.0) {
        let head = smoothstep(VC_HIT, VC_HIT + 0.1, t);
        let sg = pl_ray_seg(rd, E, mix(E, C, head), 0.0, 1.0);
        let pw = sg.y * vs.px;
        if (sg.y < len + 1.0) {
            let f = 0.8 + 0.35 * sin(t * 31.0 - sg.z * 40.0) * sin(t * 13.0 + sg.z * 17.0);
            let r0 = 2.8 * (1.0 + 0.5 * exp(-(t - VC_HIT) * 4.0));
            let rc = max(r0, 0.45 * pw);
            let core = exp(-pow(sg.x / rc, 2.0)) * min(r0 / rc, 1.0);
            let sheath = exp(-pow(sg.x / (rc * 2.6), 2.0)) * min(r0 / rc, 1.0);
            let halo = 1.0 / (1.0 + pow(sg.x / 30.0, 2.0));
            c = c + (vec3<f32>(6.0, 4.9, 3.4) * core + vec3<f32>(3.0, 0.85, 0.13) * sheath * f + vec3<f32>(0.8, 0.22, 0.04) * halo * 0.15) * fire * k;
        }
    }
    // ---- the hit's light: a bloom round where it melts in, seen over what stands in front of it ----
    let ph = project_rel(C);
    if (ph.z > 0.0 && t > VC_HIT && t < VC_OFF + 6.0) {
        let dd = (uv - ph.xy) * vec2<f32>(res.x / res.y, 1.0);
        let r2 = dot(dd, dd);
        let hot = fire * (1.0 + 0.2 * sin(t * 29.0)) + 0.06 * (1.0 - smoothstep(VC_OFF, VC_OFF + 6.0, t));
        c = c + vec3<f32>(2.2, 0.9, 0.3) * hot * (0.5 / (1.0 + r2 * 3000.0) + 0.07 / (1.0 + r2 * 160.0) + 0.35 * exp(-abs(dd.y) * 300.0) * exp(-abs(dd.x) * 10.0) * fire) * k;
    }
    return c;
}

// ---- the jolt on the picture (as the Nuke's pl_jolt): the tremor building, the eruption's front (the rest is the game's
// shake, volcano.rs) ----
fn vc_jolt(in: StageIn) -> StageIn {
    vc_px = in.position.xy;
    let t = now();
    let tgt = vec3<f32>(anchor_xz().x, block_y() + 1.0, anchor_xz().y);
    let me = vec3<f32>(frame.mod_params[3].x, frame.mod_params[3].y, frame.mod_params[3].z);
    let dist = length(me - tgt);
    let g = clamp(1.7 / (1.0 + dist / 700.0), 0.2, 1.0);
    // (the tremor, building from the hit, faster and harder up to the eruption)
    let tr = smoothstep(VC_HIT, VC_ERUPT - 1.0, t) * (1.0 - smoothstep(VC_ERUPT - 1.05, VC_ERUPT - 0.75, t));
    var amp = 0.0024 * g * tr * tr;
    let s = t - VC_ERUPT - dist / VC_V;
    if (s > 0.0 && s < 8.0) {
        amp = amp + 0.012 * g * exp(-s / 0.5) + 0.004 * g * exp(-s / 2.8);
    }
    if (amp <= 1.0e-5 || intensity_v() <= 0.0) {
        return in;
    }
    let sh = vec2<f32>(
        0.55 * sin(t * 37.0 + 0.3) + 0.3 * sin(t * 59.0 + 1.9) + 0.15 * sin(t * 83.0),
        0.55 * cos(t * 33.0 + 2.2) + 0.3 * sin(t * 61.0 + 0.7) + 0.15 * cos(t * 79.0)
    );
    let res = frame.resolution.xy;
    let asp = res.x / res.y;
    let zoom = 1.0 + 2.2 * amp;
    let q = (in.uv - 0.5) * vec2<f32>(asp, 1.0) / zoom + sh * amp;
    var o = in;
    o.uv = clamp(q / vec2<f32>(asp, 1.0) + 0.5, vec2<f32>(0.0), vec2<f32>(1.0));
    o.position = vec4<f32>(o.uv * res, in.position.zw);
    return o;
}

// What a stage of the pass gives: the picture (the whole pass and the join), or the half-size stage's (premultiplied
// colour and transmittance) and beside it how far its ray went and the cloud's distance (`fs_half`).
struct VcOut {
    c: vec4<f32>,
    e: vec4<f32>,
}
// The pass, in one of three stages: 0 the whole of it (fs_main); 1 the half-size stage (the cloud, over a two by two of
// the picture's pixels, marched to alternately the nearest and the farthest of their depths); 2 the join (the rest,
// sharp, at full size, `up` the half-size stage's colour and transmittance, `up_t` its cloud's distance).
fn volcano(in: StageIn, stage: u32, up: vec4<f32>, up_t: f32) -> VcOut {
    var uv = in.uv;
    let time = now();
    vc_set_state(time);
    vs.fine = select(1.0, 2.0, stage == 1u);
    vm_set(time);
    let cam = frame.camera_position.xyz;
    let k = intensity_v();
    let seed = u32(seed_v());
    let anc = anchor_xz();
    let C = vec3<f32>(anc.x, block_y() + 1.0, anc.y) - cam;
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);
    let sun_up = smoothstep(-0.12, 0.06, sun.y);
    let warm = (1.0 - smoothstep(0.02, 0.4, sun.y)) * smoothstep(-0.2, -0.02, sun.y);
    let moon = smoothstep(-0.02, -0.2, sun.y);
    let L = normalize(select(-sun, sun, sun.y > -0.04) + vec3<f32>(0.0, 0.03, 0.0));

    var d = 0.0;
    if (stage == 1u) {
        let full = vec2<i32>(frame.resolution.xy);
        let q = vec2<i32>(floor(in.position.xy)) * 2;
        let q1 = min(q + vec2<i32>(1), full - vec2<i32>(1));
        // (through depth_at at each pixel's middle, not textureLoad: OpenGL can't load from a depth texture)
        let rz = frame.resolution.zw;
        let d0 = depth_at((vec2<f32>(q) + 0.5) * rz);
        let d1 = depth_at((vec2<f32>(f32(q1.x), f32(q.y)) + 0.5) * rz);
        let d2 = depth_at((vec2<f32>(f32(q.x), f32(q1.y)) + 0.5) * rz);
        let d3 = depth_at((vec2<f32>(q1) + 0.5) * rz);
        let hq = vec2<i32>(floor(in.position.xy));
        d = select(min(min(d0, d1), min(d2, d3)), max(max(d0, d1), max(d2, d3)), ((hq.x + hq.y) & 1) == 0);
        uv = (vec2<f32>(q) + 1.0) * frame.resolution.zw;
    } else {
        d = depth_at(uv);
    }
    var sky = is_sky(d);
    let rel = world_offset(uv, select(d, 0.5, sky));
    var scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv, 0.5));
    let scene = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb);
    var col = scene;
    var hc = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    let fade = 1.0 - smoothstep(VC_LEN - 1.0, VC_LEN, time);

    // (the light, matched to the scene's)
    var skyl = srgb_to_linear(frame.sky_color.rgb);
    var nsk = 1.0;
    for (var s = 0; s < 3; s = s + 1) {
        let su = vec2<f32>(0.2 + 0.3 * f32(s), 0.04);
        if (is_sky(depth_at(su))) {
            skyl = skyl + srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, su, 0.0).rgb);
            nsk = nsk + 1.0;
        }
    }
    skyl = skyl / nsk;
    let sunc = mix(vec3<f32>(1.35, 1.24, 1.06), mix(vec3<f32>(1.5, 0.68, 0.3), vec3<f32>(1.3, 0.38, 0.14), smoothstep(0.0, -0.1, sun.y)), warm) * sun_up + vec3<f32>(0.07, 0.09, 0.14) * moon;
    let sky_e = vc_sky_t(-C);
    let haze_c = mix(mix(vec3<f32>(0.02, 0.025, 0.04), skyl * 1.05, day), vec3<f32>(dot(skyl, vec3<f32>(0.2126, 0.7152, 0.0722))) * vec3<f32>(0.5, 0.3, 0.18) * day, vs.cov * (1.0 - sky_e)) * (0.1 + 0.9 * sky_e);
    var l: VcLight;
    l.L = L;
    l.sunc = sunc;
    l.skyl = max(skyl, vec3<f32>(0.03, 0.035, 0.05));
    l.haze = haze_c;
    l.day = day;
    l.warm = warm;
    l.sun_up = sun_up;
    l.seed = seed;
    // ---- the mount, drawn over the land until the burst (volcano_mount.wgsl) ----
    let vmh = vm_surface(C, rd, scene_len, col, stage, l, uv, sky);
    col = vmh.c;
    if (vmh.t >= 0.0) {
        scene_len = vmh.t;
        sky = false;
    }

    // ---- the land and the sky, under it ----
    let fl = vc_flashes(seed);
    if (stage != 1u && !sky) {
        let qg = select(rel, rd * scene_len, vmh.t >= 0.0) - C;
        col = vc_dim(col, qg, L, sun_up);
        // (a bolt's foot lighting the land round it)
        col = col * (1.0 + 1.6 * vc_flash_land(fl, qg, seed));
        // (the targeting spot, the hole the beam melts)
        col = vc_open_land(col, qg, rd, -C);
        // (the cracks, the ring's glow on the land)
        let rg = length(qg.xz);
        let vent = smoothstep(VC_CRACK, VC_ERUPT, time);
        if (time > VC_ERUPT + 0.9 && abs(qg.y) < 200.0 && vmh.t < 0.0) {
            let dr = abs(rg - VC_RING);
            let ang = atan2(qg.z, qg.x);
            let wob = 14.0 * sin(ang * 7.0 + 1.0) + 9.0 * sin(ang * 19.0 + 3.0) + 6.0 * sin(ang * 43.0 + 0.5);
            let cr = abs(rg + wob - VC_RING);
            let w = 0.6 + 5.0 * vent * vent + 6.0 * smoothstep(VC_ERUPT, VC_ERUPT + 2.0, time);
            let line = 1.0 - smoothstep(w * 0.4, w * 1.4, cr);
            let glow2 = exp(-cr / (10.0 + 40.0 * vent));
            let lava = vec3<f32>(3.0, 0.8, 0.12);
            col = col + lava * line * 2.2 * (1.0 - smoothstep(VC_ERUPT + 1.0, VC_ERUPT + 5.0, time)) * k;
            col = col + scene * vec3<f32>(1.5, 0.4, 0.08) * glow2 * vent * (1.0 - smoothstep(VC_COLLAPSE, VC_LIFT, time)) * k;
            let lit = smoothstep(VC_ERUPT, VC_ERUPT + 1.0, time) * (1.0 - 0.7 * smoothstep(VC_COLLAPSE, VC_LIFT, time));
            col = col + scene * vec3<f32>(1.5, 0.42, 0.1) * (0.9 * exp(-max(rg - vs.Rb, 0.0) / 240.0)) * lit * k;
        }
    }
    if (stage != 1u && !sky && vs.cov > 0.0) {
        let lum = dot(l.skyl, vec3<f32>(0.2126, 0.7152, 0.0722));
        col = mix(col, vec3<f32>(lum) * vc_band(vec3<f32>(0.0)), (1.0 - exp(-max(scene_len - 250.0, 0.0) / 1500.0)) * smoothstep(0.1, 0.7, vs.cov));
    }
    if (stage != 1u && sky) {
        // (what sky is left, in along the horizon under the sheet: dirty with ash, dimmed)
        let cv = (vs.cov * 0.3 + 0.7 * smoothstep(0.0, 8.0, time - 23.0)) * smoothstep(VC_DARK - 6.0, VC_DARK + 8.0, time) * (1.0 - smoothstep(85.0, VC_LEN - 0.2, time));
        let lum = dot(col, vec3<f32>(0.2126, 0.7152, 0.0722));
        // (its light dirty and red low down, gone by a few degrees up under the sheet's edge)
        col = mix(col, vec3<f32>(lum) * vc_band(rd), cv);
    }
    if (stage == 2u) {
        col = col * up.a + up.rgb;
    }
    // ---- the cloud ----
    var cloud_t = up_t;
    var tr_here = select(1.0, up.a, stage == 2u);
    if (stage != 2u) {
        let j = 0.5;
        let m = vc_march(C, rd, scene_len, j, l, fl);
        cloud_t = m.t;
        // (the bombs' smoke, in front of the cloud or behind it)
        var tb = 1.0e9;
        let sb = vc_bombs_smoke(C, rd, min(scene_len, 9000.0), l, l.skyl * vc_sky_t(-C), &tb);
        let st = vm_trails(C, rd, min(scene_len, 9000.0), l, &tb);
        let sm = vec4<f32>(st.rgb + sb.rgb * st.a, sb.a * st.a);
        var ac = sm.rgb + m.c * vc_cm;
        let at0 = m.tr * sm.a;
        cloud_t = min(cloud_t, tb);
        // (the mount's steam and dust, in front of it all)
        let va = vm_air(C, rd, min(scene_len, 9000.0), j, l);
        ac = va.rgb + ac * va.a;
        let at = at0 * va.a;
        tr_here = at;
        if (stage == 0u) {
            col = col * at + ac;
        } else {
            hc = vec4<f32>(ac, at);
        }
    }
    if (stage == 1u) {
        return VcOut(hc, vec4<f32>(min(scene_len, 6.0e4), min(cloud_t, 1.0e6), vm_chunk_near(C, rd, scene_len), vmh.id));
    }
    // ---- the opening: the satellite, its beams, the steam off the hole ----
    col = vc_opening(col, C, rd, scene_len, tr_here, uv, l, sky);
    // ---- the eruption: a hard ring of light round the land, the pressure ring out from it at the speed of sound ----
    if (vs.a > -0.02 && vs.a < 7.0) {
        let Rs = VC_V * vs.a + VC_RING;
        let P = C + vec3<f32>(0.0, 8.0, 0.0);
        let bq = dot(rd, P);
        let disc = bq * bq - (dot(P, P) - Rs * Rs);
        if (disc > 0.0 && vs.a > 0.0) {
            let sq = sqrt(disc);
            var th = bq - sq;
            if (th < 0.0) {
                th = bq + sq;
            }
            let hp = rd * th;
            if (th > 0.0 && th < scene_len + 4.0 && hp.y > C.y - 4.0) {
                let edge = exp(-sq / (0.05 * Rs + 8.0));
                let sf = 1.0 - smoothstep(3.0, 7.0, vs.a);
                let pb = project_rel(P);
                var dirs = uv - pb.xy;
                if (pb.z < 0.0) {
                    dirs = -dirs;
                }
                let soft = 1.0 - exp(-sq / (0.012 * Rs + 3.0));
                let off = normalize(dirs + vec2<f32>(1.0e-5)) * (0.009 * edge + 0.002 * exp(-sq / (0.25 * Rs))) * sf * soft;
                let sc = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv - off, 0.0).rgb);
                col = col + (sc - scene) * saturate(edge * 4.0 + 0.5) * sf * tr_here * soft;
                col = col + vec3<f32>(1.0, 0.86, 0.72) * 0.1 * edge * exp(-vs.a / 1.4) * sf * tr_here * soft;
            }
        }
        // (the flash: a blaze along the horizon where the ring opens, out over the land)
        let P2 = C + vec3<f32>(0.0, 60.0, 0.0);
        let tP = dot(P2, rd);
        let hp2 = rd * max(tP, 0.0) - C;
        var dr2 = length(vec2<f32>(length(hp2.xz) - VC_RING, hp2.y - 30.0));
        // (or how far over the ring where it crosses it: a blaze all along it, its core hidden by the land)
        var dc = select(1.0e5, dr2, tP < scene_len + 60.0);
        let a2 = dot(rd.xz, rd.xz);
        let b2 = dot(rd.xz, C.xz);
        let e2 = b2 * b2 - a2 * (dot(C.xz, C.xz) - VC_RING * VC_RING);
        if (e2 > 0.0) {
            let tx = (b2 + vec2<f32>(-1.0, 1.0) * sqrt(e2)) / a2;
            let vy = abs(rd.y * tx - C.y - 30.0) + select(vec2<f32>(0.0), vec2<f32>(1.0e5), tx < vec2<f32>(0.0));
            dr2 = min(vy.x, vy.y);
            let vc = vy + select(vec2<f32>(0.0), vec2<f32>(1.0e5), tx > vec2<f32>(scene_len + 60.0));
            dc = min(vc.x, vc.y);
        }
        let fl = 5.0 * exp(-max(vs.a, 0.0) / 0.12) + 0.9 * exp(-max(vs.a, 0.0) / 1.1);
        col = col + vec3<f32>(3.0, 1.2, 0.3) * fl * (0.07 / (1.0 + pow(dc / 40.0, 2.0)) + 0.025 / (1.0 + pow(dr2 / 220.0, 2.0)) + 0.008) * smoothstep(-0.02, 0.02, vs.a) * k * tr_here;
    }
    // ---- the shock's pale shells, out over the fireball ----
    if (vs.a > 0.0 && vs.a < VC_DUST) {
        col = vc_dust(C, rd, min(scene_len, cloud_t), col, l);
    }
    if (vs.a > 0.25 && vs.a < 7.8) {
        col = vc_shells(C, rd, min(scene_len, cloud_t), col, l) ;
    }
    // ---- the air once the wall has gone over: thick with ash, the light gone brown, a red glow low towards the vent ---
    let eq = -C;
    var eye_e = -1.0e5;
    if (vs.c > 0.0) {
        let re = length(eq.xz);
        let fe = vc_flow(eq, re, atan2(eq.z, eq.x), vc_land(eq.xz));
        eye_e = fe.y;
        let over = max(eq.y - vc_land(eq.xz), 0.0);
        if (eye_e > 0.0 && over < 400.0) {
            // (engulfed: how long since the front went over, by how fast it came. Six or seven seconds of it, then it thins)
            let tau = eye_e / vs.dRf;
            let thick = smoothstep(0.0, 0.9, tau) * (1.0 - smoothstep(4.0, 8.5, tau)) * (1.0 - smoothstep(180.0, 400.0, over));
            // (how far one can see, thinning on after it has gone by, to nothing as the ash goes)
            let clear = smoothstep(8.0, 16.0, tau);
            let V = mix(mix(3000.0, 26000.0, clear), 170.0, thick) / max(1.0 - vs.thin, 1.0e-2);
            let Lh = 1800.0;
            let Lf = min(select(Lh + (6000.0 - Lh) * smoothstep(0.0, 0.15, rd.y), min(scene_len, Lh), !sky), 6000.0);
            // (only as far as the cloud, as much as it hides what is behind: a hard outline in the fog otherwise)
            let L = mix(min(Lf, cloud_t), Lf, saturate(tr_here));
            let toV = normalize(C + vec3<f32>(0.0, 40.0, 0.0));
            let vg = pow(saturate(dot(rd, toV)), 4.0) * (1.0 - smoothstep(VC_LIFT, VC_RED, time));
            // (the murk lit from under it, red down low; towards the vent the glow of all that is still burning)
            let low = 1.0 - smoothstep(-0.05, 0.5, rd.y);
            let fogc = vec3<f32>(0.032, 0.019, 0.014) * (0.3 + day) + vec3<f32>(0.1, 0.023, 0.006) * low * thick + vec3<f32>(0.2, 0.05, 0.01) * vg * thick;
            col = mix(col, fogc, (1.0 - exp(-L / V)) * smoothstep(0.0, 30.0, eye_e));
        }
    }
    // ---- flakes of ash coming down, embers driven past ----
    if (time > VC_COLLAPSE && eye_e > -700.0) {
        let wall = smoothstep(-40.0, 40.0, eye_e);
        let dirv = normalize(vec3<f32>(eq.x, 0.0, eq.z) + vec3<f32>(1.0e-3));
        if (wall > 0.0) {
            let eb = vc_specks(rd, cam * 0.0 + vec3<f32>(0.0, -time * 3.0, 0.0), dirv * 34.0 + vec3<f32>(0.0, 7.0, 0.0), min(scene_len, 40.0), time, 0.42, 1.5);
            let ek = wall * (1.0 - smoothstep(6.0, 11.0, max(eye_e, 0.0) / vs.dRf));
            col = col + vec3<f32>(2.4, 0.7, 0.12) * eb * ek * k;
        }
        let ash = wall * (1.0 - smoothstep(VC_RED + 2.0, VC_LEN - 0.5, time)) * smoothstep(VC_COLLAPSE, VC_COLLAPSE + 8.0, time);
        if (ash > 0.0) {
            let af = vc_specks(rd, cam, vec3<f32>(1.6, -4.5, 0.9), min(scene_len, 60.0), time, 0.42, 1.0);
            col = mix(col, vec3<f32>(0.28, 0.25, 0.23) * (0.2 + 0.8 * day), saturate(af) * ash * 0.8);
        }
    }
    // ---- the spray of rock, the bombs' heads, the bolts ----
    if (vs.a > 0.8 && vs.a < 21.0) {
        let sp = vc_spray(C, rd, min(scene_len, cloud_t + 60.0), seed);
        col = col * sp.a + sp.rgb * k;
    }
    if (time > VC_ERUPT + 1.0 && time < VC_COLLAPSE + 2.0) {
        col = col + vc_bombs_heads(C, rd, scene_len, cloud_t, tr_here) * k;
    }
    if (time > VC_LIGHT - 2.0 && time < VC_RED) {
        let kb = k * (1.0 - 0.8 * smoothstep(VC_HU - 200.0, VC_HU + 100.0, -C.y));
        col = col + vc_bolts(fl, C, seed, scene_len, cloud_t, tr_here, vc_px) * kb;
    }
    // ---- the blood-red sun, as the ash thins ----
    if (sky && time > VC_RED - 8.0 && sun.y > -0.03) {
        let cth = saturate(dot(rd, sun));
        let th = sqrt(max(2.0 * (1.0 - cth), 0.0));
        let show = smoothstep(VC_RED - 7.0, VC_RED, time) * (1.0 - smoothstep(VC_LEN - 3.0, VC_LEN - 0.3, time));
        let vis = max(1.0 - exp(-7.0 * (tr_here + 0.05)), 0.9);
        let disc = 1.0 - smoothstep(0.052, 0.058, th);
        col = col + (vec3<f32>(1.15, 0.07, 0.02) * disc + vec3<f32>(0.42, 0.05, 0.02) * exp(-th / 0.22) + vec3<f32>(0.12, 0.03, 0.012) * exp(-th / 0.8)) * show * vis * sun_up;
    }
    col = vm_over(col, C, rd, scene_len, cloud_t, tr_here, l);
    let srgb = linear_to_srgb(max(col, vec3<f32>(0.0)));
    let out = mix(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb, srgb, fade);
    if (capture() > 2.5) {
        let sp = floor(vc_px);
        let chk = fract((sp.x + sp.y) * 0.5);
        let ycc_y = out.g * 0.5 + (out.r + out.b) * 0.25;
        let ycc_co = out.r - out.b;
        let ycc_cg = out.g - (out.r + out.b) * 0.5;
        return VcOut(vec4<f32>(ycc_y, select(ycc_cg, ycc_co, chk < 0.25) * 0.5 + 0.5, 0.0, 1.0), vec4<f32>(0.0));
    }
    return VcOut(vec4<f32>(out, 1.0), vec4<f32>(0.0));
}
fn pl_ray_seg(rd: vec3<f32>, a: vec3<f32>, b: vec3<f32>, lo: f32, hi: f32) -> vec3<f32> {
    let ab = b - a;
    let ab2 = max(dot(ab, ab), 1.0e-6);
    let bv = dot(rd, ab);
    let den = max(ab2 - bv * bv, 1.0e-6);
    let u = clamp((dot(rd, a) * bv - dot(a, ab)) / den, lo, hi);
    let c = a + ab * u;
    let t = dot(c, rd);
    return vec3<f32>(length(c - rd * t), t, u);
}

@fragment
fn fs_main(in0: StageIn) -> @location(0) vec4<f32> {
    let in = vc_jolt(in0);
    return volcano(in, 0u, vec4<f32>(0.0, 0.0, 0.0, 1.0), 1.0e9).c;
}

// [half stage]
// QUALITY FAST (mod/src/lib.rs keeps this only then): the cloud drawn at half the width and height by fs_half and laid
// over the full-size picture by fs_join; a game without the stage compiles these too and draws fs_main alone.
@group(0) @binding(6) var half_picture: texture_2d<f32>;
@group(0) @binding(7) var half_extra: texture_2d<f32>;

struct VcHalf {
    @location(0) c: vec4<f32>,
    @location(1) e: vec4<f32>,
}
@fragment
fn fs_half(in: StageIn) -> VcHalf {
    vc_px = in.position.xy;
    let o = volcano(in, 1u, vec4<f32>(0.0), 1.0e9);
    return VcHalf(o.c, o.e);
}
// The half-size stage's cloud at this pixel (whose ray goes `len` blocks): a joint bilateral upsample against the depth
// (as the Nuke's pl_up).
fn vc_up(pos: vec2<f32>, len: f32) -> VcOut {
    let hs = vec2<i32>(textureDimensions(half_picture));
    let h = floor(pos) * 0.5 - 0.25;
    let i0 = vec2<i32>(floor(h));
    let f = h - floor(h);
    let lp = min(len, 6.0e4);
    var acc = vec4<f32>(0.0);
    var sw = 0.0;
    var best_w = -1.0;
    var best_t = 1.0e9;
    var near_dz = 1.0e9;
    var near_c = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    var near_t = 1.0e9;
    for (var k = 0; k < 4; k = k + 1) {
        let o = vec2<i32>(k & 1, k >> 1u);
        let q = clamp(i0 + o, vec2<i32>(0), hs - vec2<i32>(1));
        let c = textureLoad(half_picture, q, 0);
        let e = textureLoad(half_extra, q, 0);
        let bw = select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1);
        let dz = abs(e.x - lp) / max(lp, 1.0);
        let w = bw * exp(-dz * 24.0);
        acc = acc + c * w;
        sw = sw + w;
        if (w > best_w) {
            best_w = w;
            best_t = e.y;
        }
        if (dz < near_dz) {
            near_dz = dz;
            near_c = c;
            near_t = e.y;
        }
    }
    if (sw < 1.0e-3) {
        return VcOut(near_c, vec4<f32>(near_t, 0.0, 0.0, 0.0));
    }
    return VcOut(acc / sw, vec4<f32>(best_t, 0.0, 0.0, 0.0));
}
@fragment
fn fs_join(in0: StageIn) -> @location(0) vec4<f32> {
    let in = vc_jolt(in0);
    let d = depth_at(in.uv);
    let len0 = select(1.0e9, length(world_offset(in.uv, d)), !is_sky(d));
    let anc = anchor_xz();
    let len = vm_join_len(in.position.xy, len0, vec3<f32>(anc.x, block_y() + 1.0, anc.y) - frame.camera_position.xyz, normalize(world_offset(in.uv, 0.5)));
    let u = vc_up(in.position.xy, len);
    return volcano(in, 2u, u.c, u.e.x).c;
}
// [end half stage]
// ---- the mount (strike/vc_mount.rs): the land swelling up, then bursting ----
// Appended to volcano.wgsl as the mod builds the pass; everything here is the mount's, from the tremor's end to the
// white-out, and what it threw for as long as that stays in the air. Its hooks in volcano(): vm_surface (the land's
// picture, the drawn mount over it, the plates and shards it threw), vm_air (the steam, the dust and the fire, soft, in with
// the cloud), vm_trails (the dust of what was thrown, in with the bombs' smoke), vm_over (what is sharp, and the white-out),
// vm_chunk_near, and the half-size stage's word of what it found (fs_join looks only where and for what it says),
// vm_join_len (fs_join).
// The drawn height is land(x) + H(t) * P(x) less a crack's cut, read from the columns vc_mount.rs bakes: the real land
// stays flat underneath, and where it lifts by less than a block or two the real picture is left showing.
const VM_BASE: u32 = 65536u;
const VM_HALF: f32 = 480.0;
const VM_STEP: f32 = 4.0;
const VM_GW: u32 = 241u;
const VM_COLS: u32 = 58081u;
const VM_TSIZE: f32 = 64.0;        // a tile's width, blocks
const VM_TN: i32 = 15;
const VM_TILE: u32 = 65552u;       // VM_BASE + 16: two words a tile
const VM_SHARD: u32 = 66048u;      // VM_BASE + 512: VM_SW words a shard
const VM_SHARDS: u32 = 56u;
const VM_SW: u32 = 26u;
const VM_FOUNT: u32 = 67736u;      // VM_BASE + 2200: eight words each
const VM_FOUNTS: u32 = 44u;
const VM_BOULD: u32 = 68336u;      // VM_BASE + 2800
const VM_BOULDS: u32 = 40u;
const VM_BW: u32 = 16u;
const VM_PLATE: u32 = 69036u;      // VM_BASE + 3500
const VM_PW: u32 = 16u;
const VM_FLY: u32 = 95u;           // the plates thrown
const VM_G: f32 = 34.0;            // what comes back down, blocks a second squared
const VM_GF: f32 = 20.0;           // the lava's: slow, it is that high
const VM_W0: u32 = 73728u;         // VM_BASE + 8192
const VM_W1: u32 = 131809u;        // VM_W0 + VM_COLS
const VM_W2: u32 = 189890u;        // VM_W1 + VM_COLS
const VM_RAD: f32 = 400.0;         // the dome's radius, on average
const VM_H: f32 = 285.0;           // and how high it gets
const VM_SWELL: f32 = 7.0;         // volcano.rs's VC_SWELL, VC_HUSH, VC_ERUPT
const VM_HUSH: f32 = 17.0;
const VM_ERUPT: f32 = 18.0;
const VM_GONE: f32 = 19.0;         // nothing of the mount itself is left under the white-out
const VM_FIREOUT: f32 = 19.5;      // but the fire sheet's outer ring, burning out as the blast comes up through it
// What was thrown carries on: plain flight till VM_BRK (under the white-out's rise), then with the air's drag, each plate
// with its own (VM_FLT: its drag's time, the gravity that brings it down when it should, when it hits, the sphere it fits in; vc_mount.rs).
const VM_FLT: u32 = 71736u;        // VM_BASE + 6200: four words a plate thrown
const VM_SLAB: u32 = 72136u;       // VM_BASE + 6600: the slab each is in its own frame, four words (vc_mount.rs's vm_slabs)
// Ten of the plates come down as real land (strike/vc_lodge.rs): a word a plate (its place among them and one), then
// VL_W words each: where it comes to rest turned (a quaternion, its frame to the world), what the ease adds to its flight,
// when it goes (0 not yet, under 0 on into the ground), when the ease starts, where it meets the ground, its plate, the
// way it comes down, half its length.
const VL_MAP: u32 = 72536u;        // VM_BASE + 7000
const VL_BASE: u32 = 72636u;       // VM_BASE + 7100
const VL_W: u32 = 16u;
const VL_N: u32 = 10u;
const VL_EASE: f32 = 3.5;
const VL_FADE: f32 = 0.45;         // the drawn one going, the real one in its place
const VL_SEEN: f32 = 470.0;        // past this the game doesn't show the land's changes: the drawn one stays
const VL_END: f32 = 86.0;          // and goes with the ash, by the strike's end
const VM_BRK: f32 = 18.7;
const VM_TH: f32 = 2.5;            // the drag's time on how far out, every piece's
const VM_FLYEND: f32 = 38.0;       // the last of it is under the land
const VM_CHUNKEND: f32 = 32.5;     // and the last of the chunks

struct VmS {
    on: bool,
    fire: bool,    // the fire sheet still burns
    fly: bool,     // what was thrown is in the air
    t: f32,
    eh: f32,       // the way out it has gone since VM_BRK, as seconds of its speed then
    H: f32,        // the dome's height
    Hb: f32,       // and at the burst: what was thrown keeps that for good (vc_mount.rs's vm_burst_h)
    hk: vec4<f32>, // and each of the plates' four phases' (they lurch up out of step)
    sl: f32,       // how far the land has slid down the dome's back
    cw: f32,       // the cracks' width
    cd: f32,       // how deep they are cut
    open: f32,     // 0 to 1: how far open
    ylo: f32,
    yhi: f32,
    front: f32,    // how far the cracks have raced out
}
var<private> vm: VmS;

fn vm_w(i: u32) -> f32 {
    return bitcast<f32>(mod_data[i]);
}
// The dome's height at time t, its plates' `ph` out of step: slow, then frightening, in lurches, each a little sooner
// than the last; it stops dead.
fn vm_hgt(t: f32, ph: f32) -> f32 {
    let s = clamp(t - VM_SWELL, 0.0, VM_HUSH - VM_SWELL);
    let a = TAU * (0.42 * s + 0.03 * s * s) + ph;
    let da = TAU * (0.42 + 0.06 * s);
    let st = s - 0.8 * sin(a) / da + 0.8 * sin(ph) / (TAU * 0.42);
    let u = saturate(st / 10.0);
    let u2 = u * u;
    // (it stops dead, settling back a little under its own weight; the last instant it heaves)
    let settle = 1.0 - 0.012 * smoothstep(VM_HUSH, VM_HUSH + 0.6, t);
    let heave = 1.0 + 0.09 * smoothstep(VM_ERUPT - 0.03, VM_ERUPT + 0.07, t);
    return VM_H * (0.62 * u + 0.08 * u2 + 0.3 * u2 * u2) * smoothstep(0.0, 0.8, s) * settle * heave;
}
fn vm_set(time: f32) {
    var s: VmS;
    s.t = time;
    let got = arrayLength(&mod_data) > VM_W2 + VM_COLS - 1u && mod_data[VM_BASE] != 0u;
    s.on = got && time > VC_CRACK - 0.1 && time < VM_GONE;
    s.fire = got && time > VM_ERUPT && time < VM_FIREOUT;
    s.fly = got && time > VM_ERUPT && (time < VM_FLYEND || (time < VL_END && mod_data[VM_BASE + 5u] != 0u));
    if (s.on || s.fire || s.fly) {
        s.ylo = vm_w(VM_BASE + 1u) - 12.0;
    }
    if (s.on || s.fly) {
        s.H = vm_hgt(time, 0.0);
        s.Hb = vm_hgt(VM_GONE, 0.0);
        s.eh = vm_eh(time);
    }
    if (s.on) {
        s.hk = vec4<f32>(s.H, vm_hgt(time, 1.7), vm_hgt(time, 3.3), vm_hgt(time, 4.9));
        s.sl = 0.075 * s.H / VM_H;
        s.open = smoothstep(9.5, 17.0, time);
        s.cw = 1.0 + 12.0 * s.open * s.open;
        s.cd = 4.0 + 75.0 * s.open;
        s.yhi = vm_w(VM_BASE + 2u) + 1.45 * s.H;
        s.front = 200.0 * max(time - VC_CRACK, 0.0);
    }
    vm = s;
}
// Where the land at q (level, from the vent) has come from: its surface spreads out as the dome grows under it.
fn vm_rest(q: vec2<f32>) -> vec2<f32> {
    let w = max(1.0 - dot(q, q) / (453.0 * 453.0), 0.0);
    return q * (1.0 - vm.sl * w * w);
}
// The land at rest position g (in columns): x its top, y how much it has lifted, z how far from its plate's edge.
fn vm_fetch(rest: vec2<f32>) -> vec3<f32> {
    let g = clamp((rest + VM_HALF) / VM_STEP, vec2<f32>(0.0), vec2<f32>(239.999));
    let c = floor(g);
    let f = g - c;
    let b = VM_W0 + u32(c.y) * VM_GW + u32(c.x);
    let a0 = mod_data[b];
    let a1 = mod_data[b + 1u];
    let a2 = mod_data[b + VM_GW];
    let a3 = mod_data[b + VM_GW + 1u];
    let land = vec4<f32>(f32(a0 & 0x7ffu), f32(a1 & 0x7ffu), f32(a2 & 0x7ffu), f32(a3 & 0x7ffu)) * 0.5 - 512.0;
    let p = vec4<f32>(f32((a0 >> 11u) & 0x7ffu), f32((a1 >> 11u) & 0x7ffu), f32((a2 >> 11u) & 0x7ffu), f32((a3 >> 11u) & 0x7ffu)) * (1.6 / 2047.0) - 0.25;
    let lf = p * vec4<f32>(vm.hk[(a0 >> 29u) & 3u], vm.hk[(a1 >> 29u) & 3u], vm.hk[(a2 >> 29u) & 3u], vm.hk[(a3 >> 29u) & 3u]);
    let dv = vec4<f32>(f32((a0 >> 22u) & 127u), f32((a1 >> 22u) & 127u), f32((a2 >> 22u) & 127u), f32((a3 >> 22u) & 127u)) * 0.25;
    var hole = vec4<f32>(0.0);
    if (vm.t > VM_ERUPT) {
        // (the plates thrown leave a hole with the fire in it)
        let o = b - VM_W0 + VM_W2;
        hole = vec4<f32>(vm_gone(mod_data[o]), vm_gone(mod_data[o + 1u]), vm_gone(mod_data[o + VM_GW]), vm_gone(mod_data[o + VM_GW + 1u]));
    }
    let m = vec4<f32>((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
    return vec3<f32>(dot(land, m), dot(lf * (1.0 - hole) - 60.0 * hole, m), dot(dv, m));
}
fn vm_gone(w2: u32) -> f32 {
    return step(vm_w(VM_PLATE + (w2 & 255u) * VM_PW + 8u), vm.t);
}
fn vm_crack_w(r2: f32) -> f32 {
    return vm.cw * (1.0 - 0.72 * saturate(r2 / (440.0 * 440.0)));
}
// How much of the crack's cut at D, a crack `w` wide.
fn vm_cutv(d: f32, w: f32) -> f32 {
    return 1.0 - smoothstep(0.15 * w, w, d);
}
// The top of the drawn land at q (level, from the vent).
fn vm_height(q: vec2<f32>) -> f32 {
    let f = vm_fetch(vm_rest(q));
    let r2 = dot(q, q);
    if (f.y < -1.0) {
        return f.x + f.y;
    }
    let cut = min(0.6 * f.y, vm.cd) * vm_cutv(f.z, vm_crack_w(r2));
    // (sunk just under the real land where it has hardly lifted, so the real picture shows there)
    let sink = 3.0 + 10.0 * (1.0 - smoothstep(0.4, 8.0, f.y));
    return f.x + f.y - cut - sink;
}
fn vm_tile_top(i: vec2<i32>) -> f32 {
    let b = VM_TILE + 2u * u32(i.y * VM_TN + i.x);
    return vm_w(b) + max(vm_w(b + 1u), 0.0) * vm.H * 1.12;
}
// The ray (from the eye, `o` the eye from the vent) on to the drawn land, between t0 and t1: how far, or under 0.
// `seeded`: started from the half-size stage's answer, so a start already under the land is the hit.
fn vm_trace(o: vec3<f32>, rd: vec3<f32>, t0: f32, t1: f32, ds0: f32, seeded: bool) -> f32 {
    let rs = select(rd, rd + vec3<f32>(1.0e-5), abs(rd.x) < 1.0e-5 || abs(rd.z) < 1.0e-5);
    let inv = 1.0 / rs;
    let lo = (vec3<f32>(-VM_HALF, vm.ylo, -VM_HALF) - o) * inv;
    let hi = (vec3<f32>(VM_HALF - 0.1, vm.yhi, VM_HALF - 0.1) - o) * inv;
    let tn = min(lo, hi);
    let tf = max(lo, hi);
    var ta = max(max(tn.x, max(tn.y, tn.z)), t0);
    let tb = min(min(tf.x, min(tf.y, tf.z)), t1);
    if (ta >= tb) {
        return -1.0;
    }
    var t = ta;
    var above = true;
    var left = 220;
    var first = seeded;
    for (var it = 0; it < 40; it = it + 1) {
        let p = o + rd * t;
        let ic = clamp(vec2<i32>(floor((p.xz + VM_HALF) / VM_TSIZE)), vec2<i32>(0), vec2<i32>(VM_TN - 1));
        let b0 = vec2<f32>(ic) * VM_TSIZE - VM_HALF;
        let ex = (select(b0.x, b0.x + VM_TSIZE, rs.x > 0.0) - o.x) * inv.x;
        let ez = (select(b0.y, b0.y + VM_TSIZE, rs.z > 0.0) - o.z) * inv.z;
        let te = min(min(ex, ez) + 0.02, tb);
        let top = vm_tile_top(ic);
        let y1 = o.y + rd.y * te;
        if (min(p.y, y1) < top) {
            var s = t;
            var prev = t;
            loop {
                let q = o + rd * s;
                let gap = q.y - vm_height(q.xz);
                left = left - 1;
                if (gap < 0.0 && (above || first)) {
                    if (first) {
                        return s;
                    }
                    // (between the last two looks, closer)
                    var a = prev;
                    var b = s;
                    for (var j = 0; j < 4; j = j + 1) {
                        let m = 0.5 * (a + b);
                        let qm = o + rd * m;
                        if (qm.y - vm_height(qm.xz) < 0.0) {
                            b = m;
                        } else {
                            a = m;
                        }
                    }
                    return b;
                }
                above = gap >= 0.0;
                first = false;
                prev = s;
                s = s + max(ds0 + s * 0.0016, 0.4 * gap);
                if (s >= te || left <= 0) {
                    break;
                }
            }
            if (left <= 0) {
                return -1.0;
            }
        } else {
            above = true;
            first = false;
        }
        t = te;
        if (t >= tb) {
            break;
        }
    }
    return -1.0;
}
fn vm_565(c: u32) -> vec3<f32> {
    return vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0);
}
// The two colours at rest (sRGB, smooth between the columns), the word of its nearest column.
struct VmC {
    top: vec3<f32>,
    under: vec3<f32>,
    w2: u32,
}
fn vm_cols(rest: vec2<f32>) -> VmC {
    let g = clamp((rest + VM_HALF) / VM_STEP, vec2<f32>(0.0), vec2<f32>(239.999));
    let c = floor(g);
    let f = g - c;
    let b = u32(c.y) * VM_GW + u32(c.x);
    let w = array<u32, 4>(mod_data[VM_W1 + b], mod_data[VM_W1 + b + 1u], mod_data[VM_W1 + b + VM_GW], mod_data[VM_W1 + b + VM_GW + 1u]);
    var o: VmC;
    let tx0 = mix(vm_565(w[0]), vm_565(w[1]), f.x);
    let tx1 = mix(vm_565(w[2]), vm_565(w[3]), f.x);
    o.top = mix(tx0, tx1, f.y);
    o.under = mix(mix(vm_565(w[0] >> 16u), vm_565(w[1] >> 16u), f.x), mix(vm_565(w[2] >> 16u), vm_565(w[3] >> 16u), f.x), f.y);
    let n = vec2<u32>(floor(g + 0.5));
    o.w2 = mod_data[VM_W2 + n.y * VM_GW + n.x];
    return o;
}
fn vm_lin(c: vec3<f32>) -> vec3<f32> {
    return c * c * (0.2 + 0.8 * c);
}
// Lava by how hot (0 to 1 and past it): dull red through orange to yellow-white.
fn vm_ramp(h: f32) -> vec3<f32> {
    let u = max(h, 0.0);
    return vec3<f32>(3.2, 0.5, 0.05) * u * u + vec3<f32>(7.0, 3.6, 0.7) * pow(saturate(u - 0.6) / 0.4, 2.0) * u;
}
// Fire, by how deep in it (0 to 1 and past it): smoke-dark red at its edge to white in its heart.
fn vm_fire(h: f32) -> vec3<f32> {
    let u = saturate(h);
    return mix(vec3<f32>(0.9, 0.12, 0.012), mix(vec3<f32>(5.5, 1.5, 0.16), vec3<f32>(12.0, 8.0, 3.4), smoothstep(0.55, 1.0, u)), smoothstep(0.1, 0.6, u)) * (0.4 + 0.6 * smoothstep(0.0, 0.3, h));
}
// How hot the mount's inside shows at rest radius r, now: from the top down, the top alight by 16 s.
fn vm_heat(r: f32) -> f32 {
    let u = r / VM_RAD;
    let hush = 1.0 - 0.45 * smoothstep(VM_HUSH, VM_HUSH + 0.5, vm.t) + 2.0 * smoothstep(VM_ERUPT - 0.05, VM_ERUPT + 0.08, vm.t);
    return smoothstep(10.0 + 6.2 * u * u, 13.0 + 6.0 * u * u, vm.t) * (0.25 + 0.75 * smoothstep(1.05, 0.25, u)) * hush;
}
// The drawn land's colour at distance t along rd (linear).
fn vm_shade(C: vec3<f32>, rd: vec3<f32>, t: f32, l: VcLight, cam_uv: vec2<f32>) -> vec3<f32> {
    let p = rd * t - C;
    let r2 = dot(p.xz, p.xz);
    let r = sqrt(r2);
    let rest = vm_rest(p.xz);
    let rr = length(rest);
    let f = vm_fetch(rest);
    let cl = vm_cols(rest);
    let pw = t * vs.px;                                   // a pixel's size, blocks
    if (f.y < -1.0) {
        let hn = gnoise2(rest * 0.045 + vec2<f32>(0.0, vm.t * 3.0)) + 0.5 * gnoise2(rest * 0.17);
        return vm_fire(0.15 + 0.58 * hn);
    }
    // ---- the shape's slope, smooth and rough ----
    let e = max(3.0, pw * 1.5);
    let hc = f.x + f.y;
    let gx = (vm_height(p.xz + vec2<f32>(e, 0.0)) - vm_height(p.xz - vec2<f32>(e, 0.0))) / (2.0 * e);
    let gz = (vm_height(p.xz + vec2<f32>(0.0, e)) - vm_height(p.xz - vec2<f32>(0.0, e))) / (2.0 * e);
    let slope = length(vec2<f32>(gx, gz));
    let nz = gnoise2(rest * 0.11 + vec2<f32>(3.1, 1.7));
    let nz2 = gnoise2(rest * 0.37);
    // (the rock's grain shows on what is broken, and everything's up close)
    let grain = 1.0 - smoothstep(0.5, 3.0, pw);
    let rough = (0.16 + 0.5 * smoothstep(0.5, 1.4, slope)) * (0.5 + 0.5 * grain);
    let b1 = gnoise2(rest * 0.8 + vec2<f32>(p.y * 0.2, -p.y * 0.1)) - 0.5;
    let b2 = gnoise2(rest.yx * 0.8 + vec2<f32>(9.0, p.y * 0.2)) - 0.5;
    let n = normalize(vec3<f32>(-gx + rough * b1, 1.0, -gz + rough * b2));
    // ---- what it is made of ----
    let wc = vm_crack_w(r2);
    let cutv = vm_cutv(f.z, wc);
    let lifted = smoothstep(1.0, 16.0, f.y);
    let depth = max(hc - p.y, 0.0);                       // how far down a crack or a scarp
    let top = vm_lin(cl.top);
    let under = vm_lin(cl.under);
    // (the layers of the rock, in what is laid open: tipped a little with the plate, bands of pale and dark)
    let plate = f32(cl.w2 & 255u);
    let dip = vec2<f32>(sin(plate * 1.7), cos(plate * 2.3)) * 0.22;
    let by = p.y + dot(rest, dip) + 6.0 * nz;
    let band = 0.5 + 0.2 * sin(by * 0.41 + 3.0 * sin(by * 0.09)) + 0.16 * sin(by * 1.31) + 0.14 * (b1 + b2);
    var rock = mix(vec3<f32>(0.05, 0.047, 0.046), vec3<f32>(0.135, 0.122, 0.108), band);
    rock = mix(rock, vec3<f32>(0.02, 0.019, 0.021), smoothstep(18.0, 70.0, depth));
    // (what stands on it comes away where it steepens: first the trees and the turf, then the dirt)
    let gone = 0.75 * smoothstep(0.1, 0.75, vm.H / VM_H) * smoothstep(0.1, 0.5, f.y / max(vm.H, 1.0));
    let tear = slope + gone + 0.8 * (gnoise2(rest * 0.03 + vec2<f32>(7.0, 2.0)) - 0.5) + 0.7 * (nz - 0.5) + 0.35 * (nz2 - 0.5) + 0.5 * cutv;
    let s1 = smoothstep(0.95, 1.25, tear) * lifted;
    let s2 = smoothstep(1.25, 1.75, tear) * lifted;
    var alb = mix(top, under * 0.8, s1);
    alb = mix(alb, rock, s2);
    // (the land's own: water runs off what tilts, leaving wet ground)
    let kind = (cl.w2 >> 24u) & 7u;
    if (kind == 2u) {
        alb = mix(alb, vec3<f32>(0.05, 0.045, 0.04) * (0.7 + 0.8 * nz2), smoothstep(0.1, 0.45, slope) * smoothstep(3.0, 16.0, f.y));
    }
    // (dust settling on it all, thicker up its back)
    alb = mix(alb, vec3<f32>(0.105, 0.09, 0.08), 0.55 * smoothstep(70.0, VM_H, vm.H) * smoothstep(0.1, 0.6, f.y / max(vm.H, 1.0)) * (0.6 + 0.8 * nz2));
    // ---- its light ----
    var shadow = 1.0;
    if (l.sun_up > 0.0) {
        var s = 12.0;
        for (var i = 0; i < 5; i = i + 1) {
            let q = p + l.L * s;
            if (q.y > vm.yhi) {
                break;
            }
            shadow = min(shadow, saturate(0.5 + (q.y - vm_height(q.xz)) / (0.22 * s + 1.0)));
            s = s * 2.0;
        }
    }
    // (a point in a crevice sees less of the sky)
    let e2 = 15.0;
    let cav = 0.25 * (vm_height(p.xz + vec2<f32>(e2, 0.0)) + vm_height(p.xz - vec2<f32>(e2, 0.0)) + vm_height(p.xz + vec2<f32>(0.0, e2)) + vm_height(p.xz - vec2<f32>(0.0, e2))) - p.y;
    let ao = 1.0 - 0.75 * smoothstep(0.0, 22.0, cav);
    let dl = 0.14 + 0.86 * l.day;
    // (a flat top is as bright as the real land round it, whatever the sun's height; slopes lighter or darker by it)
    let flat_lit = saturate(l.L.y);
    let nl = saturate(dot(n, l.L));
    let lit = (0.5 + (0.92 * (nl - flat_lit) + 0.5) * shadow * l.sun_up + 0.5 * (1.0 - l.sun_up)) * ao * mix(0.72, 1.0, n.y);
    var c = alb * lit * dl * mix(vec3<f32>(1.0), l.sunc * 0.75, 0.35 * l.sun_up);
    // ---- where it has hardly lifted it is the real land itself ----
    let same = 1.0 - smoothstep(5.0, 15.0, f.y);
    if (same > 0.0) {
        let W = C + vec3<f32>(rest.x, f.x, rest.y);
        let P = project_rel(W);
        if (P.z > 0.0 && all(P.xy > vec2<f32>(0.001)) && all(P.xy < vec2<f32>(0.999))) {
            let dd = depth_at(P.xy);
            let lw = length(W);
            // (only if the picture does show that land there: nothing in front of it, no sky behind)
            if (!is_sky(dd) && abs(length(world_offset(P.xy, dd)) - lw) < 3.0 + 0.012 * lw) {
                let sc = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, P.xy, 0.0).rgb);
                c = mix(c, sc * saturate(0.45 + lit), same);
            }
        }
    }
    // ---- the fire inside: the cracks lit from under, the air over them glowing on what stands by ----
    let heat = vm_heat(rr);
    if (heat > 0.0) {
        // (down in the crack, hotter the deeper; the cracks' lips lit by it)
        let dd = saturate(depth / (8.0 + 0.5 * vm.cd));
        let flick = 0.82 + 0.18 * sin(vm.t * 7.0 + plate * 2.0 + nz * 9.0);
        let cr = cutv * heat * flick;
        c = c + vm_ramp((0.14 + 0.62 * dd + 0.2 * (nz2 - 0.5) + 0.5 * smoothstep(VM_ERUPT - 0.05, VM_ERUPT + 0.08, vm.t)) * cr);
        c = c + min(alb, vec3<f32>(0.2)) * vec3<f32>(1.6, 0.26, 0.04) * heat * exp(-max(f.z - wc, 0.0) / 2.4) * (1.0 - cutv);
    }
    // ---- the cracks while still thin; the smaller breaks over each plate, opening late ----
    c = vm_hair(c, f.z, rr, pw);
    let d2 = f32((cl.w2 >> 8u) & 255u) / 8.0;
    if (lifted > 0.0) {
        let ww = max(0.5 + 1.1 * vm.open, pw * 0.7);
        let brk = (1.0 - smoothstep(0.3 * ww, ww, d2)) * lifted * smoothstep(9.0, 14.0, vm.t) * min((0.5 + 1.1 * vm.open) / ww, 1.0);
        c = mix(c, vec3<f32>(0.012), brk * 0.85);
        c = c + vm_ramp(0.62 * heat * smoothstep(13.0, 16.5, vm.t)) * brk;
    }
    return c;
}
// A thin crack over what lies at rest radius r: `d` from its line, `pw` a pixel's size there.
fn vm_hair(c: vec3<f32>, d: f32, r: f32, pw: f32) -> vec3<f32> {
    let w = 0.5 + 1.2 * smoothstep(VC_CRACK, 10.0, vm.t);
    let ww = max(w, pw * 0.7);
    let reach = saturate((vm.front - r * (1.0 + 0.0)) / 30.0);
    let line = (1.0 - smoothstep(0.35 * ww, ww, d)) * reach * min(w / ww, 1.0);
    let hot = 0.6 + 0.4 * smoothstep(VC_CRACK, 12.0, vm.t);
    return mix(c, vec3<f32>(0.02, 0.016, 0.014), line * 0.9) + vec3<f32>(0.9, 0.14, 0.02) * line * line * hot * 0.3;
}

// ---- the shards: columns of rock thrust up through it ----
struct VmSh {
    t: f32,
    n: vec3<f32>,
    i: u32,
    face: u32,  // 5 its broken top, 6 its broken foot
    lp: vec3<f32>,  // the hit in its own frame, up its length
}
// The nearest shard the ray meets before `tmax` (`o` the eye from the vent).
fn vm_shards(o: vec3<f32>, rd: vec3<f32>, tmax: f32) -> VmSh {
    var r: VmSh;
    r.t = -1.0;
    var best = tmax;
    for (var i = 0u; i < VM_SHARDS; i = i + 1u) {
        if (vm_only.w != 0u && all(vm_only != vec4<u32>(i + 101u))) {
            continue;
        }
        let b = VM_SHARD + i * VM_SW;
        let t0 = vm_w(b + 4u);
        if (t0 >= vm.t) {
            break;
        }
        let fl = max(min(vm.t, VM_BRK) - VM_ERUPT - 0.06, 0.0);
        if (fl > 0.0) {
            // (seen from above first, as the plates)
            let pl0 = vec2<f32>(vm_w(b), vm_w(b + 1u)) * (1.0 + 0.5 * (fl + vm.eh)) - o.xz;
            let cr = pl0.x * rd.z - pl0.y * rd.x;
            let rm = vm_w(b + 25u) + 0.5 * vm_w(b + 5u);
            if (cr * cr > rm * rm * dot(rd.xz, rd.xz) + 1.0 && dot(pl0, pl0) > (rm + 90.0) * (rm + 90.0)) {
                continue;
            }
        }
        let e = saturate((vm.t - t0) / 2.2);
        let rise = 1.0 - (1.0 - e) * (1.0 - e) * (1.0 - e);
        let h = vm_w(b + 5u);
        let rad = vm_w(b + 6u);
        // (the ball it fits in, round the middle it tumbles about: all of it, its foot and its top's corners)
        let rb = vm_w(b + 25u);
        let y0 = vm_w(b + 2u) + vm_w(b + 3u) * vm.H - 30.0 + (h + 30.0) * rise - h;
        var c = vec3<f32>(vm_w(b), y0, vm_w(b + 1u));
        // (the burst takes them with the plates)
        let fly = max(vm.t - VM_ERUPT - 0.06, 0.0);
        if (fly > 0.0) {
            let up = 230.0 + 150.0 * fract(t0 * 7.3);
            c = vm_clear(vm_flown(c, vec3<f32>(c.x * 0.5, up, c.z * 0.5), VM_ERUPT + 0.06, 2.4, 44.0, vm.t, vm.eh), o, rb + 0.5 * h + 80.0);
            if (c.y + rb + 0.5 * h < vm.ylo) {
                continue;
            }
        }
        // (first its sphere: it stands h high, a good deal of that under the land yet)
        let mid = c + vec3<f32>(vm_w(b + 7u) * h, 0.5 * h, vm_w(b + 8u) * h) * 0.5;
        let oc = mid - o;
        let tc = dot(oc, rd);
        let dd = dot(oc, oc) - tc * tc;
        if (dd > rb * rb || tc + rb < 0.0) {
            continue;
        }
        let lean = vec2<f32>(vm_w(b + 7u), vm_w(b + 8u));
        // (tumbling, once it is loose: the ray in its frame)
        let tax = vec3<f32>(cos(t0 * 13.0), 0.0, sin(t0 * 13.0));
        let tang = -(0.55 + 0.5 * fract(t0 * 3.1)) * select(1.0, -1.0, fract(t0 * 5.7) < 0.5) * fly;
        let tc0 = cos(tang);
        let ts0 = sin(tang);
        let oo = vm_rot(o - mid, tax, tc0, ts0) + mid - c;
        let rr = vm_rot(rd, tax, tc0, ts0);
        let ro = vec3<f32>(oo.x - lean.x * oo.y, oo.y, oo.z - lean.y * oo.y);
        let dv = vec3<f32>(rr.x - lean.x * rr.y, rr.y, rr.z - lean.y * rr.y);
        let taper = vm_w(b + 11u);
        var tn = -1.0e9;
        var tf = 1.0e9;
        var nb = vec3<f32>(0.0, 1.0, 0.0);
        var fb = 0u;
        for (var f = 0u; f < 5u; f = f + 1u) {
            let n = vec3<f32>(vm_w(b + 12u + 2u * f), taper, vm_w(b + 13u + 2u * f));
            let den = dot(n, dv);
            let tt = (rad - dot(n, ro)) / den;
            if (den < 0.0) {
                if (tt > tn) {
                    tn = tt;
                    nb = n;
                    fb = f;
                }
            } else {
                tf = min(tf, tt);
            }
        }
        // (its top, tilted)
        let tp = vec3<f32>(vm_w(b + 9u), 1.0, vm_w(b + 10u));
        let den = dot(tp, dv);
        let tt = (h - dot(tp, ro)) / den;
        if (den < 0.0) {
            if (tt > tn) {
                tn = tt;
                nb = tp;
                fb = 5u;
            }
        } else {
            tf = min(tf, tt);
        }
        // (its foot, broken off under the land's slope: without one its sides run on down, and all that ends them is the
        // edge of its sphere, a round cut that faces the eye however the shard is turned)
        let fp = vec3<f32>(vm_w(b + 22u), 1.0, vm_w(b + 23u));
        let fden = dot(fp, dv);
        let ft = (-vm_w(b + 24u) - dot(fp, ro)) / fden;
        if (fden > 0.0) {
            if (ft > tn) {
                tn = ft;
                nb = -fp;
                fb = 6u;
            }
        } else {
            tf = min(tf, ft);
        }
        if (tn < tf && tn > 0.0 && tn < best) {
            best = tn;
            r.t = tn;
            r.i = i;
            r.face = fb;
            r.lp = ro + dv * tn;
            r.n = vm_rot(normalize(vec3<f32>(nb.x, nb.y - lean.x * nb.x - lean.y * nb.z, nb.z)), tax, tc0, -ts0);
        }
    }
    return r;
}
fn vm_shade_shard(C: vec3<f32>, rd: vec3<f32>, h: VmSh, l: VcLight) -> vec3<f32> {
    let p = rd * h.t - C;
    let b = VM_SHARD + h.i * VM_SW;
    // (how far over the land it is torn out of: a shard's foot runs down the slope)
    let up = select(1.0e3, p.y - vm_height(p.xz), vm.on);
    // (dark basalt, streaked down its length, each face its own; a broken top with the land's turf on it)
    let f = f32(h.face);
    let ac = dot(h.lp.xz, vec2<f32>(0.7, -0.7));
    // (its streaks fine up close, broad from afar: the fine ones would only shimmer there)
    // (its foot has no length for them to run down: rough, as a plate's underside)
    let st = select(mix(gnoise2(vec2<f32>(ac * 0.9 + f * 7.0, h.lp.y * 0.05)), gnoise2(vec2<f32>(ac * 0.13 + f * 7.0, h.lp.y * 0.014)), smoothstep(0.7, 2.2, h.t * vs.px)), gnoise2(h.lp.xz * 0.16 + vec2<f32>(f, 2.0)), h.face == 6u);
    var alb = mix(vec3<f32>(0.018, 0.017, 0.019), vec3<f32>(0.095, 0.086, 0.08), st * st);
    if (h.face == 5u) {
        alb = mix(vm_lin(vm_cols(vec2<f32>(vm_w(b), vm_w(b + 1u))).top), vec3<f32>(0.07, 0.06, 0.05), 0.4);
    }
    // (its turf burnt and its faces thick with dust and soot, once it is in the air)
    alb = mix(alb, vec3<f32>(0.03, 0.026, 0.024) * (0.5 + st), 0.85 * smoothstep(VM_GONE, 21.0, vm.t));
    let dl = 0.14 + 0.86 * l.day;
    let nl = saturate(dot(h.n, l.L));
    var c = alb * dl * (0.42 + 1.5 * nl * l.sun_up) * mix(vec3<f32>(1.0), l.sunc * 0.75, 0.35 * l.sun_up);
    // (lit red from where it tears out of the land)
    let heat = saturate(vm_heat(length(p.xz)) + 0.35);
    c = c + alb * vec3<f32>(9.0, 1.7, 0.2) * exp(-max(up, 0.0) / 18.0) * heat;
    c = c + vm_ramp(0.55 * exp(-max(up, 0.0) / 7.0) * heat);
    // (its foot was in the fire, as a plate's underside: burning all over as it tears loose, going out to the veins in
    // it, and then those)
    if (h.face == 6u) {
        let q = h.lp.xz + vec2<f32>(f32(h.i) * 37.0, 9.0);
        let vein = (1.0 - smoothstep(0.0, 0.07, abs(gnoise2(q * 0.07) - 0.5))) * smoothstep(0.36, 0.56, gnoise2(q * 0.03));
        c = c + vm_ramp(0.6 * mix(smoothstep(0.3, 0.7, st), vein, smoothstep(18.9, 19.6, vm.t)) * exp(-max(vm.t - VM_GONE, 0.0) / 2.2));
    }
    return c + alb * vm_firelit(p, h.n);
}

// ---- the plates, thrown: slabs of the land, on their own now, with the fire behind them ----
struct VmPl {
    t: f32,
    n: vec3<f32>,     // in the world
    rest: vec2<f32>,  // where on the land it was
    kind: u32,        // 0 its top, 1 its edge or underside
    i: u32,
    dep: f32,         // how far down through it, 0 to 1
    y: f32,           // how high it was, at rest
    vis: f32,         // how much of it shows: one that stays goes as the real one takes its place
    lodged: bool,
}
// What is thrown never goes through the eye: a plate there would black out the picture, and with the eye inside it the
// half stage's march would stop at nothing. It slides round a ball about the eye instead, `keep` from its middle.
fn vm_clear(c: vec3<f32>, o: vec3<f32>, keep: f32) -> vec3<f32> {
    let e = c - o;
    let d = length(e);
    if (d >= keep || d < 0.01) {
        return c;
    }
    return o + e * keep / d;
}
// How far out a piece has gone by time t since VM_BRK, as seconds of its speed then.
fn vm_eh(t: f32) -> f32 {
    return VM_TH * (1.0 - exp(-max(t - VM_BRK, 0.0) / VM_TH));
}
// Where a piece thrown from p0 at v, at time tr, is at time t: `tau`, `g` its fall through the air after VM_BRK, `eh` vm_eh(t).
fn vm_flown(p0: vec3<f32>, v: vec3<f32>, tr: f32, tau: f32, g: f32, t: f32, eh: f32) -> vec3<f32> {
    let s = max(t - VM_BRK, 0.0);
    let a = t - tr - s;
    let vy = v.y - VM_G * a;
    var c = p0 + vec3<f32>(v.x, v.y - 0.5 * VM_G * a, v.z) * a + vec3<f32>(v.x * eh, 0.0, v.z * eh);
    if (s > 0.0) {
        let vt = g * tau;
        c.y = c.y + (vy + vt) * tau * (1.0 - exp(-s / tau)) - vt * s;
    }
    return c;
}
// The fire's light on what is thrown (to be multiplied by its albedo), at p with normal n: red-orange, from under, while
// the fire is out in the open.
fn vm_firelit(p: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
    let f = vec3<f32>(-p.x, vm.ylo + 90.0 - p.y, -p.z);
    let d2 = dot(f, f);
    let k = 1.0 / (1.0 + d2 / (520.0 * 520.0)) * (1.0 - 0.75 * smoothstep(23.0, 34.0, vm.t));
    return vec3<f32>(1.7, 0.5, 0.08) * saturate(dot(n, f) / sqrt(d2) * 0.8 + 0.2) * k;
}
// A vector turned about the unit axis by an angle (cos, sin).
fn vm_rot(v: vec3<f32>, ax: vec3<f32>, c: f32, s: f32) -> vec3<f32> {
    return v * c + cross(ax, v) * s + ax * dot(ax, v) * (1.0 - c);
}
// Plate i's top at rest position xz, as it stood when it broke, from its own columns only: between two plates the land
// steps as far as they were heaved apart, and a top that ran across that step would stand a fin along the plate's edge,
// a block thin and tens of blocks high, that the looks catch from some sides and not from others. `miss` where none of
// the four is its own (the very tip of a broken edge).
fn vm_top(xz: vec2<f32>, i: u32, miss: f32) -> f32 {
    let g = clamp((xz + VM_HALF) / VM_STEP, vec2<f32>(0.0), vec2<f32>(239.999));
    let c = floor(g);
    let f = g - c;
    let b = VM_W0 + u32(c.y) * VM_GW + u32(c.x);
    let o = b - VM_W0 + VM_W2;
    let own = vec4<u32>(mod_data[o] & 255u, mod_data[o + 1u] & 255u, mod_data[o + VM_GW] & 255u, mod_data[o + VM_GW + 1u] & 255u) == vec4<u32>(i);
    let m = select(vec4<f32>(0.0), vec4<f32>((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y), own);
    let k = m.x + m.y + m.z + m.w;
    if (k < 1.0e-4) {
        return miss;
    }
    let a0 = mod_data[b];
    let a1 = mod_data[b + 1u];
    let a2 = mod_data[b + VM_GW];
    let a3 = mod_data[b + VM_GW + 1u];
    let land = vec4<f32>(f32(a0 & 0x7ffu), f32(a1 & 0x7ffu), f32(a2 & 0x7ffu), f32(a3 & 0x7ffu)) * 0.5 - 512.0;
    let p = vec4<f32>(f32((a0 >> 11u) & 0x7ffu), f32((a1 >> 11u) & 0x7ffu), f32((a2 >> 11u) & 0x7ffu), f32((a3 >> 11u) & 0x7ffu)) * (1.6 / 2047.0) - 0.25;
    return dot(land + p * vm.Hb, m) / k;
}
// A quaternion's turn of v.
fn vl_rot(q: vec4<f32>, v: vec3<f32>) -> vec3<f32> {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}
fn vl_slerp(a: vec4<f32>, b0: vec4<f32>, u: f32) -> vec4<f32> {
    var d = dot(a, b0);
    let b = select(b0, -b0, d < 0.0);
    d = abs(d);
    if (d > 0.9995) {
        return normalize(mix(a, b, u));
    }
    let th = acos(d);
    return (a * sin((1.0 - u) * th) + b * sin(u * th)) / sin(th);
}
// How thick a plate that comes down is at (x, z), a share of its thickness: its underside torn (vc_lodge.rs's vl_thk).
fn vl_thk(xz: vec2<f32>) -> f32 {
    let a = sin(xz.x * 0.083 + 1.3 * sin(xz.y * 0.047)) * sin(xz.y * 0.071 - 0.9);
    let b = sin(xz.x * 0.19 - xz.y * 0.13 + 0.7) * sin(xz.y * 0.17 + xz.x * 0.05);
    return 0.82 + 0.13 * a + 0.05 * b;
}
// How far the ease has come at time t, for the plate with words at lb.
fn vl_u(lb: u32, t: f32) -> f32 {
    return saturate((t - vm_w(lb + 8u)) / VL_EASE);
}
// What the ease adds to its flight by then: it slides in along its way, faster and faster.
fn vl_add(lb: u32, u: f32) -> vec3<f32> {
    return vec3<f32>(vm_w(lb + 4u), vm_w(lb + 5u), vm_w(lb + 6u)) * u * u;
}
// Whether the point lp of plate i's frame (cxz its middle, y0 its height) is in it.
fn vm_in_plate(lp: vec3<f32>, cxz: vec2<f32>, y0: f32, i: u32, th0: f32, lodged: bool) -> bool {
    let xz = lp.xz + cxz;
    if (any(abs(xz) > vec2<f32>(VM_HALF - 3.0))) {
        return false;
    }
    // (broken edges: never the columns' own stairs)
    let jit = vec2<f32>(sin(xz.y * 0.43 + xz.x * 0.11), sin(xz.x * 0.47 - xz.y * 0.13)) * 0.8;
    let gc = vec2<u32>(clamp((xz + VM_HALF) / VM_STEP + 0.5 + jit, vec2<f32>(0.0), vec2<f32>(240.0)));
    if ((mod_data[VM_W2 + gc.y * VM_GW + gc.x] & 255u) != i) {
        return false;
    }
    let y = lp.y + y0;
    let top = vm_top(xz, i, -1.0e6);
    let th = select(th0, th0 * vl_thk(xz), lodged);
    return y <= top && y >= top - th;
}
fn vm_plates(o: vec3<f32>, rd: vec3<f32>, tmax: f32) -> VmPl {
    var r: VmPl;
    r.t = -1.0;
    r.vis = 1.0;
    if (vm.t <= VM_ERUPT) {
        return r;
    }
    var best = tmax;
    // (past VM_FLYEND only those that stay are left to look at)
    let tail = vm.t > VM_FLYEND;
    let count = select(VM_FLY, VL_N, tail);
    for (var n = 0u; n < count; n = n + 1u) {
        let i = select(n, u32(vm_w(VL_BASE + n * VL_W + 12u)), tail);
        if (vm_only.w != 0u && all(vm_only != vec4<u32>(i + 1u))) {
            continue;
        }
        let lk = mod_data[VL_MAP + i];
        if (tail && lk == 0u) {
            continue;
        }
        let lb = VL_BASE + (lk - 1u) * VL_W;
        let b = VM_PLATE + i * VM_PW;
        let tr = vm_w(b + 8u);
        let a = vm.t - tr;
        let fb = VM_FLT + i * 4u;
        let rad = vm_w(fb + 3u);
        let hit = vm_w(fb + 2u);
        // (not yet thrown; or gone into the land, a plate's width after it struck; or one that stays, its real one in)
        var vis = 1.0;
        var sink = lk == 0u;
        if (lk != 0u) {
            let gone = vm_w(lb + 7u);
            sink = gone < 0.0;
            if (gone > 0.0 && vm.t > gone) {
                let e = vec3<f32>(vm_w(lb + 9u), vm_w(lb + 10u), vm_w(lb + 11u)) - o;
                vis = select(1.0 - saturate((vm.t - gone) / VL_FADE), 1.0, dot(e, e) > VL_SEEN * VL_SEEN);
            }
            vis = vis * (1.0 - smoothstep(VL_END - 4.0, VL_END, vm.t));
            if (vis <= 0.0) {
                continue;
            }
        }
        if (a <= 0.0 || (sink && vm.t > hit + rad * 0.012)) {
            continue;
        }
        // (seen from above first: where it is over the land needs no gravity, and most rays pass well clear of it)
        let vxz = vec2<f32>(vm_w(b + 9u), vm_w(b + 11u));
        let keep0 = rad + 140.0;
        if (lk == 0u) {
            let pl0 = vec2<f32>(vm_w(b), vm_w(b + 1u)) + vxz * (min(a, VM_BRK - tr) + vm.eh) - o.xz;
            let cr = pl0.x * rd.z - pl0.y * rd.x;
            if (cr * cr > rad * rad * 1.1 * dot(rd.xz, rd.xz) + 1.0 && dot(pl0, pl0) > keep0 * keep0) {
                continue;
            }
        }
        let rest = vec3<f32>(vm_w(b), vm_w(b + 2u) + vm_w(b + 3u) * vm.Hb, vm_w(b + 1u));
        // (one that stays eases into where it comes to rest, tumble and all, and stops there)
        let te = select(vm.t, min(vm.t, hit), lk != 0u);
        var c = vm_flown(rest, vec3<f32>(vxz.x, vm_w(b + 10u), vxz.y), tr, vm_w(fb), vm_w(fb + 1u), te, vm_eh(te));
        var keep = keep0;
        var eu = 0.0;
        if (lk != 0u) {
            eu = vl_u(lb, te);
            c = c + vl_add(lb, eu);
            keep = keep0 * (1.0 - eu) * (1.0 - eu);
            if (sink && vm.t > hit) {
                c = c + vec3<f32>(0.35 * vm_w(lb + 13u), -1.0, 0.35 * vm_w(lb + 14u)) * 130.0 * (vm.t - hit);
            }
        }
        c = vm_clear(c, o, keep);
        let oc = c - o;
        let tc = dot(oc, rd);
        let dd = dot(oc, oc) - tc * tc;
        if (dd > rad * rad * 1.1 || tc + rad < 0.0) {
            continue;
        }
        // (the ray in the plate's own frame: there it lies where it lay)
        let ax = vec3<f32>(vm_w(b + 12u), 0.0, vm_w(b + 13u));
        let ang = -vm_w(b + 14u) * a;
        let cs = cos(ang);
        let sn = sin(ang);
        var lo = vm_rot(o - c, ax, cs, sn);
        var ld = vm_rot(rd, ax, cs, sn);
        var qe = vec4<f32>(0.0, 0.0, 0.0, 1.0);
        if (lk != 0u) {
            let hf = 0.5 * vm_w(b + 14u) * (te - tr);
            qe = vl_slerp(vec4<f32>(ax * sin(hf), cos(hf)), vec4<f32>(vm_w(lb), vm_w(lb + 1u), vm_w(lb + 2u), vm_w(lb + 3u)), smoothstep(0.0, 1.0, eu));
            let inv = vec4<f32>(-qe.xyz, qe.w);
            lo = vl_rot(inv, o - c);
            ld = vl_rot(inv, rd);
        }
        // (between its top and its underside: the planes its own land's tops lie between, vm_slabs)
        let sb = VM_SLAB + i * 4u;
        let n = vec3<f32>(-vm_w(sb), 1.0, -vm_w(sb + 1u));
        let dn = dot(n, ld);
        if (abs(dn) < 1.0e-5) {
            continue;
        }
        let th = vm_w(b + 7u);
        let lt = vm_w(sb + 2u) - th;
        let hi = vm_w(sb + 3u);
        let t0 = (hi - dot(n, lo)) / dn;
        let t1 = (lt - dot(n, lo)) / dn;
        // (only where the ray is near it: its sphere's chord, so the looks are spent on it)
        let ch = sqrt(max(rad * rad * 1.1 - dd, 0.0));
        let ta = max(max(min(t0, t1), tc - ch), 0.0);
        let tb = min(min(max(t0, t1), tc + ch), best);
        if (ta >= tb) {
            continue;
        }
        let cxz = vec2<f32>(vm_w(b), vm_w(b + 1u));
        // (looks down the ray through the slab for this plate's own columns, between their land's top and its thickness
        // under that: it carries the land as it stood, crags and all; its edges are the cracks')
        // (the half-size stage only has to find it, near enough)
        // (`vs` is not yet set when fs_join's first look comes here)
        let fine = max(vs.fine, 1.0);
        let looks = 2 + i32(min((tb - ta) / max(2.5 * fine, ta * frame.view_params.w / frame.resolution.y), select(44.0, 60.0, fine < 1.5)));
        let dtl = (tb - ta) / f32(looks);
        for (var k = 0; k < looks; k = k + 1) {
            let t = ta + dtl * (f32(k) + 0.1);
            if (!vm_in_plate(lo + ld * t, cxz, rest.y, i, th, lk != 0u)) {
                continue;
            }
            var a0 = t - dtl;
            var b0 = t;
            // (the half-size stage only needs to know which, and about how far)
            if (fine > 1.5) {
                best = t;
                r.t = t;
                r.i = i;
                r.vis = vis;
                r.lodged = lk != 0u;
                break;
            }
            for (var q = 0; q < 4; q = q + 1) {
                let m = 0.5 * (a0 + b0);
                if (vm_in_plate(lo + ld * m, cxz, rest.y, i, th, lk != 0u)) {
                    b0 = m;
                } else {
                    a0 = m;
                }
            }
            let lp = lo + ld * b0;
            let xz = lp.xz + cxz;
            let top = vm_top(xz, i, 0.0);
            let dep = top - (lp.y + rest.y);
            best = b0;
            r.t = b0;
            r.rest = xz;
            r.kind = select(1u, 0u, dep < 3.4);
            r.i = i;
            r.vis = vis;
            r.lodged = lk != 0u;
            r.dep = saturate(dep / th);
            r.y = lp.y + rest.y;
            // (its broken side, or its underside)
            var nn = select(normalize(vec3<f32>(-ld.x, 0.0, -ld.z) + vec3<f32>(1.0e-4)), -normalize(n), r.dep > 0.8);
            if (r.kind == 0u) {
                let e = 4.0;
                nn = normalize(vec3<f32>((vm_top(xz - vec2<f32>(e, 0.0), i, top) - vm_top(xz + vec2<f32>(e, 0.0), i, top)) / (2.0 * e), 1.0, (vm_top(xz - vec2<f32>(0.0, e), i, top) - vm_top(xz + vec2<f32>(0.0, e), i, top)) / (2.0 * e)));
            }
            r.n = select(vm_rot(nn, ax, cs, -sn), vl_rot(qe, nn), lk != 0u);
            break;
        }
    }
    return r;
}
fn vm_shade_plate(C: vec3<f32>, rd: vec3<f32>, h: VmPl, l: VcLight) -> vec3<f32> {
    let p = rd * h.t - C;
    let cl = vm_cols(h.rest);
    let nl = saturate(dot(h.n, l.L));
    let dl = 0.14 + 0.86 * l.day;
    let nz = gnoise2(h.rest * 0.2);
    if (h.kind == 0u) {
        // (its land as it stood, the steep of it bare rock: lit by the sun, the fire on what faces down)
        let slope = sqrt(max(1.0 - h.n.y * h.n.y, 0.0)) / max(h.n.y, 0.15);
        // (as vm_shade made it: what stands on it torn away where it steepens, the water run off, the dust on it)
        let nf = gnoise2(h.rest * 0.11 + vec2<f32>(3.1, 1.7));
        let nf2 = gnoise2(h.rest * 0.37);
        let tear = slope + 0.7 * (nf - 0.5) + 0.35 * (nf2 - 0.5);
        let by = h.y + 6.0 * nf;
        let rock = mix(vec3<f32>(0.05, 0.047, 0.046), vec3<f32>(0.135, 0.122, 0.108), 0.5 + 0.3 * sin(by * 0.41));
        var alb = mix(vm_lin(cl.top), vm_lin(cl.under) * 0.8, smoothstep(0.95, 1.25, tear));
        if (((cl.w2 >> 24u) & 7u) == 2u) {
            alb = vec3<f32>(0.05, 0.045, 0.04) * (0.7 + 0.8 * nf2);
        }
        alb = mix(alb, rock, smoothstep(1.25, 1.75, tear));
        alb = mix(alb, vec3<f32>(0.105, 0.09, 0.08), 0.5 * (0.6 + 0.8 * nf2));
        let d2 = f32((cl.w2 >> 8u) & 255u) / 8.0;
        // (one that stays shakes it off as it comes down: its land as the real one will show it)
        let burnt = select(0.88, 0.88 * (1.0 - smoothstep(vm_w(VM_FLT + h.i * 4u + 2u) - 7.0, vm_w(VM_FLT + h.i * 4u + 2u) - 1.0, vm.t)), h.lodged);
        alb = mix(alb, vec3<f32>(0.03, 0.026, 0.023) * (0.3 + 3.0 * nf2 * nf2 * nf), burnt * smoothstep(VM_GONE, 21.0, vm.t));
        return mix(alb * dl * (0.4 + 0.9 * nl) + alb * vm_firelit(p, h.n), vec3<f32>(0.012), 0.8 * (1.0 - smoothstep(0.3, 1.4, d2)));
    }
    // (its broken edge and underside: raw rock, burning)
    let st = gnoise2(vec2<f32>(dot(h.rest, vec2<f32>(0.6, 0.8)) * 0.09, h.dep * 2.2));
    // (burning all over as it tears loose; going out to the veins in it, and then those)
    let vein = (1.0 - smoothstep(0.0, 0.07, abs(gnoise2(h.rest * 0.07 + vec2<f32>(1.0, 4.0)) - 0.5))) * smoothstep(0.36, 0.56, gnoise2(h.rest * 0.019 + vec2<f32>(9.0, 2.0)));
    let hot = smoothstep(0.62, 1.05, h.dep + 0.7 * (st - 0.5)) * mix(1.0, vein, smoothstep(18.9, 19.6, vm.t)) * exp(-max(vm.t - VM_GONE, 0.0) / 2.2);
    // (rough: the rock's own lumps turn the light; pale seams and dark patches in it, darker the deeper it was)
    let n1 = gnoise2(h.rest * 0.31);
    let n2 = gnoise2(h.rest * 0.31 + vec2<f32>(5.2, 1.3));
    let nb = normalize(h.n + 0.9 * (vec3<f32>(n1, 0.5 * (n1 + n2), n2) - 0.5));
    let big = gnoise2(h.rest * 0.045 + vec2<f32>(2.0, 8.0));
    // (one that stays as dark as its real rock will be: soil and stone near its top, burnt rock under them)
    let raw0 = mix(vec3<f32>(0.011, 0.0105, 0.011), vec3<f32>(0.068, 0.06, 0.053), st * st * (0.45 + big));
    let raw = select(raw0, mix(mix(vec3<f32>(0.16, 0.105, 0.07), vec3<f32>(0.12, 0.115, 0.11), smoothstep(0.1, 0.22, h.dep)), raw0 * 1.4, smoothstep(0.5, 0.8, h.dep + 0.2 * (st - 0.5))), h.lodged);
    let fill = 0.2 + 0.32 * saturate(0.5 + 0.5 * nb.y);
    return raw * (dl * (fill + 1.05 * saturate(dot(nb, l.L)) * l.sun_up) + vm_firelit(p, nb)) + vm_ramp(0.6 * hot);
}

// What vm_surface gives: the picture there and how far off it (under 0: nothing of the mount here).
struct VmHit {
    c: vec3<f32>,
    t: f32,
    id: f32,    // what of the thrown it is: 0 none, 1 on a plate's number and one, 101 on a shard's
}
var<private> vm_got: f32 = -2.0;   // the hit fs_join found (-2: not looked yet)
var<private> vm_plc: vec3<f32>;    // a thrown plate at this pixel, shown through the fire: land and fire lift as one sheet
var<private> vm_plk: f32 = 0.0;
var<private> vm_rocky: bool = true;  // fs_join: a chunk may be at this pixel
var<private> vm_none: bool = false;  // fs_join: nothing thrown is at this pixel
var<private> vm_only: vec4<u32>;     // fs_join: only these are (.w 0: any of them)
var<private> vm_lkd: bool = false;   // what is thrown has been looked for along this pixel's ray
var<private> vm_lsh: VmSh;
var<private> vm_lpl: VmPl;
// What is thrown along the ray (`o` the eye from the vent), up to `lim`, the plates against what is nearer of the shards.
fn vm_look(o: vec3<f32>, rd: vec3<f32>, lim: f32) {
    if (vm_lkd) {
        return;
    }
    vm_lkd = true;
    // (past VM_FLYEND nothing is left of the shards)
    if (vm.t > VM_FLYEND) {
        vm_lsh.t = -1.0;
    } else {
        vm_lsh = vm_shards(o, rd, lim);
    }
    vm_lpl = vm_plates(o, rd, select(lim, vm_lsh.t, vm_lsh.t > 0.0));
}
// The land's picture: the drawn mount where the ray meets it first; on the real land past it, the cracks.
fn vm_surface(C: vec3<f32>, rd: vec3<f32>, scene_len: f32, col: vec3<f32>, stage: u32, l: VcLight, uv: vec2<f32>, sky: bool) -> VmHit {
    var o: VmHit;
    o.c = col;
    o.t = -1.0;
    if ((!vm.on && !vm.fly) || vm_none) {
        return o;
    }
    var t = vm_got;
    if (t < -1.5 && vm.on) {
        t = vm_trace(-C, rd, 0.0, scene_len + 2.0, select(1.5, 3.0, stage == 1u), false);
    }
    let lim = select(scene_len + 1.5, min(t, scene_len + 1.5), t > 0.0);
    vm_look(-C, rd, lim);
    let sh = vm_lsh;
    let pl = vm_lpl;
    // (the air between: it stands a long way off)
    let ap = 1.0 - exp(-select(select(lim, sh.t, sh.t > 0.0), pl.t, pl.t > 0.0) / 14000.0);
    if (pl.t > 0.0) {
        o.t = pl.t;
        o.id = f32(pl.i + 1u);
        if (stage != 1u) {
            o.c = mix(col, mix(vm_shade_plate(C, rd, pl, l), vc_haze(rd, l), 0.3 * ap), pl.vis);
            vm_plc = o.c;
            vm_plk = 1.0 - smoothstep(VM_GONE - 0.05, VM_GONE + 0.1, vm.t);
        }
        return o;
    }
    if (sh.t > 0.0) {
        o.t = sh.t;
        o.id = f32(sh.i + 101u);
        if (stage != 1u) {
            o.c = mix(vm_shade_shard(C, rd, sh, l), vc_haze(rd, l), select(0.3, 1.0, vm.on) * ap);
        }
        return o;
    }
    if (t > 0.0 && t < scene_len + 1.5) {
        o.t = t;
        if (stage != 1u) {
            o.c = mix(vm_shade(C, rd, t, l, uv), vc_haze(rd, l), ap);
        }
        return o;
    }
    if (stage != 1u && !sky && vm.on) {
        let p = rd * scene_len - C;
        if (all(abs(p.xz) < vec2<f32>(VM_HALF - 3.0)) && abs(p.y - vm.ylo) < 400.0) {
            let f = vm_fetch(vm_rest(p.xz));
            o.c = vm_hair(col, f.z, length(p.xz), scene_len * vs.px);
        }
    }
    return o;
}

// ---- what hangs in the air over it: the steam off the cracks, the dust down the flanks and round the foot ----
// Soft: a density from where the cracks and the land are, worn away by noise, marched at half size with the cloud.
// The ground under q, near enough for what hangs over it (one word, no smoothing): .x its height, .y how far from a crack.
fn vm_under(q: vec2<f32>) -> vec2<f32> {
    let g = clamp((vm_rest(q) + VM_HALF) / VM_STEP + 0.5, vec2<f32>(0.0), vec2<f32>(240.0));
    let c = vec2<u32>(g);
    let a = mod_data[VM_W0 + c.y * VM_GW + c.x];
    let land = f32(a & 0x7ffu) * 0.5 - 512.0;
    let p = f32((a >> 11u) & 0x7ffu) * (1.6 / 2047.0) - 0.25;
    return vec2<f32>(land + p * vm.H, f32((a >> 22u) & 127u) * 0.25);
}
struct VmAir {
    steam: f32,
    dust: f32,
    up: f32,     // how far over the land
    crack: f32,  // how far from a crack
}
fn vm_field(q: vec3<f32>, t: f32) -> VmAir {
    var a: VmAir;
    let r = length(q.xz);
    if (r > VM_HALF * 1.2) {
        return a;
    }
    // (wind and rise carry it, so it wanders off the cracks as it climbs)
    let w0 = gnoise3(q * 0.016 + vec3<f32>(0.0, -t * 0.5, 0.0));
    let w1 = gnoise3(q.zxy * 0.016 + vec3<f32>(3.7, -t * 0.5, 1.1));
    let u0 = vm_under(q.xz);
    let up = q.y - u0.x;
    a.up = up;
    if (up < -8.0) {
        return a;
    }
    let wob = vec2<f32>(w0 - 0.5, w1 - 0.5) * (7.0 + 0.9 * max(up, 0.0));
    let u = vm_under(q.xz + wob);
    a.crack = u.y;
    // ---- the steam: thin along the cracks at first, racing out with them, then thick columns off the live ones ----
    let reach = saturate((vm.front - r) / 50.0);
    let live = smoothstep(0.42, 0.68, gnoise2(q.xz * 0.011 + vec2<f32>(t * 0.05, 3.0)));
    // (the great plumes: blobs of a broad noise, wider as they climb, each its own height, standing up off the land)
    let pw = wob * 0.35;
    let pg = gnoise2((q.xz + pw) * 0.0078 + vec2<f32>(11.0, 4.0));
    let pth = 0.63 - 0.00045 * max(up, 0.0);
    let pl = smoothstep(pth, pth + 0.05, pg) * (1.0 - smoothstep(230.0, 420.0, r - 0.5 * max(up, 0.0)));
    let ph = (180.0 + 640.0 * gnoise2((q.xz + pw) * 0.0031)) * smoothstep(6.5, 13.5, t) + 20.0;
    // (a jet where the crack has just got to: a ring of them racing out over the land)
    let jetk = exp(-max(vm.front - r, 0.0) / 300.0);
    let tall = 12.0 + (12.0 + 46.0 * live) * smoothstep(7.0, 15.0, t) * (1.0 - 0.45 * smoothstep(11.0, 14.0, t)) + 120.0 * jetk;
    let wd = 3.0 + 0.22 * max(up, 0.0);
    a.steam = max((1.0 - smoothstep(0.2 * wd, wd, u.y)) * exp(-max(up, 0.0) / tall) * min(0.2 + 0.8 * live + 1.3 * jetk, 1.0) * saturate(1.0 - up / 220.0), pl * saturate(1.0 - up / ph) * saturate(1.0 + up / 8.0)) * reach;
    // ---- the dust: pouring down off what breaks, lying in a ring round its foot, spreading ----
    let dt = smoothstep(9.5, 15.0, t);
    if (dt > 0.0) {
        let k = vm.H / VM_H;
        let fc = dot(q.xz, vec2<f32>(vm_w(VM_BASE + 3u), vm_w(VM_BASE + 4u))) / max(r, 1.0);
        let fr = VM_RAD * (1.16 - 0.32 * fc * fc) * (0.98 + 0.2 * smoothstep(12.0, 17.5, t));
        let ring = exp(-pow((r - fr) / (30.0 + 44.0 * k), 2.0));
        let ht = 16.0 + 46.0 * k;
        let band = ring * exp(-max(up, 0.0) / ht);
        let n = gnoise2(q.xz * 0.009 + vec2<f32>(-0.4 * t, 1.0));
        let n2 = gnoise2(q.xz * 0.023 + vec2<f32>(1.0, 0.3 * t));
        a.dust = band * dt * smoothstep(0.08, 0.5, 0.6 * n + 0.4 * n2);
    }
    // (blown clear by the burst, from the middle out)
    let gone = saturate((vm.t - VM_ERUPT) * 600.0 - r * 1.0) ;
    let clr = 1.0 - saturate(gone / 200.0);
    a.steam = a.steam * clr;
    a.dust = a.dust * clr;
    return a;
}
// How wide the fire sheet is, `a` seconds into the burst: well past the blast's 410 by 18.9, and never to the player's 1,000.
fn vm_fire_r(a: f32) -> f32 {
    return select(0.0, min(80.0 + 760.0 * (1.0 - exp(-a / 0.55)), 720.0), a > 0.0);
}
// Lumps: domes over a jittered lattice, as vc_dome.
fn vm_lump(p: vec3<f32>) -> f32 {
    let b = floor(p - 0.5);
    var hmax = 0.0;
    for (var c = 0u; c < 8u; c = c + 1u) {
        let o = vec3<f32>(f32(c & 1u), f32((c >> 1u) & 1u), f32(c >> 2u));
        let cell = b + o;
        let q = bitcast<vec3<u32>>(vec3<i32>(cell));
        let h = pcg(q.x ^ pcg(q.y ^ pcg(q.z + 0x77u)));
        let jit = vec3<f32>(f32(h & 1023u), f32((h >> 10u) & 1023u), f32((h >> 20u) & 1023u)) * (0.7 / 1023.0) + 0.15;
        let e = cell + jit - p;
        hmax = max(hmax, sqrt(saturate(1.0 - dot(e, e) * 1.7)));
    }
    return hmax;
}
// The fire: boiling up out of the holes and out over the land in a sheet far wider than it is tall; .rgb what it adds,
// .a what it leaves. Its heart white, then yellow and orange out to a torn red edge, the folds between its lumps hottest.
fn vm_fireball(o: vec3<f32>, rd: vec3<f32>, tend: f32, j: f32, a: f32) -> vec4<f32> {
    if (a <= 0.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    const FLAT = 0.56;
    let R = vm_fire_r(a);
    let burn = smoothstep(VM_GONE - 0.05, VM_FIREOUT - 0.05, vm.t);
    let ng = vm.ylo + 8.0;
    let oe = vec3<f32>(o.x, (o.y - ng) / FLAT, o.z);
    let de = vec3<f32>(rd.x, rd.y / FLAT, rd.z);
    let A = dot(de, de);
    let Bq = dot(oe, de);
    let Rb = R * 1.2;
    let disc = Bq * Bq - A * (dot(oe, oe) - Rb * Rb);
    if (disc <= 0.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let sq = sqrt(disc);
    let t0 = max((-Bq - sq) / A, 0.0);
    let t1 = min((-Bq + sq) / A, tend);
    if (t0 >= t1) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    const N = 30;
    let dt = (t1 - t0) / f32(N);
    var c = vec3<f32>(0.0);
    var tr = 1.0;
    var t = t0 + dt * j;
    // (the lumps ride out with it)
    let grow = 1.0 / (0.35 + 0.65 * R / 680.0);
    for (var i = 0; i < N; i = i + 1) {
        let q = o + rd * t;
        t = t + dt;
        let y = q.y - ng;
        if (y < -6.0) {
            continue;
        }
        let e = vec3<f32>(q.x, y / FLAT, q.z);
        let rho = length(e) / R;
        if (rho > 1.2) {
            continue;
        }
        let wq = q * grow + vec3<f32>(0.0, -a * 40.0, 0.0);
        let w = gnoise3(wq * 0.011);
        let l1 = vm_lump((wq + 60.0 * vec3<f32>(w - 0.5)) * (1.0 / 82.0));
        var l = 0.22 * (l1 - 0.55);
        if (abs(rho - 0.85) < 0.45) {
            let l2 = vm_lump((wq + vec3<f32>(9.0, 4.0, 1.0)) * (1.0 / 30.0));
            l = l + 0.1 * (l2 - 0.55);
        }
        // (from the white-out on it burns out from the inside, the blast coming up through it)
        let f = 1.0 - rho + l - 1.2 * burn * smoothstep(1.15, 0.6, rho + 0.35 * burn) - 1.3 * burn * (1.0 - l1);
        if (f <= 0.0) {
            continue;
        }
        let al = (1.0 - exp(-saturate(f * 7.0) * dt * 0.08)) * (1.0 - burn * burn);
        let crease = 1.0 - l1;
        let hot = saturate(f * 2.4) * (0.72 + 0.5 * crease) + 0.1 * smoothstep(0.5, 0.0, a);
        c = c + tr * al * vm_fire(hot * (1.0 - 0.75 * burn));
        tr = tr * (1.0 - al);
        if (tr < 0.02) {
            break;
        }
    }
    return vec4<f32>(c, tr);
}
// The steam and dust along the ray up to `tend`: .rgb what it adds, .a what it leaves.
fn vm_air(C: vec3<f32>, rd: vec3<f32>, tend: f32, j: f32, l: VcLight) -> vec4<f32> {
    if ((!vm.on && !vm.fire) || vm.t < VC_CRACK) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let o = -C;
    let time = vm.t;
    let fa = max(time - VM_ERUPT, 0.0);
    let fire = vm_fireball(o, rd, tend, j, fa);
    if (!vm.on || (fa > 0.3 && fire.a < 0.02)) {
        return fire;
    }
    let ytop = vm.yhi + 560.0;
    let rs = select(rd, rd + vec3<f32>(1.0e-5), abs(rd.x) < 1.0e-5 || abs(rd.z) < 1.0e-5);
    let inv = 1.0 / rs;
    let b = VM_HALF * 1.2;
    let lo = (vec3<f32>(-b, vm.ylo, -b) - o) * inv;
    let hi = (vec3<f32>(b, ytop, b) - o) * inv;
    let tn = min(lo, hi);
    let tf = max(lo, hi);
    let ta = max(max(tn.x, max(tn.y, tn.z)), 0.0);
    let tb = min(min(tf.x, min(tf.y, tf.z)), min(tend, 4000.0));
    if (ta >= tb) {
        return fire;
    }
    const N = 34;
    let dt = (tb - ta) / f32(N);
    var c = vec3<f32>(0.0);
    var tr = 1.0;
    var t = ta + dt * j;
    let dl = 0.14 + 0.86 * l.day;
    let sunk = l.sunc * l.sun_up;
    let ph = 0.8 + 0.5 * pow(saturate(dot(rd, l.L)), 4.0);
    for (var i = 0; i < N; i = i + 1) {
        let q = o + rd * t;
        t = t + dt;
        let a = vm_field(q, time);
        let e = a.steam + a.dust;
        if (e < 0.004) {
            continue;
        }
        // (worn away by noise that climbs and curls: dense in its middle, wisps at its edge)
        let fl = vec3<f32>(0.0, -time * 8.0, 0.0);
        let n1 = gnoise3(q * 0.02 + fl * 0.02);
        let n2 = gnoise3(q.zyx * 0.056 + fl * 0.056 + vec3<f32>(n1 * 1.4));
        var n = 0.62 * n1 + 0.38 * n2;
        if (e < 0.5) {
            n = n - 0.14 * (1.0 - gnoise3(q * 0.15 + fl * 0.15));
        }
        let ds = saturate(a.steam * 2.6 - (1.0 - n) * 1.25) * (1.0 - 0.5 * smoothstep(VM_HUSH, VM_HUSH + 0.8, time));
        let dd = saturate(a.dust * 2.4 - (1.0 - n) * 1.05);
        let den = ds + dd * 1.3;
        if (den < 0.003) {
            continue;
        }
        let al = 1.0 - exp(-(ds + 0.6 * dd * 1.3) * dt * 0.016);
        // ---- lit from above, shaded in its depth, greying as it climbs; the fire under it ----
        let shade = saturate(0.55 + 0.9 * (n - 0.52));
        let alb = mix(vec3<f32>(0.52, 0.43, 0.33), vec3<f32>(0.92, 0.91, 0.9), ds / max(den, 1.0e-3));
        var col = alb * (l.skyl * (0.62 + 0.3 * shade) * dl + sunk * 0.6 * shade * ph);
        let heat = vm_heat(length(q.xz));
        col = col * mix(1.0, 0.5, smoothstep(40.0, 420.0, a.up)) + vec3<f32>(1.1, 0.24, 0.035) * min(heat, 1.0) * exp(-max(a.up, 0.0) / 50.0) * exp(-a.crack / 20.0);
        c = c + tr * al * col;
        tr = tr * (1.0 - al);
        if (tr < 0.02) {
            break;
        }
    }
    // (over what is behind it: the fire)
    return vec4<f32>(c + fire.rgb * tr, tr * fire.a);
}

// [half stage]
// The join's look at the mount: its march starts from the half-size stage's depth (`half_extra`'s x, the nearest of the
// four half-size pixels round this one), so the land's hit is found in a few steps at full size. The depth the upsample
// weighs the cloud against is the mount's where the ray meets it.
fn vm_join_len(pos: vec2<f32>, len: f32, C: vec3<f32>, rd: vec3<f32>) -> f32 {
    vm_set(now());
    if (!vm.on && !vm.fly) {
        return len;
    }
    let hs = vec2<i32>(textureDimensions(half_extra));
    let h = vec2<i32>(floor(pos * 0.5 - 0.25));
    var near = 1.0e9;
    var rock = 0.0;
    var ids = vec4<f32>(0.0);
    for (var k = 0; k < 4; k = k + 1) {
        let q = clamp(h + vec2<i32>(k & 1, k >> 1u), vec2<i32>(0), hs - vec2<i32>(1));
        let e = textureLoad(half_extra, q, 0);
        near = min(near, e.x);
        rock = max(rock, e.z);
        ids[k] = e.w;
    }
    vm_rocky = rock > 0.0;
    if (!vm.on) {
        let top = max(ids.x, max(ids.y, max(ids.z, ids.w)));
        vm_none = top == 0.0;
        if (vm_none) {
            return len;
        }
        // (the half-size stage has said which: a pixel with none of them has to look at nothing, so `top` stands in)
        vm_only = vec4<u32>(select(ids, vec4<f32>(top), ids == vec4<f32>(0.0)));
    }
    vm_got = -1.0;
    if (near < min(len, 6.0e4) - 0.5) {
        var at = len;
        if (vm.on) {
            let t = vm_trace(-C, rd, max(near - 14.0, 0.0), len + 2.0, 1.2, true);
            if (t > 0.0) {
                vm_got = t;
                at = min(t, len);
            }
        }
        if (vm.fly) {
            vm_look(-C, rd, at + 1.5);
            if (vm_lpl.t > 0.0) {
                at = min(at, vm_lpl.t);
            } else if (vm_lsh.t > 0.0) {
                at = min(at, vm_lsh.t);
            }
        }
        return at;
    }
    return len;
}
// [end half stage]

// A plate that stays strikes: what it ploughed up, a line of billows along where it went in, climbing and rolling out, and
// rock flung out of them.
fn vl_burst(C: vec3<f32>, rd: vec3<f32>, tmax: f32, lb: u32, age: f32, l: VcLight, c: ptr<function, vec3<f32>>, tr: ptr<function, f32>, tm: ptr<function, f32>) {
    let f = vec3<f32>(vm_w(lb + 9u), vm_w(lb + 10u), vm_w(lb + 11u));
    let hl = vm_w(lb + 15u);
    let reach = 1.5 * hl + 150.0;
    let e0 = f + C;
    let tc = dot(e0, rd);
    if (dot(e0, e0) - tc * tc > reach * reach || tc + reach < 0.0) {
        return;
    }
    let d = vec3<f32>(vm_w(lb + 13u), 0.0, vm_w(lb + 14u));
    let a = vec3<f32>(-d.z, 0.0, d.x);
    let seed = f32(lb & 255u);
    let fade = 1.0 - smoothstep(2.5, 9.5, age);
    let dust = vec3<f32>(0.088, 0.072, 0.058) * (0.4 + 0.6 * l.day) * mix(vec3<f32>(1.0), l.sunc * 0.75, 0.3 * l.sun_up) * (1.0 - 0.72 * smoothstep(34.0, 46.0, vm.t));
    for (var k = 0u; k < 8u; k = k + 1u) {
        let h0 = hash21(vec2<f32>(f32(k), seed));
        let h1 = hash21(vec2<f32>(f32(k) + 0.5, seed + 3.0));
        let h2 = hash21(vec2<f32>(f32(k) + 0.3, seed + 7.0));
        let grow = 1.0 - exp(-age / (0.9 + 0.7 * h1));
        let side = (f32(k) / 3.5 - 1.0) * (0.55 * hl + 30.0 * grow);
        let P = f + a * side + d * ((h0 - 0.35) * 0.9 * hl * (0.3 + grow)) + vec3<f32>(0.0, (14.0 + 95.0 * h1 * h1) * grow, 0.0);
        let R = (0.26 * hl + 34.0 * h2) * (0.3 + 0.9 * grow) + 3.0 * age;
        let oe = (-C - P) * vec3<f32>(1.0, 1.15, 1.0);
        let de = rd * vec3<f32>(1.0, 1.15, 1.0);
        let A = dot(de, de);
        let B = dot(oe, de);
        let disc = B * B - A * (dot(oe, oe) - R * R);
        if (disc <= 0.0) {
            continue;
        }
        let sq = sqrt(disc);
        let t0 = max((-B - sq) / A, 0.0);
        let t1 = min((-B + sq) / A, tmax);
        if (t1 <= t0) {
            continue;
        }
        let q = rd * (t0 + 0.3 * (t1 - t0)) - C;
        let fq = 3.4 / R;
        let n = 0.55 * gnoise3(q * fq + vec3<f32>(f32(k), -age * 0.35, seed)) + 0.45 * gnoise3(q * fq * 3.1 + vec3<f32>(seed, -age * 0.6, f32(k)));
        let al = (1.0 - exp(-(t1 - t0) / R * 2.2)) * smoothstep(0.2, 0.78, (t1 - t0) / (2.0 * R) * sqrt(A) + 1.3 * (n - 0.5)) * fade;
        if (al < 0.004) {
            continue;
        }
        let up = saturate((q.y - P.y + R) / (1.6 * R));
        let sc = dust * (0.3 + 0.8 * up) * (0.75 + 0.5 * n) + vec3<f32>(0.1, 0.08, 0.065) * vm_firelit(q, vec3<f32>(0.0, -1.0, 0.0));
        vc_lay(c, tr, tm, al, sc, t0);
    }
    if (age < 5.0) {
        for (var k = 0u; k < 14u; k = k + 1u) {
            let h0 = hash21(vec2<f32>(f32(k) + 9.0, seed));
            let h1 = hash21(vec2<f32>(f32(k) + 9.5, seed + 3.0));
            let h2 = hash21(vec2<f32>(f32(k) + 9.3, seed + 7.0));
            let ang = 6.283 * h0;
            let v = (0.5 + h1) * vec3<f32>(55.0 * cos(ang) + 35.0 * d.x, 0.0, 55.0 * sin(ang) + 35.0 * d.z);
            let vy = 45.0 + 70.0 * h2;
            let P0 = f + a * ((h1 - 0.5) * 1.1 * hl);
            let s1 = age;
            let s0 = max(age - 0.03 - 0.05 * h1, 0.0);
            let y1 = vy * s1 - 17.0 * s1 * s1;
            if (y1 < -2.0) {
                continue;
            }
            let g = vm_seg(rd, P0 + v * s1 + vec3<f32>(0.0, y1, 0.0) + C, P0 + v * s0 + vec3<f32>(0.0, vy * s0 - 17.0 * s0 * s0, 0.0) + C);
            let w = max(1.6 + 2.2 * h0, g.z * vs.px * 1.3);
            let al = exp(-g.x / (w * w)) * min((1.6 + 2.2 * h0) / w, 1.0);
            if (al > 0.01 && g.z < tmax) {
                vc_lay(c, tr, tm, al, vec3<f32>(0.012, 0.011, 0.01), g.z);
            }
        }
    }
}
fn cross2(a: vec2<f32>, b: vec2<f32>) -> f32 {
    return a.x * b.y - a.y * b.x;
}
// ---- what the thrown leave in the air: dust trailing each piece, a burst of it where a big one comes down ----
// (half size) .rgb what it adds, .a what it leaves; `tm` how far off the nearest of it is.
fn vm_trails(C: vec3<f32>, rd: vec3<f32>, tmax: f32, l: VcLight, tm: ptr<function, f32>) -> vec4<f32> {
    var c = vec3<f32>(0.0);
    var tr = 1.0;
    if (!vm.fly || vm.t < VM_BRK + 0.1 || vm.t > VM_FLYEND + 11.0) {
        return vec4<f32>(c, tr);
    }
    let dl = 0.14 + 0.86 * l.day;
    let lit = l.skyl * 0.75 * dl + l.sunc * l.sun_up * 0.3;
    for (var i = 0u; i < VM_FLY; i = i + 1u) {
        let b = VM_PLATE + i * VM_PW;
        let fb = VM_FLT + i * 4u;
        let hit = vm_w(fb + 2u);
        let rad = vm_w(b + 6u);
        let lk = mod_data[VL_MAP + i];
        let lb = VL_BASE + (lk - 1u) * VL_W;
        if (rad < 66.0 || vm.t > hit + select(6.0, 11.0, lk != 0u)) {
            continue;
        }
        let trw = vm_w(b + 8u);
        // (from above first: its way is a line out from the vent)
        let vxz = vec2<f32>(vm_w(b + 9u), vm_w(b + 11u));
        let p0xz = vec2<f32>(vm_w(b), vm_w(b + 1u));
        let t3 = min(vm.t, hit);
        let cr0 = cross2(p0xz + vxz * (min(t3, VM_BRK) - trw + vm_eh(t3)) + C.xz, rd.xz);
        let t4 = max(t3 - 3.6, VM_BRK);
        let cr1 = cross2(p0xz + vxz * (VM_BRK - trw + vm_eh(t4)) + C.xz, rd.xz);
        let cl = (28.0 + select(1.5 * rad, 2.0 * rad + 260.0, lk != 0u)) * length(rd.xz) + 1.0;
        if ((cr0 > cl && cr1 > cl) || (cr0 < -cl && cr1 < -cl)) {
            continue;
        }
        let p0 = vec3<f32>(p0xz.x, vm_w(b + 2u) + vm_w(b + 3u) * vm.H, p0xz.y);
        let v = vec3<f32>(vxz.x, vm_w(b + 10u), vxz.y);
        let tau = vm_w(fb);
        let g = vm_w(fb + 1u);
        let te = min(vm.t, hit);
        var head = vm_flown(p0, v, trw, tau, g, te, vm_eh(te));
        if (lk != 0u) {
            head = head + vl_add(lb, vl_u(lb, te));
        }
        // ---- its trail, thin, hanging where it passed, thinning as it goes ----
        if (vm.t < hit + 4.0) {
            let t2 = max(te - 3.6, VM_BRK);
            var tail = vm_flown(p0, v, trw, tau, g, t2, vm_eh(t2));
            if (lk != 0u) {
                tail = tail + vl_add(lb, vl_u(lb, t2));
            }
            let g0 = vm_seg(rd, head + C, tail + C);
            let span = length(head - tail);
            let wm = 14.0 + 0.09 * rad + 0.2 * span;
            if (g0.x < wm * wm && g0.z > 4.0) {
                let t1 = mix(te, t2, 0.4);
                var mid = vm_flown(p0, v, trw, tau, g, t1, vm_eh(t1));
                if (lk != 0u) {
                    mid = mid + vl_add(lb, vl_u(lb, t1));
                }
                let g1 = vm_seg(rd, head + C, mid + C);
                let g2 = vm_seg(rd, mid + C, tail + C);
                let gb = select(vec4<f32>(g2, 0.4 + 0.6 * g2.y), vec4<f32>(g1, 0.4 * g1.y), g1.x < g2.x);
                let age = (te - t2) * gb.w + (vm.t - te);
                let w = 2.5 + 0.05 * rad + 1.7 * age;
                let wv = max(w, gb.z * vs.px * 1.4);
                let q = rd * gb.z - C;
                let n = gnoise3(q * 0.021 + vec3<f32>(0.0, f32(i), vm.t * 0.1));
                let al = 0.6 * exp(-gb.x / (wv * wv) * (1.4 - n)) * (w / wv) * smoothstep(1.0, 0.72, gb.w + 0.25 * (n - 0.5)) * (1.0 - smoothstep(0.0, 4.0, vm.t - te)) * smoothstep(0.1, 0.5, te - VM_BRK);
                if (al > 0.004 && gb.z < tmax + wv) {
                    let sc = vec3<f32>(0.06, 0.047, 0.038) * lit + vec3<f32>(0.1, 0.082, 0.07) * vm_firelit(q, vec3<f32>(0.0, -1.0, 0.0));
                    vc_lay(&c, &tr, tm, al, sc, gb.z);
                }
            }
        }
        // ---- it strikes: a low dome of dust, rolling out from under it and thinning ----
        let age = vm.t - hit + 0.3;
        if (age > 0.0) {
            if (lk != 0u) {
                vl_burst(C, rd, tmax, lb, age, l, &c, &tr, tm);
                continue;
            }
            let Rd = rad * (0.3 + 0.62 * (1.0 - exp(-age / 1.2)));
            let oe = (-C - head) * vec3<f32>(1.0, 1.7, 1.0);
            let de = rd * vec3<f32>(1.0, 1.7, 1.0);
            let A = dot(de, de);
            let B = dot(oe, de);
            let disc = B * B - A * (dot(oe, oe) - Rd * Rd);
            if (disc > 0.0) {
                let sq = sqrt(disc);
                let t0 = max((-B - sq) / A, 0.0);
                let t1 = min((-B + sq) / A, tmax);
                if (t1 > t0) {
                    let q = rd * (t0 + 0.3 * (t1 - t0)) - C;
                    let n = 0.6 * gnoise3(q * 0.026 + vec3<f32>(0.0, -age * 0.5, f32(i))) + 0.4 * gnoise3(q * 0.08 + vec3<f32>(f32(i), -age * 0.9, 0.0));
                    let al = (1.0 - exp(-(t1 - t0) / Rd * 1.7)) * smoothstep(0.3, 0.75, (t1 - t0) / (2.0 * Rd) * sqrt(A) + 1.4 * (n - 0.5)) * (1.0 - smoothstep(1.2, 5.5, age));
                    let up = saturate((q.y - head.y) / (0.6 * Rd));
                    let sc = vec3<f32>(0.3, 0.255, 0.205) * ((0.25 + 0.45 * up) * (0.4 + 0.6 * l.day) * mix(vec3<f32>(1.0), l.sunc * 0.75, 0.3 * l.sun_up) + vm_firelit(q, vec3<f32>(0.0, -1.0, 0.0)));
                    vc_lay(&c, &tr, tm, al, sc, t0);
                }
            }
        }
    }
    vm_wakes(C, rd, tmax, lit, &c, &tr, tm);
    return vec4<f32>(c, tr);
}

// ---- what is sharp over it all: the fountains, the boulders, the rock flung out, the white-out ----
// The lava bursting from cracks: arcs of bright drops off a white-hot jet, fired on and off for as long as it lasts.
fn vm_founts(C: vec3<f32>, rd: vec3<f32>, tmax: f32) -> vec4<f32> {
    var sum = vec4<f32>(0.0);
    if (vm.t < 10.0 || vm.t > VM_GONE + 0.2) {
        return sum;
    }
    for (var i = 0u; i < VM_FOUNTS; i = i + 1u) {
        let b = VM_FOUNT + i * 8u;
        let t0 = vm_w(b + 4u);
        if (t0 >= vm.t) {
            break;
        }
        let a = vm.t - t0;
        let dur = vm_w(b + 5u);
        let h = vm_w(b + 6u);
        let vy = sqrt(2.0 * VM_GF * h);
        let life = 2.0 * vy / VM_GF;
        if (a > dur + life) {
            continue;
        }
        let B = vec3<f32>(vm_w(b), vm_w(b + 2u) + vm_w(b + 3u) * vm.H, vm_w(b + 1u));
        let v = B + C;
        // (a sheet facing the eye, through its foot)
        let dist = length(v.xz);
        let n = v.xz / max(dist, 1.0);
        let den = dot(rd.xz, n);
        if (den < 0.02) {
            continue;
        }
        let tp = dist / den;
        if (tp > tmax + 6.0) {
            continue;
        }
        let P = rd * tp - v;
        let side = vec2<f32>(-n.y, n.x);
        let px = dot(P.xz, side);
        let py = P.y;
        if (abs(px) > 0.9 * h + 6.0 || py < -6.0 || py > h * 1.15) {
            continue;
        }
        let pw = tp * vs.px;
        let seed = u32(vm_w(b + 7u) * 100.0);
        // (the jet: from the crack, narrowing as it climbs, on while it fires)
        let on = smoothstep(0.0, 0.12, a) * (1.0 - smoothstep(dur - 0.3, dur, a));
        let top = h * (0.8 + 0.2 * sin(a * 2.6 + f32(seed))) * on;
        let hu = saturate(py / max(top, 1.0));
        let wj = max(1.2 + 0.022 * h * (1.0 - 0.6 * hu), pw * 0.6);
        let clot = gnoise2(vec2<f32>(px * 0.11 + f32(seed), py * 0.045 - vm.t * 2.4));
        let jet = exp(-px * px / (wj * wj)) * smoothstep(1.0, 0.55, hu) * step(-2.0, py) * on * smoothstep(0.34 + 0.3 * hu, 0.56 + 0.3 * hu, clot + 0.4 * (1.0 - hu));
        if (jet > 0.0) {
            let jc = mix(vec3<f32>(0.6, 0.07, 0.01), mix(vec3<f32>(1.5, 0.28, 0.03), vec3<f32>(2.0, 0.62, 0.06), smoothstep(0.4, 0.05, hu)), smoothstep(0.92, 0.5, hu));
            sum = sum + vec4<f32>(jc * jet, jet) * (1.0 - sum.a);
        }
        // (the drops, each thrown at its own moment on its own line, cooling as they go)
        for (var k = 0u; k < 26u; k = k + 1u) {
            let ta = dur * mh(k, seed, 0x771u);
            let s = a - ta;
            let lf = life * (0.55 + 0.45 * mh(k, seed, 0x772u));
            if (s <= 0.0 || s > lf) {
                continue;
            }
            let vk = vy * (0.5 + 0.5 * mh(k, seed, 0x773u));
            let vs_ = (mh(k, seed, 0x774u) - 0.5) * 0.5 * vy;
            let x = vs_ * s;
            let y = vk * s - 0.5 * VM_GF * s * s;
            // (a short streak along its way)
            let dt = 0.11;
            let ex = vs_ * dt;
            let ey = (vk - VM_GF * s) * dt;
            let qx = px - x;
            let qy = py - y;
            let u = saturate((qx * ex + qy * ey) / (ex * ex + ey * ey + 1.0e-4));
            let d = length(vec2<f32>(qx - ex * u, qy - ey * u));
            let w0 = 0.8 + 1.2 * mh(k, seed, 0x775u);
            let w = max(w0, pw * 0.7);
            if (d < 2.5 * w) {
                let cool = saturate(s / lf);
                let dr = exp(-d * d / (w * w)) * min(w0 / w * 1.5, 1.0);
                let dc = mix(mix(vec3<f32>(1.7, 0.4, 0.04), vec3<f32>(0.65, 0.08, 0.01), smoothstep(0.0, 0.6, cool)), vec3<f32>(0.05, 0.02, 0.015), smoothstep(0.55, 1.0, cool));
                sum = sum + vec4<f32>(dc * dr, dr) * (1.0 - sum.a);
            }
        }
    }
    return sum;
}
// The rock flung out with the plates: thousands of chunks, in shells flying out, from the eye's look only where a ray
// crosses a shell (so the count costs nothing). Each shell flies out as the fire throws it, then slows in the air, the
// outer ones' small rock soonest, and all of it falls together: rock thrown at one speed stays a shell, its middle
// dropping, and goes into the land from the bottom up.
const VM_CN: f32 = 60.0;           // cells across the shell's half
const VM_FLAT: f32 = 0.6;          // an ellipsoid, flattened: the sheet is wider than it is tall
// Shell k `a` seconds into the burst: .x how far out, .y how far its middle has dropped.
fn vm_shell(fk: f32, a: f32) -> vec2<f32> {
    let brk = VM_BRK - VM_ERUPT;
    let vk = 90.0 + 50.0 * fk;
    let f = min(a, brk);
    var o = vec2<f32>(300.0 + vk * f * (1.0 + 0.4 * f), 0.0);
    let s = a - brk;
    if (s > 0.0) {
        let tk = 2.2 - 0.14 * fk;
        o.x = o.x + vk * (1.0 + 0.8 * brk) * tk * (1.0 - exp(-s / tk));
        o.y = 88.0 * (s - 1.6 * (1.0 - exp(-s / 1.6)));
    }
    return o;
}
struct VmRock {
    on: bool,
    hs: u32,
    t: f32,         // how far along the ray it lies
    e: vec3<f32>,   // from the ray there to its middle
    size: f32,
    h: f32,         // 0 to 1: how big a one
}
// The rock in shell k by direction `dir` (up, a unit), a shell R out; `oe`, `rd` the ray, oe the eye in the shell's flattened
// space.
fn vm_rock(dir: vec3<f32>, R: f32, k: u32, a: f32, oe: vec3<f32>, rd: vec3<f32>) -> VmRock {
    var o: VmRock;
    let q = dir.xz / (abs(dir.x) + dir.y + abs(dir.z)) * VM_CN + VM_CN;
    let cell = floor(q);
    o.hs = pcg(u32(cell.x) + u32(cell.y) * 257u + k * 9973u);
    if (f32(o.hs & 0xffu) / 255.0 > 0.05 + 0.15 * smoothstep(0.15, 0.55, a)) {
        return o;
    }
    let cu = cell + vec2<f32>(0.2 + 0.6 * f32((o.hs >> 8u) & 0xffu) / 255.0, 0.2 + 0.6 * f32((o.hs >> 16u) & 0xffu) / 255.0);
    // (cells in direction: as big in blocks as the shell's radius makes them; its rock smaller than a cell, where it
    // is, so it is seen as itself from any side of the shell)
    let uv = cu / VM_CN - 1.0;
    let up = 1.0 - abs(uv.x) - abs(uv.y);
    if (up < 0.02) {
        return o;
    }
    let P = (normalize(vec3<f32>(uv.x, up, uv.y)) * R - oe) * vec3<f32>(1.0, VM_FLAT, 1.0);
    o.t = dot(P, rd);
    o.e = P - rd * o.t;
    o.h = f32(o.hs >> 24u) / 255.0;
    o.size = (1.0 + 9.0 * pow(o.h, 5.0)) * smoothstep(0.03, 0.2, a);
    o.on = true;
    return o;
}
// The dust off the bigger rocks (half size, in with the plates' trails): a thin dark line from each back along its way.
fn vm_wakes(C: vec3<f32>, rd: vec3<f32>, tmax: f32, lit: vec3<f32>, c: ptr<function, vec3<f32>>, tr: ptr<function, f32>, tm: ptr<function, f32>) {
    let a = vm.t - VM_ERUPT;
    if (a < 1.2 || vm.t > VM_CHUNKEND) {
        return;
    }
    const BACK = 0.55;   // seconds of its way behind it
    let de = vec3<f32>(rd.x, rd.y / VM_FLAT, rd.z);
    let A = dot(de, de);
    let fade = smoothstep(1.2, 1.7, a);
    for (var k = 1u; k < 9u; k = k + 2u) {
        let sh = vm_shell(f32(k), a);
        let sb = vm_shell(f32(k), a - BACK);
        let R = 0.5 * (sh.x + sb.x);
        let oe = vec3<f32>(-C.x, (-C.y - vm.ylo + 0.5 * (sh.y + sb.y)) / VM_FLAT, -C.z);
        let Bq = dot(oe, de);
        let disc = Bq * Bq - A * (dot(oe, oe) - R * R);
        if (disc <= 0.0) {
            continue;
        }
        let sq = sqrt(disc);
        for (var h = 0; h < 2; h = h + 1) {
            let tc = (-Bq + (f32(h) * 2.0 - 1.0) * sq) / A;
            if (tc <= 120.0 || tc >= tmax) {
                continue;
            }
            let dir = (oe + de * tc) / R;
            if (dir.y < 0.02) {
                continue;
            }
            let rk = vm_rock(dir, R, k, a, oe, rd);
            if (!rk.on || rk.h < 0.62) {
                continue;
            }
            // (the rock's own way, shell to shell)
            let P = rk.t * rd + rk.e;
            let hw = vec3<f32>(0.0, 0.5 * (sb.y - sh.y), 0.0);
            let rad = (sh.x - sb.x) * 0.5;
            let along = normalize((P + oe * vec3<f32>(1.0, VM_FLAT, 1.0)) / vec3<f32>(1.0, VM_FLAT, 1.0));
            let g = vm_seg(rd, P + along * rad * vec3<f32>(1.0, VM_FLAT, 1.0) - hw, P - along * rad * vec3<f32>(1.0, VM_FLAT, 1.0) + hw);
            let w = max(0.45 * rk.size, g.z * vs.px * 1.5);
            let al = 0.5 * exp(-g.x / (w * w)) * (0.45 * rk.size / w) * (1.0 - g.y * g.y) * fade;
            if (al > 0.01 && g.z < tmax) {
                vc_lay(c, tr, tm, al, vec3<f32>(0.05, 0.04, 0.033) * lit, g.z);
            }
        }
    }
}
// .rgb its colour, .a how much of the pixel it covers.
fn vm_chunks(C: vec3<f32>, rd: vec3<f32>, tmax: f32, cloud_t: f32, cloud_tr: f32, l: VcLight) -> vec4<f32> {
    let a = vm.t - VM_ERUPT;
    var best = select(tmax, min(tmax, cloud_t), cloud_tr < 0.03);
    var out = vec4<f32>(0.0);
    let de = vec3<f32>(rd.x, rd.y / VM_FLAT, rd.z);
    let A = dot(de, de);
    for (var k = 0u; k < 9u; k = k + 1u) {
        let sh = vm_shell(f32(k), a);
        let R = sh.x;
        let oe = vec3<f32>(-C.x, (-C.y - vm.ylo + sh.y) / VM_FLAT, -C.z);
        let Bq = dot(oe, de);
        let disc = Bq * Bq - A * (dot(oe, oe) - R * R);
        if (disc <= 0.0) {
            continue;
        }
        let sq = sqrt(disc);
        for (var h = 0; h < 2; h = h + 1) {
            let tc = (-Bq + (f32(h) * 2.0 - 1.0) * sq) / A;
            if (tc <= 40.0) {
                continue;
            }
            let dir = (oe + de * tc) / R;
            if (dir.y < 0.02) {
                continue;
            }
            let rk = vm_rock(dir, R, k, a, oe, rd);
            let t = rk.t;
            if (!rk.on || t <= 60.0 || t >= best) {
                continue;
            }
            let size = rk.size * min(t / 260.0, 1.0);
            let pw = t * vs.px;
            // (a broken rock, not a disc: straight sides, turned its own way, turning)
            let tu = normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)));
            let tv = cross(tu, rd);
            let d2 = vec2<f32>(dot(rk.e, tu), dot(rk.e, tv));
            let ang = f32(rk.hs & 0xfffu) * 0.0015 + a * (0.9 + 0.35 * f32((rk.hs >> 12u) & 7u));
            let ca = cos(ang);
            let sa = sin(ang);
            let e = vec2<f32>(ca * d2.x - sa * d2.y, sa * d2.x + ca * d2.y) * vec2<f32>(1.0, 0.75 + 0.6 * rk.h);
            let dlen = max(max(abs(e.x) * 1.3, abs(e.y) * 0.8), (abs(e.x) + abs(e.y)) * 0.86);
            if (dlen < size + pw) {
                let cover = saturate((size + 0.5 * pw - dlen) / pw) * smoothstep(60.0, 110.0, t);
                best = t;
                // (faceted: a face a side round a flat one, each turned its own way to the light and the fire)
                let fa = (floor((atan2(e.y, e.x) / TAU + 0.5) * 5.0 + f32(rk.hs & 7u)) + 0.5) * TAU / 5.0 - ang;
                let n = normalize(-rd + (tu * cos(fa) + tv * sin(fa)) * select(1.3, 0.3, dlen < 0.45 * size));
                let hot = exp(-a * 1.6) * saturate(-0.1 - e.y / size);
                let alb = vec3<f32>(0.05, 0.044, 0.039) * (0.65 + 0.9 * rk.h);
                let lit = (0.14 + 0.86 * l.day) * (0.16 + 0.3 * saturate(0.5 + 0.5 * n.y) + 1.1 * saturate(dot(n, l.L)) * l.sun_up);
                out = vec4<f32>(alb * lit + alb * vm_firelit(rd * t - C, n) + vm_ramp(0.6 * hot), cover * select(1.0, cloud_tr, t > cloud_t));
            }
        }
    }
    return out;
}
// For the half-size stage: 1 where a rock lies within a half-size pixel of this ray, so fs_join need only look there.
fn vm_chunk_near(C: vec3<f32>, rd: vec3<f32>, tmax: f32) -> f32 {
    let a = vm.t - VM_ERUPT;
    if (a <= 0.0 || vm.t > VM_CHUNKEND || !vm.fly) {
        return 0.0;
    }
    let de = vec3<f32>(rd.x, rd.y / VM_FLAT, rd.z);
    let A = dot(de, de);
    for (var k = 0u; k < 9u; k = k + 1u) {
        let sh = vm_shell(f32(k), a);
        let R = sh.x;
        let oe = vec3<f32>(-C.x, (-C.y - vm.ylo + sh.y) / VM_FLAT, -C.z);
        let Bq = dot(oe, de);
        let disc = Bq * Bq - A * (dot(oe, oe) - R * R);
        if (disc <= 0.0) {
            continue;
        }
        let sq = sqrt(disc);
        for (var h = 0; h < 2; h = h + 1) {
            let tc = (-Bq + (f32(h) * 2.0 - 1.0) * sq) / A;
            if (tc <= 40.0) {
                continue;
            }
            let dir = (oe + de * tc) / R;
            if (dir.y < 0.02) {
                continue;
            }
            let rk = vm_rock(dir, R, k, a, oe, rd);
            if (rk.on && rk.t < tmax && dot(rk.e, rk.e) < pow(1.1 * rk.size * min(rk.t / 260.0, 1.0) + 2.5 * rk.t * vs.px, 2.0)) {
                return 1.0;
            }
        }
    }
    return 0.0;
}
// Boulder b's line, r out (the land and the lift along it).
fn vm_rock_at(b: u32, r: f32, r0: f32, r1: f32) -> vec3<f32> {
    let u = 3.0 * saturate((r - r0) / (r1 - r0));
    let i0 = min(u32(u), 2u);
    let f = u - f32(i0);
    let s0 = vm_w(b + 8u + 2u * i0) + vm_w(b + 9u + 2u * i0) * vm.H;
    let s1 = vm_w(b + 10u + 2u * i0) + vm_w(b + 11u + 2u * i0) * vm.H;
    return vec3<f32>(vm_w(b) * r, mix(s0, s1, f), vm_w(b + 1u) * r);
}
// The ray from the eye (rd, a unit) against the segment a to b: .x the distance squared at their closest, .y how far along
// the segment, .z how far along the ray.
fn vm_seg(rd: vec3<f32>, a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    let u = b - a;
    let A = dot(u, u);
    let B = dot(u, rd);
    let D = dot(u, -a);
    let E = dot(rd, -a);
    let s = saturate((D - B * E) / max(A - B * B, 1.0e-3));
    let t = s * B - E;
    let e = rd * t - a - u * s;
    return vec3<f32>(dot(e, e), s, t);
}
// The boulders rolling down: lumps of rock, each dragging its dust down the slope, bounding as they go.
fn vm_rocks(C: vec3<f32>, rd: vec3<f32>, tmax: f32, l: VcLight, col: vec3<f32>) -> vec3<f32> {
    var c = col;
    var best = tmax;
    var dust = 0.0;
    for (var i = 0u; i < VM_BOULDS; i = i + 1u) {
        let b = VM_BOULD + i * VM_BW;
        let a = vm.t - vm_w(b + 4u);
        if (a <= 0.0) {
            continue;
        }
        let r0 = vm_w(b + 2u);
        let r1 = vm_w(b + 3u);
        let r = r0 + 0.5 * vm_w(b + 5u) * a * a;
        if (r > r1) {
            continue;
        }
        let size = vm_w(b + 6u);
        let hop = size * 0.9 * abs(sin(a * 1.7 + vm_w(b + 7u))) * smoothstep(0.0, 1.0, a);
        // (the dust it raises hangs on the slope behind it, spreading and thinning)
        let run = r - r0;
        let tl = min(run, 40.0 + 2.4 * sqrt(2.0 * vm_w(b + 5u) * run));
        let pa = vm_rock_at(b, r - tl, r0, r1) + vec3<f32>(0.0, size * 0.8, 0.0) + C;
        let pm = vm_rock_at(b, r - 0.5 * tl, r0, r1) + vec3<f32>(0.0, size * 0.7, 0.0) + C;
        let pb = vm_rock_at(b, r, r0, r1) + vec3<f32>(0.0, size * 0.6, 0.0) + C;
        for (var q = 0; q < 2; q = q + 1) {
            let a0 = select(pa, pm, q == 1);
            let a1 = select(pm, pb, q == 1);
            let g = vm_seg(rd, a0, a1);
            if (g.z > 0.0 && g.z < tmax + 20.0) {
                let v = (f32(q) + g.y) * 0.5;      // 0 its tail, 1 at the rock
                let wd = size * mix(2.2, 0.8, v) + 6.0 * (1.0 - v);
                let dn = exp(-g.x / (wd * wd)) * smoothstep(0.0, 0.3, v) * 0.6 * min(a * 1.2, 1.0);
                dust = dust + dn * (1.0 - dust);
            }
        }
        let P = vm_rock_at(b, r, r0, r1) + vec3<f32>(0.0, size + hop, 0.0) + C;
        let tc = dot(P, rd);
        let e = P - rd * tc;
        let d2 = dot(e, e);
        // (a lump, not a ball: turning as it goes)
        let sd = vec2<f32>(dot(e, normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)))), e.y);
        let ga = atan2(sd.y, sd.x) + a * 1.1 + vm_w(b + 7u);
        let rr = size * (1.0 + 0.13 * sin(ga * 2.0 + 0.7) + 0.08 * sin(ga * 3.0 + vm_w(b + 7u)));
        if (tc < 0.0 || tc > best || d2 > rr * rr) {
            continue;
        }
        let tq = tc - sqrt(rr * rr - d2);
        let q = (rd * tq - P) / rr;
        let n = normalize(q + 0.3 * vec3<f32>(sin(q.y * 3.0 + a * 1.4), sin(q.z * 4.0 + 1.0), sin(q.x * 3.0 + a * 1.1)));
        let dl = 0.14 + 0.86 * l.day;
        c = vec3<f32>(0.075, 0.066, 0.058) * dl * (0.45 + 1.3 * saturate(dot(n, l.L)));
        best = tc;
    }
    let dc = vec3<f32>(0.3, 0.255, 0.205) * (0.4 + 0.6 * l.day) * mix(vec3<f32>(1.0), l.sunc * 0.75, 0.3 * l.sun_up);
    return mix(c, dc, dust);
}
// `len` how far the picture's ray goes, the steam counted.
fn vm_over(col0: vec3<f32>, C: vec3<f32>, rd: vec3<f32>, len: f32, cloud_t: f32, cloud_tr: f32, l: VcLight) -> vec3<f32> {
    let time = now();
    if (time < VC_CRACK || time > VM_CHUNKEND || !(arrayLength(&mod_data) > VM_W2 + VM_COLS - 1u) || mod_data[VM_BASE] == 0u) {
        return col0;
    }
    var col = mix(col0, vm_plc, 0.72 * vm_plk);
    if (vm.on) {
        col = vm_rocks(C, rd, len, l, col);
        let fo = vm_founts(C, rd, len);
        col = col * (1.0 - fo.a) + fo.rgb;
    }
    if (time > VM_ERUPT && vm_rocky) {
        let ch = vm_chunks(C, rd, len, cloud_t, cloud_tr, l);
        col = mix(col, ch.rgb, ch.a);
    }
    // ---- the white-out, one flash: from where the mount was out over the picture, at its height by VM_GONE, gone by a
    // quarter of a second after it (nothing longer: photosensitivity) ----
    if (time > VM_ERUPT + 0.5 && time < VM_GONE + 0.3) {
        let u = smoothstep(VM_ERUPT + 0.6, VM_GONE - 0.03, time);
        let down = 1.0 - smoothstep(VM_GONE + 0.05, VM_GONE + 0.24, time);
        let P = C + vec3<f32>(0.0, 170.0, 0.0);
        let cs = dot(normalize(P), rd);
        // (it blooms out from the burst, soft, no edge to it: the look away from it goes last)
        let ang = sqrt(max(2.0 * (1.0 - cs), 0.0));
        let glow = exp(-ang / (0.05 + 1.5 * u * u)) * smoothstep(0.0, 0.5, u);
        col = col + mix(vec3<f32>(2.6, 1.5, 0.6), vec3<f32>(2.6, 2.3, 1.9), u) * glow * 1.6 * down;
        let w = u * u * u * u;
        col = mix(col, vec3<f32>(1.7), saturate(w) * down);
    }
    return col;
}
