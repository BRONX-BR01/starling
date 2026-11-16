// A mouse button, before the screen sees it. A touch sends its position and its press together, so the
// cursor is mapped here too; a press off the plane (and its release) goes no further.
fn spatial_gui_button(game: &mut crate::game::Game<'_>, pressed: bool, canceled: &mut bool) {
    use crate::game::official_spatial_gui as m;
    if !game.native_on(m::ID) {
        return;
    }
    if let Some((cursor, cancel)) = m::button([game.cursor.0, game.cursor.1], pressed) {
        game.cursor = (cursor[0], cursor[1]);
        if cancel {
            *canceled = true;
        }
    }
}
