# Spatial GUI for Horizon / Starling

Inventory, containers (and optionally the pause menu and other screens) drawn as a plane floating in the 3D view,
flat or curved, with an open animation, drop shadow, FOV auto-scaling and a pointer that follows the plane.

A Rust port of the Fabric mod "Spatial GUI" 1.11.126.3 by tastytrash (MIT, see LICENSE).

- `/spatialgui` turns it on and off. Options > Mods > Spatial GUI has one button per setting (click to change it to its next value).
- `runtime.rs` is the whole logic with no dependencies: settings, easing, the camera model, projection of the
  screen's triangles onto the plane, the pointer's inverse mapping. It is also the library of the standalone crate
  used to run its tests (`cargo test`, 29 tests).
- `post.rs` hands the open screen's HUD vertices to it (`native_screen_render_post`), `frame.rs` and `button.rs` map the
  pointer (`native_frame`, `native_mouse_button_pre`), `command.rs`, `list.rs`, `settings.rs`, `click.rs` are the command
  and the settings page.

Not ported from the Java mod: the third-person camera orbit, the world effects behind the screen, the recipe-book
shrink and the per-screen allow/deny lists.
