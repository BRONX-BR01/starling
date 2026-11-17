// The server half of the dragons: each tick of a level, every dragon (a ghast with a dragon's health) hunts the
// nearest player in sight with the brain in `ai.rs`; this file gives the brain the world and carries out
// what it answers (push, bite, flame, burn, blast), and tells the clients what each dragon is doing.

use super::official_iaf_dragon as m;
use super::official_iaf_dragon_ai as ai;
use crate::game::Game;
use std::{cell::RefCell, collections::HashMap};

/// The channel the server tells clients a dragon's state on (`m::encode_state`).
pub const CHANNEL: &str = "iaf_dragon:state";
/// Clients farther than this from a dragon are not told what it does.
const TELL_RANGE: f64 = 128.0;

thread_local! {
    static BRAINS: RefCell<HashMap<u32, ai::Brain>> = RefCell::new(HashMap::new());
}

fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
    ai::length(ai::sub(a, b))
}

/// Runs `damage` on the players (not creative or spectator) and the other creatures within `radius` of `at`.
fn hurt_around(game: &mut Game<'_>, dimension: &str, at: [f64; 3], radius: f64, amount: f32, kind: &str) {
    let place = format!("execute in {dimension} positioned {:.2} {:.2} {:.2} run", at[0], at[1], at[2]);
    game.native_run_command(&format!(
        "{place} damage @a[distance=..{radius},gamemode=!creative,gamemode=!spectator] {amount} {kind}"
    ));
    game.native_run_command(&format!(
        "{place} damage @e[type=!minecraft:player,type=!minecraft:ghast,type=!minecraft:item,\
         type=!minecraft:experience_orb,distance=..{radius}] {amount} {kind}"
    ));
}

fn flame(game: &mut Game<'_>, dimension: &str, from: [f64; 3], to: [f64; 3], tick: u32) {
    let line = ai::sub(to, from);
    let length = ai::length(line);
    let steps = ((length / 3.0).ceil() as usize).clamp(1, 12);
    for i in 1..=steps {
        let t = i as f64 / steps as f64;
        let p = [from[0] + line[0] * t, from[1] + line[1] * t, from[2] + line[2] * t];
        // The stream widens with the distance.
        let spread = 0.15 + 0.5 * t;
        let name = if (tick as usize + i) % 3 == 0 { "minecraft:smoke" } else { "minecraft:flame" };
        game.native_run_command(&format!(
            "execute in {dimension} run particle {name} {:.2} {:.2} {:.2} {spread:.2} {spread:.2} {spread:.2} 0.02 6 force",
            p[0], p[1], p[2]
        ));
    }
}

/// The `level_tick_post` hook.
pub fn level_tick(game: &mut Game<'_>, dimension: &str) {
    if game.native_window() || !game.native_on(m::ID) {
        return;
    }
    let dragons: Vec<_> = game
        .native_mobs(dimension)
        .into_iter()
        .filter(|d| m::is_dragon_mob(&d.kind, d.max_health))
        .collect();
    BRAINS.with(|b| b.borrow_mut().retain(|id, _| dragons.iter().any(|d| d.id == *id)));
    if dragons.is_empty() {
        return;
    }
    let players: Vec<_> = game
        .native_server_players()
        .into_iter()
        .filter(|p| p.dimension == dimension && p.health > 0.0 && matches!(p.game_mode, 0 | 2))
        .collect();
    let tick = game_tick(game);
    let mut told: Vec<(u32, [f64; 3], u8)> = Vec::new();
    for d in &dragons {
        let target = players
            .iter()
            .map(|p| (distance(p.position, d.pos), p.position))
            .filter(|(dist, _)| *dist <= ai::SIGHT)
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .map(|(_, at)| at);
        let acts = BRAINS.with(|b| b.borrow_mut().entry(d.id).or_default().step(&ai::View { pos: d.pos }, target));
        for act in acts {
            match act {
                ai::Act::Push(v) => {
                    game.native_push_mob(dimension, d.id, v);
                }
                ai::Act::Bite(at) => hurt_around(game, dimension, at, 7.0, 10.0, "minecraft:mob_attack"),
                ai::Act::Flame(from, to) => flame(game, dimension, from, to, tick),
                ai::Act::Burn(at) => hurt_around(game, dimension, at, 3.0, 4.0, "minecraft:on_fire"),
                ai::Act::Blast(at) => {
                    game.native_explode(
                        dimension,
                        at,
                        1.6,
                        true,
                        crate::game::native_explosions::NativeBlast::Keep,
                    );
                }
                ai::Act::State(s) => told.push((d.id, d.pos, s)),
            }
        }
    }
    for (id, at, state) in told {
        let bytes = m::encode_state(id, state);
        for p in players.iter().filter(|p| distance(p.position, at) <= TELL_RANGE) {
            let _ = game.native_net_send_to_player(p.uuid, CHANNEL, &bytes);
        }
    }
}

/// A counter that goes up each time this runs: enough to vary the particles.
fn game_tick(_game: &Game<'_>) -> u32 {
    thread_local! { static N: std::cell::Cell<u32> = const { std::cell::Cell::new(0) }; }
    N.with(|n| {
        n.set(n.get().wrapping_add(1));
        n.get()
    })
}

/// The `net_from_server` hook (the window's game): a dragon's state, kept for the drawing.
pub fn from_server(game: &mut Game<'_>, channel: &str, data: &[u8]) {
    if channel != CHANNEL || !game.native_on(m::ID) {
        return;
    }
    if let Some((id, state)) = m::decode_state(data) {
        m::note_state(id, state);
    }
}
