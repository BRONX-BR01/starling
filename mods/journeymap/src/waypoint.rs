//! Waypoints and their on-disk text form (one tab-separated line each).
use std::fmt;

pub const COLORS: [u32; 8] =
    [0xFF5555, 0x55FF55, 0x5555FF, 0xFFFF55, 0xFF55FF, 0x55FFFF, 0xFFAA00, 0xFFFFFF];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Waypoint {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub z: i32,
    pub dim: String,
    pub rgb: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub struct DecodeError {
    pub line: usize,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "waypoints: bad line {}", self.line)
    }
}

#[derive(Debug, Default)]
pub struct Waypoints {
    items: Vec<Waypoint>,
}

fn clean(name: &str) -> String {
    let s: String = name.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    s.trim().chars().take(32).collect()
}

impl Waypoints {
    pub fn add(&mut self, name: &str, x: i32, y: i32, z: i32, dim: &str) -> &Waypoint {
        let mut name = clean(name);
        if name.is_empty() {
            let n = (1..).find(|n| !self.items.iter().any(|w| w.name == format!("WP{n}")));
            name = format!("WP{}", n.unwrap_or(1));
        }
        let rgb = COLORS[self.items.len() % COLORS.len()];
        self.items.push(Waypoint { name, x, y, z, dim: dim.to_owned(), rgb });
        &self.items[self.items.len() - 1]
    }

    pub fn remove_named(&mut self, name: &str) -> Option<Waypoint> {
        let i = self.items.iter().position(|w| w.name.eq_ignore_ascii_case(name.trim()))?;
        Some(self.items.remove(i))
    }

    pub fn find(&self, name: &str) -> Option<&Waypoint> {
        self.items.iter().find(|w| w.name.eq_ignore_ascii_case(name.trim()))
    }

    pub fn remove_at(&mut self, i: usize) -> Option<Waypoint> {
        (i < self.items.len()).then(|| self.items.remove(i))
    }

    pub fn all(&self) -> &[Waypoint] {
        &self.items
    }

    pub fn in_dim<'a>(&'a self, dim: &'a str) -> impl Iterator<Item = (usize, &'a Waypoint)> + 'a {
        self.items.iter().enumerate().filter(move |(_, w)| w.dim == dim)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut s = String::new();
        for w in &self.items {
            s.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{:06x}\n", w.name, w.x, w.y, w.z, w.dim, w.rgb));
        }
        s.into_bytes()
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let text = std::str::from_utf8(bytes).map_err(|_| DecodeError { line: 0 })?;
        let mut items = Vec::new();
        for (i, line) in text.lines().enumerate().filter(|(_, l)| !l.is_empty()) {
            let bad = || DecodeError { line: i + 1 };
            let f: Vec<&str> = line.split('\t').collect();
            let [name, x, y, z, dim, rgb] = f[..] else { return Err(bad()) };
            items.push(Waypoint {
                name: name.to_owned(),
                x: x.parse().map_err(|_| bad())?,
                y: y.parse().map_err(|_| bad())?,
                z: z.parse().map_err(|_| bad())?,
                dim: dim.to_owned(),
                rgb: u32::from_str_radix(rgb, 16).map_err(|_| bad())?,
            });
        }
        Ok(Self { items })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_names() {
        let mut w = Waypoints::default();
        w.add("Casa\tdo Igor", 10, 64, -20, "minecraft:overworld");
        w.add("", 0, 70, 0, "minecraft:the_nether");
        let back = Waypoints::decode(&w.encode()).unwrap();
        assert_eq!(back.all(), w.all());
        assert_eq!(back.all()[0].name, "Casa do Igor");
        assert_eq!(back.all()[1].name, "WP1");
        assert_eq!(back.in_dim("minecraft:overworld").count(), 1);
    }

    #[test]
    fn remove_and_bad_input() {
        let mut w = Waypoints::default();
        w.add("A", 1, 2, 3, "d");
        assert!(w.remove_named("a").is_some());
        assert!(w.remove_at(0).is_none());
        assert_eq!(Waypoints::decode(b"a\t1\n").unwrap_err(), DecodeError { line: 1 });
    }
}
