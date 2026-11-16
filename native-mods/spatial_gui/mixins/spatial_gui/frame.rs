// Once a frame: the pointer, mapped onto the plane the screen was drawn on. The game sets its cursor
// from the window's pointer when it moves; the screen reads the cursor to hover and click, so what it
// reads must be the point of the screen the pointer is over.
fn spatial_gui_frame(game: &mut crate::game::Game<'_>) {
    use crate::game::official_spatial_gui as m;
    if !game.native_on(m::ID) {
        return;
    }
    if let Some(cursor) = m::frame([game.cursor.0, game.cursor.1]) {
        game.cursor = (cursor[0], cursor[1]);
    }
}
