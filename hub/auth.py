"""Authentication and access-control primitives, stdlib only.

PINs are salted PBKDF2-SHA256 hashes stored as `salt$hexhash`. Tokens are
opaque url-safe random strings. Access control is enforced here, on the hub:
the app can be bypassed, so every control request is authorized server-side.
"""

import hashlib
import hmac
import secrets

from fastapi import Header, HTTPException

import db

_ITERATIONS = 200_000

# Default volume cap applied to kids created without an explicit max_volume,
# so an admin can't accidentally leave a kid uncapped.
DEFAULT_KID_MAX_VOLUME = 50


def hash_pin(pin: str) -> str:
    """Return `salt$hexhash` for the given PIN (random per-call salt)."""
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", pin.encode(), salt.encode(), _ITERATIONS
    )
    return f"{salt}${digest.hex()}"


def verify_pin(pin: str, stored: str) -> bool:
    """Constant-time verify a PIN against a stored `salt$hexhash`."""
    if not stored or "$" not in stored:
        return False
    salt, expected = stored.split("$", 1)
    digest = hashlib.pbkdf2_hmac(
        "sha256", pin.encode(), salt.encode(), _ITERATIONS
    )
    return hmac.compare_digest(digest.hex(), expected)


def new_token() -> str:
    """Generate a long-lived opaque API token."""
    return secrets.token_urlsafe(32)


def get_current_user(authorization: str = Header(None)) -> dict:
    """FastAPI dependency: resolve the caller from a Bearer token.

    Raises 401 if the header is missing/malformed or the token is unknown.
    Returns a plain dict of the user row.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization[len("bearer "):].strip()
    row = db.user_by_token(token)
    if row is None:
        raise HTTPException(status_code=401, detail="invalid token")
    user = dict(row)
    # A locked user's token stops working as soon as the user is locked.
    if user.get("locked"):
        raise HTTPException(status_code=403, detail="account locked")
    return user


def require_admin(user: dict) -> None:
    """Deny with 403 unless the user is an admin."""
    if user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="admin required")


def check_volume(user: dict, level: int) -> None:
    """Deny with 403 if level exceeds the user's max_volume (if set)."""
    max_volume = user.get("max_volume")
    if max_volume is not None and level > max_volume:
        raise HTTPException(
            status_code=403,
            detail=f"volume {level} exceeds max_volume {max_volume}",
        )


# TODO: enforce room_access once rooms populated at setup
