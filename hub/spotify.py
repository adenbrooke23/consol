"""Spotify Web API integration for the hub.

Authorization Code flow: the hub holds the refresh token (in the SQLite
`secrets` table) and mints short-lived access tokens on demand. Premium is
required for playback; search and reads work regardless.

The Web API is used for search, browse and library. Playback goes through
sonos.py, and the hub never carries audio: the speaker streams from Spotify
itself. Client id/secret/redirect come from .env; the refresh token lives in
data.db. The front end only ever sees normalized data.
"""

import base64
import os
import secrets as _secrets
import threading
import time
import urllib.parse

import httpx

import db

ACCOUNTS = "https://accounts.spotify.com"
API = "https://api.spotify.com/v1"

# Scopes: playback state + control (covers shuffle/repeat/volume), playlists
# (read + add-to + create), and library (like/save). No `streaming` scope; that
# is only for the Web Playback SDK, which the hub does not use.
SCOPES = [
    "user-read-private",            # product (premium check) + country/market
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "playlist-read-private",
    "playlist-read-collaborative",
    "playlist-modify-private",
    "playlist-modify-public",
    "user-library-read",
    "user-library-modify",
]

_REFRESH_KEY = "spotify_refresh_token"


def _load_env() -> None:
    """Load .env from the hub directory into os.environ (no external dep).
    Variables already set in the process environment win."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())


_load_env()

CLIENT_ID = os.environ.get("SPOTIFY_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
REDIRECT_URI = os.environ.get(
    "SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8000/spotify/callback"
)

# In-memory access-token cache, re-minted from the refresh token as needed.
_access_token = ""
_expires_at = 0.0
# CSRF state for the in-flight authorize handshake.
_pending_state = ""


class SpotifyError(RuntimeError):
    """Raised for auth/API failures; mapped to HTTP by main.py."""


def _basic_auth_header() -> dict:
    raw = f"{CLIENT_ID}:{CLIENT_SECRET}".encode()
    return {"Authorization": "Basic " + base64.b64encode(raw).decode()}


def configured() -> bool:
    """Client id/secret present (i.e. hub/.env is wired)."""
    return bool(CLIENT_ID and CLIENT_SECRET)


def connected() -> bool:
    """A refresh token has been stored (the one-time authorize completed)."""
    return db.get_secret(_REFRESH_KEY) is not None


# --- OAuth handshake ------------------------------------------------------

def build_auth_url() -> str:
    """URL to send the browser to for the one-time consent + code grant."""
    global _pending_state
    _pending_state = _secrets.token_urlsafe(16)
    params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": " ".join(SCOPES),
        "state": _pending_state,
        "show_dialog": "true",
    }
    return f"{ACCOUNTS}/authorize?" + urllib.parse.urlencode(params)


def exchange_code(code: str, state: str) -> None:
    """Callback: swap the auth code for tokens, persist the refresh token."""
    if not _pending_state or state != _pending_state:
        raise SpotifyError("state mismatch; restart the flow at /spotify/auth")
    resp = httpx.post(
        f"{ACCOUNTS}/api/token",
        headers=_basic_auth_header(),
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
        },
        timeout=15,
    )
    if resp.status_code != 200:
        raise SpotifyError(f"token exchange failed: {resp.status_code} {resp.text}")
    tok = resp.json()
    if tok.get("refresh_token"):
        db.set_secret(_REFRESH_KEY, tok["refresh_token"])
    _cache_access(tok)


def _cache_access(tok: dict) -> None:
    global _access_token, _expires_at
    _access_token = tok.get("access_token", "")
    # refresh a minute early to avoid using a token mid-expiry
    _expires_at = time.time() + int(tok.get("expires_in", 3600)) - 60


# One refresh at a time: N cards polling with an expired token must not fire
# N concurrent refresh POSTs racing the _access_token/_expires_at globals.
_refresh_lock = threading.Lock()


def _refresh_access() -> None:
    refresh = db.get_secret(_REFRESH_KEY)
    if not refresh:
        raise SpotifyError("not connected; run /spotify/auth")
    resp = httpx.post(
        f"{ACCOUNTS}/api/token",
        headers=_basic_auth_header(),
        data={"grant_type": "refresh_token", "refresh_token": refresh},
        timeout=8,
    )
    if resp.status_code != 200:
        raise SpotifyError(f"token refresh failed: {resp.status_code} {resp.text}")
    tok = resp.json()
    # Spotify occasionally rotates the refresh token; persist if it does.
    if tok.get("refresh_token"):
        db.set_secret(_REFRESH_KEY, tok["refresh_token"])
    _cache_access(tok)


def _token() -> str:
    if not _access_token or time.time() >= _expires_at:
        with _refresh_lock:
            # double-check: the thread that held the lock likely refreshed
            if not _access_token or time.time() >= _expires_at:
                _refresh_access()
    return _access_token


# --- API helper -----------------------------------------------------------

def _api(method: str, path: str, **kwargs):
    """Call the Web API with a fresh bearer; one 401 retry after a refresh."""
    headers = kwargs.pop("headers", {})
    headers["Authorization"] = f"Bearer {_token()}"
    resp = httpx.request(method, f"{API}{path}", headers=headers, timeout=8, **kwargs)
    if resp.status_code == 401:
        with _refresh_lock:
            _refresh_access()
        headers["Authorization"] = f"Bearer {_token()}"
        resp = httpx.request(method, f"{API}{path}", headers=headers, timeout=8, **kwargs)
    if resp.status_code >= 400:
        raise SpotifyError(f"{method} {path} -> {resp.status_code} {resp.text}")
    if resp.status_code == 204 or not resp.content:
        return {}
    try:
        return resp.json()
    except ValueError:
        # some Player endpoints answer 200 with a non-JSON/blank body
        return {}


# --- Read endpoints ---------------------------------------------------------

def me() -> dict:
    d = _api("GET", "/me")
    return {
        "id": d.get("id"),
        "display_name": d.get("display_name"),
        "product": d.get("product"),   # must be "premium" for control
        "country": d.get("country"),
    }


def devices() -> dict:
    """Live Spotify Connect devices. Never cache these (they go dormant)."""
    return _api("GET", "/me/player/devices")


def now_playing() -> dict:
    return _api("GET", "/me/player")


def search(q: str, types: str = "track,artist,album,playlist", limit: int = 20) -> dict:
    """Raw Spotify search payload."""
    return _api("GET", "/search", params={"q": q, "type": types, "limit": limit})


def _img(images: list) -> str | None:
    return images[0]["url"] if images else None


def _mins(ms) -> str:
    return f"{int((ms or 0) / 60000)} min"


def _norm_show(s: dict, kind: str = "show") -> dict:
    return {
        "kind": kind, "id": s["id"], "uri": s["uri"],
        "title": s["name"],
        "subtitle": s.get("publisher") or ", ".join(
            a.get("name", "") for a in (s.get("authors") or [])) or "",
        "image": _img(s.get("images", [])),
    }


def _norm_episode(e: dict) -> dict:
    date = (e.get("release_date") or "")
    return {
        "kind": "episode", "id": e["id"], "uri": e["uri"],
        "title": e["name"],
        "subtitle": " · ".join(x for x in (date, _mins(e.get("duration_ms"))) if x),
        "image": _img(e.get("images", [])),
    }


def search_results(q: str, limit: int = 8, scope: str = "music") -> dict:
    """Flat, front-end-friendly search results the app renders directly:
    a normalized list of {kind, id, uri, title, subtitle, image}. No Spotify
    JSON shapes leak past the hub.

    scope: music (artist/track/album) | podcasts (show/episode) |
    books (audiobook)."""
    if scope == "podcasts":
        d = _api("GET", "/search",
                 params={"q": q, "type": "show,episode", "limit": limit})
        out = [_norm_show(s) for s in (d.get("shows") or {}).get("items", []) if s]
        out += [_norm_episode(e) for e in (d.get("episodes") or {}).get("items", []) if e]
        return {"results": out}
    if scope == "books":
        d = _api("GET", "/search",
                 params={"q": q, "type": "audiobook", "limit": limit})
        return {"results": [
            _norm_show(b, kind="audiobook")
            for b in (d.get("audiobooks") or {}).get("items", []) if b
        ]}
    d = _api(
        "GET", "/search",
        params={"q": q, "type": "artist,track,album", "limit": limit},
    )
    out: list[dict] = []
    for a in (d.get("artists") or {}).get("items", []):
        out.append({
            "kind": "artist", "id": a["id"], "uri": a["uri"],
            "title": a["name"], "subtitle": "Artist",
            "image": _img(a.get("images", [])),
        })
    for t in (d.get("tracks") or {}).get("items", []):
        who = ", ".join(ar["name"] for ar in t.get("artists", []))
        album = t.get("album") or {}
        out.append({
            "kind": "track", "id": t["id"], "uri": t["uri"],
            "title": t["name"], "subtitle": f"{who} · {album.get('name', '')}",
            "image": _img(album.get("images", [])),
        })
    for al in (d.get("albums") or {}).get("items", []):
        who = ", ".join(ar["name"] for ar in al.get("artists", []))
        year = (al.get("release_date") or "")[:4]
        out.append({
            "kind": "album", "id": al["id"], "uri": al["uri"],
            "title": al["name"], "subtitle": who + (f" · {year}" if year else ""),
            "image": _img(al.get("images", [])),
        })
    return {"results": out}


def _norm_track(t: dict, image: str | None = None) -> dict:
    """A track in the same flat shape search_results uses."""
    who = ", ".join(ar["name"] for ar in t.get("artists", []))
    album = t.get("album") or {}
    return {
        "kind": "track", "id": t["id"], "uri": t["uri"],
        "title": t["name"], "subtitle": who,
        "image": image or _img(album.get("images", [])),
    }


def artist(artist_id: str) -> dict:
    """Artist browse page: top tracks + albums, flat shapes for the app.

    /artists/{id}/top-tracks 403s for apps created after Spotify's November
    2024 development-mode restrictions, so approximate it: search tracks by
    the artist's exact name and rank by popularity.
    """
    a = _api("GET", f"/artists/{artist_id}")
    # development-mode apps reject limit > 10 on /search ("Invalid limit")
    found = _api(
        "GET", "/search",
        params={"q": f'artist:"{a["name"]}"', "type": "track", "limit": 10},
    )
    tracks = [
        t for t in (found.get("tracks") or {}).get("items", [])
        # exact-artist filter: the name search also matches collaborations
        if any(ar.get("id") == artist_id for ar in t.get("artists", []))
    ]
    tracks.sort(key=lambda t: -(t.get("popularity") or 0))
    raw_albums = _api(
        "GET", f"/artists/{artist_id}/albums",
        params={"include_groups": "album", "limit": 10},  # dev-mode cap
    )
    seen: set[str] = set()
    albums = []
    for al in raw_albums.get("items", []):
        name = al["name"].lower()
        if name in seen:          # drop duplicate editions (deluxe/remaster dupes)
            continue
        seen.add(name)
        year = (al.get("release_date") or "")[:4]
        albums.append({
            "kind": "album", "id": al["id"], "uri": al["uri"],
            "title": al["name"], "subtitle": year,
            "image": _img(al.get("images", [])),
        })
    # dedupe by title (the search surfaces the same song across editions)
    seen_titles: set[str] = set()
    top_tracks = []
    for t in tracks:
        title = t["name"].lower()
        if title in seen_titles:
            continue
        seen_titles.add(title)
        top_tracks.append(_norm_track(t))
        if len(top_tracks) == 5:
            break
    return {
        "id": a["id"],
        "name": a["name"],
        "image": _img(a.get("images", [])),
        "top_tracks": top_tracks,
        "albums": albums,
    }


def album(album_id: str) -> dict:
    """Album browse page: header + track list (tracks share the album art)."""
    al = _api("GET", f"/albums/{album_id}", params={"market": "from_token"})
    image = _img(al.get("images", []))
    who = ", ".join(ar["name"] for ar in al.get("artists", []))
    return {
        "id": al["id"],
        "title": al["name"],
        "artist": who,
        "year": (al.get("release_date") or "")[:4],
        "image": image,
        "tracks": [
            _norm_track(t, image) for t in (al.get("tracks") or {}).get("items", [])
        ],
    }


# --- Spotify Connect player (Premium required) -----------------------------
# Room playback goes through sonos.py, because the Web API refuses to control
# Sonos players. player_state() backs the room-less /spotify/player view.
# The Player API does not serialize back-to-back calls: await each mutation
# and re-read state via player_state() before the next.

def player_state() -> dict:
    """Normalized /me/player snapshot for the app (flat, no raw Spotify JSON)."""
    # without additional_types, a playing podcast episode comes back item:null
    d = _api("GET", "/me/player", params={"additional_types": "track,episode"})
    if not d:
        return {"active": False, "is_playing": False}
    item = d.get("item") or {}
    dev = d.get("device") or {}
    if item.get("type") == "episode":
        show = (item.get("show") or {})
        track = {
            "kind": "episode", "id": item.get("id"), "uri": item.get("uri"),
            "title": item.get("name"), "subtitle": show.get("name") or "Podcast",
            "image": _img(item.get("images", [])),
        }
    elif item.get("id"):
        track = _norm_track(item)
    else:
        track = None
    return {
        "active": True,
        "is_playing": bool(d.get("is_playing")),
        "progress_ms": d.get("progress_ms") or 0,
        "duration_ms": item.get("duration_ms") or 0,
        "shuffle": bool(d.get("shuffle_state")),
        "repeat": d.get("repeat_state") or "off",
        "device": {
            "id": dev.get("id"),
            "name": dev.get("name"),
            "volume_percent": dev.get("volume_percent"),
        },
        "track": track,
    }


def _find_device(room: str) -> dict | None:
    """Match a live Connect device to a room name (exact, then substring).

    Always queried live: Connect devices go dormant and drop off the list,
    so a cached id is unreliable.
    """
    devs = devices().get("devices", [])
    target = room.strip().lower()
    for d in devs:
        if (d.get("name") or "").strip().lower() == target:
            return d
    for d in devs:
        name = (d.get("name") or "").strip().lower()
        if name and (target in name or name in target):
            return d
    return None


def _active_matches(room: str) -> bool:
    """Is the account's active player the given room (by name)?"""
    d = _api("GET", "/me/player") or {}
    active = ((d.get("device") or {}).get("name") or "").strip().lower()
    target = room.strip().lower()
    return bool(active) and (active == target or target in active or active in target)


def _device_id_for(room: str | None) -> str | None:
    """Resolve a room to a targetable device id.

    Sonos quirk: a playing Sonos room can be missing from /me/player/devices
    and report device.id null in /me/player. If the room can't be found in
    the list but it is the verified active device, return None: an
    untargeted call then acts on the active player, which was just verified
    to be this room. Only an unverifiable room is an error.
    """
    if not room:
        return None
    d = _find_device(room)
    if d is not None and d.get("id"):
        return d["id"]
    if _active_matches(room):
        return None   # act on the active player == this room
    raise SpotifyError(
        f"no spotify device for room '{room}'. If it never appears, check "
        "the Spotify service in the Sonos app (Settings, Services). "
        "If it's linked, the speaker may be dormant: start it once from the "
        "Spotify app to wake it"
    )


def play(uris: list[str] | None = None, context_uri: str | None = None,
         room: str | None = None) -> dict:
    """Start playback on a room. uris = explicit tracks; context_uri =
    album/playlist; neither = resume. room is mandatory: untargeted play
    lands on whatever device is active anywhere on the account (a phone, a
    laptop), which this hub must never do."""
    if not room:
        raise SpotifyError("play requires a room; untargeted play is refused")
    params = {}
    device_id = _device_id_for(room)
    if device_id:
        params["device_id"] = device_id
    body: dict = {}
    if uris:
        body["uris"] = uris
    if context_uri:
        body["context_uri"] = context_uri
    _api("PUT", "/me/player/play", params=params, json=body or None)
    return player_state()


def _guard_active_is(room: str | None) -> None:
    """Refuse to steer the player unless the active device is the given room.

    Untargeted Player mutations act on whatever device is active anywhere on
    the account, which can be a phone or laptop on the same network.
    Sessions are room-bound, so every control call must prove the player is
    actually on that room's device before touching anything.
    """
    if not room:
        raise SpotifyError("no active device; commands must name a room")
    d = _api("GET", "/me/player") or {}
    active = ((d.get("device") or {}).get("name") or "").strip().lower()
    target = room.strip().lower()
    if not active:
        raise SpotifyError("no active device; start playback on the room first")
    if active != target and target not in active and active not in target:
        raise SpotifyError(
            f"no active device match: playback is on '{(d.get('device') or {}).get('name')}', "
            f"not '{room}'; refusing to touch another device"
        )


def pause(room: str | None = None) -> dict:
    _guard_active_is(room)
    _api("PUT", "/me/player/pause")
    return player_state()


def next_track(room: str | None = None) -> dict:
    _guard_active_is(room)
    _api("POST", "/me/player/next")
    return player_state()


def previous_track(room: str | None = None) -> dict:
    _guard_active_is(room)
    _api("POST", "/me/player/previous")
    return player_state()


def set_shuffle(state: bool, room: str | None = None) -> dict:
    _guard_active_is(room)
    _api("PUT", "/me/player/shuffle", params={"state": str(bool(state)).lower()})
    return player_state()


def set_repeat(state: str, room: str | None = None) -> dict:
    """state: off | context | track."""
    if state not in ("off", "context", "track"):
        raise SpotifyError(f"invalid repeat state: {state}")
    _guard_active_is(room)
    _api("PUT", "/me/player/repeat", params={"state": state})
    return player_state()


def set_player_volume(percent: int, room: str | None = None) -> dict:
    if not room:
        raise SpotifyError("volume requires a room; untargeted volume is refused")
    params: dict = {"volume_percent": max(0, min(100, int(percent)))}
    device_id = _device_id_for(room)
    if device_id:
        params["device_id"] = device_id   # None = verified-active room
    _api("PUT", "/me/player/volume", params=params)
    return player_state()


def transfer(room: str, play_now: bool = True) -> dict:
    """Move playback onto the room's Connect device (wakes a dormant one)."""
    device_id = _device_id_for(room)
    if device_id is None:
        return player_state()   # already the active player; nothing to move
    _api("PUT", "/me/player",
         json={"device_ids": [device_id], "play": bool(play_now)})
    return player_state()


def queue_add(uri: str, room: str | None = None) -> dict:
    if not room:
        raise SpotifyError("queue requires a room; untargeted queue is refused")
    params: dict = {"uri": uri}
    device_id = _device_id_for(room)
    if device_id:
        params["device_id"] = device_id   # None = verified-active room
    _api("POST", "/me/player/queue", params=params)
    return {"queued": uri}


def show(show_id: str, max_episodes: int = 30) -> dict:
    """Show/audiobook page: header + episode (chapter) list, flat shapes.
    Audiobooks ARE shows in Spotify's model (spotify:show: uris), so one
    page serves both."""
    s = _api("GET", f"/shows/{show_id}", params={"market": "from_token"})
    episodes: list[dict] = []
    inline = ((s.get("episodes") or {}).get("items")) or []
    for e in inline[:max_episodes]:
        if e:
            episodes.append(_norm_episode(e))
    offset = len(inline)
    while len(episodes) < max_episodes:
        d = _api("GET", f"/shows/{show_id}/episodes",
                 params={"limit": 10, "offset": offset, "market": "from_token"})
        batch = [e for e in (d.get("items") or []) if e]
        episodes += [_norm_episode(e) for e in batch]
        if not batch or not d.get("next"):
            break
        offset += 10
    return {
        "id": s["id"],
        "name": s["name"],
        "publisher": s.get("publisher") or "",
        "image": _img(s.get("images", [])),
        "episodes": episodes[:max_episodes],
    }


def library() -> dict:
    """The user's saved shows + audiobooks (the Library browse page)."""
    shows = []
    try:
        d = _api("GET", "/me/shows", params={"limit": 20})
        shows = [
            _norm_show(it["show"]) for it in (d.get("items") or [])
            if it.get("show")
        ]
    except SpotifyError:
        pass
    books = []
    try:
        d = _api("GET", "/me/audiobooks", params={"limit": 20})
        books = [_norm_show(b, kind="audiobook") for b in (d.get("items") or []) if b]
    except SpotifyError:
        pass
    return {"shows": shows, "audiobooks": books}


def album_context(track_id: str) -> dict | None:
    """The track's album URI + its position in that album.

    Lets a single tapped track play with continuation: the speaker's queue
    gets the whole album and starts at this index, so the music keeps going
    when the song ends (as in the Spotify app). None = fall back to the bare
    track (single-track queue).
    """
    try:
        t = _api("GET", f"/tracks/{track_id}")
        al = t.get("album") or {}
        album_id = al.get("id")
        if not album_id:
            return None
        d = _api("GET", f"/albums/{album_id}", params={"market": "from_token"})
        tracks = (d.get("tracks") or {}).get("items", [])
        for i, tr in enumerate(tracks):
            if tr.get("id") == track_id:
                return {"uri": al["uri"], "index": i}
    except SpotifyError:
        return None
    return None


# --- Playlists & library (no active device required) ----------------------

def playlists(limit: int = 50) -> dict:
    """The user's playlists (backs the app's add-to-playlist picker)."""
    d = _api("GET", "/me/playlists", params={"limit": limit})
    return {
        "items": [
            {
                "id": p["id"],
                "name": p["name"],
                "count": (p.get("tracks") or {}).get("total"),
                "owner": (p.get("owner") or {}).get("display_name"),
                "uri": p["uri"],
                "image": _img(p.get("images") or []),
            }
            for p in d.get("items", [])
        ]
    }


_WRITE_BLOCKED_MSG = (
    "Spotify blocks playlist and library edits for personal API apps; "
    "read and playback only"
)


def _explain_write_block(exc: "SpotifyError") -> "SpotifyError":
    """Development-mode apps get a bare 403 on all write endpoints (playlist
    create/add, library save). Surface a readable message instead."""
    if "403" in str(exc):
        return SpotifyError(_WRITE_BLOCKED_MSG)
    return exc


def create_playlist(name: str, public: bool = False) -> dict:
    """Create a playlist owned by the authorized user (the '+ New playlist')."""
    try:
        uid = _api("GET", "/me")["id"]
        p = _api(
            "POST",
            f"/users/{uid}/playlists",
            json={"name": name, "public": public},
        )
        return {"id": p["id"], "name": p["name"], "uri": p["uri"]}
    except SpotifyError as exc:
        raise _explain_write_block(exc) from exc


def add_to_playlist(playlist_id: str, uris: list[str]) -> dict:
    """Append tracks (spotify:track:...) to a playlist."""
    try:
        return _api("POST", f"/playlists/{playlist_id}/tracks", json={"uris": uris})
    except SpotifyError as exc:
        raise _explain_write_block(exc) from exc


def save_tracks(ids: list[str], save: bool = True) -> dict:
    """Like/unlike tracks. ids are bare track ids, not URIs."""
    method = "PUT" if save else "DELETE"
    try:
        return _api(method, "/me/tracks", json={"ids": ids})
    except SpotifyError as exc:
        raise _explain_write_block(exc) from exc


def playlist_tracks(playlist_id: str, max_tracks: int = 100) -> dict:
    """A playlist's tracks, flat for the app.

    Development mode 403s /playlists/{id}/tracks, but the full playlist
    object still inlines its first 100 tracks, so read those (paging past 100
    would need the blocked endpoint, so long playlists cap at 100).
    """
    d = _api("GET", f"/playlists/{playlist_id}")
    # Classic shape: {"tracks": {"items": [{"track": {...}}]}}. Development
    # mode's shape: {"tracks": null, "items": {"items": [{"item": {...}, "track": true}]}}
    paging = d.get("tracks") or d.get("items") or {}
    entries = paging.get("items", []) if isinstance(paging, dict) else paging
    items: list[dict] = []
    for it in entries[:max_tracks]:
        t = it.get("item") if isinstance(it.get("item"), dict) else it.get("track")
        if isinstance(t, dict) and t.get("id"):
            items.append(_norm_track(t))
    return {"items": items}


def status() -> dict:
    return {
        "configured": configured(),
        "connected": connected(),
        "redirect_uri": REDIRECT_URI,
        "scopes": SCOPES,
    }
