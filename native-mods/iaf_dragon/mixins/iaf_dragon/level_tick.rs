fn iaf_dragon_level_tick(game: &mut crate::game::Game<'_>, dimension: &str) {
    crate::game::official_iaf_dragon_server::level_tick(game, dimension);
}
