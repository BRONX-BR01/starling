// /spatialgui turns the plane on or off.
fn spatial_gui_command(game: &mut crate::game::Game<'_>, command: &str, ran: &mut bool) {
    use crate::game::official_spatial_gui as m;
    if !game.native_on(m::ID) || command.split(' ').next().unwrap_or("") != "spatialgui" {
        return;
    }
    *ran = true;
    let mut settings = m::settings(|key| game.native_setting(m::ID, key));
    // Button 0 is "enabled".
    for (key, value) in settings.cycle(0) {
        game.native_set_setting(m::ID, key, &value);
    }
    game.native_chat(&m::state_line(settings.enabled));
    m::set_settings(settings);
}
