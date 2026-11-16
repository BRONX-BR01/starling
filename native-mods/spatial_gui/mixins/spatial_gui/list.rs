// The mod's row in Options > Mods.
fn spatial_gui_listed(mods: &mut Vec<crate::game::native_hooks::NativeMod>) {
    use crate::game::official_spatial_gui as m;
    mods.push(crate::game::native_hooks::NativeMod {
        id: m::ID.into(),
        title: format!("{} {}", m::NAME, m::VERSION),
        description: m::DESCRIPTION.into(),
        keys: Vec::new(),
    });
}
