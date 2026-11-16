// A click on the mod's settings page: the next value of that setting, kept in the mod's data folder.
fn spatial_gui_click(game: &mut crate::game::Game<'_>, mod_id: &str, button: usize) {
    use crate::game::official_spatial_gui as m;
    if mod_id != m::ID {
        return;
    }
    let mut settings = m::settings(|key| game.native_setting(m::ID, key));
    for (key, value) in settings.cycle(button) {
        game.native_set_setting(m::ID, key, &value);
    }
    m::set_settings(settings);
}
