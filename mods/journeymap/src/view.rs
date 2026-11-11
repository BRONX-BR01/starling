//! Map geometry and the scene as plain shapes (the glue turns them into `ui::Draw`).
use crate::grid::{N, Run};

/// GUI pixels per map cell, and half the map's side.
pub const CELL: f32 = 3.0;
pub const HALF: f32 = N as f32 * CELL / 2.0;
const MID: f32 = (N / 2) as f32;

#[derive(Debug, Clone, PartialEq)]
pub enum Shape {
    Fill { x: f32, y: f32, w: f32, h: f32, argb: u32 },
    Quad { pts: [(f32, f32); 4], argb: u32 },
    Text { text: String, x: f32, y: f32, rgb: u32, center: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    ZoomIn,
    ZoomOut,
    /// One step on each axis (east/south positive).
    Pan(i32, i32),
    Center,
    Mode,
}

const BUTTONS: [(Control, &str); 8] = [
    (Control::ZoomIn, "+"),
    (Control::ZoomOut, "-"),
    (Control::Pan(0, -1), "^"),
    (Control::Pan(0, 1), "v"),
    (Control::Pan(-1, 0), "<"),
    (Control::Pan(1, 0), ">"),
    (Control::Center, "C"),
    (Control::Mode, "T"),
];

/// (control, label, x, y, w, h) of each button, in a column right of the map.
pub fn buttons() -> Vec<(Control, &'static str, f32, f32, f32, f32)> {
    BUTTONS
        .iter()
        .enumerate()
        .map(|(i, &(c, l))| (c, l, HALF + 8.0, -HALF + i as f32 * 18.0, 22.0, 15.0))
        .collect()
}

pub fn button_at(sx: f32, sy: f32) -> Option<Control> {
    buttons()
        .into_iter()
        .find(|&(_, _, x, y, w, h)| sx >= x && sx <= x + w && sy >= y && sy <= y + h)
        .map(|b| b.0)
}

pub struct Marker<'a> {
    pub x: i32,
    pub z: i32,
    pub name: &'a str,
    pub rgb: u32,
}

/// Cell (i, j) samples block (cx + (i - N/2) * step, cz + (j - N/2) * step);
/// north (-z) is up, east (+x) is right.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Projection {
    pub cx: i32,
    pub cz: i32,
    pub step: i32,
}

impl Projection {
    pub fn sample_columns(self) -> Vec<(i32, i32)> {
        let half = (N / 2) as i32;
        (0..N as i32)
            .flat_map(|j| (0..N as i32).map(move |i| (i, j)))
            .map(|(i, j)| (self.cx + (i - half) * self.step, self.cz + (j - half) * self.step))
            .collect()
    }

    pub fn to_screen(self, x: f64, z: f64) -> (f32, f32) {
        let f = |w: f64, c: i32| -HALF + ((w - f64::from(c)) as f32 / self.step as f32 + MID + 0.5) * CELL;
        (f(x, self.cx), f(z, self.cz))
    }

    pub fn to_world(self, sx: f32, sy: f32) -> (i32, i32) {
        let f = |s: f32, c: i32| c + (((s + HALF) / CELL - MID - 0.5) * self.step as f32).round() as i32;
        (f(sx, self.cx), f(sy, self.cz))
    }

    /// Index (row-major) of the cell under a screen point.
    pub fn cell_at(self, sx: f32, sy: f32) -> Option<usize> {
        let (i, j) = (((sx + HALF) / CELL).floor(), ((sy + HALF) / CELL).floor());
        let ok = |v: f32| (0.0..N as f32).contains(&v);
        (ok(i) && ok(j)).then(|| j as usize * N + i as usize)
    }
}

pub fn inside(sx: f32, sy: f32) -> bool {
    sx.abs() <= HALF && sy.abs() <= HALF
}

pub fn scene(
    runs: &[Run],
    proj: Projection,
    player: Option<(f64, f64, f32)>,
    markers: &[Marker<'_>],
    title: &str,
    hint: &str,
) -> Vec<Shape> {
    let fill = |x, y, w, h, argb| Shape::Fill { x, y, w, h, argb };
    let mut out = vec![
        fill(-HALF - 2.0, -HALF - 2.0, 2.0 * HALF + 4.0, 2.0 * HALF + 4.0, 0xFFAA_AAAA),
        fill(-HALF, -HALF, 2.0 * HALF, 2.0 * HALF, 0xFF10_1010),
    ];
    out.extend(runs.iter().map(|r| {
        fill(-HALF + r.col as f32 * CELL, -HALF + r.row as f32 * CELL, r.len as f32 * CELL, CELL, r.argb)
    }));
    for m in markers.iter().take(64) {
        let (sx, sy) = proj.to_screen(f64::from(m.x), f64::from(m.z));
        if !inside(sx, sy) {
            continue;
        }
        out.push(fill(sx - 3.5, sy - 3.5, 7.0, 7.0, 0xFF00_0000));
        out.push(fill(sx - 2.5, sy - 2.5, 5.0, 5.0, 0xFF00_0000 | m.rgb));
        out.push(Shape::Text { text: m.name.to_owned(), x: sx, y: sy - 13.0, rgb: 0xFFFFFF, center: true });
    }
    for (_, label, x, y, w, h) in buttons() {
        out.push(fill(x - 1.0, y - 1.0, w + 2.0, h + 2.0, 0xFF00_0000));
        out.push(fill(x, y, w, h, 0xFF6B_6B6B));
        out.push(Shape::Text { text: label.to_owned(), x: x + w / 2.0, y: y + 3.5, rgb: 0xFFFFFF, center: true });
    }
    if let Some((px, pz, yaw)) = player.filter(|&(px, pz, _)| {
        let (sx, sy) = proj.to_screen(px, pz);
        inside(sx, sy)
    }) {
        let (sx, sy) = proj.to_screen(px, pz);
        let r = yaw.to_radians();
        let d = (-r.sin(), r.cos()); // yaw 0 faces south (+z)
        let p = (-d.1, d.0);
        let at = |a: f32, b: f32| (sx + d.0 * a + p.0 * b, sy + d.1 * a + p.1 * b);
        out.push(Shape::Quad { pts: [at(6.0, 0.0), at(-3.0, 3.5), at(-1.0, 0.0), at(-3.0, -3.5)], argb: 0xFFFF_FFFF });
    }
    out.push(Shape::Text { text: title.to_owned(), x: 0.0, y: -HALF - 14.0, rgb: 0xFFFFFF, center: true });
    out.push(Shape::Text { text: hint.to_owned(), x: 0.0, y: HALF + 5.0, rgb: 0xAAAAAA, center: true });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn world_screen_roundtrip() {
        let p = Projection { cx: 100, cz: -40, step: 4 };
        for (x, z) in [(100, -40), (60, -80), (170, 20)] {
            let (sx, sy) = p.to_screen(f64::from(x), f64::from(z));
            assert_eq!(p.to_world(sx, sy), (x, z));
        }
    }

    #[test]
    fn cells_and_columns_agree() {
        let p = Projection { cx: 0, cz: 0, step: 2 };
        let cols = p.sample_columns();
        assert_eq!(cols.len(), N * N);
        let (sx, sy) = p.to_screen(f64::from(cols[5 * N + 7].0), f64::from(cols[5 * N + 7].1));
        assert_eq!(p.cell_at(sx, sy), Some(5 * N + 7));
        assert_eq!(p.cell_at(HALF + 1.0, 0.0), None);
    }

    #[test]
    fn north_is_up_and_scene_is_small() {
        let p = Projection { cx: 0, cz: 0, step: 1 };
        assert!(p.to_screen(0.0, -10.0).1 < p.to_screen(0.0, 0.0).1);
        let s = scene(&[], p, Some((0.0, 0.0, 90.0)), &[Marker { x: 5, z: 5, name: "a", rgb: 1 }], "t", "h");
        assert!(s.len() < 60);
    }

    #[test]
    fn buttons_are_hit_and_do_not_overlap_the_map() {
        for (c, _, x, y, w, h) in buttons() {
            assert_eq!(button_at(x + w / 2.0, y + h / 2.0), Some(c));
            assert!(x > HALF);
        }
        assert_eq!(button_at(0.0, 0.0), None);
    }
}
