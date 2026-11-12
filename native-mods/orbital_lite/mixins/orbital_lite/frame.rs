fn orbital_lite_frame(game: &mut crate::game::Game<'_>, elapsed: std::time::Duration) {
    crate::game::orbital_lite_glue::frame(game, elapsed);
}
