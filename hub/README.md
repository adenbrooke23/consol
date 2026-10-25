# Hub

The Consol hub: a Python FastAPI service that runs on an always-on Mac and controls Sonos speakers, Spotify playback on those speakers, and Apple TVs. The iPad app and the Mac app talk to it over the local network on port 8000.

Installation, configuration, Apple TV pairing and troubleshooting are covered in the [main README](../README.md). The route summary and the rules the code depends on are in [AI_GUIDE.xml](../AI_GUIDE.xml).

## Files

| File | Purpose |
| --- | --- |
| `main.py` | FastAPI app and every HTTP route. |
| `sonos.py` | Sonos discovery, grouping, volume, transport and Spotify playback through SoCo and ShareLink. |
| `spotify.py` | Spotify OAuth and Web API calls for search and browsing. Loads `.env`. |
| `appletv.py` | Apple TV discovery, pairing and control through pyatv, including the protected-device guard. |
| `auth.py` | PIN hashing, tokens and access checks. |
| `db.py` | SQLite schema and helpers (`data.db`). |
| `models.py` | Request bodies. |
| `hubkeeper.py` | Standard-library supervisor on port 8001 that starts and stops the hub and advertises it over Bonjour. |
| `launchd/` | launchd agent template for the keeper. |
| `.env.example` | Every configuration variable. Copy it to `.env`. |

## Run it for development

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Python 3.10 or later is required. Interactive API docs are served at `http://127.0.0.1:8000/docs`. If the installed hub is running, stop its keeper first (see the main README's development notes), because only one process can use port 8000.

Sonos and Apple TV discovery only work on the same network as the devices.
