fn orbital_lite_world_hold(game: &crate::game::Game<'_>, hold: &mut horizon_client::mod_api::WorldHold) {
    crate::game::orbital_lite_glue::world_hold(game, hold);
}
