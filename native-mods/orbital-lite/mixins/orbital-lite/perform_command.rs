fn orbital_lite_perform_command(game: &mut crate::game::Game<'_>, command: &str, ran: &mut bool) {
    crate::game::orbital_lite_glue::perform_command(game, command, ran);
}
