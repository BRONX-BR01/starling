# Accounts on Android

Open the account button in the title screen to add or switch profiles. The choice
is kept across restarts. Remove asks for confirmation and removes only that
profile and its saved sign-in; worlds and other profiles stay in place.

- **Microsoft** uses Starling's existing browser device-code sign-in. Follow the
  browser's account creation link if you need a Microsoft account. Starling shows
  the current sign-in stage after browser authorization and keeps the result
  visible until **Done** is pressed. A Minecraft
  Java entitlement is required for authenticated Microsoft play.
- **Ely.by** accepts a username or email and password, with an optional six-digit
  two-factor code. **Log in** submits the form; **Show password** / **Hide password**
  controls only the visible password field. The code remains masked. **Register**
  opens Ely.by's registration page. This session
  joins servers configured for Ely.by authentication; it does not authenticate
  with Microsoft's session servers or grant Minecraft ownership.
- **Offline** saves a name of 1–16 ASCII letters, digits or underscores. It works
  for single player, LAN and servers that allow offline players. It has no
  registration or online authentication.

Switch profiles from the title screen before opening a world or joining a server.
The title player preview follows the selected name. While a profile is selected,
Skin Customization directs name changes to Accounts instead of editing the old
offline alias.
A failed sign-in or activation leaves the previous profile selected. Cancelling
an in-flight sign-in prevents its late completion from replacing a later choice.
**Game files** still opens Starling's existing resumable official-file download.

Profile names, UUIDs, providers and the selection are stored as metadata in the
app's private `accounts/accounts.json`. Refresh/access tokens use Starling's
existing Android Keystore-backed sealed store. Passwords and two-factor codes
are used for one request and are not saved. Legacy Microsoft profiles and their
existing secret keys remain readable. Equal UUIDs from different providers have
separate secret keys and account status caches.

A desktop explicitly using `STARLING_ACCOUNTS=1` uses the same menu; without a
platform keystore its sign-in secrets remain in memory for that run. Normal
launcher-managed desktop sessions keep their existing launch flow.

The provider/profile model and Ely.by protocol are adapted from Horizon Android;
see `THIRD_PARTY_NOTICES.md`. Skin editing and upload are separate work.

On a fresh installation, **Set up Starling** offers Microsoft, Ely.by, offline
profiles and importing prepared files. Ely.by and offline forms use the setup's
resource-independent card and Android keyboard: no game assets are needed to
sign in. Registration, password visibility and optional 2FA are available there
too. Errors retry the chosen provider; Cancel or Back returns to the choice.
Microsoft's actual authorization stages are shown in setup as in the title menu.
After authentication (or a saved offline name), downloading and preparation
continue through Starling's existing installer. Ely.by does not grant Microsoft
server access or establish Minecraft ownership.
