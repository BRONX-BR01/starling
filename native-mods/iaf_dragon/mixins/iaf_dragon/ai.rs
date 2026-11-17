// The dragon's brain, with no game types in it: what a dragon does each tick, given where it is and where the
// player it hunts is. The server half (server.rs) gives it the world and carries out what it answers.

/// What a client shows of a dragon besides walking and flying.
pub const STATE_IDLE: u8 = 0;
pub const STATE_BITE: u8 = 1;
pub const STATE_CHARGE: u8 = 2;
pub const STATE_BREATH: u8 = 3;

/// Ticks of a bite, of the breath's charge and of the breath itself.
pub const BITE_TICKS: i32 = 10;
pub const CHARGE_TICKS: i32 = 8;
pub const BREATH_TICKS: i32 = 60;
/// How far a dragon sees a player, bites, and breathes fire, in blocks.
pub const SIGHT: f64 = 48.0;
pub const BITE_RANGE: f64 = 5.5;
pub const BREATH_MIN: f64 = 8.0;
pub const BREATH_MAX: f64 = 40.0;
/// How far a flame reaches from the mouth.
pub const FLAME_REACH: f64 = 30.0;

/// A dragon as the brain sees it.
#[derive(Clone, Copy, Debug)]
pub struct View {
    pub pos: [f64; 3],
}

/// What the brain asks the server half to do.
#[derive(Clone, Debug, PartialEq)]
pub enum Act {
    /// Add this to the dragon's velocity.
    Push([f64; 3]),
    /// A bite lands around this point.
    Bite([f64; 3]),
    /// A stream of flame from one point to another.
    Flame([f64; 3], [f64; 3]),
    /// The flame burns what stands at this point.
    Burn([f64; 3]),
    /// The flame bursts and sets fire at this point.
    Blast([f64; 3]),
    /// The state clients show changed (or is repeated so they keep showing it).
    State(u8),
}

#[derive(Clone, Debug, Default)]
pub struct Brain {
    bite_left: i32,
    bite_cooldown: i32,
    breath_left: i32,
    breath_cooldown: i32,
    state: u8,
    since_sent: i32,
}

pub fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub fn length(a: [f64; 3]) -> f64 {
    (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt()
}

fn scale(a: [f64; 3], k: f64) -> [f64; 3] {
    [a[0] * k, a[1] * k, a[2] * k]
}

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

/// The unit vector of `a`, or zero for a zero vector.
pub fn unit(a: [f64; 3]) -> [f64; 3] {
    let l = length(a);
    if l < 1.0e-9 { [0.0; 3] } else { scale(a, 1.0 / l) }
}

/// How high above its feet a player's chest is, where a dragon aims.
const CHEST: f64 = 1.0;

impl Brain {
    pub fn state(&self) -> u8 {
        self.state
    }

    /// One tick. `target` is where the nearest player it can hunt stands (feet), if any.
    pub fn step(&mut self, dragon: &View, target: Option<[f64; 3]>) -> Vec<Act> {
        let mut acts = Vec::new();
        self.bite_cooldown = (self.bite_cooldown - 1).max(0);
        self.breath_cooldown = (self.breath_cooldown - 1).max(0);

        let Some(feet) = target else {
            // Nobody to hunt: whatever it was doing stops, and the ghast's own wandering takes over.
            self.bite_left = 0;
            self.breath_left = 0;
            self.announce(STATE_IDLE, &mut acts);
            return acts;
        };
        let chest = add(feet, [0.0, CHEST, 0.0]);
        let delta = sub(chest, dragon.pos);
        let dist = length(delta);

        // Start a bite up close, or a breath from afar.
        if self.bite_left == 0 && self.breath_left == 0 {
            if dist <= BITE_RANGE && self.bite_cooldown == 0 {
                self.bite_left = BITE_TICKS;
                self.bite_cooldown = 30;
            } else if (BREATH_MIN..=BREATH_MAX).contains(&dist) && self.breath_cooldown == 0 {
                self.breath_left = CHARGE_TICKS + BREATH_TICKS;
                self.breath_cooldown = 200;
            }
        }

        // It closes in to bite; it holds off while it breathes.
        let standoff = if self.breath_left > 0 { 14.0 } else { 3.5 };
        let speed = ((dist - standoff) * 0.012).clamp(-0.03, 0.055);
        acts.push(Act::Push(scale(unit(delta), speed)));

        let state;
        if self.bite_left > 0 {
            self.bite_left -= 1;
            if self.bite_left == BITE_TICKS / 2 {
                acts.push(Act::Bite(dragon.pos));
            }
            state = STATE_BITE;
        } else if self.breath_left > 0 {
            let ticks = CHARGE_TICKS + BREATH_TICKS - self.breath_left;
            self.breath_left -= 1;
            if ticks < CHARGE_TICKS {
                state = STATE_CHARGE;
            } else {
                state = STATE_BREATH;
                let mouth = add(dragon.pos, add([0.0, 1.8, 0.0], scale(unit([delta[0], 0.0, delta[2]]), 2.5)));
                let aim = sub(chest, mouth);
                let reach = length(aim).min(FLAME_REACH);
                let end = add(mouth, scale(unit(aim), reach));
                acts.push(Act::Flame(mouth, end));
                let n = ticks - CHARGE_TICKS;
                if n % 4 == 0 {
                    acts.push(Act::Burn(end));
                }
                if n % 15 == 14 {
                    acts.push(Act::Blast(end));
                }
            }
        } else {
            state = STATE_IDLE;
        }
        self.announce(state, &mut acts);
        acts
    }

    /// Tell the clients the state when it changes, and every ten ticks while it is not idle (so they keep it).
    fn announce(&mut self, state: u8, acts: &mut Vec<Act>) {
        self.since_sent += 1;
        if state != self.state || (state != STATE_IDLE && self.since_sent >= 10) {
            self.state = state;
            self.since_sent = 0;
            acts.push(Act::State(state));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const AT: View = View { pos: [0.0, 70.0, 0.0] };

    fn run(brain: &mut Brain, target: Option<[f64; 3]>, ticks: usize) -> Vec<Act> {
        (0..ticks).flat_map(|_| brain.step(&AT, target)).collect()
    }

    #[test]
    fn a_dragon_with_nobody_in_sight_does_nothing() {
        let mut b = Brain::default();
        assert!(run(&mut b, None, 20).is_empty());
    }

    #[test]
    fn it_flies_toward_a_far_player_and_away_from_one_too_close() {
        let mut b = Brain::default();
        let far = b.step(&AT, Some([30.0, 70.0, 0.0]));
        let Act::Push(p) = far[0] else { panic!("{far:?}") };
        assert!(p[0] > 0.0 && p[0] <= 0.055 + 1e-9, "{p:?}");
        // Breathing keeps its distance: 8 blocks away it backs off while the breath runs.
        let mut b = Brain::default();
        let near = b.step(&AT, Some([10.0, 70.0, 0.0]));
        assert!(near.contains(&Act::State(STATE_CHARGE)), "{near:?}");
        let Act::Push(p) = near[0] else { panic!() };
        assert!(p[0] < 0.0, "{p:?}");
    }

    #[test]
    fn a_player_in_reach_is_bitten_once_per_bite() {
        let mut b = Brain::default();
        let acts = run(&mut b, Some([2.0, 70.0, 0.0]), 12);
        let bites: Vec<_> = acts.iter().filter(|a| matches!(a, Act::Bite(_))).collect();
        assert_eq!(bites.len(), 1, "{acts:?}");
        assert!(acts.contains(&Act::State(STATE_BITE)));
        // The bite ends and the dragon goes idle until its cooldown is over, then bites again.
        assert_eq!(b.state(), STATE_IDLE);
        let more = run(&mut b, Some([2.0, 70.0, 0.0]), 40);
        assert!(more.iter().any(|a| matches!(a, Act::Bite(_))));
    }

    #[test]
    fn the_breath_charges_then_burns_along_a_line_to_the_player() {
        let mut b = Brain::default();
        let acts = run(&mut b, Some([20.0, 70.0, 0.0]), CHARGE_TICKS as usize + BREATH_TICKS as usize);
        let states: Vec<u8> = acts.iter().filter_map(|a| if let Act::State(s) = a { Some(*s) } else { None }).collect();
        assert_eq!(states[0], STATE_CHARGE);
        assert!(states.contains(&STATE_BREATH));
        // No flame until the charge is over.
        let first = acts.iter().position(|a| matches!(a, Act::Flame(..))).unwrap();
        let charged = acts[..first].iter().filter(|a| matches!(a, Act::Push(_))).count();
        assert_eq!(charged, CHARGE_TICKS as usize + 1, "{charged}"); // the flame tick has its own push
        let flames = acts.iter().filter(|a| matches!(a, Act::Flame(..))).count();
        assert_eq!(flames, BREATH_TICKS as usize);
        // A flame ends within reach, on the line to the player.
        let Some(Act::Flame(from, to)) = acts.iter().find(|a| matches!(a, Act::Flame(..))) else { panic!() };
        assert!(length(sub(*to, *from)) <= FLAME_REACH + 1e-6);
        assert!(to[0] > from[0]);
        assert!(acts.iter().any(|a| matches!(a, Act::Burn(_))));
        assert_eq!(acts.iter().filter(|a| matches!(a, Act::Blast(_))).count(), 4);
    }

    #[test]
    fn losing_the_player_ends_the_attack_and_says_so() {
        let mut b = Brain::default();
        run(&mut b, Some([20.0, 70.0, 0.0]), 20);
        assert_eq!(b.state(), STATE_BREATH);
        let acts = b.step(&AT, None);
        assert_eq!(acts, vec![Act::State(STATE_IDLE)]);
    }

    #[test]
    fn a_state_is_repeated_every_ten_ticks_so_clients_keep_it() {
        let mut b = Brain::default();
        let acts = run(&mut b, Some([20.0, 70.0, 0.0]), 40);
        let sent = acts.iter().filter(|a| matches!(a, Act::State(_))).count();
        assert!(sent >= 4, "{sent}");
    }
}
