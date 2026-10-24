"""SQLite persistence for the hub, using the stdlib sqlite3 module only.

Single-household, per-home-copy datastore. No ORM, no external deps. Schema is
created idempotently on startup via init_db().
"""

import os
import sqlite3

HUB_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("HUB_DB", os.path.join(HUB_DIR, "data.db"))


def get_conn() -> sqlite3.Connection:
    """Open a connection with Row access and foreign keys enforced."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


SCHEMA = """
CREATE TABLE IF NOT EXISTS household (
    id INTEGER PRIMARY KEY,
    name TEXT
);

CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    household_id INTEGER,
    name TEXT UNIQUE NOT NULL,
    role TEXT NOT NULL CHECK(role IN ('admin','member','kid')),
    pin_hash TEXT,
    api_token TEXT UNIQUE,
    max_volume INTEGER
);

CREATE TABLE IF NOT EXISTS rooms (
    id INTEGER PRIMARY KEY,
    name TEXT UNIQUE,
    sonos_uid TEXT,
    appletv_id TEXT,
    hdmi_input TEXT
);

CREATE TABLE IF NOT EXISTS room_access (
    user_id INTEGER,
    room_id INTEGER,
    PRIMARY KEY(user_id, room_id)
);

CREATE TABLE IF NOT EXISTS favorites (
    id INTEGER PRIMARY KEY,
    kind TEXT,
    spotify_uri TEXT,
    label TEXT
);

CREATE TABLE IF NOT EXISTS scenes (
    id INTEGER PRIMARY KEY,
    name TEXT,
    room_ids TEXT,
    favorite_id INTEGER
);

CREATE TABLE IF NOT EXISTS secrets (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS recents (
    uri TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    image TEXT,
    played_at INTEGER NOT NULL
);
"""


def init_db() -> None:
    """Create all tables if they don't already exist, then migrate."""
    conn = get_conn()
    try:
        conn.executescript(SCHEMA)
        # Migration: locked users keep their row but can't log in or use
        # their token. The column probe makes the ALTER idempotent.
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(users)")]
        if "locked" not in cols:
            conn.execute(
                "ALTER TABLE users ADD COLUMN locked INTEGER NOT NULL DEFAULT 0")
        conn.commit()
    finally:
        conn.close()


def get_secret(key: str) -> str | None:
    """Read a value from the secrets table (e.g. the Spotify refresh token)."""
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT value FROM secrets WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None
    finally:
        conn.close()


def set_secret(key: str, value: str) -> None:
    """Upsert a secret. Stored in data.db, which is gitignored."""
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO secrets (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
        conn.commit()
    finally:
        conn.close()


def appletv_for_room(name: str) -> str | None:
    """Room name -> its mapped Apple TV identifier, if one is configured."""
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT appletv_id FROM rooms WHERE name = ? AND appletv_id IS NOT NULL",
            (name,),
        ).fetchone()
        return row["appletv_id"] if row else None
    finally:
        conn.close()


def room_for_appletv(appletv_id: str) -> str | None:
    """Apple TV identifier -> the room name it's mapped to."""
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT name FROM rooms WHERE appletv_id = ?", (appletv_id,)
        ).fetchone()
        return row["name"] if row else None
    finally:
        conn.close()


def set_room_tv(name: str, appletv_id: str, hdmi_input: str | None) -> None:
    """Map a room to its Apple TV (and the HDMI input the TV needs)."""
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO rooms (name, appletv_id, hdmi_input) VALUES (?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET appletv_id = excluded.appletv_id, "
            "hdmi_input = excluded.hdmi_input",
            (name, appletv_id, hdmi_input),
        )
        conn.commit()
    finally:
        conn.close()


def record_recent(kind: str, uri: str, title: str,
                  subtitle: str | None, image: str | None) -> None:
    """Upsert a played item into the house's recently-played (kept to 30).

    Recents are tracked by the hub from what actually plays on the speakers,
    so no extra Spotify OAuth scope is needed and they reflect the house
    rather than the whole account.
    """
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO recents (uri, kind, title, subtitle, image, played_at) "
            "VALUES (?, ?, ?, ?, ?, strftime('%s','now')) "
            "ON CONFLICT(uri) DO UPDATE SET played_at = excluded.played_at, "
            "title = excluded.title, subtitle = excluded.subtitle, "
            "image = excluded.image",
            (uri, kind, title, subtitle, image),
        )
        conn.execute(
            "DELETE FROM recents WHERE uri NOT IN "
            "(SELECT uri FROM recents ORDER BY played_at DESC LIMIT 30)"
        )
        conn.commit()
    finally:
        conn.close()


def list_recents(limit: int = 12) -> list[dict]:
    """Most-recently played first, in the app's flat result shape."""
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT uri, kind, title, subtitle, image FROM recents "
            "ORDER BY played_at DESC LIMIT ?", (max(1, min(30, limit)),)
        ).fetchall()
    finally:
        conn.close()
    return [
        {
            "kind": r["kind"],
            "id": r["uri"].rsplit(":", 1)[-1],
            "uri": r["uri"],
            "title": r["title"],
            "subtitle": r["subtitle"] or "",
            "image": r["image"],
        }
        for r in rows
    ]


def user_by_token(token: str) -> sqlite3.Row | None:
    """Return the user row matching api_token, or None."""
    if not token:
        return None
    conn = get_conn()
    try:
        return conn.execute(
            "SELECT * FROM users WHERE api_token = ?", (token,)
        ).fetchone()
    finally:
        conn.close()
