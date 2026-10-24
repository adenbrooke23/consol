"""Apple TV discovery, pairing and control via pyatv.

Credentials live in the secrets table (`atv_credentials_<identifier>`) as a
JSON dict of {protocol_name: credentials}. Pairing is a two-call flow
(start, the TV shows a PIN, finish) so the in-flight pairing handler is
held in a module-level dict between calls.
"""

import asyncio
import json
import os

import pyatv
from pyatv import exceptions as atv_errors
from pyatv.const import FeatureName, FeatureState, OperatingSystem, Protocol
from pyatv.interface import RemoteControl

import db

# Protocols we pair, in order. Companion drives power/app-launch/remote keys;
# AirPlay unlocks the MRP-over-AirPlay tunnel for playback state on tvOS 15+.
PAIR_PROTOCOLS = [Protocol.Companion, Protocol.AirPlay]

# Protected Apple TVs: devices the hub must never pair with, connect to, map
# to a room or command. PROTECTED_APPLE_TVS is a comma-separated list of pyatv
# identifiers. It is read per call because .env is loaded into the
# environment by spotify.py, which main.py imports after this module.
def is_protected(identifier: str) -> bool:
    raw = os.environ.get("PROTECTED_APPLE_TVS", "")
    protected = {part.strip().upper() for part in raw.split(",") if part.strip()}
    return (identifier or "").strip().upper() in protected


def guard(identifier: str) -> None:
    """Refuse to touch a protected device. Every path that could reach an
    Apple TV (connect, pair, map) goes through here."""
    if is_protected(identifier):
        raise PermissionError(
            f"{identifier} is a protected device and cannot be controlled")


# pyatv exceptions all derive straight from Exception (no shared base), so
# main.py registers a handler per class. Grouped by what the caller should do.
REPAIR_ERRORS = (                      # -> 409, the pairing is gone/bad
    atv_errors.AuthenticationError,
    atv_errors.InvalidCredentialsError,
    atv_errors.NoCredentialsError,
    atv_errors.PairingError,
    atv_errors.BlockedStateError,
)
UNSUPPORTED_ERRORS = (                 # -> 409, connected but can't do that
    atv_errors.NotSupportedError,
    atv_errors.UnsupportedProtocolError,
    atv_errors.NoServiceError,
)
UNREACHABLE_ERRORS = (                 # -> 504, the TV isn't answering
    atv_errors.ConnectionFailedError,
    atv_errors.ConnectionLostError,
    atv_errors.OperationTimeoutError,
    atv_errors.BackOffError,
    atv_errors.NonLocalSubnetError,
)
UPSTREAM_ERRORS = (                    # -> 502, pyatv/device misbehaved
    atv_errors.ProtocolError,
    atv_errors.HttpError,
    atv_errors.InvalidResponseError,
    atv_errors.CommandError,
    atv_errors.PlaybackError,
    atv_errors.DeviceIdMissingError,
    atv_errors.InvalidStateError,
    atv_errors.InvalidConfigError,
    atv_errors.SettingsError,
)

# identifier -> (in-flight pairing handler, monotonic start time)
_pending: dict[str, tuple] = {}


def _creds_key(identifier: str) -> str:
    return f"atv_credentials_{identifier}"


def _stored_credentials(identifier: str) -> dict:
    raw = db.get_secret(_creds_key(identifier))
    return json.loads(raw) if raw else {}


async def _scan(identifier: str | None = None):
    # Targeted scans return as soon as the device answers; the full sweep
    # runs its whole timeout, so keep it short enough for the app's request
    # window (ATVs announce within a second or two).
    loop = asyncio.get_running_loop()
    if identifier:
        return await pyatv.scan(loop=loop, identifier=identifier, timeout=8)
    return await pyatv.scan(loop=loop, timeout=5)


def _is_apple_tv(config) -> bool:
    """A real Apple TV runs tvOS. Macs, Sonos units and AirPlay-capable smart
    TVs (which advertise AirPlay themselves) all report otherwise."""
    info = getattr(config, "device_info", None)
    return info is not None and info.operating_system == OperatingSystem.TvOS


async def discover_devices() -> list[dict]:
    """Scan the LAN and return only real Apple TVs:
    {name, identifier, address, model, paired, room, protected}."""
    configs = await _scan()
    devices = []
    for config in configs:
        if not _is_apple_tv(config):
            continue
        creds = _stored_credentials(config.identifier)
        protected = is_protected(config.identifier)
        devices.append(
            {
                "name": config.name,
                "identifier": config.identifier,
                "address": str(config.address) if config.address else None,
                "model": config.device_info.model.name,
                # A protected device can never be driven, so never report it
                # as paired: the app keys every control off this flag.
                "paired": (not protected
                           and all(p.name in creds for p in PAIR_PROTOCOLS)),
                "room": db.room_for_appletv(config.identifier),
                "protected": protected,
            }
        )
    return devices


async def _find(identifier: str):
    configs = await _scan(identifier)
    for config in configs:
        if config.identifier == identifier:
            return config
    raise LookupError(f"Apple TV {identifier} not found on the network")


async def _connect(identifier: str):
    """Scan for the device, apply stored credentials, connect. Caller closes."""
    guard(identifier)
    creds = _stored_credentials(identifier)
    if not creds:
        raise PermissionError(f"Apple TV {identifier} is not paired")
    config = await _find(identifier)
    # set_credentials returns False when the config has no service for that
    # protocol, usually a cold mDNS cache that announced AirPlay but not
    # Companion. Connecting anyway yields an unauthenticated session whose
    # first command fails opaquely, so fail with a clear error instead.
    missing = [name for name, value in creds.items()
               if not config.set_credentials(Protocol[name], value)]
    if missing:
        raise PermissionError(
            f"Apple TV {identifier} did not announce {', '.join(missing)}; "
            "try again in a moment")
    return await pyatv.connect(config, asyncio.get_running_loop())


async def _close(atv) -> None:
    """pyatv's close() is synchronous and RETURNS the teardown tasks; dropping
    them races the next connect and leaks sockets under a 5s poll."""
    try:
        await asyncio.gather(*atv.close(), return_exceptions=True)
    except Exception:                  # teardown must never mask a real error
        pass


# --- Persistent connections ------------------------------------------------
# Connections are held open rather than made per command, for two reasons:
#
#  1. Now-playing state is pushed. The TV sends SET_STATE/SET_NOW_PLAYING
#     messages over the MRP-over-AirPlay tunnel for several seconds after the
#     tunnel comes up, so a per-command connection reads the state before it
#     arrives and reports a playing TV as idle.
#  2. Reconnecting for every keypress and poll causes overlapping Companion
#     handshakes to one device, which time out.
#
# A dead connection drops itself via the listener below and the next call
# reconnects, so callers never see a stale session.
_conns: dict[str, tuple] = {}
_conn_locks: dict[str, asyncio.Lock] = {}


class _ConnListener:
    """pyatv holds its listener weakly, so this is kept alive in _conns."""

    def __init__(self, identifier: str):
        self.identifier = identifier

    def connection_lost(self, exception) -> None:
        _conns.pop(self.identifier, None)

    def connection_closed(self) -> None:
        _conns.pop(self.identifier, None)


def _conn_lock(identifier: str) -> asyncio.Lock:
    lock = _conn_locks.get(identifier)
    if lock is None:
        lock = _conn_locks[identifier] = asyncio.Lock()
    return lock


async def _await_first_state(atv, timeout: float = 6.0) -> None:
    """Give a freshly opened tunnel a moment to receive what's on screen.

    The tunnel comes up quickly, but the SET_STATE message carrying the app
    and title can arrive 3-4s later. The wait is paid once per connection: an
    idle TV times out here and then stays connected, so later polls return
    immediately."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        if atv.metadata.app is not None:
            return
        await asyncio.sleep(0.25)


async def _session(identifier: str):
    """A live, state-populated connection. Never closed by the caller."""
    guard(identifier)
    async with _conn_lock(identifier):
        cached = _conns.get(identifier)
        if cached is not None:
            return cached[0]
        atv = await _connect(identifier)
        listener = _ConnListener(identifier)
        atv.listener = listener
        _conns[identifier] = (atv, listener)
        await _await_first_state(atv)
        return atv


async def drop_session(identifier: str) -> None:
    entry = _conns.pop(identifier, None)
    if entry is not None:
        await _close(entry[0])


async def close_all() -> None:
    for identifier in list(_conns):
        await drop_session(identifier)


# A connection error means the command did not land, so retrying it once on a
# fresh connection is safe even for mutations.
_STALE_ERRORS = (atv_errors.ConnectionLostError, atv_errors.ConnectionFailedError,
                 atv_errors.ProtocolError, OSError)


async def _run(identifier: str, action):
    """Run `action(atv)` against the held connection, replacing it once if it
    turns out to be stale (TV slept, rebooted, dropped off the network)."""
    for attempt in (1, 2):
        atv = await _session(identifier)
        try:
            return await action(atv)
        except _STALE_ERRORS:
            await drop_session(identifier)
            if attempt == 2:
                raise


async def status(identifier: str) -> dict:
    """Power state + what's playing, one flat snapshot. Reads the state the
    held connection has already been pushed, so it reflects the screen."""
    async def act(atv):
        playing = await atv.metadata.playing()
        app = atv.metadata.app

        def has(name: str) -> bool:
            return atv.features.get_feature(
                FeatureName[name]).state == FeatureState.Available

        return {
            "identifier": identifier,
            "power": atv.power.power_state.name.lower(),
            "app": app.name if app else None,
            "app_id": app.identifier if app else None,
            "state": playing.device_state.name.lower(),
            "title": playing.title,
            # Seconds. Present only while an app has an active now-playing
            # session; an idle home screen has nothing to report.
            "position": playing.position,
            "total_time": playing.total_time,
            # tvOS apps declare which transport commands they honour, so the
            # app can hide controls instead of showing dead buttons.
            "can": {
                "seek": has("SetPosition"),
                "skip_forward": has("SkipForward"),
                "skip_backward": has("SkipBackward"),
                "play_pause": has("PlayPause"),
            },
        }
    return await _run(identifier, act)


async def seek(identifier: str, position: int) -> dict:
    """Jump to an absolute position (seconds) and report whether it landed.

    Apps can accept the command and not move (some block transport during
    ads), so report whether playback actually ended up near the target. A
    refusal is transient, not a property of the app, so it is never cached.

    The app needs a moment to move and re-report, so poll rather than reading
    once; a single early read looks like a refusal.
    """
    target = int(position)

    async def act(atv):
        await atv.remote_control.set_position(target)
        actual = None
        for _ in range(6):                       # up to ~3s, exit as soon as it lands
            await asyncio.sleep(0.5)
            actual = (await atv.metadata.playing()).position
            if actual is not None and abs(actual - target) <= 15:
                return {"identifier": identifier, "position": target,
                        "actual": actual, "applied": True}
        return {"identifier": identifier, "position": target,
                "actual": actual, "applied": False}
    return await _run(identifier, act)


async def power(identifier: str, on: bool) -> dict:
    async def act(atv):
        if on:
            await atv.power.turn_on()
        else:
            await atv.power.turn_off()
        return {"identifier": identifier, "power": "on" if on else "off"}
    return await _run(identifier, act)


async def app_list(identifier: str) -> list[dict]:
    async def act(atv):
        apps = await atv.apps.app_list()
        return sorted(
            ({"name": a.name, "id": a.identifier} for a in apps),
            key=lambda a: (a["name"] or "").lower(),
        )
    return await _run(identifier, act)


async def launch_app(identifier: str, bundle_id: str) -> dict:
    async def act(atv):
        await atv.apps.launch_app(bundle_id)
        return {"identifier": identifier, "launched": bundle_id}
    return await _run(identifier, act)


async def artwork(identifier: str):
    """Now-playing artwork (poster/album art) from the TV, or LookupError.
    Returns the pyatv ArtworkInfo (bytes + mimetype)."""
    async def act(atv):
        art = await atv.metadata.artwork(width=600, height=None)
        if art is None:
            raise LookupError("nothing playing with artwork")
        return art
    return await _run(identifier, act)


async def set_text(identifier: str, text: str) -> dict:
    """Type into whatever text field the TV has focused (search boxes etc.).
    Replaces the field's whole content, so live per-keystroke sync just sends
    the full string each time. No focused field raises -> callers 409."""
    async def act(atv):
        await atv.keyboard.text_set(text)
        return {"identifier": identifier, "text": text}
    return await _run(identifier, act)


# Buttons exposed to the app; each maps to a pyatv RemoteControl coroutine.
KEYS = ["up", "down", "left", "right", "select", "menu", "home",
        "play_pause", "skip_forward", "skip_backward"]


async def press_key(identifier: str, key: str,
                    seconds: float | None = None) -> dict:
    # ValueError, not KeyError: KeyError is a LookupError, which the route's
    # error mapper reserves for "device not found".
    if key not in KEYS:
        raise ValueError(f"unknown button {key!r}")

    async def act(atv):
        if seconds and key in ("skip_forward", "skip_backward"):
            # Without an explicit interval the app picks its own (often 15 or
            # 30s), so a "back 10" button has to say 10.
            await getattr(atv.remote_control, key)(seconds)
        elif key == "play_pause":
            # Sent over Companion deliberately. pyatv prefers MRP for
            # play/pause, but MRP only has a player once a now-playing session
            # exists, so on a paused but idle screen the command does nothing.
            # Companion's HID PlayPause is the physical remote button and
            # always lands.
            release = atv.takeover(Protocol.Companion, RemoteControl)
            try:
                await atv.remote_control.play_pause()
            finally:
                release()
        else:
            await getattr(atv.remote_control, key)()
        return {"identifier": identifier, "pressed": key}
    return await _run(identifier, act)


# An abandoned pairing holds an aiohttp session and leaves the TV showing its
# PIN, so in-flight handlers expire rather than living until the hub restarts.
_PAIRING_TTL = 120.0


async def _drop_pending(identifier: str) -> None:
    entry = _pending.pop(identifier, None)
    if entry is not None:
        try:
            await entry[0].close()
        except Exception:
            pass


async def _expire_pending() -> None:
    now = asyncio.get_running_loop().time()
    for identifier, (_, started) in list(_pending.items()):
        if now - started > _PAIRING_TTL:
            await _drop_pending(identifier)


async def pair_start(identifier: str, protocol_name: str) -> dict:
    """Begin pairing one protocol. The TV displays a PIN; pair_finish
    completes it. Any previous unfinished pairing for this device is dropped."""
    guard(identifier)
    if protocol_name not in [p.name for p in PAIR_PROTOCOLS]:
        raise ValueError(f"protocol must be one of "
                         f"{', '.join(p.name for p in PAIR_PROTOCOLS)}")
    protocol = Protocol[protocol_name]
    config = await _find(identifier)

    await _expire_pending()
    await _drop_pending(identifier)
    # A held control connection and a pairing handshake to the same device
    # fight each other; pair on a clean slate.
    await drop_session(identifier)

    pairing = await pyatv.pair(config, protocol, asyncio.get_running_loop())
    try:
        await pairing.begin()
    except BaseException:
        # If begin() fails the handler is otherwise never closed, leaking
        # one aiohttp session per retry.
        await _close_quietly(pairing)
        raise
    _pending[identifier] = (pairing, asyncio.get_running_loop().time())
    return {"identifier": identifier, "protocol": protocol.name,
            "awaiting_pin": pairing.device_provides_pin}


async def _close_quietly(pairing) -> None:
    try:
        await pairing.close()
    except Exception:
        pass


async def pair_cancel(identifier: str) -> dict:
    """Abandon an in-flight pairing (closes the handler, frees the TV)."""
    await _drop_pending(identifier)
    return {"identifier": identifier, "cancelled": True}


async def pair_finish(identifier: str, pin: str) -> dict:
    """Complete an in-flight pairing with the on-screen PIN and store the
    credentials in the secrets table."""
    guard(identifier)
    entry = _pending.pop(identifier, None)
    if entry is None:
        raise LookupError("no pairing in progress for this device")
    pairing = entry[0]

    pairing.pin(pin)
    try:
        await pairing.finish()
        if not pairing.has_paired:
            raise ValueError("pairing did not complete (wrong PIN?)")
        creds = _stored_credentials(identifier)
        creds[pairing.service.protocol.name] = pairing.service.credentials
        db.set_secret(_creds_key(identifier), json.dumps(creds))
        return {"identifier": identifier,
                "protocol": pairing.service.protocol.name, "paired": True}
    finally:
        await _close_quietly(pairing)
