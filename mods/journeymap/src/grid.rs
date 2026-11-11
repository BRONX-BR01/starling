//! A `read-columns` answer -> one colour per map cell -> merged rectangles.
use crate::color::{Paint, paint_for, resolve, shade};
use std::fmt;

/// Cells per side. 56 x 56 = 3136 columns per query, and (merged by row) well
/// under the 4096 draws a screen may have.
pub const N: usize = 56;
const VOID: u32 = 0xFF10_1010;

#[derive(Debug, PartialEq, Eq)]
pub struct GridError {
    pub what: &'static str,
    pub expected: usize,
    pub got: usize,
}

impl fmt::Display for GridError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "answer `{}`: expected {} values, got {}", self.what, self.expected, self.got)
    }
}

/// What to read from each column.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Select {
    /// The top block (`below = 1`).
    Top,
    /// The first solid block at or under `y` (a cave map): 64 blocks a column.
    Slice { y: i32 },
}

pub const SLICE: usize = 64;

impl Select {
    /// The `below` to ask `read-columns` for (`above` is always 0).
    pub fn below(self) -> u32 {
        match self {
            Select::Top => 1,
            Select::Slice { .. } => SLICE as u32,
        }
    }
}

/// Borrowed view of a `column-blocks` answer.
pub struct Answer<'a> {
    pub palette: &'a [String],
    pub bases: &'a [Option<i32>],
    pub blocks: &'a [u16],
    pub tints: &'a [u32],
}

fn check(what: &'static str, got: usize, expected: usize) -> Result<(), GridError> {
    if got == expected { Ok(()) } else { Err(GridError { what, expected, got }) }
}

enum Cell {
    Unknown,
    Void,
    Solid { paint: Paint, tints: [u32; 3], y: i32 },
}

fn cell(a: &Answer<'_>, idx: usize, sel: Select) -> Cell {
    let Some(height) = a.bases[idx] else { return Cell::Unknown };
    let paint_at = |k: usize| -> Option<Option<Paint>> {
        let id = usize::from(*a.blocks.get(idx * sel.below() as usize + k)?);
        Some(paint_for(a.palette.get(id)?))
    };
    let tints = [a.tints[3 * idx], a.tints[3 * idx + 1], a.tints[3 * idx + 2]];
    match sel {
        Select::Top => match paint_at(0) {
            Some(Some(paint)) => Cell::Solid { paint, tints, y: height },
            Some(None) => Cell::Void,
            None => Cell::Unknown,
        },
        Select::Slice { y } => {
            // Index k holds the block at height - SLICE + k.
            let base = height.saturating_sub(SLICE as i32);
            let k0 = y.saturating_sub(base);
            if k0 < 0 {
                return Cell::Unknown;
            }
            for k in (0..=(k0 as usize).min(SLICE - 1)).rev() {
                if let Some(Some(paint)) = paint_at(k) {
                    return Cell::Solid { paint, tints, y: base + k as i32 };
                }
            }
            Cell::Void
        }
    }
}

/// 0xAARRGGBB per cell, row-major; 0 = nothing known (draw nothing).
pub fn colors(a: &Answer<'_>, sel: Select) -> Result<Vec<u32>, GridError> {
    let cells = N * N;
    check("bases", a.bases.len(), cells)?;
    check("blocks", a.blocks.len(), cells * sel.below() as usize)?;
    check("tints", a.tints.len(), cells * 3)?;
    let info: Vec<Cell> = (0..cells).map(|i| cell(a, i, sel)).collect();
    Ok(info
        .iter()
        .enumerate()
        .map(|(idx, c)| match c {
            Cell::Unknown => 0,
            Cell::Void => VOID,
            Cell::Solid { paint, tints, y } => {
                let north = idx.checked_sub(N).and_then(|n| match &info[n] {
                    Cell::Solid { y, .. } => Some(*y),
                    _ => None,
                });
                let delta = north.map_or(0, |n| y.saturating_sub(n));
                0xFF00_0000 | shade(resolve(*paint, *tints), delta)
            }
        })
        .collect())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Run {
    pub row: usize,
    pub col: usize,
    pub len: usize,
    pub argb: u32,
}

/// Horizontal runs of equal colour; 0 (unknown) cells are skipped.
pub fn merge_runs(colors: &[u32], n: usize) -> Vec<Run> {
    let mut runs: Vec<Run> = Vec::new();
    for (row, line) in colors.chunks(n).enumerate() {
        let mut col = 0;
        while col < line.len() {
            let argb = line[col];
            let len = line[col..].iter().take_while(|&&c| c == argb).count();
            if argb != 0 {
                runs.push(Run { row, col, len, argb });
            }
            col += len;
        }
    }
    runs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_merge_and_skip_unknown() {
        let c = [1, 1, 2, 0, 0, 2];
        let r = merge_runs(&c, 3);
        assert_eq!(
            r,
            vec![
                Run { row: 0, col: 0, len: 2, argb: 1 },
                Run { row: 0, col: 2, len: 1, argb: 2 },
                Run { row: 1, col: 2, len: 1, argb: 2 },
            ]
        );
    }

    #[test]
    fn wrong_sizes_are_errors() {
        let a = Answer { palette: &[], bases: &[], blocks: &[], tints: &[] };
        assert!(matches!(colors(&a, Select::Top), Err(GridError { what: "bases", .. })));
    }

    #[test]
    fn colours_a_flat_grass_field() {
        let palette = vec!["minecraft:grass_block".to_owned(), "minecraft:air".to_owned()];
        let mut bases = vec![Some(64); N * N];
        bases[1] = None;
        let mut blocks = vec![0u16; N * N];
        blocks[2] = 1;
        let tints = vec![0u32; N * N * 3];
        let c = colors(&Answer { palette: &palette, bases: &bases, blocks: &blocks, tints: &tints }, Select::Top).unwrap();
        assert_eq!(c[0], 0xFF78B868);
        assert_eq!(c[1], 0);
        assert_eq!(c[2], VOID);
        assert!(merge_runs(&c, N).len() < 4000);
    }

    #[test]
    fn cave_slice_finds_the_floor_under_the_player() {
        let palette = vec!["minecraft:stone".to_owned(), "minecraft:air".to_owned()];
        let bases = vec![Some(70); N * N];
        // Column 0: stone up to k = 53 (y = 59), air above; player at y = 60.
        let mut blocks = vec![1u16; N * N * SLICE];
        blocks[..54].fill(0);
        let tints = vec![0u32; N * N * 3];
        let a = Answer { palette: &palette, bases: &bases, blocks: &blocks, tints: &tints };
        let c = colors(&a, Select::Slice { y: 60 }).unwrap();
        assert_eq!(c[0] & 0xFF00_0000, 0xFF00_0000);
        assert_ne!(c[0], VOID);
        assert_eq!(c[1], VOID); // all air in column 1
        // A player deeper than the slice reaches reads nothing.
        assert_eq!(colors(&a, Select::Slice { y: 0 }).unwrap()[0], 0);
    }
}
