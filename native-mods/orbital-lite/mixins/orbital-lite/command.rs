fn orbital_lite_command(game: &mut crate::game::Game<'_>, command: &str, ran: &mut bool) {
    if crate::game::orbital_lite_glue::command(game, command) {
        *ran = true;
    }
}
