**Starling 0.8.0: the first release of Starling and Horizon Android together.**

Horizon Android and Starling are now one app, in [starling-client/starling](https://github.com/starling-client/starling). Starling, formerly Horizon Android, is co-founded by [JuanLuci](https://github.com/JuanLuci), founder of Starling, and [Vasysik](https://github.com/Vasysik), founder of Horizon Android. Thanks to Vasysik for the support for older phones, Diagnostics, account profiles with Ely.by, the terrain work on Adreno and the game folder in the Files app in this release.

## Install

- **Already have Starling:** tap **Update** inside the game.
- **New here, or coming from Horizon Android:** download the APK for your phone below and open it. Almost every phone takes **`starling-0.8.0-arm64-v8a.apk`**. Older 32-bit phones take `armeabi-v7a`, and x86 tablets and emulators take `x86_64` or `x86`.

## What's new in 0.8.0

### New

- **Accounts:** the account button on the title screen keeps Microsoft, Ely.by and offline profiles, and switches between them. The one you pick is the one you play worlds and servers with, and it stays picked after a restart. Ely.by takes your password and, if you use it, a 2FA code. The setup on the first start offers Ely.by and named offline profiles too.
- **Skins for each profile:** Skin Customization keeps a skin for each profile. A Microsoft account can send its skin to its Minecraft profile, so others see it on servers, and an Ely.by account wears its Ely.by skin, with a button to change it on ely.by.
- **A catalog inside the game:** the **Catalog** button on the Mods, Resource Packs and Shader Packs pages finds, installs and removes them. Java shader packs like Complementary, BSL and Photon install with a tap and run as they are.
- **Your game folder in the Files app:** Starling shows up in Android's Files app and file pickers, to browse, copy, rename and delete.
- **More phones:** 32-bit ARM phones and x86 devices get their own APK, and older GPUs get a game built to run on them.
- **Faster terrain on Adreno**, and a lighter upscale on Mali and PowerVR when the resolution is below 100%.
- **Diagnostics:** **Options > Diagnostics** shows what happened when something goes wrong, and Starling offers a way back if it can't start.
- **Credits:** **Options > Credits & Attribution** names Starling's founders and the game it is built on.

### Mods and shader packs

- **More shader packs work:** packs written for the core profile, like Pixel Perfect, no longer leave a black screen, and packs with only world programs, like Round World, load.
- **Many more native mods compile**, like Treefall, Eating Animation, Carry Block, Biome Compass and Dynamic FPS.
- **Use GitHub (slower)** on the Compile card compiles your native mods on GitHub's machines, for when the build server has reached its limit for the day.
- **More builds a day:** 32 instead of 16.
- **Clearer build errors:** when a native mod can't compile, the message says which one, right away, and it no longer uses up your builds for the day. **Try again** on a failed compile compiles again.
- **Build server...** on the Compile screen lets you use your own build server.
- **The Mods page finds native mods you copy in** while the game is open, when you open the page. A `.hnmod` Starling can't read gets a row that says why.
- Compiled native mods: compile them again after this update.

### Fixed

- **The on-screen keyboard opens and types in more places:** a server's dialogs, the recipe book's search, the searches in Options, the skin name, a custom button's text, the game rules in World Options and Create New World, and the LAN port.
- **Chests and shulker boxes close again** after you close them.
- **The title screen no longer shows the last world's mobs** over the panorama.
- **Scrolling the options with a finger** no longer changes the setting under it.
- **Open Folder opens the game's folders** in the Files app. If nothing can open them, a message says how to find them there.
- **The setup tries again** when a server refuses a download because of its limit, instead of stopping.
- **Opening a game in OpenGL no longer crashes** on Adreno phones.

## New in 0.2.3

- **Coming from Horizon Android?** Starling offers to bring its worlds and resource packs over: in the setup on the first start, or over the title screen if Starling is already set up. Close Horizon Android, tap **Bring them over**, then **Use this folder** and **Allow**. They are copied: Horizon Android keeps its own.
- **A new note for what you import:** a banner drops in across the top of the screen, with a sound, and says what each file you open with Starling added, or what went wrong.
- **Native mods that record sound ask for the microphone:** when the game starts with one, Starling says which mod wants it and Android asks you. **Not now** stops asking for that build.
- **The first start goes on to the title screen** once the game is prepared. It used to stay on **Starting Starling** until Starling was opened again.
- Starling also looks for updates in the new [starling-client/starling](https://github.com/starling-client/starling) repository.
- Compiled native mods: compile them again after this update.

## New in 0.2.2

- **Many more `.hnmod` native mods from [playhorizon.dev/mods](https://playhorizon.dev/mods) now compile**, like AppleSkin, Mod Menu, SmartF3, Freecam, Waymap and Distant Horizons. Open the mod's `.hnmod` with Starling, go to **Mods** and tap **Compile**.
- **Fixed the crash on opening** on GPUs limited to 4096x4096 textures, like the PowerVR GE8320. The largest textures load at half size when they don't fit.
- **More builds a day:** 16 instead of 8, and a build that fails gives its place back.

## New in 0.2.1

- **Shader packs run on Mali phones again.** On phones with a Mali GPU every pack stayed vanilla since 0.2.0.
- A pack that can't run on your phone now says so in the chat and turns off.

## New in 0.2.0, the biggest update yet

### Mods: `.hmod` and `.hnmod`

Open either kind of file with Starling, from your file manager or your downloads, and it shows up in **Mods**.

- **`.hnmod`, native mods:** tap **Compile**. Starling tells you the risks, builds the game with your mods while you fish or mine, and restarts with them. It takes a few minutes and needs a connection.
- **`.hmod`, content mods:** data-only mods, with nothing to compile. A dropped download of a mod's assets goes on from where it stopped.

The old Starling mods (Far View, FPS Overlay, Keystrokes, Minimap, Recipes, Zoom) and the wasm mod format are gone: mods now use Horizon's formats.

### Controls

- **Bedrock Inventory:** the creative inventory shows the items and your inventory side by side, with six rows of items and a 2x2 crafting grid, and a tap takes a full stack. It is on by default; turn it off in **Options > Controls** for the Java layout.
- **Custom buttons:** tap **Add** in **Touch Controls**, or go to **Options > Controls > Custom Buttons**. Each one holds or toggles a key, a native mod's key included, or sends a command or a message. Give them an icon or your own image, drawn on Bedrock's plate or imported as a PNG, and another image for while they are pressed. Select one in **Touch Controls** to move it or delete it.
- **On-screen keyboard:** a tap on a text field brings it up and a tap beside it puts it away, on every screen, number boxes included. It no longer opens by itself on the world list or in the creative inventory.
- A double tap on a stack moves it straight to the other side, as Shift-click does.
- The held F3 button also has the other F keys, and the F3 text is bigger: it follows the GUI scale.
- The three-finger Stats tap is off unless you turn it on (**3-tap** in the touch editor).

### Shader packs

- **Auto profile:** fits a pack to the phone by what its profiles ask of it, and draws terrain's depth first.
- **Shader Options** for a finger, and **Resolution** and **FPS Limit** on the Shader Packs page.
- Water and terrain came back in Photon, Sildur's and Bliss, and superDuperVanilla lost its overlay.
- Packs' own textures load, a block's cracks show, faces are no longer shaded twice, and the sky reaches the horizon.
- A pack that loses the graphics device is turned off instead of closing the game.

### Newest Horizon

Starling now sits on the newest Horizon, about 4,800 commits ahead of the previous base:

- Many more vanilla behaviours for mobs: piglins, dolphins, wolves, foxes, zombies with spears, mobs boarding minecarts and picking up gear.
- Remote players' hands and shoulder parrots, the jeb_ sheep's colours, and the portal loading screen on a server's dimension change.
- Optimize World inside Edit World, and operator commands (`/op`, `/deop`, `/ban`, `/pardon`, `/whitelist`) on a dedicated server.
- Your own skin shows with offline accounts, and on LAN the host's skin shows.

## Report a bug

Open an [issue](https://github.com/JuanLuci/starling/issues/new/choose): the form asks for your phone, your Android version and `Starling/logs/latest.log` (with `previous.log` beside it once Starling has been opened again).

---

Starling is unofficial: not an official Minecraft product, and not approved by or associated with Mojang or Microsoft. The game is [Horizon](https://github.com/ludovic111/horizon), by Ludovic Marie; Starling, the Android port, formerly Horizon Android, is by its co-founders [@JuanLuci](https://github.com/JuanLuci) and [@Vasysik](https://github.com/Vasysik). MIT licensed.
