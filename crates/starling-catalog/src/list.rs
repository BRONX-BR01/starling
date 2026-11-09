//! The catalog's list apart from its screen (`game/mod_catalog.rs`, which only compiles for
//! Android): the pages added up, and the finger that scrolls them. Distances are the screen's UI
//! units.
use crate::browser::Project;
use std::ops::Range;

/// The rows one request asks for. A source's offset moves by this, whatever a page brought.
pub const PAGE: usize = 20;
/// How far a finger moves before it drags instead of tapping: a 60th of a phone's short side, as
/// the game's other lists (`touch::slop`).
pub const SLOP: f32 = 12.0;

/// What a player reads when the network failed.
const NO_CONNECTION: &str = "Couldn't reach the catalog. Check your connection and try again.";

/// The words of an error that came from the network or the server's answer.
const NETWORK_WORDS: [&str; 13] = [
    "no connection",
    "network error",
    "connection",
    "timed out",
    "timeout",
    "dns",
    "lookup",
    "unreachable",
    "reset by peer",
    "broken pipe",
    "software caused",
    "transport",
    "interrupted",
];

/// The words of an error that is for the log, not the player.
const TECHNICAL_WORDS: [&str; 5] = ["://", "os error", "error:", "status code", "{"];

/// `raw`, an error for the log, as one plain sentence for the screen: no connection when the
/// network failed, `otherwise` when what it says is only technical, and `raw` itself when it is
/// already a sentence a player can read.
pub fn friendly(raw: &str, otherwise: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    if NETWORK_WORDS.iter().any(|w| lower.contains(w)) {
        NO_CONNECTION.to_owned()
    } else if TECHNICAL_WORDS.iter().any(|w| lower.contains(w)) {
        otherwise.to_owned()
    } else {
        raw.to_owned()
    }
}

/// What the list ends with.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Tail {
    /// A page is on its way.
    #[default]
    Loading,
    /// The next page waits for the end of the list to come near.
    More,
    /// A page came back empty: that was all.
    End,
    /// The last page failed, and why. Nothing asks again until the player does.
    Failed(String),
}

/// A page asked for. Its answer only counts while the list is still the one that asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ask {
    list: u64,
    pub offset: usize,
}

/// The rows so far, and what comes after them.
#[derive(Debug, Default)]
pub struct Feed {
    /// Which list this is: a new search or shelf is a new one.
    list: u64,
    rows: Vec<Project>,
    /// Where the next page starts in the source's own order.
    offset: usize,
    tail: Tail,
}

impl Feed {
    pub fn rows(&self) -> &[Project] {
        &self.rows
    }

    pub fn tail(&self) -> &Tail {
        &self.tail
    }

    /// A new search or shelf: the rows go, and its first page is asked for.
    pub fn restart(&mut self) -> Ask {
        self.list += 1;
        self.rows.clear();
        self.offset = 0;
        self.ask()
    }

    /// The next page, if the list has more and no page is on its way.
    pub fn next(&mut self) -> Option<Ask> {
        (self.tail == Tail::More).then(|| self.ask())
    }

    /// The page that failed, again.
    pub fn retry(&mut self) -> Option<Ask> {
        matches!(self.tail, Tail::Failed(_)).then(|| self.ask())
    }

    fn ask(&mut self) -> Ask {
        self.tail = Tail::Loading;
        Ask {
            list: self.list,
            offset: self.offset,
        }
    }

    /// What came for `ask`. A short page isn't the end: only an empty one is. A row the list has
    /// already is left out (a source's order can shift between two pages).
    pub fn answer(&mut self, ask: Ask, found: Result<Vec<Project>, String>) {
        if self.tail != Tail::Loading || ask.list != self.list || ask.offset != self.offset {
            return;
        }
        self.tail = match found {
            Err(why) => Tail::Failed(why),
            Ok(page) if page.is_empty() => Tail::End,
            Ok(page) => {
                self.offset += PAGE;
                for project in page {
                    let same = |p: &Project| p.source == project.source && p.id == project.id;
                    if !self.rows.iter().any(same) {
                        self.rows.push(project);
                    }
                }
                Tail::More
            }
        };
    }
}

/// Where the list is scrolled to, and the finger on the screen.
#[derive(Debug, Default)]
pub struct Scroller {
    /// How far down the list is.
    pub offset: f32,
    finger: Option<Finger>,
}

#[derive(Debug)]
struct Finger {
    id: u64,
    pressed: [f32; 2],
    /// It came down on the list, so a drag moves the list.
    on_list: bool,
    /// Once it drags: the height it took hold at, and where the list was then.
    grip: Option<(f32, f32)>,
}

impl Scroller {
    /// A finger came down. Another one, while one is down, does nothing.
    pub fn press(&mut self, id: u64, at: [f32; 2], on_list: bool) {
        if self.finger.as_ref().is_none_or(|f| f.id == id) {
            self.finger = Some(Finger {
                id,
                pressed: at,
                on_list,
                grip: None,
            });
        }
    }

    /// A finger moved. Past [`SLOP`] it drags, and the list follows it from there, down to `most`.
    pub fn moved(&mut self, id: u64, at: [f32; 2], most: f32) {
        let Some(finger) = self.finger.as_mut().filter(|f| f.id == id) else {
            return;
        };
        if finger.grip.is_none() {
            let (dx, dy) = (at[0] - finger.pressed[0], at[1] - finger.pressed[1]);
            if dx.hypot(dy) < SLOP {
                return;
            }
            finger.grip = Some((at[1], self.offset));
        }
        if let (true, Some((y, offset))) = (finger.on_list, finger.grip) {
            self.offset = (offset + y - at[1]).clamp(0.0, most.max(0.0));
        }
    }

    /// A finger lifted at `at`. Where it came down, if it never dragged: that is a tap.
    pub fn lift(&mut self, id: u64, at: [f32; 2], most: f32) -> Option<[f32; 2]> {
        self.moved(id, at, most);
        let finger = self.finger.take_if(|f| f.id == id)?;
        finger.grip.is_none().then_some(finger.pressed)
    }

    /// The system took the finger away: no tap.
    pub fn cancel(&mut self, id: u64) {
        self.finger.take_if(|f| f.id == id);
    }

    /// Back to the top, and a finger still down acts no more.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Back inside the list, which may have got shorter (the screen turned).
    pub fn clamp(&mut self, most: f32) {
        self.offset = self.offset.clamp(0.0, most.max(0.0));
    }
}

/// The rows of `count`, each `row` tall, that show in a list `view` tall scrolled to `offset`.
pub fn rows_shown(offset: f32, view: f32, row: f32, count: usize) -> Range<usize> {
    let first = (offset / row).floor().max(0.0) as usize;
    let end = ((offset + view) / row).ceil().max(0.0) as usize;
    first.min(count)..end.min(count)
}

/// Whether the end of a list `content` tall is within `margin` of what shows.
pub fn near_end(offset: f32, view: f32, content: f32, margin: f32) -> bool {
    offset + view + margin >= content
}

/// The part of `rect` (x, y, width, height) between `top` and `bottom`, if any: a button half
/// under what's above the list only takes touches where it shows.
pub fn shown_part(rect: [f32; 4], top: f32, bottom: f32) -> Option<[f32; 4]> {
    let y0 = rect[1].max(top);
    let y1 = (rect[1] + rect[3]).min(bottom);
    (y1 > y0).then_some([rect[0], y0, rect[2], y1 - y0])
}
