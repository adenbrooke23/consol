from pydantic import BaseModel, Field


class GroupRequest(BaseModel):
    rooms: list[str]


class VolumeRequest(BaseModel):
    level: int = Field(ge=0, le=100)


class UserCreate(BaseModel):
    name: str
    role: str
    pin: str | None = None
    max_volume: int | None = None


class LoginRequest(BaseModel):
    name: str
    pin: str | None = None


class PinLogin(BaseModel):
    pin: str


class NetworkName(BaseModel):
    name: str


class PlaylistCreate(BaseModel):
    name: str
    public: bool = False


class TrackURIs(BaseModel):
    uris: list[str]        # e.g. ["spotify:track:..."]


class TrackIDs(BaseModel):
    ids: list[str]         # bare track ids (like/save)


class PlayRequest(BaseModel):
    uris: list[str] | None = None       # explicit tracks
    context_uri: str | None = None      # album/playlist/artist context
    room: str | None = None             # Sonos room to play on
    start_index: int = Field(default=0, ge=0)   # where in the context to start


class RoomRequest(BaseModel):
    room: str                           # every player mutation names its room


class ShuffleRequest(BaseModel):
    state: bool
    room: str


class RepeatRequest(BaseModel):
    state: str = "off"                  # off | context | track
    room: str


class PlayerVolumeRequest(BaseModel):
    percent: int = Field(ge=0, le=100)
    room: str | None = None


class QueueAddRequest(BaseModel):
    uri: str                            # spotify:track:...
    room: str | None = None


class SeekRequest(BaseModel):
    room: str
    position_ms: int = Field(ge=0)


class GroupRooms(BaseModel):
    rooms: list[str]                    # first = coordinator/anchor


class SwitchRequest(BaseModel):
    from_room: str
    to_room: str


class QueuePlayRequest(BaseModel):
    room: str
    position: int = Field(ge=0)         # absolute 0-based queue index


class QueueRemoveRequest(BaseModel):
    room: str
    positions: list[int]                # absolute 0-based queue indices


class QueueReorderRequest(BaseModel):
    room: str
    from_position: int = Field(ge=0)
    insert_before: int = Field(ge=0)


class TVPairStart(BaseModel):
    identifier: str
    protocol: str                       # "Companion" | "AirPlay"


class TVPairFinish(BaseModel):
    identifier: str
    pin: str


class TVMapping(BaseModel):
    appletv_id: str
    hdmi_input: str | None = None


class TVText(BaseModel):
    text: str


class TVPairCancel(BaseModel):
    identifier: str


class TVSeek(BaseModel):
    position: int = Field(ge=0)          # absolute seconds
