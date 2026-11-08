# The catalog on Starling

**Options > Mods > Catalog** finds and installs mods, resource packs and shader packs from inside the game
(`game/mod_catalog.rs`). The searching, the compatibility checks and the checked downloads are the desktop launcher's
mod browser: the `starling-catalog` crate compiles `launcher/src/browser.rs` as it is, without its window, and answers
what the browser asks of the rest of the launcher.

| Shelf | Where from | Goes to | Then |
|---|---|---|---|
| Mods | Horizon's registry of reviewed mods | `horizon-native-mods/` or `horizon-mods/` | A native mod gets its Compile button ([starling-native-mods.md](starling-native-mods.md)); a content mod loads at the next start |
| Resource packs | Modrinth | `resourcepacks/` | The player turns it on |
| Shader packs | Modrinth's Iris and OptiFine packs; a search also finds the registry's | `shaderpacks/` | The player chooses it |

- **Java mods aren't offered.** Modrinth's mods are Java: on the desktop their content is ported, and this catalog
  leaves that out.
- **Resource packs for other versions** stay hidden until the player asks for all game versions. Each then says what it
  was made for.
- **Modrinth's shader packs** aren't in the desktop browser, because the desktop's own format is `.hshader`.
  `starling-catalog` searches them itself, the most downloaded first, downloads the newest ZIP (one made for this
  version of the game, if any), checks its SHA-512 and that it holds a `shaders/` folder. Whether it runs well is up to
  the converter and the phone.
- **What's installed** is listed in the browser's own file, `mod-browser.json`, in the game folder.

## Testing without a phone

`cargo test -p starling-catalog` runs what needs no network. The browser's own tests stay in the launcher's workspace.
