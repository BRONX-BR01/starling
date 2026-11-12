fn orbital_lite_register_commands(
    game: &mut crate::game::Game<'_>,
    commands: &mut Vec<crate::mod_api::NativeCommand>,
) {
    crate::game::orbital_lite_glue::register_commands(game, commands);
}
