//! Android: the catalog, where a player finds and installs mods, resource packs and shader packs
//! without leaving the game. It opens from the Mods, Resource Packs and Shader Packs pages, on their
//! shelf. Searching, checking and installing are the desktop launcher's mod browser (the
//! `starling-catalog` crate); this is its screen. The list's pages and the finger on it are
//! `starling_catalog::list`, where they have tests.
use super::Game;
use super::native_builds::{density, wrapped};
use horizon_client::{
    hud::HudBatch,
    ui_theme::{Face, Ui, color},
};
use starling_catalog::{
    Done, Shelf,
    list::{self, Ask, Feed, Scroller, Tail},
};
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
// In UI units: a landscape phone's short side is 700 of them (`density`), about 0.1 mm each. The
// system's smallest finger target, 48 dp, is about 78 of them.
const MARGIN: f32 = 16.0;
/// What's above and below the list.
const HEAD_H: f32 = 158.0;
const FOOT_H: f32 = 78.0;
/// A row and the gap under it: three and a half rows show on a phone.
const ROW_H: f32 = 132.0;
const ROW_GAP: f32 = 12.0;
/// A row's button.
const ROW_BUTTON_W: f32 = 190.0;
const ROW_BUTTON_H: f32 = 80.0;
/// The line at the end of the list.
const END_H: f32 = 96.0;
const CLEAR_W: f32 = 96.0;
/// Text sizes: about the system's 16 and 14 sp.
const TITLE_TEXT: f32 = 26.0;
const BODY_TEXT: f32 = 22.0;
const BUTTON_TEXT: f32 = 22.0;
/// A line of `BODY_TEXT` (`Ui::text`).
const BODY_LINE: f32 = 32.0;
/// The next page is asked for when the end of the list is this close to what shows.
const NEAR_END: f32 = 3.0 * ROW_H;
/// What the screen leaves free while typing: the system's navigation bar comes back with the
/// keyboard, over the right edge in landscape, and takes the touches there. 48 dp, at most this
/// much of a phone's width.
const NAV_BAR_SHARE: f32 = 0.08;
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
    Retry,
    Install(usize),
}

#[derive(Default)]
struct Shared {
    /// The list: the searches' threads add to it.
    feed: Feed,
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
    /// How far the list is scrolled, and the finger on the screen.
    list: Scroller,
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

/// `text` in at most `most` lines that fit `width`, the last cut with dots if it must be.
fn fitted_lines(
    ui: &Ui<'_>,
    face: Face,
    size: f32,
    width: f32,
    most: usize,
    text: &str,
) -> Vec<String> {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut lines = wrapped(ui, face, size, width, &text);
    if lines.len() > most {
        let rest = lines.split_off(most - 1).join(" ");
        lines.push(rest);
    }
    lines
        .iter()
        .map(|line| fitted(ui, face, size, width, line))
        .collect()
}

/// `text` in the middle of `rect`.
fn label(ui: &mut Ui<'_>, rect: [f32; 4], ink: u32, text: &str) {
    let width = ui.measure(Face::Semibold, BUTTON_TEXT, text);
    ui.text_line(
        Face::Semibold,
        BUTTON_TEXT,
        rect[3],
        rect[0] + (rect[2] - width) / 2.0,
        rect[1],
        ink,
        text,
    );
}

/// A button's look: filled with the accent when `lit`.
fn plate(ui: &mut Ui<'_>, rect: [f32; 4], text: &str, lit: bool) {
    let (fill, ink) = if lit {
        (color::ACCENT, color::ON_ACCENT)
    } else {
        (color::RAISED, color::TEXT)
    };
    ui.rounded(rect[0], rect[1], rect[2], rect[3], 10.0, fill);
    label(ui, rect, ink, text);
}

/// A button above or below the list.
fn button(
    ui: &mut Ui<'_>,
    rect: [f32; 4],
    text: &str,
    lit: bool,
    act: Act,
    drawn: &mut Vec<([f32; 4], Act)>,
) {
    plate(ui, rect, text, lit);
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

/// The list's height with `rows` rows and its last line.
fn content_h(rows: usize) -> f32 {
    rows as f32 * ROW_H + END_H
}

/// What the last line says while a page is on its way.
fn loading_line(shelf: Shelf, first: bool) -> String {
    let what = match shelf {
        Shelf::Mods => "mods",
        Shelf::ResourcePacks => "resource packs",
        Shelf::ShaderPacks => "shader packs",
    };
    if first {
        format!("Loading {what}...")
    } else {
        format!("Loading more {what}...")
    }
}

/// The rows that show and the list's last line, under what's above and below them.
fn draw_list(
    ui: &mut Ui<'_>,
    card: &Catalog,
    shared: &Shared,
    edge: f32,
    drawn: &mut Vec<([f32; 4], Act)>,
) {
    let (top, bottom) = (HEAD_H, ui.h - FOOT_H);
    let row_w = edge - MARGIN;
    let text_w = row_w - ROW_BUTTON_W - 44.0;
    let rows = shared.feed.rows();
    let scrolled = card.list.offset;
    for i in list::rows_shown(scrolled, bottom - top, ROW_H, rows.len()) {
        let project = &rows[i];
        let y = top + i as f32 * ROW_H - scrolled;
        let row = ROW_H - ROW_GAP;
        ui.rounded(MARGIN, y, row_w, row, 12.0, color::RAISED);
        let title = if starling_catalog::is_native_mod(project) {
            format!("{} (native mod)", project.title)
        } else {
            project.title.clone()
        };
        let title = fitted(ui, Face::Semibold, TITLE_TEXT, text_w, &title);
        ui.text(
            Face::Semibold,
            TITLE_TEXT,
            MARGIN + 14.0,
            y + 8.0,
            color::TEXT,
            &title,
        );
        let about = starling_catalog::caution(project).unwrap_or_else(|| project.summary.clone());
        let mut line_y = y + 46.0;
        for line in fitted_lines(ui, Face::Regular, BODY_TEXT, text_w, 2, &about) {
            ui.text(
                Face::Regular,
                BODY_TEXT,
                MARGIN + 14.0,
                line_y,
                color::MUTED,
                &line,
            );
            line_y += BODY_LINE;
        }
        let rect = [
            MARGIN + row_w - ROW_BUTTON_W - 16.0,
            y + (row - ROW_BUTTON_H) / 2.0,
            ROW_BUTTON_W,
            ROW_BUTTON_H,
        ];
        if shared.installing.as_deref() == Some(project.title.as_str()) {
            label(ui, rect, color::MUTED, "Installing");
        } else if card.installed.contains(&project.id) {
            label(ui, rect, color::MUTED, "Installed");
        } else {
            plate(ui, rect, "Install", true);
            if let Some(part) = list::shown_part(rect, top, bottom) {
                drawn.push((part, Act::Install(i)));
            }
        }
    }

    let y = top + content_h(rows.len()) - END_H - scrolled;
    if y >= bottom {
        return;
    }
    let (line, ink) = match shared.feed.tail() {
        Tail::Loading => (loading_line(card.shelf, rows.is_empty()), color::MUTED),
        Tail::More => (loading_line(card.shelf, false), color::MUTED),
        Tail::End if rows.is_empty() => ("Nothing found.".to_owned(), color::MUTED),
        Tail::End => ("That's all of them.".to_owned(), color::MUTED),
        Tail::Failed(why) => (why.clone(), color::TEXT),
    };
    let lines = fitted_lines(ui, Face::Regular, BODY_TEXT, text_w, 2, &line);
    let mut line_y = y + (END_H - lines.len() as f32 * BODY_LINE) / 2.0;
    for line in lines {
        ui.text(Face::Regular, BODY_TEXT, MARGIN + 14.0, line_y, ink, &line);
        line_y += BODY_LINE;
    }
    if matches!(shared.feed.tail(), Tail::Failed(_)) {
        let rect = [
            MARGIN + row_w - ROW_BUTTON_W - 16.0,
            y + (END_H - ROW_BUTTON_H) / 2.0,
            ROW_BUTTON_W,
            ROW_BUTTON_H,
        ];
        plate(ui, rect, "Try again", false);
        if let Some(part) = list::shown_part(rect, top, bottom) {
            drawn.push((part, Act::Retry));
        }
    }
}

/// The title, Close, the three shelves and the search box.
fn draw_head(ui: &mut Ui<'_>, card: &Catalog, edge: f32, drawn: &mut Vec<([f32; 4], Act)>) {
    ui.text_line(
        Face::Semibold,
        TITLE_TEXT,
        62.0,
        MARGIN,
        8.0,
        color::TEXT,
        "Catalog",
    );
    button(
        ui,
        [edge - 130.0, 8.0, 130.0, 62.0],
        "Close",
        false,
        Act::Close,
        drawn,
    );

    const SHELF_Y: f32 = 78.0;
    const SHELF_H: f32 = 72.0;
    let mut x = MARGIN;
    for (shelf, name) in SHELVES {
        let width = ui.measure(Face::Semibold, BUTTON_TEXT, name) + 44.0;
        button(
            ui,
            [x, SHELF_Y, width, SHELF_H],
            name,
            card.shelf == shelf,
            Act::Shelf(shelf),
            drawn,
        );
        x += width + 8.0;
    }
    let search = [x + 4.0, SHELF_Y, (edge - x - 4.0).max(120.0), SHELF_H];
    ui.rounded(
        search[0],
        search[1],
        search[2],
        search[3],
        10.0,
        color::RAISED,
    );
    if card.typing {
        ui.border(
            search[0],
            search[1],
            search[2],
            search[3],
            10.0,
            color::ACCENT,
        );
    }
    let (typed, ink) = if card.query.is_empty() && !card.typing {
        ("Search...", color::MUTED)
    } else {
        (card.query.as_str(), color::TEXT)
    };
    let typed = fitted(
        ui,
        Face::Regular,
        BODY_TEXT,
        search[2] - 32.0 - CLEAR_W,
        typed,
    );
    ui.text_line(
        Face::Regular,
        BODY_TEXT,
        search[3],
        search[0] + 16.0,
        search[1],
        ink,
        &typed,
    );
    if card.typing {
        let end = search[0] + 16.0 + ui.measure(Face::Regular, BODY_TEXT, &typed);
        ui.fill(end + 1.0, search[1] + 18.0, 2.0, 36.0, color::ACCENT);
    }
    if !card.query.is_empty() {
        let clear = [
            search[0] + search[2] - CLEAR_W,
            search[1],
            CLEAR_W,
            search[3],
        ];
        label(ui, clear, color::MUTED, "Clear");
        drawn.push((clear, Act::Clear));
    }
    drawn.push((search, Act::Search));
}

/// The versions toggle on its shelf, and what an install says.
fn draw_foot(
    ui: &mut Ui<'_>,
    card: &Catalog,
    shared: &Shared,
    edge: f32,
    drawn: &mut Vec<([f32; 4], Act)>,
) {
    let foot = ui.h - FOOT_H + 7.0;
    let mut right = edge;
    if card.shelf == Shelf::ResourcePacks {
        let name = if card.everything {
            "Other game versions: On"
        } else {
            "Other game versions: Off"
        };
        let width = ui.measure(Face::Semibold, BUTTON_TEXT, name) + 44.0;
        right -= width;
        button(
            ui,
            [right, foot, width, 64.0],
            name,
            card.everything,
            Act::Everything,
            drawn,
        );
        right -= 12.0;
    }
    let status_w = (right - MARGIN).max(0.0);
    if shared.installing.is_some() {
        let line = fitted(ui, Face::Regular, BODY_TEXT, status_w, &shared.line);
        ui.text(Face::Regular, BODY_TEXT, MARGIN, foot, color::TEXT, &line);
        ui.rounded(MARGIN, foot + 38.0, status_w, 12.0, 6.0, color::RAISED);
        let done = (status_w * shared.fraction.clamp(0.0, 1.0)).max(12.0);
        ui.rounded(MARGIN, foot + 38.0, done, 12.0, 6.0, color::ACCENT);
    } else if let Some((notice, failed)) = &card.notice {
        let ink = if *failed { color::DANGER } else { color::TEXT };
        let mut y = foot;
        for line in fitted_lines(ui, Face::Regular, BODY_TEXT, status_w, 2, notice) {
            ui.text(Face::Regular, BODY_TEXT, MARGIN, y, ink, &line);
            y += BODY_LINE;
        }
    }
}

impl Game<'_> {
    /// A page's Catalog button: the screen, on that page's shelf.
    pub(super) fn open_catalog_on(&mut self, shelf: Shelf) {
        self.catalog.shelf = shelf;
        self.open_catalog();
    }

    /// The screen, on the shelf it was on.
    pub(super) fn open_catalog(&mut self) {
        starling_catalog::set_game_home(Self::game_dir());
        let card = &mut self.catalog;
        card.shown = true;
        card.notice = None;
        card.installed = starling_catalog::installed_projects(&Self::game_dir());
        self.catalog_search();
    }

    /// Whether the keyboard types in the search box (`text_context`).
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
        self.catalog_search();
    }

    /// A new list for the shelf and search as they are: back to the top, its first page asked for.
    fn catalog_search(&mut self) {
        self.catalog.list.reset();
        let ask = self
            .catalog
            .shared
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .feed
            .restart();
        self.catalog_ask(ask);
    }

    /// Asks for a page on its own thread; its answer adds to the list when it comes.
    fn catalog_ask(&self, ask: Ask) {
        let card = &self.catalog;
        let shared = card.shared.clone();
        let worker = shared.clone();
        let (shelf, query, everything) = (card.shelf, card.query.clone(), card.everything);
        let started = std::thread::Builder::new()
            .name("catalog search".into())
            .spawn(move || {
                let found =
                    starling_catalog::search(shelf, &query, everything, ask.offset, list::PAGE);
                if let Err(e) = &found {
                    log::warn!("Horizon: the catalog's search failed: {e}");
                }
                worker
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .feed
                    .answer(ask, found);
            });
        if let Err(e) = started {
            shared
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .feed
                .answer(ask, Err(format!("The search didn't start: {e}")));
        }
    }

    /// How tall the part of the list that shows is, and the whole list.
    fn catalog_list_size(&self) -> (f32, f32) {
        let [w, h] = self.touch_size();
        let view = h as f32 / density(w as f32, h as f32) - HEAD_H - FOOT_H;
        let rows = self
            .catalog
            .shared
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .feed
            .rows()
            .len();
        (view, content_h(rows))
    }

    /// While the screen is open: the list inside its ends, and its next page once the end is near.
    fn catalog_keep_up(&mut self) {
        let (view, content) = self.catalog_list_size();
        let card = &mut self.catalog;
        card.list.clamp(content - view);
        if !list::near_end(card.list.offset, view, content, NEAR_END) {
            return;
        }
        let ask = card
            .shared
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .feed
            .next();
        if let Some(ask) = ask {
            self.catalog_ask(ask);
        }
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
            self.catalog.notice = None;
            self.catalog_search();
        }
        if self.catalog.shown {
            self.catalog_keep_up();
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
                    // The Resource Packs page lists what was read when Options opened, and its
                    // folder watcher only sees what changes with the page open. A selection
                    // made on the page and not yet applied stays.
                    Done::ResourcePack => {
                        let infos = super::packs::pack_infos(
                            &self.vanilla_root(),
                            &self.server_packs.active,
                        );
                        self.ui.options.update_pack_infos(infos);
                    }
                    Done::ContentMod => {}
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
        let worker = shared.clone();
        let project = {
            let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
            if s.installing.is_some() {
                return;
            }
            let Some(project) = s.feed.rows().get(index).cloned() else {
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
        let title = project.title.clone();
        let started = std::thread::Builder::new()
            .name("catalog install".into())
            .spawn(move || {
                let progress = |line: &str, fraction: f32| {
                    let mut s = worker.lock().unwrap_or_else(PoisonError::into_inner);
                    line.clone_into(&mut s.line);
                    s.fraction = fraction;
                };
                // However it ends, the screen stops saying Installing: nothing else can install
                // while it does.
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    starling_catalog::install(&project, everything, &home, &progress)
                }))
                .unwrap_or_else(|_| Err(format!("Installing {} stopped.", project.title)));
                let mut s = worker.lock().unwrap_or_else(PoisonError::into_inner);
                s.installing = None;
                s.finished = Some((project.title, result));
            });
        if let Err(e) = started {
            let mut s = shared.lock().unwrap_or_else(PoisonError::into_inner);
            s.installing = None;
            let why = format!("Installing {title} didn't start: {e}");
            s.finished = Some((title, Err(why)));
        }
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
        let edge = w - MARGIN - if card.typing { w * NAV_BAR_SHARE } else { 0.0 };
        let mut drawn = Vec::new();
        ui.fill(0.0, 0.0, w, h, color::BG);
        draw_list(&mut ui, card, &shared, edge, &mut drawn);
        // The rows go under these two.
        ui.fill(0.0, 0.0, w, HEAD_H, color::BG);
        ui.fill(0.0, h - FOOT_H, w, FOOT_H, color::BG);
        draw_head(&mut ui, card, edge, &mut drawn);
        draw_foot(&mut ui, card, &shared, edge, &mut drawn);
        ui.finish();
        *card.buttons.borrow_mut() = drawn;
    }

    /// While the screen is open it takes every touch. A finger that moves scrolls the list; one
    /// that lifts where it came down acts on the button there.
    pub(super) fn catalog_touch(&mut self, touch: &Touch) -> bool {
        if !self.catalog.shown {
            return false;
        }
        let [w, h] = self.touch_size();
        let d = density(w as f32, h as f32);
        let at = [touch.location.x as f32 / d, touch.location.y as f32 / d];
        let bottom = h as f32 / d - FOOT_H;
        let (view, content) = self.catalog_list_size();
        let most = content - view;
        let card = &mut self.catalog;
        let tapped = match touch.phase {
            TouchPhase::Started => {
                let on_list = at[1] >= HEAD_H && at[1] < bottom;
                card.list.press(touch.id, at, on_list);
                None
            }
            TouchPhase::Moved => {
                card.list.moved(touch.id, at, most);
                None
            }
            TouchPhase::Ended => card.list.lift(touch.id, at, most),
            TouchPhase::Cancelled => {
                card.list.cancel(touch.id);
                None
            }
        };
        let Some(at) = tapped else {
            return true;
        };
        let act = card
            .buttons
            .borrow()
            .iter()
            .find(|(r, _)| {
                at[0] >= r[0] && at[0] <= r[0] + r[2] && at[1] >= r[1] && at[1] <= r[1] + r[3]
            })
            .map(|(_, act)| act.clone());
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
                card.typed_at = None;
                card.notice = None;
                self.catalog_search();
            }
            Act::Search => card.typing = true,
            Act::Clear => {
                card.query.clear();
                card.typed_at = None;
                self.catalog_search();
            }
            Act::Everything => {
                card.everything = !card.everything;
                self.catalog_search();
            }
            Act::Retry => {
                let ask = card
                    .shared
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .feed
                    .retry();
                if let Some(ask) = ask {
                    self.catalog_ask(ask);
                }
            }
            Act::Install(index) => self.catalog_install(index),
        }
        true
    }
}
