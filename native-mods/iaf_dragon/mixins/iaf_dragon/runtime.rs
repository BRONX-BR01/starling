// Fire dragons for Horizon and Starling, from Ice and Fire's own model.
//
// A native mod (client and server halves in one bundle). The dragon is an ordinary ghast the server half
// spawns with a name (`/firedragon`): it flies, hunts and shoots as a ghast does, and the client half draws
// it with Ice and Fire's Tabula model (104 boxes, `model.rs`) instead of the ghast's, posed from the mod's
// own poses (the wing-beat frames, the walk frames) the way the original animates it.
//
// This file has no dependencies and no game types: it is both the mod's Cargo library (its tests) and the
// module the bundle adds to the game as `game::official_iaf_dragon`. The helpers next to it do the talking
// to the game.
//
// The maths: a part sits at its rotation point inside its parent, turns by Rz * Ry * Rx (degrees) and holds a
// box; the model's y points down and its front is -z, so a point (x, y, z) in pixels goes to
// ((x), (FLOOR - y), (-z)) / 16 blocks in the frame the game gives a mob's model (feet at the origin, +z the
// way it faces, +x its left, +y up).

use super::official_iaf_dragon_model as model;
use model::{PARTS, Pose};

pub const ID: &str = "iaf_dragon";
pub const NAME: &str = "Ice and Fire dragons";
pub const VERSION: &str = "0.1.0";
pub const DESCRIPTION: &str = "Fire dragons with Ice and Fire's own model and wing beats. /firedragon [red|green|bronze|gray] summons one.";

/// A dragon's custom name: the client half knows its ghasts by it.
pub const DRAGON_NAME: &str = "Fire Dragon";
pub const COLORS: [&str; 4] = ["red", "green", "bronze", "gray"];
/// How big the model is drawn, in blocks per model block (the adult is about 9 blocks long).
pub const SIZE: f32 = 1.5;

/// Whether a mob with this custom name is one of the mod's dragons.
pub fn is_dragon(name: Option<&str>) -> bool {
    name.is_some_and(|n| n.starts_with(DRAGON_NAME))
}

/// The colour a dragon is drawn in: a name's own ("Fire Dragon green"), else by the mob's id.
pub fn color_of(name: &str, id: u32) -> &'static str {
    let wanted = name.trim_start_matches(DRAGON_NAME).trim();
    COLORS
        .iter()
        .copied()
        .find(|c| *c == wanted)
        .unwrap_or(COLORS[id as usize % COLORS.len()])
}

/// The sprite a dragon of `color` is textured with: its adult texture, in the content mod's item folder
/// (the item atlas packs it as `iceandfire:item/dragon/red_5`).
pub fn sprite(color: &str) -> String {
    format!("iceandfire:item/dragon/{color}_5")
}

/// The command that summons a dragon at the player: `/firedragon`, `/firedragon green`.
pub fn summon_line(color: &str) -> String {
    format!(
        "summon minecraft:ghast ~ ~3 ~ {{CustomName:\"{DRAGON_NAME} {color}\",Health:200.0f,\
         attributes:[{{id:\"minecraft:max_health\",base:200.0d}}],PersistenceRequired:1b}}"
    )
}

/// The color named in a command's arguments, if it is one.
pub fn parse_color(args: &str) -> Option<&'static str> {
    COLORS.iter().copied().find(|c| *c == args.trim())
}

// ---------------------------------------------------------------- poses

type Mat3 = [[f32; 3]; 3];

fn mul3(a: &Mat3, b: &Mat3) -> Mat3 {
    let mut out = [[0.0; 3]; 3];
    for (i, row) in out.iter_mut().enumerate() {
        for (j, cell) in row.iter_mut().enumerate() {
            *cell = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
        }
    }
    out
}

fn apply3(m: &Mat3, v: [f32; 3]) -> [f32; 3] {
    [
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    ]
}

/// `Rz * Ry * Rx` for angles in degrees about x, y and z (vanilla's `rotationZYX`).
pub fn rot_zyx(degrees: [f32; 3]) -> Mat3 {
    let [x, y, z] = degrees.map(f32::to_radians);
    let (sx, cx, sy, cy, sz, cz) = (x.sin(), x.cos(), y.sin(), y.cos(), z.sin(), z.cos());
    let rx = [[1.0, 0.0, 0.0], [0.0, cx, -sx], [0.0, sx, cx]];
    let ry = [[cy, 0.0, sy], [0.0, 1.0, 0.0], [-sy, 0.0, cy]];
    let rz = [[cz, -sz, 0.0], [sz, cz, 0.0], [0.0, 0.0, 1.0]];
    mul3(&rz, &mul3(&ry, &rx))
}

/// A part's place in the model: where its rotation point is and how it is turned (model pixels).
#[derive(Clone, Copy)]
struct Place {
    r: Mat3,
    t: [f32; 3],
}

fn places(pose: &Pose) -> [Place; PARTS.len()] {
    let identity = Place { r: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], t: [0.0; 3] };
    let mut out = [identity; PARTS.len()];
    for (i, part) in PARTS.iter().enumerate() {
        let (position, rotation) = pose[i];
        let turn = rot_zyx(rotation);
        out[i] = if part.parent < 0 {
            Place { r: turn, t: position }
        } else {
            let parent = out[part.parent as usize];
            let at = apply3(&parent.r, position);
            Place {
                r: mul3(&parent.r, &turn),
                t: [parent.t[0] + at[0], parent.t[1] + at[1], parent.t[2] + at[2]],
            }
        };
    }
    out
}

/// Every position and angle `t` of the way from `a` to `b`.
pub fn blend(a: &Pose, b: &Pose, t: f32) -> Pose {
    let mut out = *a;
    for i in 0..PARTS.len() {
        for k in 0..3 {
            out[i].0[k] = a[i].0[k] + (b[i].0[k] - a[i].0[k]) * t;
            out[i].1[k] = a[i].1[k] + (b[i].1[k] - a[i].1[k]) * t;
        }
    }
    out
}

/// Frame `phase` of a looping list of poses, blended with the next (and the first after the last).
fn cycle(frames: &[&Pose], phase: f32) -> Pose {
    let n = frames.len() as f32;
    let p = phase.rem_euclid(n);
    let i = (p.floor() as usize).min(frames.len() - 1);
    blend(frames[i], frames[(i + 1) % frames.len()], p - p.floor())
}

/// What a frame of a dragon shows of the game's mob state.
#[derive(Clone, Copy, Debug, Default)]
pub struct Anim {
    /// `ageInTicks`.
    pub age: f32,
    pub walk_position: f32,
    pub walk_speed: f32,
    pub on_ground: bool,
    /// Ticks since death, 0 while alive.
    pub death_time: i32,
}

/// The pose a dragon is in and how far it floats above its feet, in blocks (before `SIZE`).
pub fn pose_of(a: &Anim) -> (Pose, f32) {
    if a.death_time > 0 {
        let t = (a.death_time as f32 / 12.0).min(1.0);
        return (blend(&model::HOVERING, &model::DEAD, t), 0.0);
    }
    if a.on_ground {
        // The walk is four frames; the legs and arms swing with the distance walked.
        let frames = [&model::WALK1, &model::WALK2, &model::WALK3, &model::WALK4];
        let walking = cycle(&frames, a.walk_position * 0.5);
        let rest = blend(&model::GROUND, &walking, a.walk_speed.clamp(0.0, 1.0));
        return (rest, 0.0);
    }
    // In the air: the six wing-beat frames, one beat every 22 ticks, over a slow bob.
    let frames = [
        &model::FLIGHT1,
        &model::FLIGHT2,
        &model::FLIGHT3,
        &model::FLIGHT4,
        &model::FLIGHT5,
        &model::FLIGHT6,
    ];
    let beating = cycle(&frames, a.age * (6.0 / 22.0));
    let bob = 0.25 * (a.age * 0.12).sin();
    (beating, 0.9 + bob)
}

// ---------------------------------------------------------------- geometry

/// One face of the model in the mob's frame, as `native_draw_quad` takes it: four corners (top left, bottom
/// left, bottom right, top right as seen from outside) and the uv rectangle (u0, v0, u1, v1) in texels of
/// 16 per side of the whole texture.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quad {
    pub corners: [[f32; 3]; 4],
    pub uv: [f32; 4],
}

/// Corner indices of each face of a box, as vanilla's `ModelPart.Cube` lists them: down, up, west, north,
/// east, south, over the eight corners [V0..V7] of the box (see `box_corners`).
const FACES: [[usize; 4]; 6] = [
    [4, 3, 7, 0],
    [1, 2, 6, 5],
    [7, 3, 6, 2],
    [0, 7, 2, 1],
    [4, 0, 1, 5],
    [3, 4, 5, 6],
];

/// `V0..V7` of a box from (x, y, z) to (x2, y2, z2): vanilla's `vertex` = V0, `vertex1` = V1, ..., and
/// `vertex7` (the box's own corner) = V7.
fn box_corners(x: f32, y: f32, z: f32, x2: f32, y2: f32, z2: f32) -> [[f32; 3]; 8] {
    [
        [x2, y, z],
        [x2, y2, z],
        [x, y2, z],
        [x, y, z2],
        [x2, y, z2],
        [x2, y2, z2],
        [x, y2, z2],
        [x, y, z],
    ]
}

/// Appends every face of the model in `pose`, `size` blocks per model block, floating `lift` blocks above
/// the feet. Faces with no area (the wing membranes' edges) are left out.
pub fn quads(pose: &Pose, size: f32, lift: f32, out: &mut Vec<Quad>) {
    let placed = places(pose);
    let k = size / 16.0;
    let local = |p: &Place, v: [f32; 3]| -> [f32; 3] {
        let m = apply3(&p.r, v);
        let (x, y, z) = (m[0] + p.t[0], m[1] + p.t[1], m[2] + p.t[2]);
        [x * k, (model::FLOOR - y) * k + lift * size, -z * k]
    };
    for (part, place) in PARTS.iter().zip(&placed) {
        let [w, h, d] = part.size;
        let [ox, oy, oz] = part.offset;
        let [u, v] = part.texture;
        let (mut x, mut x2) = (ox, ox + w);
        if part.mirror {
            std::mem::swap(&mut x, &mut x2);
        }
        let corners = box_corners(x, oy, oz, x2, oy + h, oz + d);
        let (u1, u2, u3) = (u + d, u + d + w, u + d + w + w);
        let (u4, u5) = (u + d + w + d, u + d + w + d + w);
        let (v1, v2) = (v + d, v + d + h);
        // Each face's uv (minU, minV, maxU, maxV) as vanilla gives its polygon.
        let rects = [
            (u1, v, u2, v1),
            (u2, v1, u3, v),
            (u, v1, u1, v2),
            (u1, v1, u2, v2),
            (u2, v1, u4, v2),
            (u4, v1, u5, v2),
        ];
        for (face, rect) in FACES.iter().zip(rects) {
            let (min_u, min_v, max_u, max_v) = rect;
            // Vanilla's polygon: vertex 0 takes (maxU, minV), 1 (minU, minV), 2 (minU, maxV), 3
            // (maxU, maxV); a mirrored box lists them the other way round.
            let uvs = [(max_u, min_v), (min_u, min_v), (min_u, max_v), (max_u, max_v)];
            let mut verts: [([f32; 3], (f32, f32)); 4] =
                std::array::from_fn(|i| (local(place, corners[face[i]]), uvs[i]));
            if part.mirror {
                verts.reverse();
            }
            // The engine wants top left, bottom left, bottom right, top right: vertices 1, 2, 3, 0
            // (a mirrored box's list is reversed, which starts it at 3, 0, 1, 2 of the original).
            let order = if part.mirror { [3, 0, 1, 2] } else { [1, 2, 3, 0] };
            let c: [[f32; 3]; 4] = std::array::from_fn(|i| verts[order[i]].0);
            let uv0 = verts[order[0]].1;
            let uv2 = verts[order[2]].1;
            let (e1, e2) = (sub(c[1], c[0]), sub(c[2], c[1]));
            let n = cross(e1, e2);
            if n[0] * n[0] + n[1] * n[1] + n[2] * n[2] < 1.0e-12 {
                continue;
            }
            out.push(Quad {
                corners: c,
                uv: [
                    uv0.0 / model::TEXTURE_WIDTH * 16.0,
                    uv0.1 / model::TEXTURE_HEIGHT * 16.0,
                    uv2.0 / model::TEXTURE_WIDTH * 16.0,
                    uv2.1 / model::TEXTURE_HEIGHT * 16.0,
                ],
            });
        }
    }
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

#[cfg(test)]
mod tests {
    use super::*;

    include!("../../tests-crate/golden.rs");

    fn near(a: f32, b: f32) -> bool {
        (a - b).abs() < 2.0e-3
    }

    #[test]
    fn model_matches_the_reference_maths() {
        // The numbers come from the Python reference (gen_model.py) the previews were checked with.
        let mut all = Vec::new();
        quads(&model::FLIGHT3, 1.5, 0.5, &mut all);
        assert_eq!(all.len(), 576);
        for (index, corners, uv) in GOLDEN {
            let q = all[*index];
            for c in 0..4 {
                for k in 0..3 {
                    assert!(near(q.corners[c][k], corners[c][k]), "quad {index} corner {c}: {:?} vs {:?}", q.corners[c], corners[c]);
                }
            }
            for k in 0..4 {
                assert!(near(q.uv[k], uv[k]), "quad {index} uv: {:?} vs {:?}", q.uv, uv);
            }
        }
    }

    #[test]
    fn every_pose_keeps_its_feet_near_the_floor_and_is_finite() {
        for pose in [&model::GROUND, &model::WALK1, &model::HOVERING, &model::FLIGHT1, &model::FLIGHT4, &model::DEAD] {
            let mut all = Vec::new();
            quads(pose, 1.0, 0.0, &mut all);
            assert!(all.iter().all(|q| q.corners.iter().all(|c| c.iter().all(|v| v.is_finite()))));
            let low = all.iter().flat_map(|q| q.corners).map(|c| c[1]).fold(f32::MAX, f32::min);
            let high = all.iter().flat_map(|q| q.corners).map(|c| c[1]).fold(f32::MIN, f32::max);
            assert!(low > -3.0 && high < 6.0, "{low} {high}");
        }
        // The ground pose stands on the floor.
        let mut all = Vec::new();
        quads(&model::GROUND, 1.0, 0.0, &mut all);
        let low = all.iter().flat_map(|q| q.corners).map(|c| c[1]).fold(f32::MAX, f32::min);
        assert!(low.abs() < 0.2, "ground pose floats at {low}");
    }

    #[test]
    fn every_solid_face_points_outward() {
        let mut inward = 0;
        for pose in [&model::GROUND, &model::FLIGHT3, &model::WALK2] {
            let placed = places(pose);
            let mut all = Vec::new();
            quads(pose, 1.0, 0.0, &mut all);
            // Rebuild the per-part quad ranges: parts have 6 faces less the empty ones.
            let mut next = 0;
            for (part, place) in PARTS.iter().zip(&placed) {
                let [w, h, d] = part.size;
                if w == 0.0 || h == 0.0 || d == 0.0 {
                    // a membrane: skip its faces by counting them below
                }
                let centre_model = [part.offset[0] + w / 2.0, part.offset[1] + h / 2.0, part.offset[2] + d / 2.0];
                let m = apply3(&place.r, centre_model);
                let centre = [
                    (m[0] + place.t[0]) / 16.0,
                    (model::FLOOR - (m[1] + place.t[1])) / 16.0,
                    -(m[2] + place.t[2]) / 16.0,
                ];
                let faces = if w == 0.0 || h == 0.0 || d == 0.0 {
                    // A flat part: its two big faces (empty ones are not listed).
                    2
                } else {
                    6
                };
                for q in &all[next..next + faces] {
                    if w != 0.0 && h != 0.0 && d != 0.0 {
                        let n = cross(sub(q.corners[1], q.corners[0]), sub(q.corners[2], q.corners[1]));
                        let mid = [
                            (q.corners[0][0] + q.corners[2][0]) / 2.0,
                            (q.corners[0][1] + q.corners[2][1]) / 2.0,
                            (q.corners[0][2] + q.corners[2][2]) / 2.0,
                        ];
                        let out = sub(mid, centre);
                        if n[0] * out[0] + n[1] * out[1] + n[2] * out[2] <= 0.0 {
                            inward += 1;
                        }
                    }
                }
                next += faces;
            }
            assert_eq!(next, all.len());
        }
        assert_eq!(inward, 0);
    }

    #[test]
    fn wing_beat_loops_and_blends_between_frames() {
        let a = Anim { age: 0.0, ..Anim::default() };
        let (first, _) = pose_of(&a);
        for i in 0..PARTS.len() {
            for k in 0..3 {
                assert!(near(first[i].0[k], model::FLIGHT1[i].0[k]) && near(first[i].1[k], model::FLIGHT1[i].1[k]));
            }
        }
        // One beat later it is back at the first frame.
        let b = Anim { age: 22.0, ..Anim::default() };
        let (again, _) = pose_of(&b);
        for i in 0..PARTS.len() {
            for k in 0..3 {
                assert!(near(again[i].0[k], first[i].0[k]) && near(again[i].1[k], first[i].1[k]));
            }
        }
        // Half a frame in is half way between the first and the second.
        let c = Anim { age: 0.5 * 22.0 / 6.0, ..Anim::default() };
        let (mid, _) = pose_of(&c);
        let expected = blend(&model::FLIGHT1, &model::FLIGHT2, 0.5);
        for i in 0..PARTS.len() {
            for k in 0..3 {
                assert!(near(mid[i].1[k], expected[i].1[k]));
            }
        }
    }

    #[test]
    fn names_colours_and_commands() {
        assert!(is_dragon(Some("Fire Dragon green")));
        assert!(!is_dragon(Some("Steve")) && !is_dragon(None));
        assert_eq!(color_of("Fire Dragon green", 7), "green");
        assert_eq!(color_of("Fire Dragon", 6), COLORS[2]);
        assert_eq!(parse_color(" bronze "), Some("bronze"));
        assert_eq!(parse_color("blue"), None);
        assert_eq!(sprite("red"), "iceandfire:item/dragon/red_5");
        assert!(summon_line("gray").contains("CustomName:\"Fire Dragon gray\""));
    }

    #[test]
    fn dead_and_walking_poses() {
        let same = |a: &Pose, b: &Pose| {
            (0..PARTS.len()).all(|i| (0..3).all(|k| near(a[i].0[k], b[i].0[k]) && near(a[i].1[k], b[i].1[k])))
        };
        let dead = Anim { death_time: 30, ..Anim::default() };
        assert!(same(&pose_of(&dead).0, &model::DEAD));
        let still = Anim { on_ground: true, ..Anim::default() };
        assert!(same(&pose_of(&still).0, &model::GROUND));
    }
}
