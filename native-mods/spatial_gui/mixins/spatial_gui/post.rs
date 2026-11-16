// After the open screen has drawn itself: its vertices are placed on the plane (flat or curved) in front
// of the camera, with the open animation's scale and fade, a drop shadow behind it, and the scissors of
// its depth runs moved to where the screen now is. The 2D GUI pass then draws the result as it always does.
fn spatial_gui_post(
    game: &crate::game::Game<'_>,
    batch: &mut horizon_client::hud::HudBatch,
    screen: &horizon_client::mod_api::NativeScreenView<'_>,
) {
    use crate::game::official_spatial_gui as m;
    use horizon_client::hud::{Blend, HudVertex};

    if !game.native_on(m::ID) {
        return;
    }
    let settings = m::settings(|key| game.native_setting(m::ID, key));
    if !settings.applies(screen.id) {
        return;
    }
    let fov = game.native_camera().map_or(70.0, |camera| camera.fov_degrees);
    let (mapping, opacity) = m::begin_frame(&settings, fov, [batch.width, batch.height]);

    // The HUD before `blur_at` is the world's overlay behind the screen; the screen is what follows.
    let first = (batch.blur_at as usize).min(batch.vertices.len());
    let screen_vertices = batch.vertices.split_off(first);
    let projected = m::project_triangles(
        &mapping,
        &screen_vertices,
        |v: &HudVertex| v.pos,
        |v: &mut HudVertex, at| v.pos = at,
        |a: &HudVertex, b: &HudVertex, t| HudVertex {
            pos: [m::lerp(a.pos[0], b.pos[0], t), m::lerp(a.pos[1], b.pos[1], t)],
            uv: [m::lerp(a.uv[0], b.uv[0], t), m::lerp(a.uv[1], b.uv[1], t)],
            color: m::mix_color(a.color, b.color, t),
            depth: m::lerp(a.depth, b.depth, t),
            glint_uv: [m::lerp(a.glint_uv[0], b.glint_uv[0], t), m::lerp(a.glint_uv[1], b.glint_uv[1], t)],
            text: a.text,
        },
        |v: &mut HudVertex, k| v.color = m::scale_alpha(v.color, k),
        opacity,
    );

    // The drop shadow goes in front of the screen's vertices so it is drawn first, under it.
    if settings.shadow {
        if let Some(quad) = mapping.shadow_quad(settings.shadow_dx, settings.shadow_dy, settings.shadow_dz) {
            let alpha = (settings.shadow_alpha as f32 * opacity).round().clamp(0.0, 255.0) as u32;
            let at = batch.vertices.len();
            // A unit fill gives the two triangles with the solid sprite's uv; each of its vertices
            // is then moved to the same place on the shadow's quad.
            game.native_fill(batch, [0.0, 0.0, 1.0, 1.0], alpha << 24);
            for v in &mut batch.vertices[at..] {
                let (u, w) = (v.pos[0].clamp(0.0, 1.0), v.pos[1].clamp(0.0, 1.0));
                let top = [
                    m::lerp(quad[0][0], quad[1][0], u),
                    m::lerp(quad[0][1], quad[1][1], u),
                ];
                let bottom = [
                    m::lerp(quad[3][0], quad[2][0], u),
                    m::lerp(quad[3][1], quad[2][1], u),
                ];
                v.pos = [m::lerp(top[0], bottom[0], w), m::lerp(top[1], bottom[1], w)];
            }
        }
    }
    let shift = (batch.vertices.len() - first) as u32;
    batch.vertices.extend_from_slice(&projected.vertices);

    // Ranges that blend or clip differently follow their vertices; a scissor is where the screen is now.
    for (range, blend) in batch.blends.iter_mut() {
        *range = m::remap_range(range.clone(), first as u32, shift, &projected);
        if let Blend::Depth(clip) = blend {
            let rect = [clip[0] as f32, clip[1] as f32, clip[2] as f32, clip[3] as f32];
            *clip = match mapping.project_rect(rect) {
                Some([x, y, w, h]) => [x.max(0.0) as u32, y.max(0.0) as u32, w.max(0.0).ceil() as u32, h.max(0.0).ceil() as u32],
                None => [0, 0, 0, 0],
            };
        }
    }
    batch.blends.retain(|(range, _)| !range.is_empty());
}
