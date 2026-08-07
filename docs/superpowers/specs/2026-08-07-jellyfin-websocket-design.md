# Jellyfin WebSocket + Remote Control Design

**Date:** 2026-08-07
**Status:** Approved for implementation
**Scope:** `/socket` endpoint, live client-session registry, and remote-control command delivery

## 1. Summary

Hivefin has no WebSocket endpoint. `GET /socket` 404s, and clients retry it
persistently — 69 attempts in a single observed session. Clients degrade rather
than break, but three features are unavailable without it: "now playing"
session sync, live library refresh, and remote control (phone → TV casting,
remote seek/volume).

This adds the Jellyfin WebSocket protocol and the session infrastructure that
remote control requires, in three independently shippable stages.

**Delivered**

| Capability | Mechanism |
|-----------|-----------|
| Socket handshake + auth | `WebSockAdapter` upgrade, token via header or query |
| Keepalive | `ForceKeepAlive` on connect, `KeepAlive` echo |
| Live session tracking | `Hivefin.Sessions` over a `Registry` |
| Session push | `Sessions` message on `SessionsStart` and on change |
| Remote control | `Play` / `Playstate` / `GeneralCommand` routed to a target socket |

**Non-goals**

- Activity log and scheduled-task messages (no such subsystems exist; the
  corresponding subscribe messages are accepted as no-ops)
- SyncPlay (`SyncPlayCommand`, `SyncPlayGroupUpdate`)
- Live TV timer messages (`TimerCreated`, `SeriesTimerCreated`, …)
- Package/plugin installation messages
- Fixing the pre-existing `/Sessions` ID-format test failures (see §8)

## 2. Protocol contract

Taken from `jellyfin-sdk-kotlin` generated models, which the official Android
client deserializes with `kotlinx.serialization`. The naming is server-centric
because the SDK is generated from Jellyfin's OpenAPI spec:

- `OutboundWebSocketMessage` — **server → client**. Requires `MessageId` (UUID).
- `InboundWebSocketMessage` — **client → server**. No `MessageId`.

Both use `MessageType` as the JSON class discriminator. Envelope:

```json
{"MessageType": "ForceKeepAlive", "Data": 60, "MessageId": "<uuid>"}
```

### 2.1 Required fields

A property declared with no default value is **required** by
`kotlinx.serialization`; a missing key raises `MissingFieldException` and the
client discards the message. This is the same defect class already fixed for
`MediaSourceInfo` (see `Hivefin.Jellyfin.Dto.SdkRequired`), so every payload
below is built through the same discipline.

| Payload | Required fields |
|---------|----------------|
| `ForceKeepAliveMessage` | `Data` (Int), `MessageId` |
| `SessionInfoDto` | `PlayableMediaTypes`, `UserId`, `LastActivityDate`, `LastPlaybackCheckIn`, `IsActive`, `SupportsMediaControl`, `SupportsRemoteControl`, `HasCustomDeviceName`, `SupportedCommands` |
| `PlayerStateInfo` (`SessionInfoDto.PlayState`) | `CanSeek`, `IsPaused`, `IsMuted`, `RepeatMode`, `PlaybackOrder` |
| `PlayRequest` | `PlayCommand`, `ControllingUserId` |
| `PlaystateRequest` | `Command` |
| `GeneralCommand` | `Name`, `ControllingUserId`, `Arguments` (all three) |

`Dto.Session` currently omits `LastPlaybackCheckIn`. Stage 2 adds it.

`PlayState` itself is optional on `SessionInfoDto` (nullable-with-default), but
**hivefin always emits it**, idle or not: idle sessions get
`CanSeek: false, IsPaused: false, IsMuted: false, RepeatMode: "RepeatNone",
PlaybackOrder: "Default"` with `PositionTicks` omitted. This is not optional in
practice — jellyfin-web's session-card renderer dereferences
`PlayState.IsPaused` with **no null guard**, so a session with `PlayState`
entirely absent throws inside the socket message-dispatch chain on every
`Sessions` push, which is the same chain the video player's own events go
through; the practical effect is that video playback never starts in the
browser. `NowPlayingItem` is the only one of the two that stays genuinely
optional and is omitted when nothing is playing.

### 2.2 Enums

- `PlayCommand`: `PlayNow`, `PlayNext`, `PlayLast`, `PlayInstantMix`, `PlayShuffle`
- `PlaystateCommand`: `Stop`, `Pause`, `Unpause`, `NextTrack`, `PreviousTrack`, `Seek`, `Rewind`, `FastForward`, `PlayPause`
- `GeneralCommandType`: 43 values; hivefin advertises only the subset it can deliver

Unknown enum values are tolerated client-side (`coerceInputValues = true`), but
a missing required key is not.

## 3. Architecture

```
GET /socket ──► SocketController.connect
                  │  authenticate (JellyfinAuth.resolve_token/1)
                  │  401 if no valid token
                  ▼
             WebSockAdapter.upgrade ──► HivefinWeb.JellyfinSocket
                                          │ init      → register session, send ForceKeepAlive
                                          │ handle_in → KeepAlive / SessionsStart / …
                                          │ handle_info → pushes from PubSub
                                          │ terminate → unregister
                                          ▼
                                    Hivefin.Sessions (Registry + PubSub)
                                          ▲
POST /Sessions/:id/Playing ──► SessionsController ──┘  (looks up target, pushes)
```

**Session identity.** A session id is the **access token id**, which
`Dto.Session.from_access_token/1` already emits as `Id`. Reusing it keeps
`GET /Sessions` and socket-addressed commands consistent, and requires no new
identifier scheme.

Clients also pass `deviceId` on the socket query string. It is recorded for
reporting but is **not** the session key: the access token already carries the
device, and trusting a client-supplied key would let one client address
another's session. A `deviceId` that disagrees with the token's device is
logged and otherwise ignored.

**No new GenServer.** `Registry` with `Registry.update_value/3` holds the
mutable per-session state (capabilities, now-playing). Fan-out uses the
existing `Hivefin.PubSub`. This matches `Hivefin.Playback.Registry`.

## 4. Components

| Module | Purpose | Depends on |
|--------|---------|-----------|
| `Hivefin.Sessions` | register/unregister/list/lookup live sessions; capability + now-playing state | `Registry`, `Phoenix.PubSub` |
| `Hivefin.Jellyfin.WsMessage` | build the `MessageType`/`MessageId`/`Data` envelope; required-field defaults | — |
| `HivefinWeb.JellyfinSocket` | `WebSock` callbacks; translate messages to/from `Hivefin.Sessions` | `Hivefin.Sessions`, `WsMessage` |
| `HivefinWeb.Jellyfin.SocketController` | authenticate and upgrade | `JellyfinAuth` |
| `Dto.Session` (edit) | add `LastPlaybackCheckIn`; route through required-field defaults | `SdkRequired` |
| `SessionsController` (edit) | command endpoints that push to a target socket | `Hivefin.Sessions` |

Each is independently testable: `Hivefin.Sessions` without a socket,
`JellyfinSocket` callbacks without a network connection, `WsMessage` as a pure
function.

## 5. Message handling

**Client → server**

| Type | Behaviour |
|------|-----------|
| `KeepAlive` | echo `KeepAlive` |
| `SessionsStart` | subscribe to session topic; immediately push `Sessions` |
| `SessionsStop` | unsubscribe |
| `ActivityLogEntryStart`/`Stop` | accept, no-op |
| `ScheduledTasksInfoStart`/`Stop` | accept, no-op |
| unknown | ignore, debug-log |

Malformed JSON is ignored with a debug log; it must never terminate the socket.

**Server → client**

| Type | Trigger |
|------|---------|
| `ForceKeepAlive` | on connect, `Data: 60` |
| `KeepAlive` | reply to client `KeepAlive` |
| `Sessions` | on `SessionsStart`, and on session add/remove/state change |
| `Play` | `POST /Sessions/:id/Playing` |
| `Playstate` | `POST /Sessions/:id/Playing/:command` |
| `GeneralCommand` | `POST /Sessions/:id/Command/:command`, `POST /Sessions/:id/Message` |

## 6. Command endpoints

| Route | Message | Notes |
|-------|---------|-------|
| `POST /Sessions/:session_id/Playing` | `Play` | `ItemIds`, `StartPositionTicks`, `PlayCommand` |
| `POST /Sessions/:session_id/Playing/:command` | `Playstate` | `Seek` carries `SeekPositionTicks` |
| `POST /Sessions/:session_id/Command/:command` | `GeneralCommand` | e.g. `SetVolume`, `Mute` |
| `POST /Sessions/:session_id/Message` | `GeneralCommand` | `DisplayMessage` with `Header`/`Text` |

`ControllingUserId` is the authenticated caller. Responses: **204** on
delivery; **404** when the target session has no live socket; **403** when the
target has not advertised `SupportsMediaControl`.

Routes must precede the SPA catch-all in the router. `socket` stays in
`WebClientController`'s `@api_roots` so unmatched `/socket/*` paths still 404 as
JSON rather than SPA HTML.

## 7. Staged delivery

Each stage is independently shippable and testable on real devices.

**Stage 1 — transport and keepalive.** `SocketController`, `JellyfinSocket`,
`WsMessage`, router wiring. Socket connects, authenticates, sends
`ForceKeepAlive`, echoes `KeepAlive`, accepts and ignores everything else. The
observed 404 retry loop stops. No session state.

*Done when:* a client holds an open socket without reconnecting, and `/socket`
without credentials returns 401.

**Stage 2 — session registry and push.** `Hivefin.Sessions`, `Dto.Session`
gains `LastPlaybackCheckIn` and required-field defaults, `SessionsStart` pushes
a real `Sessions` payload, and the playback-reporting endpoints
(`Playing`, `Progress`, `Stopped`) update session state.

*Done when:* a second client sees the first client's now-playing state, and
every emitted `SessionInfoDto` carries all 9 required fields.

**Stage 3 — remote control.** The four command endpoints, capability gating,
and `GeneralCommandType` advertisement.

*Done when:* "play on device" from one client starts playback on another, and
pause/seek/volume reach the target.

## 8. Out of scope: `/Sessions` ID format

Four `/Sessions` and `Resume` tests currently fail on an ID-format mismatch
(`3f2470acd2fa4158810a7f3944d58a7c` returned, `3f2470ac-d2fa-4158-810a-7f3944d58a7c`
asserted) introduced by an earlier `Id.format` change. This is orthogonal to
the WebSocket work and is deliberately not addressed here. Reusing the access
token id as the session id neither depends on nor changes that behaviour.

## 9. Testing

| Level | Approach |
|-------|----------|
| `WsMessage` | pure unit tests; assert required keys present and non-null |
| `Hivefin.Sessions` | register/lookup/unregister/state update without a socket |
| `JellyfinSocket` | call `init/1`, `handle_in/2`, `handle_info/2` directly and assert `{:push, …}` replies |
| Upgrade + auth | controller test: valid token upgrades, missing token 401 |
| Commands | POST, then assert the registered target receives a correctly shaped message |
| Regression | required-key sets pinned literally, so shrinking a defaults map fails the test |

Required-field assertions list the field names literally, taken from the SDK —
never read from the implementation's own defaults map, which would make the
test agree with a regression instead of catching it.

## 10. Risks

| Risk | Mitigation |
|------|-----------|
| Missing required field silently breaks a client | Required-field defaults + literal key-set tests, per §2.1 |
| Socket leak on abnormal disconnect | `terminate/2` unregisters; `Registry` also clears entries when the owning process dies |
| Push to a dead socket | Look up at send time; 404 when absent |
| Keepalive interval mismatch causes client reconnects | Advertise 60s in `ForceKeepAlive`; verify no reconnect loop on a real client in Stage 1 |
| Untrusted `MessageType` from a client | Explicit allowlist; unknown types ignored, never dispatched dynamically |
