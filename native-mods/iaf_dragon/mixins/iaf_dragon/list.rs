// The mod's row in Options > Mods.
fn iaf_dragon_listed(mods: &mut Vec<crate::game::native_hooks::NativeMod>) {
    use crate::game::official_iaf_dragon as m;
    mods.push(crate::game::native_hooks::NativeMod {
        id: m::ID.into(),
        title: format!("{} {}", m::NAME, m::VERSION),
        description: m::DESCRIPTION.into(),
        keys: Vec::new(),
    });
}
