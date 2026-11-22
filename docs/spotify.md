# Spotify on the Stream Deck

Home key **6** opens Spotify. The submenu keeps **Home at 1** and **Menu at 5**:

| Key | Button | Result |
| --- | --- | --- |
| 2 | Play Here | Bring the current queue to this computer and resume it. |
| 3 | Low Roar / 0 | Play Low Roar's album *0* on this computer. |
| 4 | Low Roar / Album | Play Low Roar's self-titled album on this computer. |
| 6 | Ambient | Play the requested Ambient playlist on this computer. |

These are explicit playback actions. Installation, authorization, and `status`
do not play, pause, transfer, or change volume. Keep Spotify desktop open and
logged in; the buttons do not launch it or fall back to another device.

## Connect once

Spotify's desktop MPRIS interface has playback/URI controls, but no device-transfer
operation. Knobby uses the [official playback API](https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback)
to select this computer explicitly. Spotify Premium is required. No ChatGPT
connector, client secret, or other application's authorization is used.

1. Open [Spotify's developer dashboard](https://developer.spotify.com/dashboard)
   and create a **Knobby** application using **Web API**.
2. Register this exact redirect URI: `http://127.0.0.1:43821/callback`.
   If Spotify requires an authorized-user entry, add your Spotify account in the
   app's user management page. Copy its **Client ID**, not its client secret.
3. Run `~/.local/bin/knobby-spotify authorize --client-id YOUR_CLIENT_ID`.
   Open the consent URL it prints and approve reading playback state and
   modifying playback. The loopback listener expires after five minutes.
4. Run `~/.local/bin/knobby-spotify status` to verify device availability without
   changing playback. Then try a Deck button when you want music.

The device name defaults to this computer's hostname (`high-steel`). If Spotify
uses a different name, repeat authorization with `--device-name 'EXACT NAME'`.
A missing, restricted, or duplicate matching device is refused; Knobby never
chooses a phone or remote speaker because it happens to be active.

Authorization requests only `user-read-playback-state` and
`user-modify-playback-state`, using [PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow).
Tokens are stored owner-private in `~/.config/knobby/spotify/credentials.json`
(or the equivalent XDG config directory), outside shared button configuration
and Git. Expiring authorization is refreshed on demand. Simultaneous commands
are refused while one is running, and failed music commands are never replayed.
Button results are recorded without credentials in `journalctl --user -t knobby-spotify`;
they do not open a window or produce a notification sound.
To disconnect, remove that file and revoke the Knobby app in Spotify's account
application settings. Do not include tokens in bug reports.

## Editable targets and artwork

The shared configuration uses ordinary command actions calling the packaged Nim
helper. The installer `nim r tools/setup_spotify_buttons.nim --apply` adds the
menu using Knobby's revision-checked apply API and preserves other controls and
subsequent Spotify edits. Artwork uses the existing pixel renderer:
`cd gui && nim r app/tools/generate_obs_icons.nim --spotify-only`.

The destinations were verified against Spotify's own pages:

- [0 — Low Roar](https://open.spotify.com/album/1jrEpZYD1Pn4Dvrg933YIp)
- [Low Roar — Low Roar](https://open.spotify.com/album/2mR9yWuHj65NkxpgFdaC2b)
- [Ambient playlist](https://open.spotify.com/playlist/40LVHt7vpqeCSaARDgcENV)
