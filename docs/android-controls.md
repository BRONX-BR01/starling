# Android control system

Starling integrates Horizon Android's control engine and visual editor. Open the
control hub to select **MCPE** or **GoyControl**, change the movement mode or edit
a layout. The touch-layout entry in Controls opens the same visual editor.

The editor supports moving and resizing controls, independent dimensions,
component properties, colors, borders, shapes, labels and event bindings. It has
undo/redo, visibility controls and a save/back confirmation. Presets keep their
names, descriptions and separate MCPE/GoyControl layouts under `controls/`;
`horizon-touch.json` keeps the active selection.

The control hub includes movement and joystick configuration, aiming and axis
sensitivity, virtual pointer settings, gyroscope settings, button behavior and
inventory controls. GoyControl supports custom static buttons, pass-through,
swiping, hold/toggle behavior and up to three simultaneous events. MCPE supports
joystick/crosshair, joystick/tap and D-pad schemes.

The compact Controls page keeps Starling's Bedrock Inventory option. On the
main title screen, H and `…` sit below the existing account button; in game they
keep their original positions. Back retains its original menu behavior.

**360-degree movement** is available in H → Controls and is off by default.
With it off, touch movement uses Java directional sectors. **Look while
interacting** applies to both attacking and use/place gestures. Vertical swipes
starting on hub sliders scroll the pane; horizontal drags adjust their values.

The original MCPE artwork is downloaded from a pinned manifest with size and
SHA-256 checks. These files are read as a small disk overlay even when the
prepared vanilla resource archive predates their download.

Starling's chat shortcuts (history, completion, cursor and paste) and touch slot
gestures remain available. Inventory Shift/Control include the control system's
latched modifiers and held custom keys. Foreground/focus changes release touch
owners through the existing input paths.

This is independent of account management. It uses the current game's settings
folder; selecting an account does not select a control preset. Existing Starling
`touch-layout.json` files are preserved, but are not imported into the new preset
format automatically.

See `THIRD_PARTY_NOTICES.md` for the MIT source attribution.
