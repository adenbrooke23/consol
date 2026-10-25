This guide was written with AI assistance for use with AI tools.

# Consol: guide for AI assistants

**For people:** paste or attach this file into an AI assistant (ChatGPT, Claude, Copilot or similar) before asking for help installing, configuring or extending Consol. It gives the assistant the context it needs. The [README](README.md) has the full installation guide.

**For the assistant:** you are helping someone install, configure, troubleshoot or modify Consol. Everything below describes the code as it is in this repository. Prefer it over general assumptions about Sonos, Spotify or Apple TV integrations, and follow the rules in "Rules the code depends on" when suggesting changes. When something here conflicts with what the user sees, ask them to check the code or the logs rather than guessing.

## Project summary

Consol is a single-household home entertainment controller with three parts:

- **Hub** (`hub/`): a Python 3.10+ FastAPI service on an always-on Mac, port 8000. It controls Sonos speakers with SoCo (local UPnP), plays Spotify on them through Sonos ShareLink, uses the Spotify Web API for search and browsing only, and controls Apple TVs with pyatv. It owns every credential and stores state in SQLite (`hub/data.db`).
- **Keeper** (`hub/hubkeeper.py`): a standard-library supervisor on port 8001, run by launchd as the agent `local.consol.hubkeeper`. It starts and stops the hub and advertises it over Bonjour as `_consol-hub._tcp`.
- **iPad app** (`Console/`, SwiftUI, Xcode target "Console", iPadOS 18.1+): the remote. It talks only to the hub over HTTP on the LAN, finds it through Bonjour, and signs users in with a four-digit PIN.
- **Mac app** (`HubApp/`, SwiftUI, product name "CONSOL Hub", macOS 14+): an installer wizard and a dashboard. It bundles a copy of `hub/` and installs it to `~/Library/Application Support/CONSOL/hub`.

Default bundle identifiers are `com.example.consol` (iPad) and `com.example.consol.hub` (Mac), with no development team set. Users must set their own.

It is a personal project, not a product. Spotify Premium, a Spotify Developer app and a Spotify service link in the Sonos app are required.

## Architecture

- **Components.** The iPad app and the Mac app call the hub (FastAPI) over HTTP on port 8000; the Mac app also calls the keeper on port 8001. The hub controls the Sonos speakers with SoCo over UPnP, reads the Spotify Web API with httpx (search, browse, playlists) and controls the Apple TVs with pyatv (Companion and AirPlay). launchd keeps the keeper alive; the keeper starts the hub and advertises it over Bonjour as `_consol-hub._tcp`. The speakers stream audio from Spotify themselves.
- **Playback path.** To play, the hub finds the room's Sonos group coordinator, clears its queue, adds the Spotify URI with SoCo's `ShareLinkPlugin`, and calls `play_from_queue`. The speaker streams the audio from Spotify using the account linked in the Sonos app. The hub never touches audio.
- **Why not Spotify Connect.** Spotify's Web API returns 403 "Restricted device" when a third-party app tries to control a Sonos player, reports Sonos device IDs as null and often omits Sonos speakers from `/me/player/devices`. This is a Spotify policy, so the local SoCo path is the only playback route. Do not suggest switching to Connect.
- **State normalization.** The hub turns all third-party data into flat shapes. Content items are `{kind, id, uri, title, subtitle, image}`. The player snapshot from `GET /spotify/player?room=` is `{active, is_playing, progress_ms, duration_ms, shuffle, repeat, device: {id, name, volume_percent}, group: [room names], track: {kind, id, uri, title, subtitle, image} | null}`. The apps never parse raw Spotify, Sonos or pyatv payloads.
- **Speaker cache.** `sonos.py` keeps a zone cache (5-minute lifetime). It refreshes through known speakers by unicast first, then multicast discovery, then speaker IPs saved in the `secrets` table under `sonos_zone_ips`. A successful refresh saves the IPs again. launchd-run processes cannot use multicast on macOS, so a keeper-started hub relies on the saved IPs. The Mac app's installer seeds them from a GUI process.
- **Apple TV connections** are held open per device (`appletv._session`) so that pushed now-playing state arrives. A stale connection is dropped and the command retried once.
- **Auth.** Users have a role (`admin`, `member` or `kid`), a PBKDF2 PIN hash and one long-lived API token. `POST /login/pin` resolves a user from the PIN alone (PINs are unique) and returns the token. Mutations require `Authorization: Bearer <token>`. Reads are open.
- **Keeper.** `GET /health` and `GET /status` return `{ok, hub_running}`. `POST /start` and `POST /stop` need any valid user token (open while the users table is empty). Start spawns `hub/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000` detached, logging to `hub/hub.log`. Stop calls the hub's `POST /admin/stop`. "Running" means port 8000 answers.
- **iPad discovery.** The app browses `_consol-hub._tcp`, connects once to the first result to learn its IP, and stores it in UserDefaults (`console.hubhost`). A manual "Hub address" field on the Profile tab writes the same setting. The keeper URL is the same host on port 8001.

## Rules the code depends on

Keep these intact in any change you suggest:

1. **Every playback command names a room**, and the hub sends it to that room's speaker locally. All `/spotify/*` playback routes require `room` and resolve it to a Sonos device through `sonos._find`. Never add a playback, pause, volume, queue or transfer command that does not name a room, and never call Spotify Web API player endpoints without a target. Untargeted Spotify player calls act on whatever device is active on the account, which can be someone's phone or work computer.
2. **The Spotify Web API is for content only**: search, artists, albums, playlists, shows, audiobooks and the account profile. Playback control goes through Sonos.
3. **Group transport goes to the group coordinator.** Transport, queue, play mode and seek act on `device.group.coordinator`. A grouped room's volume sets the group volume.
4. **Bonded-pair satellites are never commanded.** `group.members` includes the hidden half of a stereo pair; filter with `is_visible` before acting on members. Commanding a satellite fails with UPnP error 1023.
5. **A coordinator with members cannot `unjoin()`** (also UPnP 1023). Moving or leaving uses `DelegateGroupCoordinationTo` (`sonos._delegate_and_leave`). In `switch_room`, extra members are removed only after the delegation, never before.
6. **Room chip taps switch, they do not group.** Moving playback to another room is a straight switch (`POST /spotify/switch`). Grouping happens only through explicit group actions. Never auto-group.
7. **The hub is the only component holding secrets.** Spotify credentials (`.env`), the Spotify refresh token, Apple TV credentials, PIN hashes and tokens (`data.db`) stay on the hub. The apps hold only the user's hub token. Never move a secret into an app, and never commit `.env` or `data.db`.
8. **Protected Apple TVs are refused by the hub.** Identifiers listed in `PROTECTED_APPLE_TVS` (in `hub/.env`, comma-separated) are rejected by `appletv.guard()` in every path that can reach a TV: connecting, pair start, pair finish and the room-mapping route all return 403. Discovery reports them with `protected: true` and never as paired, and the iPad app hides their controls. Do not add a path to a TV that bypasses `guard()`.
9. **Do not reimplement Spotify audio** (librespot and similar are out of scope and against Spotify's terms), do not stream audio through the hub, and do not suggest AirPlay audio for Spotify.
10. **Spotify development-mode limits are real.** Spotify tightened development mode in February 2026: the app owner needs Premium, new apps allow five users, search `limit` is capped at 10, artist top tracks and the `popularity` fields are gone, playlist items are only returned for playlists the user owns or collaborates on, and several endpoints moved (library saves to `/me/library`, playlist creation to `POST /me/playlists`, `/playlists/{id}/tracks` to `/playlists/{id}/items`). The hub's like and playlist-edit calls still use the old paths and get 403, which the hub reports plainly instead of retrying. Keep `limit` at 10 or below on search and artist album requests.
11. **Never expose the hub to the internet.** It is plain HTTP with PIN-derived tokens and no rate limiting.
12. **UPnP 701 and 711** during skip or seek mean "nothing to skip to" or "nothing to seek in"; the hub maps them to friendly 409 responses. Keep that mapping when touching transport.

## File map

| Path | What it contains |
| --- | --- |
| `hub/main.py` | All HTTP routes, exception-to-status mapping, the Debug heartbeat watchdog, admin and user management. |
| `hub/sonos.py` | Zone cache and discovery, rooms, now playing, player snapshot, ShareLink playback, switch, group, ungroup, volume, transport, queue. |
| `hub/spotify.py` | Loads `hub/.env` into the environment, OAuth (authorization code flow), Web API helpers, normalization, development-mode workarounds. |
| `hub/appletv.py` | Apple TV scan (tvOS devices only), pairing (Companion, AirPlay), held connections, status, power, apps, keys, text, seek, artwork, protected-device guard. |
| `hub/auth.py` | PBKDF2 PIN hashing, token generation, `get_current_user`, `require_admin`, kid volume cap. |
| `hub/db.py` | SQLite schema (`users`, `rooms`, `secrets`, `recents` and unused tables), secrets and room-mapping helpers. `HUB_DB` env var overrides the path. |
| `hub/models.py` | Pydantic request bodies. |
| `hub/hubkeeper.py` | Keeper HTTP server on 8001, Bonjour advertisement via `/usr/bin/dns-sd -R`, start and stop logic. |
| `hub/launchd/local.consol.hubkeeper.plist` | launchd agent template for a manual install. |
| `hub/.env.example` | Every configuration variable. |
| `hub/requirements.txt` | fastapi, uvicorn[standard], soco, pyatv, pydantic>=2, httpx, requests (unpinned). |
| `Console/Console/Services/Hub.swift` | The iPad app's only network client: base URL, token storage, every hub call. |
| `Console/Console/Services/HubDiscovery.swift` | Bonjour browse and resolve. |
| `Console/Console/Stores/AuthStore.swift` | PIN login (`/login/pin`), client-side lockout (3 failures, 30 seconds), PIN change. |
| `Console/Console/Stores/SessionStore.swift` | Session cards, outputs (Sonos rooms plus paired and mapped TVs), playback polling. |
| `Console/Console/Screens/` | Login, Stage and session chooser, Devices, Profile (in `Stage/PlaceholderTabs.swift`). |
| `Console/Console/ConsoleApp.swift` | App entry and Debug-only `UITEST_*` launch hooks (`UITEST_AUTOLOGIN=1` signs in as mock admin "Alex", PIN 1111, which must exist on a real hub). |
| `Console/Console/Fonts/` | Martian Mono (OFL, license included). General Sans is not redistributable and must be downloaded from Fontshare by the builder (four OTFs: Regular, Medium, Semibold, Bold); without it the app falls back to the system font. |
| `Console/Info.plist` | Local network usage text, `NSBonjourServices` (`_consol-hub._tcp`), local-networking ATS exception. |
| `HubApp/HubApp/Services/HubInstaller.swift` | Install steps, launchd plist generation, uninstall. |
| `HubApp/HubApp/Services/StackMonitor.swift` | Dashboard polling, sign-in, user management, start, stop, restart. |
| `HubApp/HubApp/Screens/WizardView.swift`, `DashboardView.swift` | Setup wizard and dashboard. |
| `HubApp/HubApp.xcodeproj` | Contains a Run Script build phase that rsyncs `hub/` into the app bundle as `hub-payload`, excluding `.venv`, `data.db`, `.env`, `__pycache__` and logs. |
| `docs/design/style-guide.html` | Original iPad app design specification (some features in it are not built). |

## Data stored by the hub

- `.env`: `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, optional `SPOTIFY_REDIRECT_URI` (default `http://127.0.0.1:8000/spotify/callback`), optional `NETWORK_NAME`, optional `PROTECTED_APPLE_TVS` (comma-separated, case-insensitive). Plain `KEY=value` lines; the loader does not strip quotes or trailing comments. Real environment variables win over the file.
- Process environment only (read before `.env` is loaded): `HUB_DB` (database path; the keeper ignores it and always uses `data.db` next to itself), `HUBKEEPER_AUTOSTART` (`0` disables starting the hub when the keeper launches).
- `data.db` tables in use: `users` (name, role, pin_hash, api_token, max_volume, locked), `rooms` (room name to Apple TV identifier and optional HDMI input), `secrets` (`spotify_refresh_token`, `atv_credentials_<identifier>`, `sonos_zone_ips`, `network_name`), `recents` (last 30 items played on the speakers).
- Logs: `hub.log` (hub, written by the keeper's launch) and `hubkeeper.log` (keeper, from the launchd plist), both in the hub folder.

## Setup sequence

Walk the user through these in order. Ask the listed questions, and confirm each check before moving on.

1. **Prerequisites.**
   Ask: Do you have a Mac that can stay on and logged in, with macOS 14 or later? An iPad with iPadOS 18.1 or later? Sonos speakers already working in the Sonos app? Spotify Premium? An Apple ID or paid Apple Developer membership? Which Xcode version? What does `python3 --version` print?
   Check: Python must be 3.10 or later (the hub's type syntax fails on 3.9, which is Apple's `/usr/bin/python3`). Xcode 16 or later (last built with 26.3); Xcode 26 if the iPad runs iPadOS 26 or for TestFlight.

2. **Sonos service link.**
   Ask the user to add Spotify in the Sonos app (Settings, services section) with the household Premium account.
   Check: the user can play Spotify on a room from the Sonos app.

3. **Spotify Developer app.**
   Ask the user to create an app at developer.spotify.com/dashboard with redirect URI `http://127.0.0.1:8000/spotify/callback` and the Web API selected, then copy the client ID and secret. The developer account must have an active Premium subscription (Spotify rule since February 2026), so using the household Premium account is simplest. If the account they will link is not the developer account, it must be added under User Management (five users maximum for new apps).
   Check: they have both values. Never ask them to paste the secret into the chat; tell them where to enter it.

4. **Python** (Mac app path). The installer looks for Python 3.10 or later in the Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), python.org and pyenv locations, builds `.venv` with the first match, rebuilds an existing `.venv` that uses an older Python, and stops with "Python 3.10 or later is required" if it finds none. If the user only has Apple's 3.9, have them install Python from python.org or with `brew install python` first.
   Check: after install, `"$HOME/Library/Application Support/CONSOL/hub/.venv/bin/python" --version` prints 3.10 or later.

5. **Install the hub.**
   Mac app path: open `HubApp/HubApp.xcodeproj`, set signing (a team, or Sign to Run Locally) and a unique bundle ID, run, and complete the wizard (Spotify credentials, admin name and PIN, members with unique four-digit PINs, optional network name). Allow local network access when macOS asks.
   Manual path: `cd hub && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt && cp .env.example .env`, edit `.env`, run `.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000`, create the first admin with an unauthenticated `POST /users` (allowed only while there are no users), open `/rooms` once from that Terminal-started hub so it saves speaker IPs, then install the plist from `hub/launchd/` with its paths edited and `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.consol.hubkeeper.plist`.
   Check: `curl -s http://127.0.0.1:8001/health` returns `{"ok": true, "hub_running": true}` and `curl -s http://127.0.0.1:8000/rooms` lists the Sonos rooms.

6. **Authorize Spotify.**
   Ask the user to open `http://127.0.0.1:8000/spotify/auth` in a browser on the hub Mac (the redirect goes to 127.0.0.1, so it must be that Mac), or press Link Spotify in the Mac app.
   Check: `curl -s http://127.0.0.1:8000/spotify/status` shows `"configured": true, "connected": true`.

7. **Build the iPad app.**
   Ask: free Apple ID or paid membership? Set the team and a unique bundle ID on the Console target. Recommend the Release build configuration for daily use (Debug builds send a heartbeat that makes the hub pause music about 20 seconds after polling stops). On first device install, Developer Mode must be on; with a free Apple ID, the developer certificate must be trusted in Settings and the install expires after 7 days.
   Also: General Sans is not in the repository; the user downloads it from Fontshare and copies the four OTF files into `Console/Console/Fonts/` (optional; the system font is used otherwise).
   Check: the app launches and shows the PIN screen.

8. **Sign in.**
   The user enters a PIN from the wizard and allows local network access.
   Check: the Stage appears and the chooser lists the Sonos rooms. If the app cannot reach the hub, see troubleshooting. On a device the app has no default hub address and learns it through Bonjour; the manual Hub address field is behind the sign-in screen, so the first sign-in requires Bonjour to work (same subnet, mDNS allowed, local network permission granted to the app).

9. **Optional: Apple TVs.** See "Pair an Apple TV" below.

10. **Keep it running.** The Mac must stay awake (Energy settings) and the hub's user must stay logged in (automatic login helps after power cuts), because the keeper is a per-user launchd agent.

## API reference

Base URL `http://<hub>:8000`. "Token" means `Authorization: Bearer <token>` from any user; "admin" means an admin's token; "open" means no token. Error bodies are `{"detail": "..."}`. Unknown rooms return 404. Interactive docs: `GET /docs`.

### Health, login and users

| Method and path | Auth | Purpose and body |
| --- | --- | --- |
| `GET /health` | open | `{"status":"ok"}` |
| `POST /login/pin` | open | `{"pin":"1234"}` returns `{name, role, token}`. 401 wrong PIN, 403 locked. |
| `POST /login` | open | `{"name":"...","pin":"1234"}` returns `{token}`. Used by the Mac app. |
| `GET /me` | token | The caller's user row without hash or token. |
| `PUT /users/me/pin` | token | `{"name":"","pin":"1234"}`; four digits; 409 if another user has it. |
| `GET /users` | token | Roster: id, name, role, max_volume, locked. |
| `POST /users` | admin (open while no users exist) | `{"name":"...","role":"member","pin":"1234","max_volume":null}`. The bootstrap user is always admin. Returns the new token. 409 if the name or PIN is taken. |
| `PUT /users/{name}/pin` | admin | `{"pin":"1234"}` resets a PIN. |
| `POST /users/{name}/lock`, `/unlock` | admin | Lock refuses login and kills the token. Cannot lock yourself or the last unlocked admin. |
| `DELETE /users/{name}` | admin | Cannot delete the last admin. |

### Admin

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /admin/info` | open | `{"network": "..."}` |
| `PUT /admin/network` | admin | `{"name":"..."}` sets the network label (stored in the DB, beats `NETWORK_NAME`). |
| `GET /admin/logs?source=hub\|keeper&lines=200` | admin | Tail of `hub.log` or `hubkeeper.log`. |
| `POST /admin/restart` | token | Re-execs the hub in place (501 under `--reload`). |
| `POST /admin/stop` | token | Exits the hub. Start again through the keeper. |
| `PUT /admin/rooms/{name}/tv` | admin | `{"appletv_id":"...","hdmi_input":null}` maps a room name to an Apple TV. 403 for protected TVs. |

### Sonos and Spotify playback (local, room-targeted)

| Method and path | Auth | Body or query |
| --- | --- | --- |
| `GET /rooms` | open | All rooms: name, uid, volume, group_id, coordinator_name, is_coordinator, members. |
| `GET /now-playing`, `GET /rooms/{room}/now-playing` | open | Speaker now-playing snapshots. |
| `GET /spotify/player?room=` | open | Player snapshot for the room (`watch=1` registers the Debug heartbeat). Without `room` it returns the Spotify account's active player, for debugging only. |
| `POST /spotify/play` | token | `{"room":"...","context_uri":"spotify:album:...","start_index":0}` or `{"room":"...","uris":["spotify:track:..."]}`. A single track URI plays inside its album. Neither field resumes. |
| `POST /spotify/pause`, `/next`, `/previous` | token | `{"room":"..."}`. Skip returns 409 at the end of the queue. |
| `PUT /spotify/shuffle` | token | `{"room":"...","state":true}` |
| `PUT /spotify/repeat` | token | `{"room":"...","state":"off"\|"context"\|"track"}` (Sonos treats any non-off as repeat all). |
| `PUT /spotify/volume` | token | `{"room":"...","percent":30}`; group volume for grouped rooms. |
| `POST /spotify/seek` | token | `{"room":"...","position_ms":60000}` |
| `POST /spotify/switch` | token | `{"from_room":"...","to_room":"..."}` moves playback. |
| `POST /spotify/group` | token | `{"rooms":["anchor","other"]}`, at least two; first is the coordinator. |
| `POST /spotify/ungroup` | token | `{"room":"..."}` |
| `GET /spotify/queue?room=&limit=40` | open | The room's queue with absolute 0-based positions and `playing_position` (1-based). |
| `POST /spotify/queue` | token | `{"room":"...","uri":"spotify:track:..."}` appends. |
| `POST /spotify/queue/play` | token | `{"room":"...","position":3}` |
| `POST /spotify/queue/remove` | token | `{"room":"...","positions":[3,4]}` |
| `POST /spotify/queue/reorder` | token | `{"room":"...","from_position":5,"insert_before":1}` |
| `POST /group`, `POST /rooms/{room}/ungroup`, `PUT /rooms/{room}/volume`, `POST /rooms/{room}/transport/{play\|pause\|next\|previous}` | token | Older role-aware routes; the kid role's limits are checked here only. |

### Spotify content (Web API)

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /spotify/status` | open | `{configured, connected, redirect_uri, scopes}` |
| `GET /spotify/auth`, `GET /spotify/callback` | open | One-time OAuth in a browser on the hub Mac. |
| `GET /spotify/search?q=&limit=8&scope=music\|podcasts\|books` | open | `{results:[flat items]}`; keep `limit` at 10 or below. |
| `GET /spotify/artists/{id}`, `/albums/{id}`, `/shows/{id}` | open | Browse pages. |
| `GET /spotify/playlists`, `/playlists/{id}/tracks` | open | The account's playlists; tracks capped at 100. |
| `GET /spotify/library` | open | Saved shows and audiobooks. |
| `GET /spotify/recents?limit=12` | open | What the speakers played recently (hub-recorded). |
| `GET /spotify/me`, `/devices`, `/now-playing` | open | Account profile and raw Connect state, for debugging. |
| `POST /spotify/playlists`, `POST /spotify/playlists/{id}/tracks`, `PUT`/`DELETE /spotify/tracks/saved` | token | Exist, but Spotify returns 403 for them (old endpoints, development mode); the hub answers 409 with an explanation. |

### Apple TV

`{device}` is a mapped room name or a raw identifier.

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /tv/devices` | open | Scan (about 5 s) of tvOS devices: name, identifier, address, model, paired, room, protected. |
| `POST /tv/pair/start` | admin | `{"identifier":"...","protocol":"Companion"\|"AirPlay"}`; the TV shows a PIN. |
| `POST /tv/pair/finish` | admin | `{"identifier":"...","pin":"1234"}` stores credentials. |
| `POST /tv/pair/cancel` | admin | `{"identifier":"..."}` |
| `GET /tv/{device}/status` | open | power, app, app_id, state, title, position, total_time, `can` flags. |
| `GET /tv/{device}/apps` | open | Installed apps `{name, id}`. |
| `GET /tv/{device}/artwork` | open | Now-playing image bytes. |
| `POST /tv/{device}/power/{on\|off}` | token | |
| `POST /tv/{device}/launch/{app_id}` | token | Bundle ID from the apps list. |
| `POST /tv/{device}/key/{button}?seconds=` | token | up, down, left, right, select, menu, home, play_pause, skip_forward, skip_backward. `seconds` applies to skips. |
| `POST /tv/{device}/text` | token | `{"text":"..."}` replaces the focused text field; 409 if none. |
| `POST /tv/{device}/seek` | token | `{"position":600}` seconds; returns `applied` true or false. |

Apple TV errors map to 409 (needs re-pairing, or the app cannot do that), 504 (not answering), 502 (protocol error), 403 (protected) and 404 (not found on the network).

### Keeper (port 8001)

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /health`, `GET /status` | open | `{ok, hub_running}` |
| `POST /start`, `POST /stop` | token (open while no users exist) | Start or stop the hub. |

## Common tasks

Use these shell variables in examples (run on the hub Mac; replace the PIN with an admin PIN):

```sh
HUB=http://127.0.0.1:8000
TOKEN=$(curl -s -X POST "$HUB/login/pin" -H 'Content-Type: application/json' \
  -d '{"pin":"1234"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
```

- **Add a user.** Mac app dashboard, Users card (members only), or `curl -s -X POST "$HUB/users" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"Guest","role":"member","pin":"4321"}'`. PINs must be four digits and unique. The iPad needs no update.
- **Reset a PIN or lock someone out.** Dashboard, or `PUT /users/{name}/pin` and `POST /users/{name}/lock`.
- **Re-link Spotify** (different account, or revoked access). Open `http://127.0.0.1:8000/spotify/auth` on the hub Mac and approve again; the new refresh token replaces the old one. If the client ID or secret changed, edit `.env` first and restart the hub. The account should match the one linked in the Sonos app.
- **Add Spotify credentials after a blank install.** Edit `~/Library/Application Support/CONSOL/hub/.env` (`SPOTIFY_CLIENT_ID=...`, `SPOTIFY_CLIENT_SECRET=...`, plain `KEY=value` lines with no quotes or trailing comments), restart the hub, then link as above. Re-running the Mac app's setup also works: it merges `.env`, updating only the Spotify keys and `NETWORK_NAME` and keeping other lines such as `PROTECTED_APPLE_TVS`.
- **Pair an Apple TV.** `GET /tv/devices` to get the identifier; `POST /tv/pair/start` with `"protocol":"Companion"`, read the PIN on the TV, `POST /tv/pair/finish`; repeat with `"protocol":"AirPlay"`. The TV counts as paired only when both are stored.
- **Map a room to a TV.** `curl -s -X PUT "$HUB/admin/rooms/Den/tv" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"appletv_id":"AA:BB:CC:DD:EE:FF"}'`. URL-encode spaces. The iPad offers a TV in its chooser only when it is paired and mapped; the app loads outputs when its main screen appears, so relaunch or sign out and in.
- **Protect a TV.** Add its identifier (as shown by `GET /tv/devices`; matching ignores case) to `PROTECTED_APPLE_TVS` in `.env`, comma-separated, and restart the hub.
- **Change the hub address on the iPad.** Normally automatic. Otherwise, after signing in: Profile tab, Network card, Hub address field, enter the Mac's IP (`ipconfig getifaddr en0` on the Mac), press Return.
- **Re-run speaker discovery** (all speakers changed IP). From Terminal in the hub folder, run a script that calls `soco.discover(timeout=8)` and saves `{player_name.lower(): ip}` to the `sonos_zone_ips` secret with `db.set_secret`; the README's troubleshooting section has the exact script.
- **Restart the hub.** Dashboard Restart, iPad Profile, or `curl -X POST "$HUB/admin/restart" -H "Authorization: Bearer $TOKEN"`. Start a stopped hub with `curl -X POST http://127.0.0.1:8001/start -H "Authorization: Bearer $TOKEN"` or the dashboard's Start (which can also kick the keeper through `launchctl kickstart`).
- **Rebuild the apps.** iPad: open `Console/Console.xcodeproj`, check signing, build Release to the device. Mac: open `HubApp/HubApp.xcodeproj` and run. After changing `hub/` code, the installed hub does not change until the Mac app is rebuilt and the hub reinstalled (or the changed files are copied into `~/Library/Application Support/CONSOL/hub` and the hub restarted). A reinstall keeps `.env`, `data.db` and `.venv`; Uninstall deletes them.
- **Run the hub from the checkout for development.** `launchctl bootout gui/$(id -u)/local.consol.hubkeeper`, then `cd hub && .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload`.

## Troubleshooting by symptom

| Symptom | Likely cause and fix |
| --- | --- |
| Installer stops at "Wait for the hub to answer" | Read `hub.log` in the install folder. `TypeError: unsupported operand type(s) for \|` means Python 3.9; install Python 3.10+ and run the install again (the installer rebuilds an old `.venv`). Missing modules mean the dependency step failed. |
| Installer says no speakers answered | macOS local network permission for CONSOL Hub was denied or not yet granted. Allow it in System Settings > Privacy & Security > Local Network and run the install again. Speakers must be on the Mac's subnet. |
| iPad: "Can't reach the hub" | Same network? Guest network or VLAN blocking mDNS or client traffic? Local network permission for the app? macOS firewall blocking the venv's Python? Hub running (`curl http://<mac-ip>:8000/health` from another device)? The manual Hub address field is on the Profile tab, which requires signing in first. |
| Wrong PIN on iPad | PIN must exist in the hub's `users` table. Check with `GET /users` and an admin token, or reset it in the dashboard. Three wrong PINs lock the iPad's PIN screen for 30 seconds (client-side only). |
| 403 "account locked" | The user is locked. Reactivate them in the dashboard or with `POST /users/{name}/unlock`. |
| No rooms, or rooms vanish after a router restart | The hub cannot reach any saved speaker IP. Re-run discovery from Terminal (see above). Recommend DHCP reservations. |
| Play returns an error, or the speaker stays silent | Sonos service link missing or tied to another account, account not Premium, or the URI is not playable in the account's market. Test from the Sonos app. |
| 409 "end of queue" on skip | The queue has nothing after the current track. Expected for one-track queues. |
| 409 "nothing playing to scrub" | Seek on a stopped room or empty queue. |
| 409 about playlist or library edits | Spotify returns 403 for the hub's write calls, which use pre-February-2026 endpoints. Fixing it would mean moving to the new endpoints, and it is unverified whether development mode allows them. |
| 500 "Spotify creds missing (hub/.env)" | `.env` lacks the client ID or secret. Edit and restart. |
| 409 starting with "not connected" | Spotify was never authorized or the token was lost. Authorize again. |
| Spotify "INVALID_CLIENT: Invalid redirect URI" | Dashboard redirect URI must equal `SPOTIFY_REDIRECT_URI` exactly. |
| Music pauses about 20 s after the iPad locks | Debug build heartbeat. Build Release. |
| `/tv/devices` is empty | TVs asleep or on another network, or multicast is blocked for the launchd-run hub (there is no unicast fallback for Apple TVs yet). Try running the hub from Terminal to compare. |
| Apple TV 409 "needs re-pairing" | Credentials invalid. Pair both protocols again. |
| Apple TV 409 "did not announce ..." | Incomplete mDNS announcement; retry after a moment. |
| Apple TV 504 "not answering" | TV asleep or unreachable; the next request reconnects. |
| Apple TV seek returns `applied: false` | The app refused it, often during ads. |
| Apple TV 403 "protected device" | Listed in `PROTECTED_APPLE_TVS`. Intended. |
| Restart returns 501 | Hub is running under `--reload` or not via the uvicorn CLI; use stop and start. |
| Code changes have no effect | The installed hub runs from `~/Library/Application Support/CONSOL/hub`, not the checkout. |
| Mac app "Wrong name or PIN" | `/login` matches the name exactly, including case. |
| iPad app stops launching after 7 days | Free Apple ID provisioning expired; reinstall from Xcode. |

## Guidance for extending Consol

- Add hub features as small, predictable routes in `hub/main.py`, with logic in the relevant module. Normalize every third-party payload into flat shapes before returning it.
- Any route that changes state takes `user: dict = Depends(auth.get_current_user)`; add `auth.require_admin(user)` for household-level settings.
- Any new playback route must take a room and go through `sonos._find(room).group.coordinator`.
- Any new Apple TV path must go through `appletv.guard()` (directly or via `_session` and `_connect`).
- SoCo calls are blocking, so Sonos routes are plain `def` (FastAPI runs them in a thread pool). pyatv is async, so Apple TV routes are `async def`.
- Keep Spotify list `limit` values at 10 or below where development mode enforces it. If you add or fix write features (likes, playlists), use the post-February-2026 endpoints (`PUT`/`DELETE /me/library` with URIs, `POST /me/playlists`, `/playlists/{id}/items`) and check against Spotify's current documentation; it has not been verified whether development mode allows them.
- In the iPad app, `Hub.swift` is the only place that talks to the network. The hub is authoritative; the app reflects its state.
- There are no automated tests. Verify changes against real devices, and test playback only with a named room.
