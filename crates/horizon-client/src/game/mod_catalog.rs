//! Android: the catalog, where a player finds and installs mods, resource packs and shader packs
//! without leaving the game. It opens from Options > Mods. Searching, checking and installing are
//! the desktop launcher's mod browser (the `starling-catalog` crate); this is its screen.
use super::Game;
use super::native_builds::{density, wrapped};
use horizon_client::{
    hud::HudBatch,
    ui_theme::{Face, Ui, color},
};
use starling_catalog::{Done, Shelf, browser::Project};
use std::cell::RefCell;
use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};
use winit::event::{Touch, TouchPhase};

const SHELVES: [(Shelf, &str); 3] = [
    (Shelf::Mods, "Mods"),
    (Shelf::ResourcePacks, "Resource packs"),
    (Shelf::ShaderPacks, "Shader packs"),
];
const MARGIN: f32 = 16.0;
/// What's above and below the rows, and a row with its gap.
const HEAD_H: f32 = 94.0;
const FOOT_H: f32 = 50.0;
const ROW_H: f32 = 60.0;
const ROW_BUTTON_W: f32 = 110.0;
const CLEAR_W: f32 = 56.0;
/// The most characters a search takes.
const QUERY_CHARS: usize = 64;
/// The search runs once the typing has paused this long.
const TYPING_PAUSE: Duration = Duration::from_millis(400);

#[derive(Clone, PartialEq)]
enum Act {
    Close,
    Shelf(Shelf),
    Search,
    Clear,
    Everything,
    Back,
    More,
    Install(usize),
}

#[derive(Default)]
struct Shared {
    /// Which search the answer below is for: an older one's is dropped.
    asked: u64,
    results: Option<Result<Vec<Project>, String>>,
    /// The title of what is being installed, what it says, and how far it is.
    installing: Option<String>,
    line: String,
    fraction: f32,
    finished: Option<(String, Result<Done, String>)>,
}

#[derive(Default)]
pub(super) struct Catalog {
    shown: bool,
    shelf: Shelf,
    query: String,
    /// The search box has the keyboard (text_mirror.rs), and when it last changed.
    typing: bool,
    typed_at: Option<Instant>,
    /// Resource packs: those made for other versions too.
    everything: bool,
    offset: usize,
    /// Rows on a page, as the last search asked.
    page: usize,
    asked: u64,
    /// The projects installed from here, by id.
    installed: HashSet<String>,
    /// What the last install said, and whether it failed.
    notice: Option<(String, bool)>,
    shared: Arc<Mutex<Shared>>,
    /// The buttons as last drawn (UI units), with what each does.
    buttons: RefCell<Vec<([f32; 4], Act)>>,
}

/// `text` on one line that fits `width`, cut with dots if it must be.
fn fitted(ui: &Ui<'_>, face: Face, size: f32, width: f32, text: &str) -> String {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if ui.measure(face, size, &text) <= width {
        return text;
    }
    let mut chars: Vec<char> = text.chars().collect();
    while !chars.is_empty() {
        chars.pop();
        let cut = format!("{}...", chars.iter().collect::<String>().trim_end());
        if ui.measure(face, size, &cut) <= width {
            return cut;
        }
    }
    String::new()
}

/// A button: filled with the accent when `lit`.
fn button(
    ui: &mut Ui<'_>,
    rect: [f32; 4],
    text: &str,
    lit: bool,
    act: Act,
    drawn: &mut Vec<([f32; 4], Act)>,
) {
    let (fill, ink) = if lit {
        (color::ACCENT, color::ON_ACCENT)
    } else {
        (color::RAISED, color::TEXT)
    };
    ui.rounded(rect[0], rect[1], rect[2], rect[3], 8.0, fill);
    ui.text_centered(
        Face::Semibold,
        13.0,
        rect[0] + rect[2] / 2.0,
        rect[1] + (rect[3] - 13.0) / 2.0 - 2.0,
        ink,
        text,
    );
    drawn.push((rect, act));
}

/// What to do next, after an install.
fn done_notice(done: Done, title: &str) -> String {
    match done {
        Done::NativeMod => {
            format!("{title} is in. Close this and press Compile on its row to play with it.")
        }
        Done::ContentMod => format!("{title} is in. It loads the next time you start the game."),
        Done::ResourcePack => format!("{title} is in. Turn it on in Options > Resource Packs."),
        Done::ShaderPack => format!("{title} is in. Choose it on the Shader Packs page."),
    }
}

impl Game<'_> {
    /// Options > Mods' Catalog button.
    pub(super) fn open_catalog(&mut self) {
        starling_catalog::set_game_home(Self::game_dir());
        let card = &mut self.catalog;
        card.shown = true;
        card.notice = None;
        card.installed = starling_catalog::installed_projects(&Self::game_dir());
        self.catalog_search();
    }

    /// Whether the keyboard types in the search box (	ext_context).
    pub(super) fn catalog_typing(&self) -> bool {
        self.catalog.shown && self.catalog.typing
    }

    pub(super) fn catalog_query(&self) -> &str {
        &self.catalog.query
    }

    pub(super) fn catalog_type(&mut self, text: &str) {
        let card = &mut self.catalog;
        let room = QUERY_CHARS.saturating_sub(card.query.chars().count());
        card.query
            .extend(text.chars().filter(|c| !c.is_control()).take(room));
        card.typed_at = Some(Instant::now());
    }

    pub(super) fn catalog_backspace(&mut self) {
        let card = &mut self.catalog;
        card.query.pop();
        card.typed_at = Some(Instant::now());
    }

    /// The keyboard's action key: the search now, and the keyboard away.
    pub(super) fn catalog_submit(&mut self) {
        let card = &mut self.catalog;
        card.typing = false;
        card.typed_at = None;
        card.offset = 0;
        self.catalog_search();
    }

    /// Asks for the page the screen is on; its answer replaces the rows when it comes.
    fn catalog_search(&mut self) {
        let [w, h] = self.touch_size();
        let height = h as f32 / density(w as f32, h as f32);
        let page = (((height - HEAD_H - FOOT_H) / ROW_H).floor() as usize).clamp(2, 12);
        let card = &mut self.catalog;
        card.page = page;
        card.asked += 1;
        let asked = card.asked;
        let shared = card.shared.clone();
        {
            let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
            s.asked = asked;
            s.results = None;
        }
        let (shelf, query, everything, offset) =
            (card.shelf, card.query.clone(), card.everything, card.offset);
        let _ = std::thread::Builder::new()
            .name("catalog search".into())
            .spawn(move || {
                let found = starling_catalog::search(shelf, &query, everything, offset, page);
                if let Err(e) = &found {
                    log::warn!("Horizon: the catalog's search failed: {e}");
                }
                let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
                if s.asked == asked {
                    s.results = Some(found);
                }
            });
    }

    /// What came since the last frame: a pause in the typing, the keyboard put away, an install
    /// that ended (it goes on with the screen closed).
    pub(super) fn poll_catalog(&mut self) {
        if self.catalog.typing && self.keyboard_put_away("catalog") {
            self.catalog.typing = false;
        }
        if self
            .catalog
            .typed_at
            .is_some_and(|at| at.elapsed() >= TYPING_PAUSE)
        {
            self.catalog.typed_at = None;
            self.catalog.offset = 0;
            self.catalog.notice = None;
            self.catalog_search();
        }
        let finished = self
            .catalog
            .shared
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .finished
            .take();
        let Some((title, result)) = finished else {
            return;
        };
        self.catalog.notice = Some(match result {
            Ok(done) => {
                match done {
                    Done::NativeMod => self.list_new_native_mods(),
                    Done::ShaderPack => {
                        self.settings.shader_packs =
                            horizon_client::shader_pack_list::scan(&Self::shader_packs_dir());
                    }
                    Done::ContentMod | Done::ResourcePack => {}
                }
                self.catalog.installed = starling_catalog::installed_projects(&Self::game_dir());
                (done_notice(done, &title), false)
            }
            Err(e) => {
                log::warn!("Horizon: the catalog could not install {title}: {e}");
                (e, true)
            }
        });
    }

    fn catalog_install(&mut self, index: usize) {
        let card = &mut self.catalog;
        let shared = card.shared.clone();
        let project = {
            let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
            if s.installing.is_some() {
                return;
            }
            let Some(Ok(list)) = &s.results else {
                return;
            };
            let Some(project) = list.get(index).cloned() else {
                return;
            };
            s.installing = Some(project.title.clone());
            s.line = project.title.clone();
            s.fraction = 0.0;
            project
        };
        card.notice = None;
        let everything = card.everything;
        let home = Self::game_dir();
        let _ = std::thread::Builder::new()
            .name("catalog install".into())
            .spawn(move || {
                let progress = |line: &str, fraction: f32| {
                    let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
                    line.clone_into(&mut s.line);
                    s.fraction = fraction;
                };
                let result = starling_catalog::install(&project, everything, &home, &progress);
                let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
                s.installing = None;
                s.finished = Some((project.title, result));
            });
    }

    /// The screen, over everything else while it is open.
    pub(super) fn draw_catalog(&self, batch: &mut HudBatch) {
        let card = &self.catalog;
        if !card.shown {
            return;
        }
        let shared = card.shared.lock().unwrap_or_else(PoisonError::into_inner);
        let mut ui = Ui::new(&self.gui.atlas, batch, (-1.0, -1.0));
        let (w, h) = (ui.w, ui.h);
        let mut drawn = Vec::new();
        ui.fill(0.0, 0.0, w, h, color::BG);
        ui.text(Face::Semibold, 18.0, MARGIN, 14.0, color::TEXT, "Catalog");
        button(
            &mut ui,
            [w - MARGIN - 84.0, 10.0, 84.0, 30.0],
            "Close",
            false,
            Act::Close,
            &mut drawn,
        );

        let mut x = MARGIN;
        for (shelf, label) in SHELVES {
            let width = ui.measure(Face::Semibold, 13.0, label) + 28.0;
            button(
                &mut ui,
                [x, 50.0, width, 34.0],
                label,
                card.shelf == shelf,
                Act::Shelf(shelf),
                &mut drawn,
            );
            x += width + 8.0;
        }
        let search = [x + 4.0, 50.0, (w - MARGIN - x - 4.0).max(80.0), 34.0];
        ui.rounded(
            search[0],
            search[1],
            search[2],
            search[3],
            8.0,
            color::RAISED,
        );
        if card.typing {
            ui.border(
                search[0],
                search[1],
                search[2],
                search[3],
                8.0,
                color::ACCENT,
            );
        }
        let (typed, ink) = if card.query.is_empty() && !card.typing {
            ("Search...", color::MUTED)
        } else {
            (card.query.as_str(), color::TEXT)
        };
        let typed = fitted(&ui, Face::Regular, 13.0, search[2] - 24.0 - CLEAR_W, typed);
        ui.text(
            Face::Regular,
            13.0,
            search[0] + 12.0,
            search[1] + 8.0,
            ink,
            &typed,
        );
        if card.typing {
            let end = search[0] + 12.0 + ui.measure(Face::Regular, 13.0, &typed);
            ui.fill(end + 1.0, search[1] + 8.0, 1.5, 18.0, color::ACCENT);
        }
        if !card.query.is_empty() {
            let clear = [
                search[0] + search[2] - CLEAR_W,
                search[1],
                CLEAR_W,
                search[3],
            ];
            ui.text_centered(
                Face::Regular,
                12.0,
                clear[0] + clear[2] / 2.0,
                clear[1] + 9.0,
                color::MUTED,
                "Clear",
            );
            drawn.push((clear, Act::Clear));
        }
        drawn.push((search, Act::Search));

        let row_w = w - 2.0 * MARGIN;
        let mut full = false;
        match &shared.results {
            None => {
                ui.text(
                    Face::Regular,
                    14.0,
                    MARGIN,
                    HEAD_H + 8.0,
                    color::MUTED,
                    "Looking...",
                );
            }
            Some(Err(e)) => {
                let mut y = HEAD_H + 8.0;
                for line in wrapped(&ui, Face::Regular, 14.0, row_w, e) {
                    ui.text(Face::Regular, 14.0, MARGIN, y, color::MUTED, &line);
                    y += 20.0;
                }
            }
            Some(Ok(list)) if list.is_empty() => {
                ui.text(
                    Face::Regular,
                    14.0,
                    MARGIN,
                    HEAD_H + 8.0,
                    color::MUTED,
                    "Nothing found.",
                );
            }
            Some(Ok(list)) => {
                full = list.len() >= card.page;
                let text_w = row_w - ROW_BUTTON_W - 36.0;
                for (i, project) in list.iter().enumerate() {
                    let y = HEAD_H + i as f32 * ROW_H;
                    ui.rounded(MARGIN, y, row_w, ROW_H - 6.0, 10.0, color::RAISED);
                    let native = starling_catalog::is_native_mod(project);
                    let title = if native {
                        format!("{} (native mod)", project.title)
                    } else {
                        project.title.clone()
                    };
                    let title = fitted(&ui, Face::Semibold, 14.0, text_w, &title);
                    ui.text(
                        Face::Semibold,
                        14.0,
                        MARGIN + 12.0,
                        y + 7.0,
                        color::TEXT,
                        &title,
                    );
                    let about = starling_catalog::caution(project)
                        .unwrap_or_else(|| project.summary.clone());
                    let about = fitted(&ui, Face::Regular, 12.0, text_w, &about);
                    ui.text(
                        Face::Regular,
                        12.0,
                        MARGIN + 12.0,
                        y + 29.0,
                        color::MUTED,
                        &about,
                    );
                    let rect = [
                        MARGIN + row_w - ROW_BUTTON_W - 10.0,
                        y + 10.0,
                        ROW_BUTTON_W,
                        ROW_H - 26.0,
                    ];
                    if shared.installing.as_deref() == Some(project.title.as_str()) {
                        ui.text_centered(
                            Face::Semibold,
                            13.0,
                            rect[0] + rect[2] / 2.0,
                            rect[1] + 8.0,
                            color::MUTED,
                            "Installing",
                        );
                    } else if card.installed.contains(&project.id) {
                        ui.text_centered(
                            Face::Semibold,
                            13.0,
                            rect[0] + rect[2] / 2.0,
                            rect[1] + 8.0,
                            color::MUTED,
                            "Installed",
                        );
                    } else {
                        button(&mut ui, rect, "Install", true, Act::Install(i), &mut drawn);
                    }
                }
            }
        }

        let foot = h - FOOT_H + 8.0;
        let mut left = MARGIN;
        if card.offset > 0 {
            button(
                &mut ui,
                [left, foot, 76.0, 34.0],
                "Back",
                false,
                Act::Back,
                &mut drawn,
            );
            left += 84.0;
        }
        if full {
            button(
                &mut ui,
                [left, foot, 76.0, 34.0],
                "More",
                false,
                Act::More,
                &mut drawn,
            );
            left += 84.0;
        }
        let mut right = w - MARGIN;
        if card.shelf == Shelf::ResourcePacks {
            let label = if card.everything {
                "All game versions"
            } else {
                "Only this version"
            };
            let width = ui.measure(Face::Semibold, 13.0, label) + 28.0;
            right -= width;
            button(
                &mut ui,
                [right, foot, width, 34.0],
                label,
                card.everything,
                Act::Everything,
                &mut drawn,
            );
            right -= 8.0;
        }
        let status_w = (right - left - 8.0).max(0.0);
        if shared.installing.is_some() {
            let line = fitted(&ui, Face::Regular, 12.0, status_w, &shared.line);
            ui.text(Face::Regular, 12.0, left + 8.0, foot, color::TEXT, &line);
            ui.rounded(left + 8.0, foot + 22.0, status_w, 8.0, 4.0, color::RAISED);
            let done = (status_w * shared.fraction.clamp(0.0, 1.0)).max(8.0);
            ui.rounded(left + 8.0, foot + 22.0, done, 8.0, 4.0, color::ACCENT);
        } else if let Some((notice, failed)) = &card.notice {
            let ink = if *failed { color::DANGER } else { color::TEXT };
            let mut y = foot;
            for line in wrapped(&ui, Face::Regular, 12.0, status_w, notice)
                .iter()
                .take(2)
            {
                ui.text(Face::Regular, 12.0, left + 8.0, y, ink, line);
                y += 17.0;
            }
        }
        ui.finish();
        *card.buttons.borrow_mut() = drawn;
    }

    /// While the screen is open it takes every touch; a lifted finger on a button acts.
    pub(super) fn catalog_touch(&mut self, touch: &Touch) -> bool {
        if !self.catalog.shown {
            return false;
        }
        if touch.phase != TouchPhase::Ended {
            return true;
        }
        let [w, h] = self.touch_size();
        let d = density(w as f32, h as f32);
        let at = [touch.location.x as f32 / d, touch.location.y as f32 / d];
        let act = self
            .catalog
            .buttons
            .borrow()
            .iter()
            .find(|(r, _)| {
                at[0] >= r[0] && at[0] <= r[0] + r[2] && at[1] >= r[1] && at[1] <= r[1] + r[3]
            })
            .map(|(_, act)| act.clone());
        let card = &mut self.catalog;
        // A tap anywhere else leaves the search box; what was typed still runs.
        if !matches!(act, Some(Act::Search | Act::Clear)) {
            card.typing = false;
        }
        let Some(act) = act else {
            return true;
        };
        match act {
            Act::Close => card.shown = false,
            Act::Shelf(shelf) => {
                card.shelf = shelf;
                card.offset = 0;
                card.typed_at = None;
                card.notice = None;
                self.catalog_search();
            }
            Act::Search => card.typing = true,
            Act::Clear => {
                card.query.clear();
                card.offset = 0;
                card.typed_at = None;
                self.catalog_search();
            }
            Act::Everything => {
                card.everything = !card.everything;
                card.offset = 0;
                self.catalog_search();
            }
            Act::Back => {
                card.offset = card.offset.saturating_sub(card.page);
                self.catalog_search();
            }
            Act::More => {
                card.offset += card.page;
                self.catalog_search();
            }
            Act::Install(index) => self.catalog_install(index),
        }
        true
    }
}
