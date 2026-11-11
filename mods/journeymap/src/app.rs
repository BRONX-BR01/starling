//! The mod's state and the game's hooks. Everything testable lives in the
//! other modules; this is the glue to the host's API.
use crate::exports::horizon::mods::events::{Guest, Registration};
use crate::grid::Select;
use crate::horizon::mods::{chat, game, input, storage, ui, world};
use crate::view::{self, Control, Marker, Projection, Shape};
use crate::{grid, waypoint::Waypoints};
use std::sync::{Mutex, PoisonError};

const KEY: &str = "journeymap.map";
const STORE: &str = "waypoints";
const STEPS: [i32; 4] = [1, 2, 4, 8];
const REFRESH_TICKS: u64 = 40;
const PENDING_TIMEOUT: u64 = 100;
const PAN_CELLS: i32 = 10;
const HELP: &str = "/jm [map] | add [nome] | del <nome> | tp <nome> | list | zoom <1|2|4|8>";
const HINT: &str = "Toque no mapa: criar/apagar waypoint  Esc: fechar";

struct Here {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    health: f32,
    dim: String,
}

impl From<game::Player> for Here {
    fn from(p: game::Player) -> Self {
        Self { x: p.x, y: p.y, z: p.z, yaw: p.yaw, health: p.health, dim: p.dimension }
    }
}

/// What the last answer drew; `proj` says where its cells are in the world.
struct Image {
    proj: Projection,
    dim: String,
    cave: bool,
    ref_y: i32,
    runs: Vec<grid::Run>,
    heights: Vec<Option<i32>>,
}

struct Pending {
    tag: u32,
    proj: Projection,
    dim: String,
    select: Select,
    tick: u64,
}

struct State {
    waypoints: Waypoints,
    open: bool,
    cave: bool,
    step: usize,
    pan: (i32, i32),
    map: Option<Image>,
    pending: Option<Pending>,
    next_tag: u32,
    last_request: Option<u64>,
    dirty: bool,
    drawn_at: Option<(i32, i32, i32)>,
    cursor: Option<(i32, i32)>,
    last_health: f32,
    error_reported: bool,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> Option<R> {
    let mut guard = STATE.lock().unwrap_or_else(PoisonError::into_inner);
    guard.as_mut().map(f)
}

fn to_draw(s: &Shape) -> ui::Draw {
    match s {
        Shape::Fill { x, y, w, h, argb } => ui::Draw::Fill((ui::Rect { x: *x, y: *y, w: *w, h: *h }, *argb)),
        Shape::Quad { pts, argb } => {
            ui::Draw::Quad((pts.iter().map(|&(x, y)| ui::Point { x, y }).collect(), *argb))
        }
        Shape::Text { text, x, y, rgb, center } => {
            ui::Draw::Text((text.clone(), ui::Point { x: *x, y: *y }, *rgb, *center))
        }
    }
}

fn control_for_text(c: char) -> Option<Control> {
    Some(match c {
        '+' | '=' => Control::ZoomIn,
        '-' => Control::ZoomOut,
        'c' => Control::Center,
        't' => Control::Mode,
        'w' => Control::Pan(0, -1),
        's' => Control::Pan(0, 1),
        'a' => Control::Pan(-1, 0),
        'd' => Control::Pan(1, 0),
        _ => return None,
    })
}

fn control_for_key(k: &str) -> Option<Control> {
    Some(match k {
        "key.keyboard.up" => Control::Pan(0, -1),
        "key.keyboard.down" => Control::Pan(0, 1),
        "key.keyboard.left" => Control::Pan(-1, 0),
        "key.keyboard.right" => Control::Pan(1, 0),
        "key.keyboard.home" => Control::Center,
        _ => return None,
    })
}

impl State {
    fn new(waypoints: Waypoints) -> Self {
        Self {
            waypoints,
            open: false,
            cave: false,
            step: 1,
            pan: (0, 0),
            map: None,
            pending: None,
            next_tag: 0,
            last_request: None,
            dirty: false,
            drawn_at: None,
            cursor: None,
            last_health: 20.0,
            error_reported: false,
        }
    }

    /// Where the map is (or will be) centred: the player, moved by the pan.
    fn wanted_center(&self, here: &Here) -> (i32, i32) {
        (here.x.floor() as i32 + self.pan.0, here.z.floor() as i32 + self.pan.1)
    }

    fn proj(&self, here: &Here) -> Projection {
        self.map.as_ref().map_or_else(
            || {
                let (cx, cz) = self.wanted_center(here);
                Projection { cx, cz, step: STEPS[self.step] }
            },
            |m| m.proj,
        )
    }

    fn toggle(&mut self) {
        self.open = !self.open;
        if self.open {
            self.refresh_now();
        } else {
            ui::close();
        }
    }

    fn refresh_now(&mut self) {
        self.pending = None;
        self.last_request = None;
        self.dirty = true;
    }

    fn set_zoom(&mut self, i: usize) {
        if i != self.step {
            self.step = i;
            self.map = None;
            self.refresh_now();
        }
    }

    fn control(&mut self, c: Control) {
        match c {
            Control::ZoomIn => self.set_zoom(self.step.saturating_sub(1)),
            Control::ZoomOut => self.set_zoom((self.step + 1).min(STEPS.len() - 1)),
            Control::Pan(dx, dy) => {
                let d = STEPS[self.step] * PAN_CELLS;
                self.pan = (self.pan.0.saturating_add(dx * d), self.pan.1.saturating_add(dy * d));
                self.refresh_now();
            }
            Control::Center => {
                self.pan = (0, 0);
                self.refresh_now();
            }
            Control::Mode => {
                self.cave = !self.cave;
                self.map = None;
                self.refresh_now();
            }
        }
    }

    fn save(&self) {
        if let Err(e) = storage::set(STORE, &self.waypoints.encode()) {
            chat::show(&format!("[JourneyMap] nao salvou os waypoints: {e}"));
        }
    }

    fn tick(&mut self, now: u64) {
        let here = game::get_player().map(Here::from);
        if let Some(h) = &here {
            if self.last_health > 0.0 && h.health <= 0.0 {
                self.waypoints.add("Morte", h.x.floor() as i32, h.y.floor() as i32, h.z.floor() as i32, &h.dim);
                self.save();
                self.dirty = true;
            }
            self.last_health = h.health;
        }
        for event in input::poll() {
            match event {
                input::Event::KeyDown(k) if k == KEY => {
                    if !self.open {
                        self.toggle();
                    }
                }
                input::Event::ScreenClick(c) => self.click(c.x, c.y, c.button, here.as_ref()),
                input::Event::ScreenClosed => self.open = false,
                _ => {}
            }
        }
        if self.open {
            for typed in input::poll_typed() {
                match typed {
                    input::Typed::Text(s) => s.chars().filter_map(control_for_text).for_each(|c| self.control(c)),
                    input::Typed::Key(k) => {
                        if let Some(c) = control_for_key(&k) {
                            self.control(c);
                        }
                    }
                }
            }
        }
        for answer in world::poll_columns() {
            self.accept(answer);
        }
        let Some(here) = here else { return };
        if self.pending.as_ref().is_some_and(|p| now.saturating_sub(p.tick) > PENDING_TIMEOUT) {
            self.pending = None;
        }
        if self.map.as_ref().is_some_and(|m| m.dim != here.dim) {
            self.map = None;
            self.dirty = true;
        }
        if !self.open {
            return;
        }
        if self.pending.is_none() && self.needs_refresh(now, &here) {
            self.request(now, &here);
        }
        let proj = self.proj(&here);
        let cursor = ui::cursor().filter(|p| view::inside(p.x, p.y)).map(|p| proj.to_world(p.x, p.y));
        if cursor != self.cursor {
            self.cursor = cursor;
            self.dirty = true;
        }
        let (sx, sy) = proj.to_screen(here.x, here.z);
        let key = ((sx * 2.0) as i32, (sy * 2.0) as i32, (here.yaw / 5.0) as i32);
        if self.dirty || self.drawn_at != Some(key) {
            self.render(&here, key);
        }
    }

    fn needs_refresh(&self, now: u64, here: &Here) -> bool {
        match (&self.map, self.last_request) {
            (Some(m), Some(t)) => {
                let (wx, wz) = self.wanted_center(here);
                let far = (wx - m.proj.cx).abs().max((wz - m.proj.cz).abs()) > m.proj.step * 6;
                let climbed = m.cave && (here.y.floor() as i32 - m.ref_y).abs() >= 2;
                far || climbed || now.saturating_sub(t) >= REFRESH_TICKS
            }
            _ => true,
        }
    }

    fn request(&mut self, now: u64, here: &Here) {
        let (cx, cz) = self.wanted_center(here);
        let proj = Projection { cx, cz, step: STEPS[self.step] };
        let select = if self.cave { Select::Slice { y: here.y.floor() as i32 } } else { Select::Top };
        self.next_tag = self.next_tag.wrapping_add(1);
        world::read_columns(self.next_tag, &proj.sample_columns(), world::Heightmap::MotionBlocking, select.below(), 0);
        self.pending = Some(Pending { tag: self.next_tag, proj, dim: here.dim.clone(), select, tick: now });
        self.last_request = Some(now);
    }

    fn accept(&mut self, a: world::ColumnBlocks) {
        let Some(p) = self.pending.take_if(|p| p.tag == a.tag) else { return };
        let answer = grid::Answer { palette: &a.palette, bases: &a.bases, blocks: &a.blocks, tints: &a.tints };
        match grid::colors(&answer, p.select) {
            Ok(colors) => {
                let (cave, ref_y) = match p.select {
                    Select::Top => (false, 0),
                    Select::Slice { y } => (true, y),
                };
                self.map = Some(Image {
                    proj: p.proj,
                    dim: p.dim,
                    cave,
                    ref_y,
                    runs: grid::merge_runs(&colors, grid::N),
                    heights: a.bases,
                });
                self.dirty = true;
            }
            Err(e) if !self.error_reported => {
                self.error_reported = true;
                chat::show(&format!("[JourneyMap] {e}"));
            }
            Err(_) => {}
        }
    }

    fn render(&mut self, here: &Here, key: (i32, i32, i32)) {
        let proj = self.proj(here);
        let runs = self.map.as_ref().map_or(&[][..], |m| m.runs.as_slice());
        let markers: Vec<Marker<'_>> = self
            .waypoints
            .in_dim(&here.dim)
            .map(|(_, w)| Marker { x: w.x, z: w.z, name: &w.name, rgb: w.rgb })
            .collect();
        let mode = if self.cave { "Caverna" } else { "Superficie" };
        let cursor = self.cursor.map_or(String::new(), |(x, z)| format!("  cursor {x} {z}"));
        let title = if self.map.is_some() {
            format!("{mode}  X {} Z {}{cursor}  1:{}", here.x.floor() as i32, here.z.floor() as i32, proj.step)
        } else {
            format!("{mode}: carregando...")
        };
        let shapes = view::scene(runs, proj, Some((here.x, here.z, here.yaw)), &markers, &title, HINT);
        let draws: Vec<ui::Draw> = shapes.iter().map(to_draw).collect();
        ui::show(&draws);
        self.dirty = false;
        self.drawn_at = Some(key);
    }

    fn click(&mut self, sx: f32, sy: f32, button: u32, here: Option<&Here>) {
        if let Some(c) = view::button_at(sx, sy) {
            self.control(c);
            return;
        }
        let (Some(here), Some(img)) = (here, self.map.as_ref()) else { return };
        if !view::inside(sx, sy) {
            return;
        }
        let proj = img.proj;
        let near = self
            .waypoints
            .in_dim(&here.dim)
            .map(|(i, w)| {
                let (wx, wy) = proj.to_screen(f64::from(w.x), f64::from(w.z));
                (i, (wx - sx).hypot(wy - sy))
            })
            .filter(|&(_, d)| d <= 8.0)
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| i);
        let changed = if let Some(i) = near {
            self.waypoints.remove_at(i).is_some()
        } else if button <= 1 {
            let (x, z) = proj.to_world(sx, sy);
            let y = if img.cave {
                here.y.floor() as i32
            } else {
                proj.cell_at(sx, sy)
                    .and_then(|i| img.heights.get(i).copied().flatten())
                    .unwrap_or(here.y.floor() as i32)
            };
            self.waypoints.add("", x, y, z, &here.dim);
            true
        } else {
            false
        };
        if changed {
            self.save();
            self.dirty = true;
        }
    }

    fn command(&mut self, args: &str) -> Result<Option<String>, String> {
        let args = args.trim();
        let (sub, rest) = args.split_once(char::is_whitespace).map_or((args, ""), |(a, b)| (a, b.trim()));
        match sub {
            "" | "map" => {
                self.toggle();
                Ok(None)
            }
            "add" => {
                let p = game::get_player().ok_or("sem jogador")?;
                let w = self.waypoints.add(rest, p.x.floor() as i32, p.y.floor() as i32, p.z.floor() as i32, &p.dimension);
                let msg = format!("Waypoint \"{}\" em {} {} {}", w.name, w.x, w.y, w.z);
                self.save();
                self.dirty = true;
                Ok(Some(msg))
            }
            "del" => match self.waypoints.remove_named(rest) {
                Some(w) => {
                    self.save();
                    self.dirty = true;
                    Ok(Some(format!("Removido \"{}\"", w.name)))
                }
                None => Err(format!("nao achei \"{rest}\"")),
            },
            "tp" => {
                let w = self.waypoints.find(rest).ok_or_else(|| format!("nao achei \"{rest}\""))?;
                let p = game::get_player().ok_or("sem jogador")?;
                if w.dim != p.dimension {
                    return Err(format!("\"{}\" esta em outra dimensao ({})", w.name, w.dim));
                }
                world::run_commands(&[format!("tp @p {} {} {}", w.x, w.y, w.z)]);
                Ok(Some(format!("Indo para \"{}\"", w.name)))
            }
            "list" => {
                let lines: Vec<String> = self
                    .waypoints
                    .all()
                    .iter()
                    .map(|w| format!("{}: {} {} {} ({})", w.name, w.x, w.y, w.z, w.dim))
                    .collect();
                Ok(Some(if lines.is_empty() { "Nenhum waypoint.".to_owned() } else { lines.join("\n") }))
            }
            "zoom" => {
                let i = rest.parse::<i32>().ok().and_then(|n| STEPS.iter().position(|&s| s == n));
                let i = i.ok_or("zoom: 1, 2, 4 ou 8")?;
                self.set_zoom(i);
                Ok(None)
            }
            _ => Ok(Some(HELP.to_owned())),
        }
    }
}

pub struct JourneyMap;

impl Guest for JourneyMap {
    fn init() -> Result<Registration, String> {
        input::register_key(KEY, "JourneyMap: abrir mapa", "key.keyboard.m");
        let waypoints = match storage::get(STORE) {
            Some(bytes) => Waypoints::decode(&bytes).unwrap_or_else(|e| {
                chat::show(&format!("[JourneyMap] {e}; comecando vazio"));
                Waypoints::default()
            }),
            None => Waypoints::default(),
        };
        *STATE.lock().unwrap_or_else(PoisonError::into_inner) = Some(State::new(waypoints));
        Ok(Registration { commands: vec!["jm".to_owned()], tick: true, frame: false, chat: false })
    }

    fn tick(tick: u64) {
        with_state(|s| s.tick(tick));
    }

    fn frame(_seconds: f32) {}

    fn command(name: String, args: String) -> Result<Option<String>, String> {
        if name != "jm" {
            return Ok(None);
        }
        with_state(|s| s.command(&args)).unwrap_or(Ok(None))
    }

    fn chat(_text: String) {}
}
