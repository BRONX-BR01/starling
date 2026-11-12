fn orbital_lite_mods(
    game: &mut crate::game::Game<'_>,
    mods: &mut Vec<crate::game::native_hooks::NativeMod>,
) {
    crate::game::orbital_lite_glue::mods(game, mods);
}
