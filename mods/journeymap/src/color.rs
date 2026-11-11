//! Block name -> map colour (the atlas is for the post pass, not for this).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Paint {
    Fixed(u32),
    Grass,
    Foliage,
    Water,
}

/// Grass, foliage and water colours for a column the world did not tint.
const FALLBACK: [u32; 3] = [0x7CBD6B, 0x4A7A32, 0x3F76E4];

const TABLE: &[(&[&str], Paint)] = &[
    (&["cherry_leaves"], Paint::Fixed(0xE5A3C0)),
    (&["leaves"], Paint::Foliage),
    (&["water", "kelp", "seagrass", "bubble_column"], Paint::Water),
    (&["lava", "magma"], Paint::Fixed(0xD96514)),
    (&["snow", "powder"], Paint::Fixed(0xFFFFFF)),
    (&["soul_sand", "soul_soil"], Paint::Fixed(0x51402F)),
    (&["red_sand"], Paint::Fixed(0xBE6621)),
    (&["sand"], Paint::Fixed(0xF7E9A3)),
    (&["terracotta"], Paint::Fixed(0xD87F33)),
    (&["grass", "fern"], Paint::Grass),
    (&["mycelium"], Paint::Fixed(0x6F6C7A)),
    (&["dirt", "podzol", "mud", "farmland", "rooted"], Paint::Fixed(0x976D4D)),
    (&["gravel"], Paint::Fixed(0x83807E)),
    (&["deepslate", "blackstone", "basalt"], Paint::Fixed(0x505050)),
    (&["netherrack", "nylium", "crimson"], Paint::Fixed(0x701F1F)),
    (&["log", "wood", "planks", "stem"], Paint::Fixed(0x8F7748)),
    (&["cactus", "bamboo", "sugar_cane", "moss", "vine", "lily"], Paint::Fixed(0x4C7F19)),
    (&["obsidian"], Paint::Fixed(0x15121F)),
];

/// `None` for air.
pub fn paint_for(name: &str) -> Option<Paint> {
    let p = name.rsplit(':').next().unwrap_or(name);
    if matches!(p, "air" | "cave_air" | "void_air") {
        return None;
    }
    if p == "ice" || p.ends_with("_ice") {
        return Some(Paint::Fixed(0xA0A0FF));
    }
    let hit = TABLE
        .iter()
        .find(|(keys, _)| keys.iter().any(|k| p.contains(k)))
        .map(|(_, paint)| *paint);
    Some(hit.unwrap_or(Paint::Fixed(0x7F7F7F)))
}

/// `tints` = the column's grass, foliage and water colours (0 = untinted).
pub fn resolve(paint: Paint, tints: [u32; 3]) -> u32 {
    let tint = |i: usize| if tints[i] == 0 { FALLBACK[i] } else { tints[i] & 0xFF_FFFF };
    match paint {
        Paint::Fixed(c) => c,
        Paint::Grass => tint(0),
        Paint::Foliage => tint(1),
        Paint::Water => tint(2),
    }
}

/// Relief shading: `delta` > 0 lighter, < 0 darker, then 5-bit channels so
/// near colours merge into one rectangle.
pub fn shade(rgb: u32, delta: i32) -> u32 {
    let (num, den) = match delta.signum() {
        1 => (115u32, 100u32),
        -1 => (85, 100),
        _ => (100, 100),
    };
    let ch = |shift: u32| {
        let c = (rgb >> shift) & 0xFF;
        (c.saturating_mul(num) / den).min(255) & 0xF8
    };
    (ch(16) << 16) | (ch(8) << 8) | ch(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn air_is_none_and_stone_is_gray() {
        assert_eq!(paint_for("minecraft:air"), None);
        assert_eq!(paint_for("minecraft:stone"), Some(Paint::Fixed(0x7F7F7F)));
    }
    #[test]
    fn specific_beats_general() {
        assert_eq!(paint_for("minecraft:red_sandstone"), Some(Paint::Fixed(0xBE6621)));
        assert_eq!(paint_for("minecraft:soul_sand"), Some(Paint::Fixed(0x51402F)));
        assert_eq!(paint_for("minecraft:seagrass"), Some(Paint::Water));
        assert_eq!(paint_for("minecraft:grass_block"), Some(Paint::Grass));
        assert_eq!(paint_for("minecraft:spruce_planks"), Some(Paint::Fixed(0x8F7748)));
        assert_eq!(paint_for("minecraft:packed_ice"), Some(Paint::Fixed(0xA0A0FF)));
    }
    #[test]
    fn untinted_falls_back() {
        assert_eq!(resolve(Paint::Grass, [0, 0, 0]), 0x7CBD6B);
        assert_eq!(resolve(Paint::Water, [0, 0, 0x112233]), 0x112233);
    }
    #[test]
    fn shade_never_overflows() {
        assert_eq!(shade(0xFFFFFF, 1), 0xF8F8F8);
        assert!(shade(0x808080, -1) < shade(0x808080, 1));
    }
}
