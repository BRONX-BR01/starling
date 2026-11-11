//! Corner overlay: the engine's round minimap plus real time, game clock, coordinates and biome.
use crate::horizon::mods::{game, hud, render};

const PERIOD: u64 = 10;
/// Blank lines that keep the text below the minimap (same corner).
const PAD_LINES: usize = 11;
const WHITE: u32 = 0xFF_FFFF;
/// Brasilia time; change it if the device is somewhere else.
const UTC_OFFSET_HOURS: i64 = -3;

pub fn enable() {
    render::set_minimap(Some(render::Minimap {
        corner: hud::Corner::TopRight,
        size: 96.0,
        blocks_per_pixel: 1.0,
        rotate: true,
        round: true,
    }));
}

fn phase(t: u64) -> &'static str {
    match t % 24_000 {
        0..=11_999 => "Daytime",
        12_000..=13_799 => "Sunset",
        13_800..=22_199 => "Night",
        _ => "Sunrise",
    }
}

pub fn clock_text(day_time: u64) -> String {
    let t = day_time % 24_000;
    let hours = (t / 1_000 + 6) % 24;
    let minutes = (t % 1_000) * 60 / 1_000;
    format!("{hours:02}:{minutes:02} {}", phase(t))
}

pub fn real_time_text(unix_secs: u64, offset_hours: i64) -> String {
    let secs = i64::try_from(unix_secs).unwrap_or(0);
    let local = secs.saturating_add(offset_hours.saturating_mul(3_600)).rem_euclid(86_400);
    format!("{:02}:{:02}:{:02}", local / 3_600, local % 3_600 / 60, local % 60)
}

pub fn biome_text(id: &str) -> String {
    let name = id.rsplit(':').next().unwrap_or(id);
    name.split('_')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().chain(c).collect::<String>(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn coords_text(x: f64, y: f64, z: f64) -> String {
    let (x, y, z) = (x.floor() as i64, y.floor() as i64, z.floor() as i64);
    format!("x: {x}, z: {z}, y: {y} ({})", y.div_euclid(16))
}

pub fn update(tick: u64) {
    if tick % PERIOD != 0 {
        return;
    }
    let mut lines: Vec<hud::Line> = (0..PAD_LINES)
        .map(|_| hud::Line { text: " ".to_string(), color: WHITE })
        .collect();
    lines.push(hud::Line {
        text: real_time_text(game::wall_clock(), UTC_OFFSET_HOURS),
        color: WHITE,
    });
    if let Some(c) = game::get_clock() {
        lines.push(hud::Line { text: clock_text(c.day_time), color: WHITE });
    }
    if let Some(p) = game::get_player() {
        lines.push(hud::Line { text: coords_text(p.x, p.y, p.z), color: WHITE });
    }
    if let Some(b) = game::get_biome() {
        lines.push(hud::Line { text: biome_text(&b), color: WHITE });
    }
    hud::set_panel(hud::Corner::TopRight, &lines);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_matches_the_original_screenshot() {
        assert_eq!(clock_text(2_700), "08:42 Daytime");
        assert_eq!(clock_text(12_000), "18:00 Sunset");
        assert_eq!(clock_text(18_000), "00:00 Night");
        assert_eq!(clock_text(23_000), "05:00 Sunrise");
    }

    #[test]
    fn coords_show_the_chunk_slice() {
        assert_eq!(coords_text(236.4, 73.0, 1.9), "x: 236, z: 1, y: 73 (4)");
        assert_eq!(coords_text(-0.5, -1.0, 0.0), "x: -1, z: 0, y: -1 (-1)");
    }

    #[test]
    fn real_time_uses_the_offset_and_wraps() {
        assert_eq!(real_time_text(70_001, -3), "16:26:41");
        assert_eq!(real_time_text(0, -3), "21:00:00");
    }

    #[test]
    fn biome_ids_become_readable_names() {
        assert_eq!(biome_text("minecraft:plains"), "Plains");
        assert_eq!(biome_text("minecraft:dark_forest"), "Dark Forest");
    }
}
