// The mod's settings page: one button per setting; a click changes it to its next value.
fn spatial_gui_page(game: &mut crate::game::Game<'_>, mod_id: &str, buttons: &mut Vec<String>) {
    use crate::game::official_spatial_gui as m;
    if mod_id != m::ID {
        return;
    }
    let settings = m::settings(|key| game.native_setting(m::ID, key));
    for i in 0..m::CONTROLS.len() {
        buttons.push(settings.label(i));
    }
}
