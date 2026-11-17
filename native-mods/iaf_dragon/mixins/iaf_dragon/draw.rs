// A dragon's ghast, drawn with the dragon model: once a frame for every mob in view (vanilla's
// `RenderLivingEvent.Pre`). `drawn` leaves the ghast's own model out; its name tag, shadow and flames still draw.
fn iaf_dragon_draw(
    game: &crate::game::Game<'_>,
    mob: &crate::game::native_mob_draw::NativeMobRender<'_>,
    draw: &mut crate::game::native_block_entity_draw::BlockEntityDraw,
    drawn: &mut bool,
) {
    use crate::game::official_iaf_dragon as m;
    if mob.kind != "minecraft:ghast" || !m::is_dragon(mob.custom_name) || !game.native_on(m::ID) {
        return;
    }
    let name = mob.custom_name.unwrap_or_default();
    let color = m::color_of(name, mob.id);
    let sprite = m::sprite(color);
    let (action, action_ticks) = m::state_of(mob.id);
    let anim = m::Anim {
        action,
        action_ticks,
        age: mob.age,
        walk_position: mob.walk_position,
        walk_speed: mob.walk_speed,
        on_ground: mob.on_ground,
        death_time: mob.death_time,
    };
    let (pose, lift) = m::pose_of(&anim);
    let mut quads = Vec::with_capacity(600);
    m::quads(&pose, m::SIZE, lift, &mut quads);
    // The red flash of a hit, and a dead dragon fading to grey.
    let tint = if mob.hurt_time > 0 { 0xFF_A0A0 } else { 0xFF_FFFF };
    let mut any = false;
    for q in &quads {
        any |= game.native_draw_quad(draw, &sprite, q.corners, q.uv, tint);
    }
    // Without the content mod's texture the dragon is drawn in a plain block colour, still a dragon.
    if !any {
        let plain = m::fallback_sprite(color);
        for q in &quads {
            any |= game.native_draw_quad(draw, plain, q.corners, [0.0, 0.0, 16.0, 16.0], tint);
        }
    }
    *drawn = any;
}
