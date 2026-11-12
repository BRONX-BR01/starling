fn orbital_lite_key(game: &mut crate::game::Game<'_>, key: &str, pressed: bool) {
    crate::game::orbital_lite_glue::key(game, key, pressed);
}
