// Spatial GUI for Horizon and Starling: inventory, container and other screens drawn as a plane
// (flat or curved) floating in front of the camera instead of flat over the window.
//
// A port to Rust of the Fabric mod "Spatial GUI" by tastytrash (MIT). This file is both the mod's
// Cargo library (its tests) and the module the bundle adds to the game as `game::official_spatial_gui`.
// It has no dependencies: the helpers next to it do the talking to the game.
//
// How it works: Horizon draws every screen into one batch of 2D vertices (GUI pixels). After a screen
// has drawn itself, the `screen_render_post` helper hands the screen's vertices to `project_triangles`,
// which places each of them on the plane in view space and projects it back to the window with a
// pinhole camera of the game's own field of view. The mouse goes the other way (`Mapping::unproject`):
// the pointer's place in the window becomes the place on the plane, and the game's cursor is set to it.

use std::cell::RefCell;
use std::time::Instant;

/// The mod's id (its settings folder), name and version.
pub const ID: &str = "spatial_gui";
pub const NAME: &str = "Spatial GUI";
pub const VERSION: &str = "0.1.0";
pub const DESCRIPTION: &str =
    "Inventories and containers as a plane floating in the 3D view. Port of tastytrash's Spatial GUI. /spatialgui turns it on or off.";

/// Nearest distance in front of the camera a point may have to be drawn.
const NEAR: f64 = 0.05;
/// How far the plane swings with the pointer when Parallax is on, in degrees at the window's edge.
const PARALLAX_YAW_DEG: f64 = 6.0;
const PARALLAX_PITCH_DEG: f64 = 4.0;
/// A triangle with an edge longer than this (GUI pixels) is cut in four, up to `MAX_DEPTH` times, so the
/// affine texturing of the HUD pass stays close to a perspective one.
const MAX_EDGE: f64 = 24.0;
const MAX_DEPTH: u32 = 4;

pub fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

// ---------------------------------------------------------------- easing

/// The open animation's curves: the original's `EasingType`, each an "ease out" from 0 to 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Easing {
    Cubic,
    Elastic,
    Bounce,
    Back,
    Exponential,
    Quadratic,
    Quartic,
}

impl Easing {
    pub const ALL: [Easing; 7] = [
        Easing::Cubic,
        Easing::Elastic,
        Easing::Bounce,
        Easing::Back,
        Easing::Exponential,
        Easing::Quadratic,
        Easing::Quartic,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Easing::Cubic => "Cubic",
            Easing::Elastic => "Elastic",
            Easing::Bounce => "Bounce",
            Easing::Back => "Back",
            Easing::Exponential => "Exponential",
            Easing::Quadratic => "Quadratic",
            Easing::Quartic => "Quartic",
        }
    }

    pub fn parse(text: &str) -> Option<Easing> {
        Easing::ALL
            .into_iter()
            .find(|e| e.name().eq_ignore_ascii_case(text.trim()))
    }

    pub fn next(self) -> Easing {
        let at = Easing::ALL.iter().position(|e| *e == self).unwrap_or(0);
        Easing::ALL[(at + 1) % Easing::ALL.len()]
    }

    /// `t` in 0..=1.
    pub fn apply(self, t: f32) -> f32 {
        let t = t as f64;
        let v = match self {
            Easing::Cubic => {
                let u = t - 1.0;
                u * u * u + 1.0
            }
            Easing::Elastic => {
                let c4 = 2.0943952_f64; // 2 pi / 3
                if t <= 0.0 {
                    0.0
                } else if t >= 1.0 {
                    1.0
                } else {
                    2f64.powf(-10.0 * t) * ((t * 10.0 - 0.75) * c4).sin() + 1.0
                }
            }
            Easing::Bounce => {
                let (n1, d1) = (7.5625, 2.75);
                if t < 1.0 / d1 {
                    n1 * t * t
                } else if t < 2.0 / d1 {
                    let t = t - 1.5 / d1;
                    n1 * t * t + 0.75
                } else if t < 2.5 / d1 {
                    let t = t - 2.25 / d1;
                    n1 * t * t + 0.9375
                } else {
                    let t = t - 2.625 / d1;
                    n1 * t * t + 0.984375
                }
            }
            Easing::Back => {
                let c1 = 1.70158;
                let c3 = c1 + 1.0;
                let u = t - 1.0;
                1.0 + c3 * u * u * u + c1 * u * u
            }
            Easing::Exponential => {
                if t >= 1.0 {
                    1.0
                } else {
                    1.0 - 2f64.powf(-10.0 * t)
                }
            }
            Easing::Quadratic => 1.0 - (1.0 - t) * (1.0 - t),
            Easing::Quartic => 1.0 - (1.0 - t).powi(4),
        };
        v as f32
    }
}

// -------------------------------------------------------------- settings

/// Everything the player can change. Defaults are the original's first-person ones.
#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub enabled: bool,
    /// The survival and creative inventories and every container.
    pub inventory: bool,
    /// The pause menu.
    pub pause: bool,
    /// Every other screen in a world (experimental, as in the original).
    pub all_screens: bool,
    /// Blocks in front of the camera, side and height offsets in blocks.
    pub distance: f32,
    pub side: f32,
    pub height: f32,
    /// Blocks wide.
    pub scale: f32,
    /// Degrees, on top of facing the camera.
    pub yaw: f32,
    pub pitch: f32,
    pub curved: bool,
    /// Arc length of the curved screen in degrees (-180..=180; negative bulges away).
    pub arc: f32,
    /// 0..=255.
    pub opacity: u8,
    pub parallax: bool,
    pub scale_anim: bool,
    pub fade_anim: bool,
    pub anim_ms: u32,
    pub fade_ms: u32,
    /// The scale the open animation starts from (0.75 = 75%).
    pub start_scale: f32,
    pub easing: Easing,
    pub auto_fov: bool,
    pub baseline_fov: f32,
    pub fov_power: f32,
    pub fov_side_mult: f32,
    pub fov_distance_mult: f32,
    pub shadow: bool,
    /// 0..=255.
    pub shadow_alpha: u8,
    pub shadow_dx: f32,
    pub shadow_dy: f32,
    pub shadow_dz: f32,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            enabled: true,
            inventory: true,
            pause: false,
            all_screens: false,
            distance: 1.5,
            side: 0.0,
            height: 0.0,
            scale: 1.8,
            yaw: 0.0,
            pitch: 0.0,
            curved: false,
            arc: 30.0,
            opacity: 255,
            parallax: true,
            scale_anim: true,
            fade_anim: true,
            anim_ms: 300,
            fade_ms: 150,
            start_scale: 0.75,
            easing: Easing::Back,
            auto_fov: true,
            baseline_fov: 70.0,
            fov_power: 1.2,
            fov_side_mult: -0.3,
            fov_distance_mult: 0.8,
            shadow: true,
            shadow_alpha: 120,
            shadow_dx: 0.008,
            shadow_dy: -0.012,
            shadow_dz: 0.002,
        }
    }
}

/// The settings page's buttons, in order: each is a key of a setting.
pub const CONTROLS: [&str; 19] = [
    "enabled",
    "inventory",
    "pause",
    "all_screens",
    "distance",
    "scale",
    "side",
    "height",
    "yaw",
    "pitch",
    "curved",
    "arc",
    "opacity",
    "parallax",
    "open_animation",
    "easing",
    "auto_fov",
    "shadow",
    "reset",
];

/// The screens of the title, which this mod never touches.
const TITLE_SCREENS: [&str; 25] = [
    "title",
    "world_select",
    "world_create",
    "world_create_flat",
    "world_create_buffet",
    "world_edit",
    "world_backup",
    "world_backup_confirm",
    "world_optimize_confirm",
    "world_optimize",
    "low_disk_space",
    "world_delete",
    "world_recover",
    "world_recovered",
    "error",
    "multiplayer",
    "add_server",
    "edit_server",
    "direct_connect",
    "server_delete",
    "friends_join",
    "disconnected",
    "multiplayer_warning",
    "onboarding",
    "ban_notice",
];

fn yes(on: bool) -> &'static str {
    if on { "ON" } else { "OFF" }
}

fn number(v: f32) -> String {
    let text = format!("{v:.2}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    if text == "-0" || text.is_empty() {
        "0".into()
    } else {
        text.into()
    }
}

/// The next value in `min..=max` by `step`, wrapping to `min` past `max`.
fn next_in(v: f32, min: f32, max: f32, step: f32) -> f32 {
    let next = ((v + step) / step).round() * step;
    if next > max + step * 0.01 { min } else { next }
}

impl Settings {
    /// Whether the screen `id` (`NativeScreenView::id`) is drawn as a plane.
    pub fn applies(&self, id: &str) -> bool {
        if !self.enabled {
            return false;
        }
        match id {
            "inventory" | "creative" => self.inventory,
            "paused" => self.pause,
            id if TITLE_SCREENS.contains(&id) => false,
            _ => self.all_screens,
        }
    }

    /// A setting as it is stored, one file per key.
    pub fn value(&self, key: &str) -> String {
        match key {
            "enabled" => self.enabled.to_string(),
            "inventory" => self.inventory.to_string(),
            "pause" => self.pause.to_string(),
            "all_screens" => self.all_screens.to_string(),
            "distance" => number(self.distance),
            "scale" => number(self.scale),
            "side" => number(self.side),
            "height" => number(self.height),
            "yaw" => number(self.yaw),
            "pitch" => number(self.pitch),
            "curved" => self.curved.to_string(),
            "arc" => number(self.arc),
            "opacity" => self.opacity.to_string(),
            "parallax" => self.parallax.to_string(),
            "open_animation" => (self.scale_anim && self.fade_anim).to_string(),
            "easing" => self.easing.name().into(),
            "auto_fov" => self.auto_fov.to_string(),
            "shadow" => self.shadow.to_string(),
            _ => String::new(),
        }
    }

    /// Reads a stored value; false when the key or the value is not understood (nothing changes).
    pub fn apply(&mut self, key: &str, text: &str) -> bool {
        let text = text.trim();
        let flag = || match text {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        };
        let num = || text.parse::<f32>().ok().filter(|v| v.is_finite());
        match key {
            "enabled" => flag().map(|v| self.enabled = v).is_some(),
            "inventory" => flag().map(|v| self.inventory = v).is_some(),
            "pause" => flag().map(|v| self.pause = v).is_some(),
            "all_screens" => flag().map(|v| self.all_screens = v).is_some(),
            "distance" => num().map(|v| self.distance = v.clamp(0.3, 4.0)).is_some(),
            "scale" => num().map(|v| self.scale = v.clamp(0.2, 6.0)).is_some(),
            "side" => num().map(|v| self.side = v.clamp(-4.0, 4.0)).is_some(),
            "height" => num().map(|v| self.height = v.clamp(-4.0, 4.0)).is_some(),
            "yaw" => num().map(|v| self.yaw = v.clamp(-90.0, 90.0)).is_some(),
            "pitch" => num().map(|v| self.pitch = v.clamp(-90.0, 90.0)).is_some(),
            "curved" => flag().map(|v| self.curved = v).is_some(),
            "arc" => num().map(|v| self.arc = v.clamp(-180.0, 180.0)).is_some(),
            "opacity" => text
                .parse::<u8>()
                .ok()
                .map(|v| self.opacity = v.max(10))
                .is_some(),
            "parallax" => flag().map(|v| self.parallax = v).is_some(),
            "open_animation" => flag()
                .map(|v| {
                    self.scale_anim = v;
                    self.fade_anim = v;
                })
                .is_some(),
            "easing" => Easing::parse(text).map(|v| self.easing = v).is_some(),
            "auto_fov" => flag().map(|v| self.auto_fov = v).is_some(),
            "shadow" => flag().map(|v| self.shadow = v).is_some(),
            _ => false,
        }
    }

    /// Settings from a store that answers a key with its text, as `native_setting` does.
    pub fn load(get: impl Fn(&str) -> Option<String>) -> Settings {
        let mut s = Settings::default();
        for key in CONTROLS {
            if let Some(text) = get(key) {
                s.apply(key, &text);
            }
        }
        s
    }

    /// A button's text on the settings page.
    pub fn label(&self, index: usize) -> String {
        let Some(&key) = CONTROLS.get(index) else {
            return String::new();
        };
        match key {
            "enabled" => format!("Spatial GUI: {}", yes(self.enabled)),
            "inventory" => format!("Inventory and containers: {}", yes(self.inventory)),
            "pause" => format!("Pause menu: {}", yes(self.pause)),
            "all_screens" => format!("All other screens (experimental): {}", yes(self.all_screens)),
            "distance" => format!("Distance: {} blocks", number(self.distance)),
            "scale" => format!("Width: {} blocks", number(self.scale)),
            "side" => format!("Horizontal offset: {}", number(self.side)),
            "height" => format!("Vertical offset: {}", number(self.height)),
            "yaw" => format!("Yaw: {} deg", number(self.yaw)),
            "pitch" => format!("Pitch: {} deg", number(self.pitch)),
            "curved" => format!("Curved screen: {}", yes(self.curved)),
            "arc" => format!("Curved arc: {} deg", number(self.arc)),
            "opacity" => format!("Opacity: {}", self.opacity),
            "parallax" => format!("Parallax: {}", yes(self.parallax)),
            "open_animation" => format!("Open animation: {}", yes(self.scale_anim && self.fade_anim)),
            "easing" => format!("Animation easing: {}", self.easing.name()),
            "auto_fov" => format!("Auto scale by FOV: {}", yes(self.auto_fov)),
            "shadow" => format!("Drop shadow: {}", yes(self.shadow)),
            _ => "Reset to defaults".into(),
        }
    }

    /// A click on button `index`: the settings change and every key that changed comes back with its
    /// new stored value, for the game to keep.
    pub fn cycle(&mut self, index: usize) -> Vec<(&'static str, String)> {
        let Some(&key) = CONTROLS.get(index) else {
            return Vec::new();
        };
        let before = self.clone();
        match key {
            "enabled" => self.enabled = !self.enabled,
            "inventory" => self.inventory = !self.inventory,
            "pause" => self.pause = !self.pause,
            "all_screens" => self.all_screens = !self.all_screens,
            "distance" => self.distance = next_in(self.distance, 0.75, 3.0, 0.25),
            "scale" => self.scale = next_in(self.scale, 1.0, 3.0, 0.2),
            "side" => self.side = next_in(self.side, -1.0, 1.0, 0.1),
            "height" => self.height = next_in(self.height, -1.0, 1.0, 0.1),
            "yaw" => self.yaw = next_in(self.yaw, -30.0, 30.0, 5.0),
            "pitch" => self.pitch = next_in(self.pitch, -30.0, 30.0, 5.0),
            "curved" => self.curved = !self.curved,
            "arc" => self.arc = next_in(self.arc, 30.0, 120.0, 30.0),
            "opacity" => {
                let next = next_in(self.opacity as f32, 50.0, 255.0, 25.0);
                self.opacity = next.round().clamp(10.0, 255.0) as u8;
                if self.opacity > 250 {
                    self.opacity = 255;
                }
            }
            "parallax" => self.parallax = !self.parallax,
            "open_animation" => {
                let on = !(self.scale_anim && self.fade_anim);
                self.scale_anim = on;
                self.fade_anim = on;
            }
            "easing" => self.easing = self.easing.next(),
            "auto_fov" => self.auto_fov = !self.auto_fov,
            "shadow" => self.shadow = !self.shadow,
            _ => *self = Settings::default(),
        }
        CONTROLS
            .iter()
            .filter(|k| before.value(k) != self.value(k))
            .map(|k| (*k, self.value(k)))
            .collect()
    }
}

// ------------------------------------------------------------- geometry

/// Opening animation: the scale factor and the opacity (0..=1) `elapsed_ms` after the screen opened.
pub fn animation(s: &Settings, elapsed_ms: u32) -> (f32, f32) {
    let scale = if s.scale_anim && s.anim_ms > 0 {
        let t = (elapsed_ms as f32 / s.anim_ms as f32).min(1.0);
        lerp(s.start_scale, 1.0, s.easing.apply(t))
    } else {
        1.0
    };
    let fade = if s.fade_anim && s.fade_ms > 0 {
        (elapsed_ms as f32 / s.fade_ms as f32).min(1.0)
    } else {
        1.0
    };
    (scale, fade * (s.opacity as f32 / 255.0))
}

/// `(scale multiplier, distance, side offset)` after Auto Scale by FOV (the original's
/// `calculateFovScaleMultiplier`, `calculateAutoFovDistance` and `calculateAutoFovSideOffset`).
pub fn fov_adjusted(s: &Settings, fov_degrees: f32) -> (f32, f32, f32) {
    if !s.auto_fov || fov_degrees <= 0.0 || s.baseline_fov <= 0.0 {
        return (1.0, s.distance, s.side);
    }
    let mult = fov_degrees / s.baseline_fov;
    let inverse = 1.0 / mult - 1.0;
    (
        mult.powf(s.fov_power),
        (s.distance * (1.0 + inverse * s.fov_distance_mult)).clamp(-4.0, 4.0),
        (s.side * (1.0 + inverse * s.fov_side_mult)).clamp(-4.0, 4.0),
    )
}

type V3 = [f64; 3];

fn rotate_y(p: V3, a: f64) -> V3 {
    let (s, c) = a.sin_cos();
    [p[0] * c + p[2] * s, p[1], -p[0] * s + p[2] * c]
}

fn rotate_x(p: V3, a: f64) -> V3 {
    let (s, c) = a.sin_cos();
    [p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c]
}

/// Where the screen is in front of the camera and how it is seen. The camera looks down -z, x is right,
/// y is up; the plane is `width` blocks wide centred at `(side, height, -distance)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Mapping {
    /// The window in GUI pixels (the screen's own layout size).
    gui: [f64; 2],
    tan_half_fov: f64,
    distance: f64,
    side: f64,
    height: f64,
    width: f64,
    yaw: f64,
    pitch: f64,
    /// Arc length in radians; 0 is flat.
    arc: f64,
    parallax_yaw: f64,
    parallax_pitch: f64,
}

impl Mapping {
    /// `scale_factor` is the open animation's; `pointer` (window GUI pixels) swings the plane when
    /// Parallax is on.
    pub fn new(
        s: &Settings,
        fov_degrees: f32,
        gui: [f32; 2],
        scale_factor: f32,
        pointer: Option<[f32; 2]>,
    ) -> Mapping {
        let (fov_scale, distance, side) = fov_adjusted(s, fov_degrees);
        let gui = [gui[0].max(1.0) as f64, gui[1].max(1.0) as f64];
        let (parallax_yaw, parallax_pitch) = match pointer {
            Some(p) if s.parallax => (
                (p[0] as f64 / gui[0] * 2.0 - 1.0).clamp(-1.0, 1.0) * PARALLAX_YAW_DEG.to_radians(),
                (p[1] as f64 / gui[1] * 2.0 - 1.0).clamp(-1.0, 1.0) * PARALLAX_PITCH_DEG.to_radians(),
            ),
            _ => (0.0, 0.0),
        };
        let fov = if fov_degrees > 1.0 && fov_degrees < 170.0 { fov_degrees } else { 70.0 };
        let arc = if s.curved && s.arc.abs() >= 1.0 {
            (s.arc as f64).to_radians()
        } else {
            0.0
        };
        Mapping {
            gui,
            tan_half_fov: (fov as f64 / 2.0).to_radians().tan(),
            distance: distance as f64,
            side: side as f64,
            height: s.height as f64,
            width: (s.scale * fov_scale * scale_factor).max(0.01) as f64,
            yaw: (s.yaw as f64).to_radians(),
            pitch: (s.pitch as f64).to_radians(),
            arc,
            parallax_yaw,
            parallax_pitch,
        }
    }

    /// A point of the plane (`u`, `v` from -0.5 to 0.5, v up) plus a local offset, in view space.
    fn world(&self, u: f64, v: f64, offset: V3) -> V3 {
        let height = self.width * self.gui[1] / self.gui[0];
        let local = if self.arc != 0.0 {
            // A cylinder whose arc is `width` long, bulging toward the viewer when `arc` is positive.
            let radius = self.width / self.arc;
            let theta = u * self.arc;
            [radius * theta.sin(), v * height, radius * (1.0 - theta.cos())]
        } else {
            [u * self.width, v * height, 0.0]
        };
        let local = [local[0] + offset[0], local[1] + offset[1], local[2] + offset[2]];
        let p = rotate_x(rotate_y(local, self.yaw), self.pitch);
        let p = [p[0] + self.side, p[1] + self.height, p[2] - self.distance];
        rotate_x(rotate_y(p, self.parallax_yaw), self.parallax_pitch)
    }

    /// A view space point's place in the window, GUI pixels; None behind the camera.
    fn project(&self, p: V3) -> Option<[f64; 2]> {
        let depth = -p[2];
        if depth < NEAR {
            return None;
        }
        let aspect = self.gui[0] / self.gui[1];
        let ndc_x = p[0] / depth / (self.tan_half_fov * aspect);
        let ndc_y = p[1] / depth / self.tan_half_fov;
        Some([(ndc_x * 0.5 + 0.5) * self.gui[0], (0.5 - ndc_y * 0.5) * self.gui[1]])
    }

    /// Where a point of the screen's own layout (GUI pixels) is in the window.
    pub fn forward(&self, at: [f32; 2]) -> Option<[f32; 2]> {
        self.forward64([at[0] as f64, at[1] as f64])
            .map(|p| [p[0] as f32, p[1] as f32])
    }

    fn forward64(&self, at: [f64; 2]) -> Option<[f64; 2]> {
        let u = at[0] / self.gui[0] - 0.5;
        let v = 0.5 - at[1] / self.gui[1];
        self.project(self.world(u, v, [0.0; 3]))
    }

    /// The point of the screen's layout drawn at window point `target`: where a click lands. Newton's
    /// method on `forward`; None when the pointer cannot be put on the screen (the plane is edge on or
    /// behind the camera). The answer may lie outside the layout when the pointer is off the plane.
    pub fn unproject(&self, target: [f32; 2]) -> Option<[f32; 2]> {
        let t = [target[0] as f64, target[1] as f64];
        let mut g = t;
        for _ in 0..32 {
            let f = self.forward64(g)?;
            let e = [f[0] - t[0], f[1] - t[1]];
            if e[0].abs() < 0.01 && e[1].abs() < 0.01 {
                return Some([g[0] as f32, g[1] as f32]);
            }
            let h = 0.5;
            let fx = self.forward64([g[0] + h, g[1]])?;
            let fy = self.forward64([g[0], g[1] + h])?;
            let (a, b) = ((fx[0] - f[0]) / h, (fy[0] - f[0]) / h);
            let (c, d) = ((fx[1] - f[1]) / h, (fy[1] - f[1]) / h);
            let det = a * d - b * c;
            if det.abs() < 1e-12 {
                return None;
            }
            let step = [(d * e[0] - b * e[1]) / det, (-c * e[0] + a * e[1]) / det];
            g = [
                g[0] - step[0].clamp(-self.gui[0], self.gui[0]),
                g[1] - step[1].clamp(-self.gui[1], self.gui[1]),
            ];
        }
        None
    }

    /// Whether window point `target` is over the screen.
    pub fn over(&self, target: [f32; 2]) -> bool {
        self.unproject(target).is_some_and(|g| {
            g[0] >= 0.0 && g[1] >= 0.0 && g[0] <= self.gui[0] as f32 && g[1] <= self.gui[1] as f32
        })
    }

    /// The pointer's place on the screen for the game's cursor, kept inside the layout.
    pub fn cursor(&self, target: [f32; 2]) -> Option<[f32; 2]> {
        self.unproject(target).map(|g| {
            [
                g[0].clamp(0.0, (self.gui[0] - 1.0) as f32),
                g[1].clamp(0.0, (self.gui[1] - 1.0) as f32),
            ]
        })
    }

    /// The window's bounding box `[x, y, w, h]` of a rectangle of the layout, for scissors.
    pub fn project_rect(&self, rect: [f32; 4]) -> Option<[f32; 4]> {
        let [x, y, w, h] = rect;
        let corners = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
        let mut min = [f32::INFINITY; 2];
        let mut max = [f32::NEG_INFINITY; 2];
        for c in corners {
            let p = self.forward(c)?;
            for i in 0..2 {
                min[i] = min[i].min(p[i]);
                max[i] = max[i].max(p[i]);
            }
        }
        Some([min[0], min[1], max[0] - min[0], max[1] - min[1]])
    }

    /// The drop shadow: the flat plane's four corners moved by `(dx, dy, dz)` blocks (dz behind),
    /// top left first and round. None for a curved screen.
    pub fn shadow_quad(&self, dx: f32, dy: f32, dz: f32) -> Option<[[f32; 2]; 4]> {
        if self.arc != 0.0 {
            return None;
        }
        let offset = [dx as f64, dy as f64, -(dz as f64)];
        let mut out = [[0.0; 2]; 4];
        for (i, (u, v)) in [(-0.5, 0.5), (0.5, 0.5), (0.5, -0.5), (-0.5, -0.5)]
            .into_iter()
            .enumerate()
        {
            let p = self.project(self.world(u, v, offset))?;
            out[i] = [p[0] as f32, p[1] as f32];
        }
        Some(out)
    }
}

// ------------------------------------------------------------- vertices

/// `0xAABBGGBB`-style colours as Horizon packs them: `a << 24 | b << 16 | g << 8 | r`.
pub fn scale_alpha(color: u32, factor: f32) -> u32 {
    let a = ((color >> 24) as f32 * factor.clamp(0.0, 1.0)).round() as u32;
    (a.min(255) << 24) | (color & 0x00FF_FFFF)
}

/// A colour between two, channel by channel.
pub fn mix_color(a: u32, b: u32, t: f32) -> u32 {
    let mut out = 0;
    for shift in [0, 8, 16, 24] {
        let x = ((a >> shift) & 0xFF) as f32;
        let y = ((b >> shift) & 0xFF) as f32;
        out |= ((lerp(x, y, t).round() as u32).min(255)) << shift;
    }
    out
}

/// What `project_triangles` made: the new vertices and, for each input triangle, where its first output
/// vertex is (one more entry than triangles, the last the total).
#[derive(Clone, Debug)]
pub struct Projected<V> {
    pub vertices: Vec<V>,
    pub starts: Vec<u32>,
}

impl<V> Projected<V> {
    /// Where input vertex index `i` (counted from the first projected vertex) lands, as the start of a
    /// range, `shift` further on.
    pub fn start(&self, i: u32, shift: u32) -> u32 {
        shift + self.starts[((i / 3) as usize).min(self.starts.len() - 1)]
    }
}

/// Where a vertex range of the batch (`first` = the screen's first vertex, `shift` = vertices put in
/// front of it, as the shadow) ends up. A range's start and end map differently at `first`: a start
/// there moves past what was put in front, an end there stays.
pub fn remap_range<V>(
    range: std::ops::Range<u32>,
    first: u32,
    shift: u32,
    projected: &Projected<V>,
) -> std::ops::Range<u32> {
    let start = if range.start < first {
        range.start
    } else {
        first + projected.start(range.start - first, shift)
    };
    let end = if range.end <= first {
        range.end
    } else {
        first + projected.start(range.end - first, shift)
    };
    start..end
}

/// Places a screen's triangles (three vertices each) on the plane. `pos` and `set_pos` read and write a
/// vertex's position in GUI pixels, `mix` makes the vertex between two (position, uv, colour, depth...),
/// `fade` multiplies its opacity. A triangle that covers the whole window (the dim behind a screen)
/// or has a corner behind the camera is left out. Vertices past the last whole triangle are dropped.
pub fn project_triangles<V: Copy>(
    mapping: &Mapping,
    input: &[V],
    pos: impl Fn(&V) -> [f32; 2],
    set_pos: impl Fn(&mut V, [f32; 2]),
    mix: impl Fn(&V, &V, f32) -> V,
    fade: impl Fn(&mut V, f32),
    opacity: f32,
) -> Projected<V> {
    let mut out = Vec::with_capacity(input.len() + input.len() / 2);
    let mut starts = Vec::with_capacity(input.len() / 3 + 1);
    for tri in input.chunks_exact(3) {
        starts.push(out.len() as u32);
        let p = [pos(&tri[0]), pos(&tri[1]), pos(&tri[2])];
        let (mut lo, mut hi) = ([f32::INFINITY; 2], [f32::NEG_INFINITY; 2]);
        for q in p {
            for i in 0..2 {
                lo[i] = lo[i].min(q[i]);
                hi[i] = hi[i].max(q[i]);
            }
        }
        if (hi[0] - lo[0]) as f64 >= mapping.gui[0] * 0.98
            && (hi[1] - lo[1]) as f64 >= mapping.gui[1] * 0.98
        {
            continue;
        }
        let mut pieces = Vec::new();
        split(&[tri[0], tri[1], tri[2]], &pos, &mix, MAX_DEPTH, &mut pieces);
        'piece: for mut piece in pieces {
            for v in piece.iter_mut() {
                let Some(q) = mapping.forward(pos(v)) else {
                    continue 'piece;
                };
                set_pos(v, q);
                fade(v, opacity);
            }
            out.extend_from_slice(&piece);
        }
    }
    starts.push(out.len() as u32);
    Projected { vertices: out, starts }
}

fn split<V: Copy>(
    t: &[V; 3],
    pos: &impl Fn(&V) -> [f32; 2],
    mix: &impl Fn(&V, &V, f32) -> V,
    depth: u32,
    out: &mut Vec<[V; 3]>,
) {
    let p = [pos(&t[0]), pos(&t[1]), pos(&t[2])];
    let edge = |a: [f32; 2], b: [f32; 2]| (((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2)) as f64).sqrt();
    let longest = edge(p[0], p[1]).max(edge(p[1], p[2])).max(edge(p[2], p[0]));
    if depth == 0 || longest <= MAX_EDGE {
        out.push(*t);
        return;
    }
    let ab = mix(&t[0], &t[1], 0.5);
    let bc = mix(&t[1], &t[2], 0.5);
    let ca = mix(&t[2], &t[0], 0.5);
    for piece in [[t[0], ab, ca], [ab, t[1], bc], [ca, bc, t[2]], [ab, bc, ca]] {
        split(&piece, pos, mix, depth - 1, out);
    }
}

// ----------------------------------------------------------------- state

/// What carries from the frame hook to the screen hook and back.
struct State {
    settings: Option<Settings>,
    /// Set by the screen hook each frame it draws a plane, cleared by the frame hook: a frame that
    /// finds it clear knows the screen closed.
    seen: bool,
    opened: Option<Instant>,
    mapping: Option<Mapping>,
    /// The pointer as the window reports it, and the cursor this mod last wrote over it.
    pointer: [f32; 2],
    written: Option<[f32; 2]>,
    /// A press landed off the plane and was cancelled: its release is too.
    ignored: bool,
}

thread_local! {
    static STATE: RefCell<State> = const {
        RefCell::new(State {
            settings: None,
            seen: false,
            opened: None,
            mapping: None,
            pointer: [0.0, 0.0],
            written: None,
            ignored: false,
        })
    };
}

/// The settings, read once through `get` (the mod's setting files), then kept.
pub fn settings(get: impl Fn(&str) -> Option<String>) -> Settings {
    STATE.with(|s| {
        s.borrow_mut()
            .settings
            .get_or_insert_with(|| Settings::load(get))
            .clone()
    })
}

/// Replaces them (a click on the settings page or `/spatialgui` changed one).
pub fn set_settings(settings: Settings) {
    STATE.with(|s| s.borrow_mut().settings = Some(settings));
}

/// A screen is about to be drawn as a plane: starts or goes on with its opening animation and gives the
/// mapping and opacity for this frame. `gui` is the window in GUI pixels.
pub fn begin_frame(s: &Settings, fov_degrees: f32, gui: [f32; 2]) -> (Mapping, f32) {
    STATE.with(|state| {
        let mut st = state.borrow_mut();
        st.seen = true;
        let opened = *st.opened.get_or_insert_with(Instant::now);
        let elapsed = opened.elapsed().as_millis().min(60_000) as u32;
        let (scale, opacity) = animation(s, elapsed);
        let pointer = (st.pointer != [0.0, 0.0] || st.written.is_some()).then_some(st.pointer);
        let mapping = Mapping::new(s, fov_degrees, gui, scale, pointer);
        st.mapping = Some(mapping);
        (mapping, opacity)
    })
}

/// Once a frame, before the game reads the cursor: `cursor` is the game's. Returns the cursor to put
/// in its place (the pointer mapped onto the plane), or None when no plane was drawn.
pub fn frame(cursor: [f32; 2]) -> Option<[f32; 2]> {
    STATE.with(|state| {
        let mut st = state.borrow_mut();
        if !st.seen {
            st.opened = None;
            st.mapping = None;
            st.written = None;
            return None;
        }
        st.seen = false;
        let mapping = st.mapping?;
        // The game moves the cursor only when the pointer moves: the cursor we wrote is not news.
        if st.written != Some(cursor) {
            st.pointer = cursor;
        }
        let mapped = mapping.cursor(st.pointer)?;
        st.written = Some(mapped);
        Some(mapped)
    })
}

/// A mouse button went down (`pressed`) or up while the game's cursor is `cursor`: the cursor may still
/// be the window's, as a touch sends its position and its press together, so it is mapped now. Returns
/// the cursor to use and whether to cancel the event: a press off the plane is not the screen's, and
/// neither is its release. None when no plane is up.
pub fn button(cursor: [f32; 2], pressed: bool) -> Option<([f32; 2], bool)> {
    STATE.with(|state| {
        let mut st = state.borrow_mut();
        let mapping = st.mapping?;
        if st.written != Some(cursor) {
            st.pointer = cursor;
        }
        let mapped = mapping.cursor(st.pointer)?;
        st.written = Some(mapped);
        let cancel = if pressed {
            st.ignored = !mapping.over(st.pointer);
            st.ignored
        } else {
            std::mem::take(&mut st.ignored)
        };
        Some((mapped, cancel))
    })
}

/// `/spatialgui`'s answer line.
pub fn state_line(on: bool) -> String {
    format!("Spatial GUI {}", if on { "on" } else { "off" })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f32, b: f32, eps: f32) -> bool {
        (a - b).abs() <= eps
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    struct Vx {
        pos: [f32; 2],
        color: u32,
    }

    fn project(m: &Mapping, input: &[Vx], opacity: f32) -> Projected<Vx> {
        project_triangles(
            m,
            input,
            |v| v.pos,
            |v, p| v.pos = p,
            |a, b, t| Vx {
                pos: [lerp(a.pos[0], b.pos[0], t), lerp(a.pos[1], b.pos[1], t)],
                color: mix_color(a.color, b.color, t),
            },
            |v, f| v.color = scale_alpha(v.color, f),
            opacity,
        )
    }

    fn defaults() -> Settings {
        Settings {
            parallax: false,
            ..Settings::default()
        }
    }

    // Expected values below are worked out by hand from the pinhole camera, not from the code.

    #[test]
    fn easings_start_at_zero_and_end_at_one() {
        for e in Easing::ALL {
            assert!(close(e.apply(0.0), 0.0, 1e-5), "{e:?} at 0");
            assert!(close(e.apply(1.0), 1.0, 1e-5), "{e:?} at 1");
        }
    }

    #[test]
    fn easings_at_the_half_way_point() {
        // 1 - (1 - t)^n and the like, by hand.
        assert!(close(Easing::Cubic.apply(0.5), 0.875, 1e-6));
        assert!(close(Easing::Quadratic.apply(0.5), 0.75, 1e-6));
        assert!(close(Easing::Quartic.apply(0.5), 0.9375, 1e-6));
        assert!(close(Easing::Exponential.apply(0.5), 1.0 - 1.0 / 32.0, 1e-6));
        // 7.5625 * (0.5 - 1.5/2.75)^2 + 0.75
        assert!(close(Easing::Bounce.apply(0.5), 0.765625, 1e-4));
        // Back overshoots 1 on the way: 1 + 2.70158 * (-0.125) + 1.70158 * 0.25
        assert!(close(Easing::Back.apply(0.5), 1.0876975, 1e-5));
    }

    #[test]
    fn easing_names_round_trip_and_cycle_through_all() {
        for e in Easing::ALL {
            assert_eq!(Easing::parse(e.name()), Some(e));
        }
        assert_eq!(Easing::parse(" back "), Some(Easing::Back));
        assert_eq!(Easing::parse("nope"), None);
        let mut e = Easing::Cubic;
        for _ in 0..Easing::ALL.len() {
            e = e.next();
        }
        assert_eq!(e, Easing::Cubic);
    }

    #[test]
    fn animation_runs_from_the_start_scale_to_full_and_fades_in() {
        let s = Settings::default();
        let (scale, alpha) = animation(&s, 0);
        assert!(close(scale, 0.75, 1e-6) && close(alpha, 0.0, 1e-6));
        // Past both durations: full size, full opacity.
        let (scale, alpha) = animation(&s, 1000);
        assert!(close(scale, 1.0, 1e-6) && close(alpha, 1.0, 1e-6));
        // Half way through the fade (150 ms): half opaque.
        assert!(close(animation(&s, 75).1, 0.5, 1e-6));
    }

    #[test]
    fn animation_off_is_always_full() {
        let s = Settings {
            scale_anim: false,
            fade_anim: false,
            opacity: 128,
            ..Settings::default()
        };
        let (scale, alpha) = animation(&s, 0);
        assert!(close(scale, 1.0, 1e-6) && close(alpha, 128.0 / 255.0, 1e-6));
    }

    #[test]
    fn auto_fov_leaves_the_baseline_alone_and_grows_with_the_fov() {
        let s = Settings::default();
        let (scale, distance, side) = fov_adjusted(&s, 70.0);
        assert!(close(scale, 1.0, 1e-6) && close(distance, 1.5, 1e-6) && close(side, 0.0, 1e-6));
        // 90 degrees: (90/70)^1.2 wide; distance 1.5 * (1 + (70/90 - 1) * 0.8)
        let (scale, distance, _) = fov_adjusted(&s, 90.0);
        assert!(close(scale, 1.352, 1e-3), "{scale}");
        assert!(close(distance, 1.5 * (1.0 + (70.0 / 90.0 - 1.0) * 0.8), 1e-5));
        // Off: nothing moves.
        let off = Settings {
            auto_fov: false,
            ..Settings::default()
        };
        assert_eq!(fov_adjusted(&off, 110.0), (1.0, 1.5, 0.0));
    }

    #[test]
    fn the_layouts_centre_lands_in_the_windows_centre() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let p = m.forward([240.0, 135.0]).unwrap();
        assert!(close(p[0], 240.0, 1e-3) && close(p[1], 135.0, 1e-3), "{p:?}");
    }

    #[test]
    fn a_flat_screens_edge_is_where_the_pinhole_camera_puts_it() {
        // 1.8 blocks wide, 1.5 away, vertical fov 70, 480x270: the right edge is 0.9 to the side, so
        // ndc.x = (0.9 / 1.5) / (tan 35 deg * 16/9) and the pixel is (ndc.x / 2 + 0.5) * 480.
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let ndc = (0.9 / 1.5) / (35f64.to_radians().tan() * 16.0 / 9.0);
        let expected = ((ndc / 2.0 + 0.5) * 480.0) as f32;
        let p = m.forward([480.0, 135.0]).unwrap();
        assert!(close(p[0], expected, 0.01), "{} vs {expected}", p[0]);
        // The top edge: height 1.8 * 270/480 = 1.0125, half 0.50625.
        let ndc_y = (0.50625 / 1.5) / 35f64.to_radians().tan();
        let expected_y = ((0.5 - ndc_y / 2.0) * 270.0) as f32;
        let p = m.forward([240.0, 0.0]).unwrap();
        assert!(close(p[1], expected_y, 0.01), "{} vs {expected_y}", p[1]);
    }

    #[test]
    fn a_nearer_screen_looks_bigger() {
        let far = Mapping::new(&Settings { distance: 3.0, auto_fov: false, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        let near = Mapping::new(&Settings { distance: 1.0, auto_fov: false, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        let width = |m: &Mapping| m.forward([480.0, 135.0]).unwrap()[0] - m.forward([0.0, 135.0]).unwrap()[0];
        assert!(width(&near) > width(&far) * 2.5);
    }

    #[test]
    fn unproject_undoes_forward_for_every_pose() {
        let poses = [
            Settings { auto_fov: false, ..defaults() },
            Settings { yaw: 25.0, pitch: -10.0, side: 0.3, height: -0.2, ..defaults() },
            Settings { curved: true, arc: 90.0, ..defaults() },
            Settings { curved: true, arc: -60.0, yaw: 10.0, ..defaults() },
        ];
        for (i, s) in poses.iter().enumerate() {
            for pointer in [None, Some([100.0, 50.0])] {
                let mut s = s.clone();
                s.parallax = pointer.is_some();
                let m = Mapping::new(&s, 85.0, [427.0, 240.0], 0.9, pointer);
                for g in [[10.0, 10.0], [213.0, 120.0], [400.0, 200.0], [60.0, 230.0]] {
                    let window = m.forward(g).unwrap();
                    let back = m.unproject(window).unwrap();
                    assert!(
                        close(back[0], g[0], 0.05) && close(back[1], g[1], 0.05),
                        "pose {i} {pointer:?}: {g:?} -> {window:?} -> {back:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn the_pointer_is_over_the_screen_only_inside_its_outline() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        assert!(m.over([240.0, 135.0]));
        let left = m.forward([0.0, 135.0]).unwrap()[0];
        assert!(m.over([left + 2.0, 135.0]));
        assert!(!m.over([left - 6.0, 135.0]));
        assert!(!m.over([1.0, 1.0]));
        // The cursor handed to the game never leaves the layout.
        let c = m.cursor([1.0, 1.0]).unwrap();
        assert!(c[0] >= 0.0 && c[1] >= 0.0 && c[0] <= 479.0 && c[1] <= 269.0);
    }

    #[test]
    fn parallax_moves_the_screen_against_the_pointer() {
        let s = Settings::default();
        let still = Mapping::new(&s, 70.0, [480.0, 270.0], 1.0, Some([240.0, 135.0]));
        let right = Mapping::new(&s, 70.0, [480.0, 270.0], 1.0, Some([480.0, 135.0]));
        let c = |m: &Mapping| m.forward([240.0, 135.0]).unwrap()[0];
        assert!(close(c(&still), 240.0, 1e-3));
        // Pointer at the right edge: the plane swings left, by tan(6 deg) of a 1.5 block distance.
        assert!(c(&right) < c(&still) - 5.0);
        // With Parallax off the pointer does nothing.
        let off = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, Some([480.0, 135.0]));
        assert!(close(c(&off), 240.0, 1e-3));
    }

    #[test]
    fn a_curved_screen_pulls_its_edges_toward_the_viewer() {
        let flat = Mapping::new(&Settings { auto_fov: false, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        let curved = Mapping::new(&Settings { auto_fov: false, curved: true, arc: 90.0, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        // The edge is nearer the camera on the cylinder, so it appears further from the centre.
        let edge = |m: &Mapping| m.forward([480.0, 135.0]).unwrap()[0];
        assert!(edge(&curved) > edge(&flat));
        // The middle does not move.
        assert!(close(curved.forward([240.0, 135.0]).unwrap()[0], 240.0, 1e-3));
        // A tiny arc is a flat screen.
        let tiny = Mapping::new(&Settings { curved: true, arc: 0.4, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        let flat_default = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        assert_eq!(tiny.forward([480.0, 0.0]), flat_default.forward([480.0, 0.0]));
    }

    #[test]
    fn a_plane_behind_the_camera_draws_nothing() {
        let m = Mapping::new(&Settings { distance: -1.0, auto_fov: false, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        assert_eq!(m.forward([240.0, 135.0]), None);
        assert_eq!(m.unproject([240.0, 135.0]), None);
    }

    #[test]
    fn the_shadow_sits_behind_and_slightly_off_the_screen() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let q = m.shadow_quad(0.008, -0.012, 0.002).unwrap();
        let tl = m.forward([0.0, 0.0]).unwrap();
        // Moved right a little and down a little (y grows downward), and only a little.
        assert!(q[0][0] > tl[0] && q[0][1] > tl[1]);
        assert!(q[0][0] - tl[0] < 5.0 && q[0][1] - tl[1] < 5.0);
        let curved = Mapping::new(&Settings { curved: true, ..defaults() }, 70.0, [480.0, 270.0], 1.0, None);
        assert_eq!(curved.shadow_quad(0.0, 0.0, 0.0), None);
    }

    #[test]
    fn project_rect_bounds_the_corners() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let r = m.project_rect([100.0, 50.0, 100.0, 100.0]).unwrap();
        let a = m.forward([100.0, 50.0]).unwrap();
        let b = m.forward([200.0, 150.0]).unwrap();
        assert!(close(r[0], a[0], 1e-3) && close(r[1], a[1], 1e-3));
        assert!(close(r[0] + r[2], b[0], 1e-3) && close(r[1] + r[3], b[1], 1e-3));
    }

    #[test]
    fn colours_scale_and_mix_channel_by_channel() {
        let c = (200u32 << 24) | (30 << 16) | (20 << 8) | 10;
        assert_eq!(scale_alpha(c, 0.5) >> 24, 100);
        assert_eq!(scale_alpha(c, 0.5) & 0x00FF_FFFF, c & 0x00FF_FFFF);
        assert_eq!(scale_alpha(c, 2.0) >> 24, 200);
        let a = 0x0000_0000;
        let b = 0xFF_FF_FF_FF;
        assert_eq!(mix_color(a, b, 0.5), 0x80_80_80_80);
        assert_eq!(mix_color(a, b, 0.0), a);
        assert_eq!(mix_color(a, b, 1.0), b);
    }

    #[test]
    fn small_triangles_stay_whole_and_big_ones_are_cut() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let white = 0xFFFF_FFFF;
        let small = [
            Vx { pos: [100.0, 100.0], color: white },
            Vx { pos: [110.0, 100.0], color: white },
            Vx { pos: [100.0, 110.0], color: white },
        ];
        let p = project(&m, &small, 1.0);
        assert_eq!(p.vertices.len(), 3);
        assert_eq!(p.starts, vec![0, 3]);
        let big = [
            Vx { pos: [100.0, 50.0], color: white },
            Vx { pos: [280.0, 50.0], color: white },
            Vx { pos: [100.0, 200.0], color: white },
        ];
        let p = project(&m, &big, 1.0);
        assert!(p.vertices.len() > 3 && p.vertices.len().is_multiple_of(3));
    }

    #[test]
    fn cutting_keeps_the_covered_area() {
        // The pieces of one big triangle fill it exactly: their areas (before projection) add up.
        let mut pieces = Vec::new();
        let t = [
            Vx { pos: [0.0, 0.0], color: 0 },
            Vx { pos: [160.0, 0.0], color: 0 },
            Vx { pos: [0.0, 120.0], color: 0 },
        ];
        split(
            &t,
            &|v: &Vx| v.pos,
            &|a: &Vx, b: &Vx, k| Vx { pos: [lerp(a.pos[0], b.pos[0], k), lerp(a.pos[1], b.pos[1], k)], color: 0 },
            MAX_DEPTH,
            &mut pieces,
        );
        let area = |t: &[Vx; 3]| {
            let (a, b, c) = (t[0].pos, t[1].pos, t[2].pos);
            ((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])).abs() / 2.0
        };
        let total: f32 = pieces.iter().map(area).sum();
        assert!(close(total, 160.0 * 120.0 / 2.0, 1.0), "{total}");
        assert!(pieces.len() > 4);
    }

    #[test]
    fn a_window_sized_dim_is_dropped_and_the_rest_fades() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let col = (255u32 << 24) | 0x00_FF_FF_FF;
        let dim = [
            Vx { pos: [0.0, 0.0], color: col },
            Vx { pos: [480.0, 0.0], color: col },
            Vx { pos: [0.0, 270.0], color: col },
        ];
        let tri = [
            Vx { pos: [200.0, 100.0], color: col },
            Vx { pos: [210.0, 100.0], color: col },
            Vx { pos: [200.0, 110.0], color: col },
        ];
        let input: Vec<Vx> = dim.iter().chain(tri.iter()).copied().collect();
        let p = project(&m, &input, 0.5);
        // The dim made nothing; the small one is one triangle at half opacity.
        assert_eq!(p.starts, vec![0, 0, 3]);
        assert_eq!(p.vertices.len(), 3);
        assert_eq!(p.vertices[0].color >> 24, 128);
    }

    #[test]
    fn ranges_follow_their_vertices() {
        let m = Mapping::new(&defaults(), 70.0, [480.0, 270.0], 1.0, None);
        let col = 0xFFFF_FFFF;
        let v = |x: f32, y: f32| Vx { pos: [x, y], color: col };
        // dim (dropped), a small triangle, a big one (cut), a small one.
        let mut input = vec![v(0.0, 0.0), v(480.0, 0.0), v(0.0, 270.0)];
        input.extend([v(10.0, 10.0), v(20.0, 10.0), v(10.0, 20.0)]);
        input.extend([v(100.0, 50.0), v(280.0, 50.0), v(100.0, 200.0)]);
        input.extend([v(300.0, 10.0), v(310.0, 10.0), v(300.0, 20.0)]);
        let p = project(&m, &input, 1.0);
        let first = 30; // the screen begins at vertex 30 of the batch
        // 1 vertex of shadow quad (a stand-in count of 6) was put in front.
        let shift = 6;
        // A range over the third input triangle (the big one): input 6..9.
        let r = remap_range(first + 6..first + 9, first, shift, &p);
        assert_eq!(r.start, first + shift + p.starts[2]);
        assert_eq!(r.end, first + shift + p.starts[3]);
        assert!(r.end - r.start > 3);
        // A range before the screen does not move; one ending at the first vertex stays.
        assert_eq!(remap_range(0..first, first, shift, &p), 0..first);
        // One starting at the first vertex moves past the shadow.
        assert_eq!(remap_range(first..first + 3, first, shift, &p).start, first + shift);
        // The whole thing ends where the output ends.
        assert_eq!(
            remap_range(first..first + 12, first, shift, &p).end,
            first + shift + p.vertices.len() as u32
        );
    }

    #[test]
    fn settings_round_trip_through_their_stored_text() {
        let mut s = Settings::default();
        s.cycle(CONTROLS.iter().position(|k| *k == "distance").unwrap());
        s.cycle(CONTROLS.iter().position(|k| *k == "easing").unwrap());
        s.cycle(CONTROLS.iter().position(|k| *k == "curved").unwrap());
        let store = |key: &str| Some(s.value(key));
        let loaded = Settings::load(store);
        assert_eq!(loaded.value("distance"), s.value("distance"));
        assert_eq!(loaded.easing, s.easing);
        assert!(loaded.curved);
        assert_eq!(loaded, s);
    }

    #[test]
    fn a_stored_value_that_makes_no_sense_changes_nothing() {
        let mut s = Settings::default();
        assert!(!s.apply("distance", "far"));
        assert!(!s.apply("distance", "NaN"));
        assert!(!s.apply("enabled", "maybe"));
        assert!(!s.apply("nothing", "1"));
        assert_eq!(s, Settings::default());
        // Out of range values are held to their range.
        assert!(s.apply("distance", "99"));
        assert_eq!(s.distance, 4.0);
    }

    #[test]
    fn clicking_cycles_a_number_and_wraps() {
        let mut s = Settings::default();
        let i = CONTROLS.iter().position(|k| *k == "distance").unwrap();
        // 1.5 -> 1.75 -> ... -> 3.0 -> back to 0.75.
        let mut seen = vec![s.distance];
        for _ in 0..9 {
            let changed = s.cycle(i);
            assert_eq!(changed.len(), 1);
            assert_eq!(changed[0].0, "distance");
            seen.push(s.distance);
        }
        assert_eq!(seen[1], 1.75);
        assert_eq!(seen[6], 3.0);
        assert_eq!(seen[7], 0.75);
        assert_eq!(seen[8], 1.0);
    }

    #[test]
    fn reset_brings_back_the_defaults_and_reports_what_changed() {
        let mut s = Settings::default();
        s.cycle(CONTROLS.iter().position(|k| *k == "pause").unwrap());
        s.cycle(CONTROLS.iter().position(|k| *k == "scale").unwrap());
        let changed = s.cycle(CONTROLS.len() - 1);
        let keys: Vec<_> = changed.iter().map(|c| c.0).collect();
        assert_eq!(keys, vec!["pause", "scale"]);
        assert_eq!(s, Settings::default());
    }

    #[test]
    fn every_button_has_a_label_and_the_last_is_reset() {
        let s = Settings::default();
        for i in 0..CONTROLS.len() {
            assert!(!s.label(i).is_empty(), "button {i}");
        }
        assert_eq!(s.label(0), "Spatial GUI: ON");
        assert_eq!(s.label(4), "Distance: 1.5 blocks");
        assert_eq!(s.label(CONTROLS.len() - 1), "Reset to defaults");
        assert_eq!(s.label(99), "");
        assert!(Settings::default().cycle(99).is_empty());
    }

    #[test]
    fn screens_are_taken_by_what_the_player_asked_for() {
        let s = Settings::default();
        assert!(s.applies("inventory"));
        assert!(s.applies("creative"));
        assert!(!s.applies("paused"));
        assert!(!s.applies("stats"));
        for title in ["title", "world_select", "multiplayer", "ban_notice"] {
            assert!(!Settings { all_screens: true, pause: true, ..Settings::default() }.applies(title), "{title}");
        }
        let more = Settings { pause: true, all_screens: true, ..Settings::default() };
        assert!(more.applies("paused") && more.applies("stats"));
        assert!(!Settings { enabled: false, ..more }.applies("inventory"));
    }

    #[test]
    fn a_click_off_the_plane_is_cancelled_with_its_release_and_one_on_it_is_mapped() {
        std::thread::spawn(|| {
            let s = defaults();
            // No plane up: the click is the game's.
            assert_eq!(button([240.0, 135.0], true), None);
            let (m, _) = begin_frame(&s, 70.0, [480.0, 270.0]);
            // On the plane (a touch sends position and press together: the cursor is still the window's).
            let at = m.forward([240.0, 135.0]).unwrap();
            let (cursor, cancel) = button(at, true).unwrap();
            assert!(!cancel);
            assert!(close(cursor[0], 240.0, 0.1) && close(cursor[1], 135.0, 0.1), "{cursor:?}");
            assert!(!button(cursor, false).unwrap().1);
            // Off it, left of the plane: cancelled, and so is the release, once.
            let outside = [m.forward([0.0, 135.0]).unwrap()[0] - 10.0, 135.0];
            assert!(button(outside, true).unwrap().1);
            assert!(button(outside, false).unwrap().1);
            assert!(!button(at, false).unwrap().1);
        })
        .join()
        .unwrap();
    }

    #[test]
    fn the_frame_hands_back_the_pointer_mapped_onto_the_plane() {
        // A fresh thread: the state is thread local.
        std::thread::spawn(|| {
            let s = defaults();
            // No plane drawn yet: nothing to map.
            assert_eq!(frame([10.0, 10.0]), None);
            let (m, opacity) = begin_frame(&s, 70.0, [480.0, 270.0]);
            assert!((0.0..=1.0).contains(&opacity));
            // The game's cursor is the window's pointer: the middle maps to the layout's middle.
            let c = frame([240.0, 135.0]).unwrap();
            assert!(close(c[0], 240.0, 0.1) && close(c[1], 135.0, 0.1), "{c:?}");
            // The next frame the game still holds what we wrote: the pointer is unchanged, not "moved".
            begin_frame(&s, 70.0, [480.0, 270.0]);
            let again = frame(c).unwrap();
            assert_eq!(again, c);
            // The pointer moves: the cursor follows through the mapping.
            begin_frame(&s, 70.0, [480.0, 270.0]);
            let window = m.forward([100.0, 80.0]).unwrap();
            // (the animation changed the scale a little: ask the mapping the state really used)
            let moved = frame(window).unwrap();
            assert!(moved[0] < c[0] && moved[1] < c[1]);
            // No plane drawn this frame: the screen closed, the state resets.
            assert_eq!(frame(moved), None);
            assert_eq!(frame(moved), None);
        })
        .join()
        .unwrap();
    }
}
