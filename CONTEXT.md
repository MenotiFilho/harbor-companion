# Harbor Companion

A native Android companion for Harbor: the phone is a thin remote that renders
host snapshots and sends wire commands. Playback always runs on the host PC —
the phone never resolves streams.

## Language

### Connectivity

**Host**:
The Harbor instance running on the user's computer; it resolves streams and
plays media.
_Avoid_: server, PC, device

**Snapshot**:
The host's periodic state message over the remote WebSocket, carrying
now-playing, library and profiles.
_Avoid_: state, payload, update

### Catalog

**Rail**:
A titled horizontal row of catalog entries on Home.
_Avoid_: row, shelf, carousel

**Poster**:
A title's 2:3 portrait artwork, used on cards and small surfaces.
_Avoid_: cover, thumbnail

**Backdrop**:
A title's 16:9 wide artwork, used for hero bands.
_Avoid_: cover, banner, fanart

### Design language

**Hero**:
The large featured area at the top of a screen, built from a title's artwork,
name and primary actions.
_Avoid_: banner, spotlight

**Cinemascope**:
The Remote layout whose top band is a full-bleed cover.
_Avoid_: full-bleed

**Glass surface**:
A translucent, blurred surface that lets content behind it show through.
_Avoid_: frosted card, blur card

**Accent**:
The single brand color that marks interactive and active states.
_Avoid_: primary, highlight, theme color

### Playback

**Playback position**:
How far into the currently playing media the host is, in seconds; it ships in
every snapshot.
_Avoid_: progress, timestamp

**Watch progress**:
Per-item resume state the host stores for a title; it is not present in the
snapshot.
_Avoid_: progress (unqualified)

**Seek**:
An absolute jump to a point in the current media.
_Avoid_: jump

**Skip**:
A relative transport action (±30 s) resolved to a seek against the latest known
playback position.
_Avoid_: advance, rewind, seek by
