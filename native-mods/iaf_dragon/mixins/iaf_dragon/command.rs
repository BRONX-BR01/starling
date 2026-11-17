// /firedragon [red|green|bronze|gray] summons a dragon at the player.
fn iaf_dragon_command(game: &mut crate::game::Game<'_>, command: &str, ran: &mut bool) {
    use crate::game::official_iaf_dragon as m;
    let mut words = command.split_whitespace();
    if words.next() != Some("firedragon") || !game.native_on(m::ID) {
        return;
    }
    *ran = true;
    let rest = words.collect::<Vec<_>>().join(" ");
    let color = if rest.is_empty() { Some(m::COLORS[0]) } else { m::parse_color(&rest) };
    let Some(color) = color else {
        game.native_chat("Usage: /firedragon [red|green|bronze|gray]");
        return;
    };
    if game.run_command(&m::summon_line(color)) {
        game.native_chat(&format!("A {color} fire dragon rises."));
    } else {
        game.native_chat("The dragon could not be summoned here (cheats on? peaceful?).");
    }
}
