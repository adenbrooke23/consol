import sqlite3
import threading
import time

import requests

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response

import auth
import db
import sonos
import appletv
import spotify
from models import (
    GroupRequest,
    GroupRooms,
    LoginRequest,
    NetworkName,
    PinLogin,
    PlayerVolumeRequest,
    PlaylistCreate,
    PlayRequest,
    QueueAddRequest,
    QueuePlayRequest,
    QueueRemoveRequest,
    QueueReorderRequest,
    RepeatRequest,
    RoomRequest,
    SeekRequest,
    ShuffleRequest,
    SwitchRequest,
    TrackIDs,
    TVMapping,
    TVPairCancel,
    TVPairFinish,
    TVPairStart,
    TVSeek,
    TVText,
    TrackURIs,
    UserCreate,
    VolumeRequest,
)
from soco.exceptions import SoCoException, SoCoUPnPException

app = FastAPI(title="Home Entertainment Hub")


@app.on_event("startup")
def _startup() -> None:
    db.init_db()
    threading.Thread(target=_watchdog_loop, daemon=True).start()


@app.on_event("shutdown")
async def _shutdown() -> None:
    # Apple TV connections are held open (see appletv._session); a restart
    # must hand them back rather than leaving half-open tunnels on the TVs.
    await appletv.close_all()


# Dead-man switch: DEBUG builds of the app mark their player polls with
# watch=1. If a watched room's heartbeat goes stale (app killed or simulator
# quit; iOS gives no termination callback to catch), pause the room. The
# app polls every 5s, so 20s of silence means the controller is gone.
_WATCHDOG_TIMEOUT = 20.0
_watched: dict[str, float] = {}
_watched_lock = threading.Lock()


def _watchdog_loop() -> None:
    while True:
        time.sleep(5)
        now = time.time()
        stale = []
        with _watched_lock:
            for room, seen in list(_watched.items()):
                if now - seen > _WATCHDOG_TIMEOUT:
                    stale.append(room)
                    del _watched[room]
        for room in stale:
            try:
                sonos.transport(room, "pause")
            except Exception:   # already paused, stopped or unreachable
                pass


@app.exception_handler(ValueError)
async def value_error_handler(request: Request, exc: ValueError) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": str(exc)})


@app.exception_handler(spotify.SpotifyError)
async def spotify_error_handler(request: Request, exc: spotify.SpotifyError) -> JSONResponse:
    # Caller-resolvable states (not connected / no device to play on) are 409;
    # everything else is upstream (502).
    msg = str(exc).lower()
    caller_fault = (
        "not connected" in msg
        or "no spotify device" in msg
        or "no_active_device" in msg
        or "no active device" in msg
        or "requires a room" in msg
        or "refusing to touch" in msg
        or "read and playback only" in msg
    )
    return JSONResponse(status_code=409 if caller_fault else 502,
                        content={"detail": str(exc)})


@app.exception_handler(SoCoException)
async def soco_error_handler(request: Request, exc: SoCoException) -> JSONResponse:
    return JSONResponse(status_code=502, content={"detail": f"sonos: {exc}"})


# pyatv raises ~25 exception types that share no base class beyond Exception,
# so each is registered here; otherwise real Apple TV failures (asleep,
# re-paired elsewhere, out of range) surface as raw 500s. Grouped by what the
# caller can do about it.
def _atv_error_handler(status: int, prefix: str):
    async def handler(request: Request, exc: Exception) -> JSONResponse:
        return JSONResponse(status_code=status,
                            content={"detail": f"{prefix}{exc}"})
    return handler


for _group, _status, _prefix in (
    (appletv.REPAIR_ERRORS, 409, "apple tv needs re-pairing: "),
    (appletv.UNSUPPORTED_ERRORS, 409, "apple tv can't do that: "),
    (appletv.UNREACHABLE_ERRORS, 504, "apple tv not answering: "),
    (appletv.UPSTREAM_ERRORS, 502, "apple tv: "),
):
    for _exc_type in _group:
        app.add_exception_handler(_exc_type, _atv_error_handler(_status, _prefix))


@app.exception_handler(requests.exceptions.RequestException)
async def sonos_network_error_handler(
    request: Request, exc: requests.exceptions.RequestException
) -> JSONResponse:
    # SoCo speaks HTTP via requests; a speaker timing out mid-command must
    # surface as an upstream error, not a raw 500 traceback.
    return JSONResponse(
        status_code=502,
        content={"detail": f"sonos: speaker not answering ({type(exc).__name__})"})


@app.get("/health")
def health():
    return {"status": "ok"}


# --- Admin (LAN-only household controls; app Profile page) ----------------

_network_name_cache: str | None = None


def _network_name() -> str:
    """The Wi-Fi network this hub lives on, for the app's Profile page.

    macOS redacts the SSID from headless processes, so the sources in order
    are: the name set from the app (secrets table), NETWORK_NAME in .env,
    ipconfig (works on older macOS or with location consent), then a generic
    fallback.
    """
    global _network_name_cache
    if _network_name_cache:
        return _network_name_cache
    import os
    import re
    import subprocess

    name = (db.get_secret("network_name") or "").strip()
    if not name:
        name = os.environ.get("NETWORK_NAME", "").strip()
    if not name:
        try:
            out = subprocess.run(
                ["ipconfig", "getsummary", "en0"],
                capture_output=True, text=True, timeout=3,
            ).stdout
            m = re.search(r"^\s*SSID : (.+)$", out, re.MULTILINE)
            if m and "redacted" not in m.group(1):
                name = m.group(1).strip()
        except Exception:
            pass
    _network_name_cache = name or "Home network"
    return _network_name_cache


@app.get("/admin/info")
def admin_info():
    return {"network": _network_name()}


@app.put("/admin/network")
def admin_set_network(body: NetworkName, user: dict = Depends(auth.get_current_user)):
    """Set the network name the household sees (admin). Stored in the DB so
    it survives reinstalls and never needs a .env edit."""
    auth.require_admin(user)
    global _network_name_cache
    db.set_secret("network_name", body.name.strip())
    _network_name_cache = None
    return {"ok": True, "network": _network_name()}


@app.get("/admin/logs")
def admin_logs(source: str = "hub", lines: int = 200,
               user: dict = Depends(auth.get_current_user)):
    """Tail of what the stack writes (admin). `source` = hub | keeper.
    Reads the last chunk of the file the process actually logs to."""
    auth.require_admin(user)
    import os as _os
    hub_dir = _os.path.dirname(_os.path.abspath(__file__))
    path = {
        "hub": _os.path.join(hub_dir, "hub.log"),
        "keeper": _os.path.join(hub_dir, "hubkeeper.log"),
    }.get(source)
    if path is None:
        raise HTTPException(status_code=400, detail="source must be hub or keeper")
    lines = max(1, min(1000, lines))
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 256_000))
            chunk = f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return {"source": source, "lines": []}
    return {"source": source, "lines": chunk.splitlines()[-lines:]}

@app.post("/admin/restart")
def admin_restart(user: dict = Depends(auth.get_current_user)):
    """Bounce the hub: answer, then re-exec this process in place.

    execv preserves pid and cwd, so the same `python -m uvicorn main:app ...`
    comes straight back up; speakers keep playing (they stream on their own).
    The re-exec is only correct for a plain uvicorn CLI launch; under --reload
    or another server it would just kill the hub, so those are refused.
    """
    import os
    import sys

    if "uvicorn" not in sys.argv[0] or "--reload" in sys.argv:
        raise HTTPException(
            status_code=501,
            detail="restart unsupported for this launch mode; use stop, then start")

    def _reexec():
        time.sleep(0.5)   # let the response flush
        os.execv(sys.executable, [sys.executable, "-m", "uvicorn"] + sys.argv[1:])

    threading.Thread(target=_reexec, daemon=True).start()
    return {"ok": True, "action": "restart"}


@app.post("/admin/stop")
def admin_stop(user: dict = Depends(auth.get_current_user)):
    """Force-stop the hub. One-way from the app: starting again needs the Mac."""
    import os

    def _exit():
        time.sleep(0.5)
        os._exit(0)

    threading.Thread(target=_exit, daemon=True).start()
    return {"ok": True, "action": "stop"}


# --- Users / auth ---------------------------------------------------------
def _pin_in_use(conn, pin: str, exclude_id: int | None = None) -> bool:
    """True if any (other) user's PIN verifies against `pin`.

    The PIN is the identity (the app's login sends only the PIN), so two
    users sharing one would merge into whoever sorts first. Hashes are salted,
    so this has to verify per user, which is cheap for a household.
    """
    rows = conn.execute(
        "SELECT id, pin_hash FROM users WHERE pin_hash IS NOT NULL"
    ).fetchall()
    return any(
        r["id"] != exclude_id and auth.verify_pin(pin, r["pin_hash"])
        for r in rows
    )


@app.post("/users")
def create_user(body: UserCreate, authorization: str = Header(None)):
    """Create a user.

    Bootstrap: if the users table is empty, the first user may be created with
    no auth but is forced to role='admin'. Otherwise an admin caller is
    required. Returns the api_token so the app can store it.
    """
    conn = db.get_conn()
    try:
        count = conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]

        if count == 0:
            role = "admin"  # first user is always the admin
        else:
            # Not bootstrap: require an authenticated admin caller.
            user = auth.get_current_user(authorization)
            auth.require_admin(user)
            role = body.role
            if role not in ("admin", "member", "kid"):
                raise HTTPException(status_code=400, detail="invalid role")

        if body.pin and _pin_in_use(conn, body.pin):
            raise HTTPException(status_code=409, detail="pin already in use")

        max_volume = body.max_volume
        if role == "kid" and max_volume is None:
            max_volume = auth.DEFAULT_KID_MAX_VOLUME
        pin_hash = auth.hash_pin(body.pin) if body.pin else None
        token = auth.new_token()
        try:
            cur = conn.execute(
                "INSERT INTO users (name, role, pin_hash, api_token, max_volume) "
                "VALUES (?, ?, ?, ?, ?)",
                (body.name, role, pin_hash, token, max_volume),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(
                status_code=409, detail="name already exists"
            ) from exc
        conn.commit()
        return {"id": cur.lastrowid, "name": body.name, "role": role, "token": token}
    finally:
        conn.close()


@app.get("/users")
def list_users(user: dict = Depends(auth.get_current_user)):
    """The household roster (no hashes, no tokens). Any signed-in user."""
    conn = db.get_conn()
    try:
        rows = conn.execute(
            "SELECT id, name, role, max_volume, locked FROM users ORDER BY id"
        ).fetchall()
    finally:
        conn.close()
    return [{**dict(r), "locked": bool(r["locked"])} for r in rows]


@app.put("/users/{name}/pin")
def admin_reset_pin(name: str, body: PinLogin,
                    user: dict = Depends(auth.get_current_user)):
    """Admin resets someone's PIN (forgot it, kid shared it, etc.)."""
    auth.require_admin(user)
    if not body.pin or len(body.pin) != 4 or not body.pin.isdigit():
        raise HTTPException(status_code=400, detail="pin must be 4 digits")
    conn = db.get_conn()
    try:
        row = conn.execute(
            "SELECT id FROM users WHERE name = ?", (name,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="no such user")
        if _pin_in_use(conn, body.pin, exclude_id=row["id"]):
            raise HTTPException(status_code=409, detail="pin already in use")
        conn.execute("UPDATE users SET pin_hash = ? WHERE id = ?",
                     (auth.hash_pin(body.pin), row["id"]))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "name": name}


def _set_locked(name: str, locked: bool, caller: dict) -> dict:
    auth.require_admin(caller)
    conn = db.get_conn()
    try:
        row = conn.execute(
            "SELECT id, role FROM users WHERE name = ?", (name,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="no such user")
        if locked:
            if row["id"] == caller["id"]:
                raise HTTPException(
                    status_code=409, detail="you can't lock yourself out")
            if row["role"] == "admin":
                others = conn.execute(
                    "SELECT COUNT(*) AS n FROM users "
                    "WHERE role = 'admin' AND locked = 0 AND id != ?",
                    (row["id"],)).fetchone()["n"]
                if others == 0:
                    raise HTTPException(
                        status_code=409, detail="cannot lock the last admin")
        conn.execute("UPDATE users SET locked = ? WHERE id = ?",
                     (1 if locked else 0, row["id"]))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "name": name, "locked": locked}


@app.post("/users/{name}/lock")
def lock_user(name: str, user: dict = Depends(auth.get_current_user)):
    """Lock a user out (admin): login refused, existing token dead, row kept."""
    return _set_locked(name, True, user)


@app.post("/users/{name}/unlock")
def unlock_user(name: str, user: dict = Depends(auth.get_current_user)):
    return _set_locked(name, False, user)


@app.delete("/users/{name}")
def delete_user(name: str, user: dict = Depends(auth.get_current_user)):
    """Remove a household member (admin). The last admin cannot be deleted,
    or the household could no longer be administered."""
    auth.require_admin(user)
    conn = db.get_conn()
    try:
        row = conn.execute(
            "SELECT id, role FROM users WHERE name = ?", (name,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="no such user")
        if row["role"] == "admin":
            admins = conn.execute(
                "SELECT COUNT(*) AS n FROM users WHERE role = 'admin'"
            ).fetchone()["n"]
            if admins <= 1:
                raise HTTPException(
                    status_code=409, detail="cannot delete the last admin")
        conn.execute("DELETE FROM users WHERE id = ?", (row["id"],))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "deleted": name}


@app.post("/login/pin")
def login_pin(body: PinLogin):
    """PIN-only login: the DB resolves who the PIN belongs to.

    This keeps the household roster entirely in the hub; the app never ships
    a user list. PINs are unique (enforced on create and change), so at most
    one user verifies.
    """
    if not body.pin:
        raise HTTPException(status_code=401, detail="invalid credentials")
    conn = db.get_conn()
    try:
        rows = conn.execute(
            "SELECT name, role, api_token, pin_hash, locked FROM users "
            "WHERE pin_hash IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()
    for row in rows:
        if auth.verify_pin(body.pin, row["pin_hash"]):
            if row["locked"]:
                raise HTTPException(status_code=403, detail="account locked")
            return {"name": row["name"], "role": row["role"],
                    "token": row["api_token"]}
    raise HTTPException(status_code=401, detail="invalid credentials")


@app.post("/login")
def login(body: LoginRequest):
    conn = db.get_conn()
    try:
        row = conn.execute(
            "SELECT * FROM users WHERE name = ?", (body.name,)
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status_code=401, detail="invalid credentials")
    if row["pin_hash"]:
        if not body.pin or not auth.verify_pin(body.pin, row["pin_hash"]):
            raise HTTPException(status_code=401, detail="invalid credentials")
    if row["locked"]:
        raise HTTPException(status_code=403, detail="account locked")
    return {"token": row["api_token"]}


@app.get("/me")
def me(user: dict = Depends(auth.get_current_user)):
    return {k: v for k, v in user.items() if k not in ("pin_hash", "api_token")}


@app.put("/users/me/pin")
def change_own_pin(body: LoginRequest, user: dict = Depends(auth.get_current_user)):
    """Change the calling user's PIN (the app's passcode change syncs here
    so hub login keeps matching the app's local PIN)."""
    if not body.pin or len(body.pin) != 4 or not body.pin.isdigit():
        raise HTTPException(status_code=400, detail="pin must be 4 digits")
    conn = db.get_conn()
    try:
        if _pin_in_use(conn, body.pin, exclude_id=user["id"]):
            raise HTTPException(status_code=409, detail="pin already in use")
        conn.execute("UPDATE users SET pin_hash = ? WHERE id = ?",
                     (auth.hash_pin(body.pin), user["id"]))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True}


# Sonos routes are plain `def`: SoCo is synchronous/blocking, so Starlette runs
# them in a threadpool and they do not block the event loop.
@app.get("/rooms")
def rooms():
    return sonos.discover_rooms()


# Read-only state, unauthenticated like /rooms. The deck polls /now-playing for
# a whole-deck snapshot; /rooms/{room}/now-playing serves a single strip.
@app.get("/now-playing")
def now_playing_all():
    return sonos.now_playing_all()


@app.get("/rooms/{room}/now-playing")
def room_now_playing(room: str):
    return sonos.now_playing(room)


@app.post("/group")
def group(body: GroupRequest, user: dict = Depends(auth.get_current_user)):
    if user.get("role") == "kid":
        raise HTTPException(status_code=403, detail="kids may not change groups")
    return sonos.create_group(body.rooms)


@app.post("/rooms/{room}/ungroup")
def ungroup(room: str, user: dict = Depends(auth.get_current_user)):
    if user.get("role") == "kid":
        raise HTTPException(status_code=403, detail="kids may not ungroup")
    return sonos.ungroup(room)


@app.put("/rooms/{room}/volume")
def set_volume(
    room: str, body: VolumeRequest, user: dict = Depends(auth.get_current_user)
):
    auth.check_volume(user, body.level)
    return sonos.set_volume(room, body.level)


@app.post("/rooms/{room}/transport/{action}")
def transport(
    room: str, action: str, user: dict = Depends(auth.get_current_user)
):
    return sonos.transport(room, action)


# Apple TV discovery is async, so this route is `async def` and awaits it.
@app.get("/tv/devices")
async def tv_devices():
    return await appletv.discover_devices()


# Pairing is admin-only and a two-call flow: start makes the TV show a PIN,
# finish submits it and stores the credentials in DB secrets.
@app.post("/tv/pair/start")
async def tv_pair_start(body: TVPairStart,
                        user: dict = Depends(auth.get_current_user)):
    auth.require_admin(user)
    try:
        return await appletv.pair_start(body.identifier, body.protocol)
    except PermissionError as exc:      # protected device
        raise HTTPException(status_code=403, detail=str(exc))
    except ValueError as exc:           # unknown/unsupported protocol
        raise HTTPException(status_code=422, detail=str(exc))
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@app.post("/tv/pair/finish")
async def tv_pair_finish(body: TVPairFinish,
                         user: dict = Depends(auth.get_current_user)):
    auth.require_admin(user)
    try:
        return await appletv.pair_finish(body.identifier, body.pin)
    except PermissionError as exc:      # protected device
        raise HTTPException(status_code=403, detail=str(exc))
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    except ValueError as exc:           # wrong PIN / didn't complete
        raise HTTPException(status_code=409, detail=f"pairing failed: {exc}")


@app.post("/tv/pair/cancel")
async def tv_pair_cancel(body: TVPairCancel,
                         user: dict = Depends(auth.get_current_user)):
    auth.require_admin(user)
    return await appletv.pair_cancel(body.identifier)


# Room to Apple TV mapping (admin). The room name is what the app shows as a
# TV output; hdmi_input is for input sequencing on TVs that need it.
@app.put("/admin/rooms/{name}/tv")
def admin_set_room_tv(name: str, body: TVMapping,
                      user: dict = Depends(auth.get_current_user)):
    auth.require_admin(user)
    # Mapping a protected device would give it a room name and make it
    # reachable through the room-based TV routes.
    try:
        appletv.guard(body.appletv_id)
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc))
    db.set_room_tv(name, body.appletv_id, body.hdmi_input)
    return {"room": name, "appletv_id": body.appletv_id,
            "hdmi_input": body.hdmi_input}


def _tv_id(device: str) -> str:
    """Routes take a room name (rooms.appletv_id mapping) or a raw identifier."""
    return db.appletv_for_room(device) or device


async def _tv_call(coro):
    """Map appletv errors onto the hub's HTTP vocabulary. pyatv's own
    exceptions are handled globally (see the handlers near the top)."""
    try:
        return await coro
    except PermissionError as exc:      # protected, or no stored credentials
        status = 403 if "protected" in str(exc) else 409
        raise HTTPException(status_code=status, detail=str(exc))
    except LookupError as exc:          # not found on the network
        raise HTTPException(status_code=404, detail=str(exc))


@app.get("/tv/{device}/status")
async def tv_status(device: str):
    return await _tv_call(appletv.status(_tv_id(device)))


@app.post("/tv/{device}/power/{state}")
async def tv_power(device: str, state: str,
                   user: dict = Depends(auth.get_current_user)):
    if state not in ("on", "off"):
        raise HTTPException(status_code=422, detail="state must be on|off")
    return await _tv_call(appletv.power(_tv_id(device), state == "on"))


@app.get("/tv/{device}/apps")
async def tv_apps(device: str):
    return await _tv_call(appletv.app_list(_tv_id(device)))


@app.post("/tv/{device}/launch/{app_id}")
async def tv_launch(device: str, app_id: str,
                    user: dict = Depends(auth.get_current_user)):
    return await _tv_call(appletv.launch_app(_tv_id(device), app_id))


# Now-playing artwork, proxied as an image so the app's AsyncImage can show
# what the TV is playing (open read, like /tv/{device}/status).
@app.get("/tv/{device}/artwork")
async def tv_artwork(device: str):
    art = await _tv_call(appletv.artwork(_tv_id(device)))
    return Response(content=art.bytes, media_type=art.mimetype or "image/jpeg")


@app.post("/tv/{device}/text")
async def tv_text(device: str, body: TVText,
                  user: dict = Depends(auth.get_current_user)):
    try:
        return await _tv_call(appletv.set_text(_tv_id(device), body.text))
    except appletv.UNSUPPORTED_ERRORS:
        # The TV is reachable but nothing on screen accepts text. Other
        # failures keep their own status.
        raise HTTPException(status_code=409,
                            detail="no text field on the TV screen")


@app.post("/tv/{device}/seek")
async def tv_seek(device: str, body: TVSeek,
                  user: dict = Depends(auth.get_current_user)):
    return await _tv_call(appletv.seek(_tv_id(device), body.position))


@app.post("/tv/{device}/key/{button}")
async def tv_key(device: str, button: str, seconds: float | None = None,
                 user: dict = Depends(auth.get_current_user)):
    # Validated here, before _tv_call, so an invalid button never costs a
    # scan and connect.
    if button not in appletv.KEYS:
        raise HTTPException(
            status_code=422,
            detail=f"button must be one of {', '.join(appletv.KEYS)}")
    # `seconds` only means anything for the skip buttons (see press_key).
    return await _tv_call(appletv.press_key(_tv_id(device), button, seconds))


# --- Spotify -------------------------------------------------------------
# OAuth handshake (browser-facing, open like /rooms). Read routes call the Web
# API using the hub-held refresh token.
@app.get("/spotify/status")
def spotify_status():
    return spotify.status()


@app.get("/spotify/auth")
def spotify_auth():
    """Open this in a browser on the hub machine to do the one-time authorize."""
    if not spotify.configured():
        raise HTTPException(status_code=500, detail="Spotify creds missing (hub/.env)")
    return RedirectResponse(spotify.build_auth_url())


@app.get("/spotify/callback")
def spotify_callback(code: str = "", state: str = "", error: str = ""):
    if error:
        return HTMLResponse(f"<h2>Spotify authorize failed: {error}</h2>", status_code=400)
    spotify.exchange_code(code, state)
    return HTMLResponse(
        "<h2>Consol hub is connected to Spotify</h2><p>You can close this tab.</p>"
    )


@app.get("/spotify/me")
def spotify_me():
    return spotify.me()


@app.get("/spotify/devices")
def spotify_devices():
    return spotify.devices()


@app.get("/spotify/now-playing")
def spotify_now_playing():
    return spotify.now_playing()


@app.get("/spotify/search")
def spotify_search(q: str, limit: int = 8, scope: str = "music"):
    """Normalized flat results the app renders directly.
    scope: music | podcasts | books."""
    return spotify.search_results(q, limit, scope)


@app.get("/spotify/shows/{show_id}")
def spotify_show(show_id: str):
    """Show/audiobook page (episodes = chapters for books)."""
    return spotify.show(show_id)


@app.get("/spotify/library")
def spotify_library():
    """Saved shows + audiobooks."""
    return spotify.library()


@app.get("/spotify/artists/{artist_id}")
def spotify_artist(artist_id: str):
    return spotify.artist(artist_id)


@app.get("/spotify/albums/{album_id}")
def spotify_album(album_id: str):
    return spotify.album(album_id)


# Playback control goes through the local Sonos path (SoCo + ShareLink).
# Spotify's Web API rejects control of Sonos players with 403 "Restricted
# device", so the speaker itself is told to stream the URI over the LAN; the
# Web API is used for search, browse and library only. Every route names a
# room, so nothing can reach a non-Sonos device.
# Recently played is tracked from the polls: a room reporting a new track uri
# (compared with its last poll) records it. This needs no extra OAuth scope
# and reflects what played in the house rather than on the whole account.
_last_track: dict[str, str] = {}


@app.get("/spotify/player")
def spotify_player(room: str | None = None, watch: bool = False):
    """Playback snapshot. room -> that speaker's truth (the normal app path);
    no room -> the Spotify account's active player (debugging). watch=1
    registers the room with the dead-man switch (heartbeat = this poll)."""
    if room:
        if watch:
            with _watched_lock:
                _watched[room] = time.time()
        state = sonos.player_state(room)
        track = state.get("track")
        if track and track.get("uri") and _last_track.get(room) != track["uri"]:
            _last_track[room] = track["uri"]
            db.record_recent(track.get("kind") or "track", track["uri"],
                             track.get("title") or "", track.get("subtitle"),
                             track.get("image"))
        return state
    return spotify.player_state()


@app.get("/spotify/recents")
def spotify_recents(limit: int = 12):
    """What the house played recently (flat shapes, newest first)."""
    return {"items": db.list_recents(limit)}


@app.post("/spotify/play")
def spotify_play(body: PlayRequest, user: dict = Depends(auth.get_current_user)):
    if not body.room:
        raise HTTPException(status_code=409, detail="play requires a room")
    # A single tapped track plays inside its album context so the music
    # continues when the song ends (and next/previous have real targets).
    if (body.uris and len(body.uris) == 1 and not body.context_uri
            and body.uris[0].startswith("spotify:track:")):
        ctx = spotify.album_context(body.uris[0].rsplit(":", 1)[1])
        if ctx:
            return sonos.play_spotify(body.room, context_uri=ctx["uri"],
                                      start_index=ctx["index"])
    return sonos.play_spotify(body.room, uris=body.uris,
                              context_uri=body.context_uri,
                              start_index=body.start_index)


@app.post("/spotify/pause")
def spotify_pause(body: RoomRequest, user: dict = Depends(auth.get_current_user)):
    sonos.transport(body.room, "pause")
    return sonos.player_state(body.room)


def _skip(room: str, action: str):
    """next/previous, mapping the end of the queue to a 409. A one-track or
    finished queue has nowhere to go: Sonos answers UPnP 701 'Transition not
    available' (mid-play) or 711 'Illegal seek target' (stopped or empty)."""
    try:
        sonos.transport_settled(room, action)
    except SoCoUPnPException as exc:
        if str(exc.error_code) in ("701", "711"):
            raise HTTPException(
                status_code=409,
                detail="end of queue: nothing to skip to (queue more from search)",
            ) from exc
        raise
    return sonos.player_state(room)


@app.post("/spotify/next")
def spotify_next(body: RoomRequest, user: dict = Depends(auth.get_current_user)):
    return _skip(body.room, "next")


@app.post("/spotify/previous")
def spotify_previous(body: RoomRequest, user: dict = Depends(auth.get_current_user)):
    return _skip(body.room, "previous")


@app.put("/spotify/shuffle")
def spotify_shuffle(body: ShuffleRequest, user: dict = Depends(auth.get_current_user)):
    return sonos.set_shuffle(body.room, body.state)


@app.put("/spotify/repeat")
def spotify_repeat(body: RepeatRequest, user: dict = Depends(auth.get_current_user)):
    return sonos.set_repeat(body.room, body.state != "off")


@app.put("/spotify/volume")
def spotify_volume(body: PlayerVolumeRequest, user: dict = Depends(auth.get_current_user)):
    if not body.room:
        raise HTTPException(status_code=409, detail="volume requires a room")
    sonos.set_volume(body.room, body.percent)
    return sonos.player_state(body.room)


# Music routing (Sonos grouping) for the app's sessions. /group and
# /rooms/{room}/ungroup above are the role-checked equivalents.
@app.post("/spotify/group")
def spotify_group(body: GroupRooms, user: dict = Depends(auth.get_current_user)):
    if len(body.rooms) < 2:
        raise HTTPException(status_code=409, detail="grouping needs two rooms")
    return sonos.create_group(body.rooms)


@app.post("/spotify/ungroup")
def spotify_ungroup(body: RoomRequest, user: dict = Depends(auth.get_current_user)):
    return sonos.ungroup(body.room)


@app.post("/spotify/switch")
def spotify_switch(body: SwitchRequest, user: dict = Depends(auth.get_current_user)):
    """Straight switch: move a session's playback to another room."""
    return sonos.switch_room(body.from_room, body.to_room)


@app.post("/spotify/seek")
def spotify_seek(body: SeekRequest, user: dict = Depends(auth.get_current_user)):
    try:
        return sonos.seek_ms(body.room, body.position_ms)
    except SoCoUPnPException as exc:
        if str(exc.error_code) in ("701", "711"):
            raise HTTPException(
                status_code=409, detail="nothing playing to scrub"
            ) from exc
        raise


@app.post("/spotify/queue")
def spotify_queue(body: QueueAddRequest, user: dict = Depends(auth.get_current_user)):
    if not body.room:
        raise HTTPException(status_code=409, detail="queue requires a room")
    return sonos.queue_spotify(body.room, body.uri)


@app.get("/spotify/queue")
def spotify_queue_list(room: str, limit: int = 40):
    """The room's queue, read from the speaker (backs the app's Up Next list)."""
    return sonos.queue_list(room, limit)


@app.post("/spotify/queue/play")
def spotify_queue_play(body: QueuePlayRequest, user: dict = Depends(auth.get_current_user)):
    """Jump to a queue entry and play it."""
    return sonos.queue_play(body.room, body.position)


@app.post("/spotify/queue/remove")
def spotify_queue_remove(body: QueueRemoveRequest, user: dict = Depends(auth.get_current_user)):
    return sonos.queue_remove(body.room, body.positions)


@app.post("/spotify/queue/reorder")
def spotify_queue_reorder(body: QueueReorderRequest, user: dict = Depends(auth.get_current_user)):
    return sonos.queue_reorder(body.room, body.from_position, body.insert_before)


@app.get("/spotify/playlists")
def spotify_playlists(limit: int = 50):
    return spotify.playlists(limit)


@app.get("/spotify/playlists/{playlist_id}/tracks")
def spotify_playlist_tracks(playlist_id: str, limit: int = 50):
    """Flat track list for the browse card's playlist page."""
    return spotify.playlist_tracks(playlist_id, limit)


@app.post("/spotify/playlists")
def spotify_create_playlist(body: PlaylistCreate, user: dict = Depends(auth.get_current_user)):
    return spotify.create_playlist(body.name, body.public)


@app.post("/spotify/playlists/{playlist_id}/tracks")
def spotify_add_to_playlist(playlist_id: str, body: TrackURIs, user: dict = Depends(auth.get_current_user)):
    return spotify.add_to_playlist(playlist_id, body.uris)


@app.put("/spotify/tracks/saved")
def spotify_save_tracks(body: TrackIDs, user: dict = Depends(auth.get_current_user)):
    return spotify.save_tracks(body.ids, save=True)


@app.delete("/spotify/tracks/saved")
def spotify_unsave_tracks(body: TrackIDs, user: dict = Depends(auth.get_current_user)):
    return spotify.save_tracks(body.ids, save=False)
