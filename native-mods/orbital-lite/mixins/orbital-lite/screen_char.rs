fn orbital_lite_screen_char(
    game: &crate::game::Game<'_>,
    screen: &crate::game::native_hooks::NativeScreenView<'_>,
    c: char,
    canceled: &mut bool,
) {
    crate::game::orbital_lite_glue::screen_char(game, screen, c, canceled);
}
