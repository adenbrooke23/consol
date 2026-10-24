"""Sonos control module for the home-entertainment hub.

Local LAN/UPnP control via SoCo. No cloud, no credentials, no device IDs
hardcoded. Grouping, volume, transport, and Spotify playback via ShareLink:
the speaker is handed a spotify: URI and streams it itself through the
household's Sonos<->Spotify service link.

This local path is the only music-control route. Spotify's Web API flags
Sonos players as "Restricted device" (403) for third-party apps, so Connect
control is not possible. The local path is also safer: commands go to a
named speaker on the LAN, so no other device on the account (a phone, a
laptop) can be touched.
"""

import json
import threading
import time
import urllib.parse

import soco
import soco.config
from soco.exceptions import SoCoUPnPException
from soco.plugins.sharelink import ShareLinkPlugin

import db as _db

# (connect, read) tuple passed straight to requests: a dead speaker fails in
# 3s (connect), while a busy one gets 15s to answer. Group topology calls
# (join, DelegateGroupCoordinationTo) routinely run past 3s, and cutting them
# off mid-handoff leaves speakers half-grouped. A flat short timeout is only
# safe for reads, never for topology changes.
soco.config.REQUEST_TIMEOUT = (3.0, 15.0)

# Zone cache: multicast SSDP discovery is slow (5s when an AP drops the probe)
# and unreliable on consumer Wi-Fi, so it must never sit on the request path.
# Speakers keep stable LAN presence; once we hold one SoCo instance, topology
# refreshes ride unicast (`visible_zones`) instead of multicast.
_zone_lock = threading.Lock()
_zone_cache: dict[str, soco.SoCo] = {}   # lowercase player name -> device
_zone_cache_at: float = 0.0
_ZONE_TTL = 300.0


_ZONE_IPS_KEY = "sonos_zone_ips"


def _zones_from_saved() -> set:
    """Cold-start fallback: contact last-known speaker IPs directly.

    Multicast SSDP is blocked for launchd-spawned processes by macOS
    local-network privacy, so a hub started by the keeper may never see a
    discovery reply. Unicast to a remembered speaker works everywhere; one
    live speaker returns the whole topology.
    """
    try:
        saved = json.loads(_db.get_secret(_ZONE_IPS_KEY) or "{}")
    except Exception:
        return set()
    for ip in saved.values():
        try:
            zone = soco.SoCo(ip)
            zone.player_name   # round-trip proves a live Sonos at this IP
            return set(zone.visible_zones)
        except Exception:
            continue
    return set()


_zone_fail_at: float = 0.0
_ZONE_FAIL_COOLDOWN = 15.0


def _sweep(candidates: list) -> set:
    """The slow network part of a refresh; runs with NO lock held.

    Unicast via a few known speakers first (one moved DHCP address must be a
    blip, not an outage), multicast next, saved IPs from the DB last.
    """
    for zone in candidates[:3]:
        try:
            return set(zone.visible_zones)
        except Exception:
            continue
    zones = soco.discover() or set()
    if zones:
        return set(zones)
    return _zones_from_saved()


def _refresh_zones() -> None:
    """Refill the zone cache. Cheap no-op when the cache is fresh or a sweep
    just failed (15s cooldown), so callers can invoke this freely.

    The sweep itself runs unlocked: holding the lock through seconds of
    network I/O would serialize every hub request behind one refresh.
    A failed sweep never clobbers a good cache, so a dropped multicast reply
    can't make known rooms vanish mid-session.
    """
    global _zone_cache_at, _zone_fail_at
    with _zone_lock:
        if _zone_cache and time.time() - _zone_cache_at <= _ZONE_TTL:
            return   # someone else refreshed while we waited
        if time.time() - _zone_fail_at < _ZONE_FAIL_COOLDOWN:
            return   # network is dark; don't hammer it on every request
        candidates = list(_zone_cache.values())
    zones = _sweep(candidates)
    if not zones:
        with _zone_lock:
            _zone_fail_at = time.time()
        return
    fresh = {z.player_name.strip().lower(): z for z in zones}
    with _zone_lock:
        _zone_cache.clear()
        _zone_cache.update(fresh)
        _zone_cache_at = time.time()
        _zone_fail_at = 0.0
    try:
        _db.set_secret(_ZONE_IPS_KEY, json.dumps(
            {name: z.ip_address for name, z in fresh.items()}))
    except Exception:
        pass   # persistence is best-effort; the live cache is what serves


def _discover():
    """Return the set of visible SoCo zones on the LAN (empty set if none).

    Served from the zone cache (TTL 300s). A bonded set (stereo pair,
    playbar+sub+surrounds) surfaces as a single logical zone here; SoCo's
    zones are taken as-is and never split.
    """
    _refresh_zones()
    with _zone_lock:
        return set(_zone_cache.values())


def _find(name: str):
    """Look up a SoCo device by player name (case-insensitive exact match).

    Cache-first; at most one extra sweep on a miss (the refresh guards make
    repeat calls cheap). Raises ValueError: "room not found" when other
    rooms exist, "no sonos speakers reachable" when none answer.
    """
    target = name.strip().lower()
    _refresh_zones()
    with _zone_lock:
        device = _zone_cache.get(target)
    if device is None:
        _refresh_zones()   # a genuinely new/renamed room; guarded, so cheap
        with _zone_lock:
            device = _zone_cache.get(target)
            if device is None and not _zone_cache:
                raise ValueError("no sonos speakers reachable")
    if device is None:
        raise ValueError(f"room not found: {name}")
    return device


def discover_rooms() -> list[dict]:
    """Discover Sonos players on the LAN via soco.discover().

    One dict per zone/player:
    {name, uid, volume:int, group_id, coordinator_name, is_coordinator:bool,
     members:list[str]}. members = player names in the same group.
    Return [] if none found.
    """
    rooms = []
    for device in _discover():
        group = device.group
        coordinator = group.coordinator
        rooms.append(
            {
                "name": device.player_name,
                "uid": device.uid,
                "volume": int(device.volume),
                "group_id": group.uid,
                "coordinator_name": coordinator.player_name,
                "is_coordinator": device.uid == coordinator.uid,
                # visible only, deduped by name: group.members includes the
                # hidden half of a bonded pair, which shares its twin's name.
                "members": sorted({m.player_name for m in group.members
                                   if m.is_visible}),
            }
        )
    rooms.sort(key=lambda r: r["name"].lower())
    return rooms


def _hms_to_secs(value):
    """Convert SoCo's 'H:MM:SS' (or 'M:SS') time string to int seconds.

    SoCo returns '' or 'NOT_IMPLEMENTED' when idle/unsupported -> None.
    """
    if not value or value == "NOT_IMPLEMENTED":
        return None
    try:
        parts = [int(p) for p in value.split(":")]
    except ValueError:
        return None
    secs = 0
    for p in parts:
        secs = secs * 60 + p
    return secs


def _now_playing_for(device) -> dict:
    """Now-playing snapshot for a device, read from its group coordinator.

    Transport state and track metadata live on the coordinator, so a grouped
    member reports whatever the coordinator is playing. Fields are normalized
    for the app: empty strings become None, times become int seconds.
    album_art is the absolute LAN URL SoCo builds; the app can load it as-is.
    """
    coordinator = device.group.coordinator
    state = coordinator.get_current_transport_info().get(
        "current_transport_state", "STOPPED"
    )
    track = coordinator.get_current_track_info()
    return {
        "room": device.player_name,
        "coordinator": coordinator.player_name,
        # PLAYING | PAUSED_PLAYBACK | STOPPED | TRANSITIONING
        "state": state,
        "playing": state == "PLAYING",
        "title": track.get("title") or None,
        "artist": track.get("artist") or None,
        "album": track.get("album") or None,
        "album_art": track.get("album_art") or None,
        "duration": _hms_to_secs(track.get("duration")),
        "position": _hms_to_secs(track.get("position")),
        "uri": track.get("uri") or None,
    }


def now_playing(room: str) -> dict:
    """Now-playing snapshot for a single room. Raises ValueError if not found."""
    return _now_playing_for(_find(room))


def now_playing_all() -> list[dict]:
    """Now-playing snapshot for every discovered zone, sorted by room name.

    One entry per player; grouped members each resolve to their coordinator's
    metadata, so the app can render the whole deck from a single poll.
    """
    snaps = [_now_playing_for(d) for d in _discover()]
    snaps.sort(key=lambda s: s["room"].lower())
    return snaps


# --- Spotify playback (local ShareLink; the speaker streams, we conduct) ---

def _spotify_uri_from_sonos(uri: str | None) -> str | None:
    """Extract a spotify: URI from a Sonos track URI.

    Queue items enqueued via ShareLink look like
    x-sonos-spotify:spotify%3Atrack%3A<id>?sid=12&...  ->  spotify:track:<id>.
    Streams started elsewhere (x-sonos-vli:...) carry no Spotify identity.
    """
    if not uri or not uri.startswith("x-sonos-spotify:"):
        return None
    body = uri.split(":", 1)[1].split("?", 1)[0]
    s = urllib.parse.unquote(body)
    return s if s.startswith("spotify:") else None


# play_mode <-> (shuffle, repeat); Sonos encodes both in one enum.
_MODE_FLAGS = {
    "NORMAL": (False, False),
    "SHUFFLE_NOREPEAT": (True, False),
    "REPEAT_ALL": (False, True),
    "SHUFFLE": (True, True),
    "REPEAT_ONE": (False, True),
    "SHUFFLE_REPEAT_ONE": (True, True),
}
_FLAGS_MODE = {
    (False, False): "NORMAL",
    (True, False): "SHUFFLE_NOREPEAT",
    (False, True): "REPEAT_ALL",
    (True, True): "SHUFFLE",
}


def player_state(room: str) -> dict:
    """Room playback snapshot in the app's flat player shape (the same
    contract as spotify.player_state, so the front end is agnostic)."""
    device = _find(room)
    coordinator = device.group.coordinator
    _group_visible = {m.player_name for m in device.group.members if m.is_visible}
    state = coordinator.get_current_transport_info().get(
        "current_transport_state", "STOPPED"
    )
    t = coordinator.get_current_track_info()
    shuffle, repeat = _MODE_FLAGS.get(coordinator.play_mode, (False, False))
    uri = _spotify_uri_from_sonos(t.get("uri"))
    track = None
    if t.get("title"):
        track = {
            # spotify:episode: items report their real kind (recents etc.)
            "kind": uri.split(":")[1] if uri and uri.count(":") >= 2 else "track",
            "id": uri.rsplit(":", 1)[1] if uri else None,
            "uri": uri,
            "title": t.get("title"),
            "subtitle": t.get("artist") or "",
            "image": t.get("album_art") or None,
        }
    return {
        "active": state in ("PLAYING", "PAUSED_PLAYBACK", "TRANSITIONING"),
        "is_playing": state == "PLAYING",
        "progress_ms": (_hms_to_secs(t.get("position")) or 0) * 1000,
        "duration_ms": (_hms_to_secs(t.get("duration")) or 0) * 1000,
        "shuffle": shuffle,
        "repeat": "context" if repeat else "off",
        # Grouped rooms report the group volume, the same value the volume
        # slider drives, so the readout and the slider stay in agreement.
        "device": {"id": None, "name": room, "volume_percent": int(
            device.group.volume if len(_group_visible) > 1 else device.volume)},
        # The speaker's actual group, so a group created elsewhere shows up
        # in the app instead of whatever the session assumed.
        "group": sorted(_group_visible),
        "track": track,
    }


def _wait_for_playing(coordinator, timeout: float = 3.0) -> None:
    """Block briefly until the coordinator actually reports PLAYING.

    Right after a start command the speaker sits in TRANSITIONING/STOPPED for
    a few hundred ms; answering with that snapshot makes the app show a
    paused state until the next poll. Gives up quietly on timeout; the next
    poll corrects it.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = coordinator.get_current_transport_info().get(
            "current_transport_state"
        )
        if state == "PLAYING":
            return
        time.sleep(0.15)


def play_spotify(room: str, uris: list[str] | None = None,
                 context_uri: str | None = None, start_index: int = 0) -> dict:
    """Play Spotify content on a room NOW: replace the queue and start it.

    uris = explicit tracks; context_uri = an album/playlist URI (ShareLink
    handles both); start_index picks where in the fresh queue to begin (a
    tapped track playing inside its album context). Neither = resume.
    """
    coordinator = _find(room).group.coordinator
    links = list(uris or ([] if context_uri is None else [context_uri]))
    if not links:
        coordinator.play()
        _wait_for_playing(coordinator)
        return player_state(room)
    sharelink = ShareLinkPlugin(coordinator)
    coordinator.clear_queue()
    for link in links:
        sharelink.add_share_link_to_queue(link)
    begin = min(max(0, start_index), max(0, coordinator.queue_size - 1))
    # A coordinator mid-transition (e.g. song just switched) can throw UPnP
    # 701 "Transition not available"; settle briefly and retry once.
    try:
        coordinator.play_from_queue(begin)
    except SoCoUPnPException:
        time.sleep(0.6)
        coordinator.play_from_queue(begin)
    _wait_for_playing(coordinator)
    return player_state(room)


def switch_room(room_from: str, room_to: str) -> dict:
    """Move playback to another room: a straight switch, not a group.

    Join the destination to the source's group so the audio carries over,
    delegate coordination to the destination (the old coordinator leaves
    atomically; a coordinator with members can't .unjoin(), that's UPnP
    1023), then drop every other member. Queue, position and state carry
    over; idle sessions work too.
    """
    src = _find(room_from)
    dst = _find(room_to)
    coordinator = src.group.coordinator

    if dst.uid != coordinator.uid:
        if dst.uid not in {m.uid for m in _visible_members(coordinator)}:
            dst.join(coordinator)
        try:
            _delegate_and_leave(coordinator, dst.uid)
        except Exception:
            # The handoff can outlive a client timeout yet still land on
            # the speakers, so trust the resulting topology over the error.
            time.sleep(1.0)
            if dst.group.coordinator.uid != dst.uid:
                raise

    # Shed strays only after the handoff. Unjoining before the delegate races
    # its topology snapshot, which re-adds the unjoined member and leaves
    # audio playing in both rooms. Loop until the group is just the
    # destination (topology reads lag slightly behind commands).
    deadline = time.time() + 8.0
    while time.time() < deadline:
        strays = [m for m in _visible_members(dst) if m.uid != dst.uid]
        if not strays:
            break
        for member in strays:
            try:
                member.unjoin()
            except SoCoUPnPException:
                pass   # mid-transition; the next lap re-checks
        time.sleep(0.8)
    return player_state(room_to)


def transport_settled(room: str, action: str) -> dict:
    """Transport action, then wait out the transition so the returned
    snapshot reflects the result (skips hop through TRANSITIONING)."""
    result = transport(room, action)
    if action in ("play", "next", "previous"):
        _wait_for_playing(_find(room).group.coordinator, timeout=2.0)
    return result


def queue_spotify(room: str, uri: str) -> dict:
    """Append a Spotify track to the room's queue without interrupting."""
    coordinator = _find(room).group.coordinator
    ShareLinkPlugin(coordinator).add_share_link_to_queue(uri)
    return {"queued": uri}


def queue_list(room: str, limit: int = 100) -> dict:
    """The room's entire queue (the album/track list), flat for the app.

    positions are absolute 0-based queue indices (what remove_from_queue and
    play_from_queue take); playing_position marks the current track (1-based,
    0 = none) so the app can highlight it.
    """
    coordinator = _find(room).group.coordinator
    t = coordinator.get_current_track_info()
    pos = int(t.get("playlist_position") or 0)      # 1-based; 0 = no queue
    start = 0
    items = []
    for i, item in enumerate(coordinator.get_queue(start=start, max_items=limit)):
        res_uri = item.resources[0].uri if getattr(item, "resources", None) else None
        art = getattr(item, "album_art_uri", None)
        if art and art.startswith("/"):
            art = f"http://{coordinator.ip_address}:1400{art}"
        items.append({
            "position": start + i,
            "title": item.title,
            "subtitle": getattr(item, "creator", None) or "",
            "uri": _spotify_uri_from_sonos(res_uri),
            "image": art,
        })
    return {"items": items, "playing_position": pos}


def queue_remove(room: str, positions: list[int]) -> dict:
    """Remove queue entries by absolute 0-based position."""
    coordinator = _find(room).group.coordinator
    for p in sorted(set(positions), reverse=True):
        coordinator.remove_from_queue(p)
    return {"removed": sorted(set(positions))}


def queue_play(room: str, position: int) -> dict:
    """Jump to a queue entry (absolute 0-based) and play it."""
    coordinator = _find(room).group.coordinator
    try:
        coordinator.play_from_queue(position)
    except SoCoUPnPException:
        time.sleep(0.6)
        coordinator.play_from_queue(position)
    _wait_for_playing(coordinator)
    return player_state(room)


def queue_reorder(room: str, from_position: int, insert_before: int) -> dict:
    """Move one queue entry (absolute 0-based from / insert-before)."""
    coordinator = _find(room).group.coordinator
    coordinator.avTransport.ReorderTracksInQueue([
        ("InstanceID", 0),
        ("StartingIndex", from_position + 1),   # UPnP is 1-based
        ("NumberOfTracks", 1),
        ("InsertBefore", insert_before + 1),
        ("UpdateID", 0),
    ])
    return {"moved": from_position, "before": insert_before}


def set_shuffle(room: str, state: bool) -> dict:
    coordinator = _find(room).group.coordinator
    _, repeat = _MODE_FLAGS.get(coordinator.play_mode, (False, False))
    coordinator.play_mode = _FLAGS_MODE[(bool(state), repeat)]
    return player_state(room)


def set_repeat(room: str, state: bool) -> dict:
    coordinator = _find(room).group.coordinator
    shuffle, _ = _MODE_FLAGS.get(coordinator.play_mode, (False, False))
    coordinator.play_mode = _FLAGS_MODE[(shuffle, bool(state))]
    return player_state(room)


def seek_ms(room: str, position_ms: int) -> dict:
    """Scrub the current track to a position (milliseconds)."""
    coordinator = _find(room).group.coordinator
    s = max(0, int(position_ms) // 1000)
    coordinator.seek(f"{s // 3600}:{(s % 3600) // 60:02d}:{s % 60:02d}")
    return player_state(room)


def create_group(rooms: list[str]) -> dict:
    """Join the named rooms into one Sonos group.

    The first room is the coordinator; the rest .join() it.
    Returns {"coordinator": <name>, "members": [<names>]}.
    Raises ValueError(f"room not found: {name}") if any room isn't discovered.
    """
    devices = [_find(name) for name in rooms]
    coordinator = devices[0]
    for member in devices[1:]:
        member.join(coordinator)
    return {
        "coordinator": coordinator.player_name,
        "members": [d.player_name for d in devices],
    }


def _delegate_and_leave(coordinator, new_coordinator_uid: str) -> None:
    """Hand the group's stream to another member and leave, atomically.

    A coordinator that still has members cannot .unjoin() (Sonos answers
    UPnP 1023). DelegateGroupCoordinationTo moves queue, position and state
    to the new coordinator and drops the old one without stopping playback.
    """
    coordinator.avTransport.DelegateGroupCoordinationTo([
        ("InstanceID", 0),
        ("NewCoordinator", new_coordinator_uid),
        ("RejoinGroup", False),
    ])


def _visible_members(coordinator) -> list:
    """A group's visible members only. Bonded-pair satellites (the hidden
    half of a stereo pair) also appear in group.members, and commanding one
    to unjoin its own pair fails with UPnP 1023. Never address them directly."""
    return [m for m in coordinator.group.members if m.is_visible]


def ungroup(room: str) -> dict:
    """Remove the room from its group.

    A plain member just unjoins. A coordinator with members must delegate
    coordination to another visible member first (unjoin would fail with
    1023); the rest of the group keeps playing.
    Returns {"room": room, "standalone": True}. Raises ValueError if not found.
    """
    device = _find(room)
    others = [m for m in _visible_members(device.group.coordinator)
              if m.uid != device.uid]
    if device.uid == device.group.coordinator.uid and others:
        _delegate_and_leave(device, others[0].uid)
    else:
        device.unjoin()
    return {"room": room, "standalone": True}


def set_volume(room: str, level: int) -> dict:
    """Set the player's volume (clamped to 0..100).

    A grouped room sets the group volume (SoCo scales every member
    proportionally, so one slider moves the whole group, like the Sonos app).
    Returns {"room": room, "volume": <applied int>}. Raises ValueError if
    the room isn't found.
    """
    device = _find(room)
    applied = max(0, min(100, int(level)))
    group = device.group
    if len([m for m in group.members if m.is_visible]) > 1:
        group.volume = applied
    else:
        device.volume = applied
    return {"room": room, "volume": applied}


def transport(room: str, action: str) -> dict:
    """Run a transport action on the room's group coordinator.

    action in {'play','pause','next','previous'}. Transport state lives on the
    coordinator, so we resolve it from the room's group before acting.
    Returns {"room": room, "action": action, "state": <transport state str>}.
    Raises ValueError for an unknown action or a room that isn't found.
    """
    if action not in {"play", "pause", "next", "previous"}:
        raise ValueError(f"unknown action: {action}")
    coordinator = _find(room).group.coordinator
    getattr(coordinator, action)()
    state = coordinator.get_current_transport_info()["current_transport_state"]
    return {"room": room, "action": action, "state": state}
