# Custom touch buttons

Open the touch layout editor (hold Pause while playing), then add or edit a custom
button. Starling keeps its chat shortcuts, built-in controls, imported/drawn button
images and Hold/Toggle behavior.

A custom button has three binding slots. Tap **Binding** to choose slot 1, 2 or 3,
then choose a game control or a keyboard key. They are pressed together, with
modifiers first. **Clear binding** clears the current slot. A key shared by two
custom buttons stays held until both release it. Opening another screen releases
custom holds and toggles.

The text field switches between a chat/command and a button label. An empty label
uses the action names. The first slot may send a chat line or command; extra slots
hold keys. A custom label does not change the command or bindings.

Width and height change independently in 25% steps from 25% to 300%, wrapping
back to 25%. These multiply the size in the layout editor. The button's picture
and touch area use the same rectangle. Existing buttons keep 100% dimensions.

The existing `touch-layout.json` stores these additions alongside the original
positions, images and actions. Old layouts remain readable. This does not import
Horizon Android layout files: their presets and bindings use a different format.

Adapted from Horizon Android under MIT; see `THIRD_PARTY_NOTICES.md`.
