# Live sessions: design

Status: in progress. Stage S1 (echo) is built in `server/`; see its README.

Fitmeasure today is local-only: profiles, plans, workouts and measurements
live on the phone. This document describes the first online feature: **live
video sessions** where people train together, either as equals (group mode)
or led by a trainer (trainer mode).

## 1. Goals and non-goals

Goals:

- Live audio and video for up to **16 people** (a leader and 15 others).
- Two modes, **group** and **trainer**, with the visibility rules below.
- **Ongoing groups** that members rejoin freely, and **one-off sessions**.
- A **waiting room** for anyone not yet accepted.
- Host and moderator controls: mute, ask to unmute, remove, lock, promote.
- Layouts that adapt to any screen: phone (portrait and landscape), tablet,
  laptop.
- **Android app** first, plus a **web link** that works in Chrome on Android
  and desktop and in Safari on iPhone.
- A self-hosted Go backend.

Not in scope for now:

- Recording or replays.
- Payments.
- A native iPhone app with push notifications (iPhone users join via the web
  link).
- Choosing the server region.
- Syncing workout data, plans or measurements. The existing app stays
  local-first.

## 2. Concepts

| Term | Meaning |
|---|---|
| **Account** | An online identity (name, email). A local profile on the phone can link to one. |
| **Group** | A persistent set of members, e.g. "Morning crew". Has one owner and any number of admins. Sessions can be started from it, now or scheduled. |
| **Session** | One live video session. Either belongs to a group or is a one-off, and either starts now or is scheduled. |
| **Host** | The person who started the session. In trainer mode, the host is the trainer. |
| **Moderator** | A participant the host has promoted. |
| **Participant** | Anyone else in the session. |
| **Waiting room** | Where people wait until a host or moderator admits them. |

### Modes

| | Group mode | Trainer mode |
|---|---|---|
| Who sees whom | Everyone sees everyone | The trainer sees everyone. Each participant picks **Everyone** or **Trainer only**. |
| Who hears whom | Everyone hears everyone | Everyone hears everyone, including "trainer only" participants. When the trainer answers someone, the whole class should have heard the question. |
| Main layout | Equal grid | Trainer large, others in a grid. The trainer's own screen shows the grid. |

## 3. Rules

### 3.1 Joining

| Situation | What happens |
|---|---|
| Member of the group opens a group session | Joins directly, no waiting room. |
| Non-member opens a group session link | Waiting room. If admitted, they **become a member of the group** and can rejoin future sessions directly. |
| Anyone opens a one-off session link | Waiting room, except the host. |
| Someone already admitted to this session drops out (network, app closed) | Rejoins this session directly. |
| Session is locked | New people can't enter the waiting room. Members and people already admitted can still rejoin. |

Who can admit people: the host and moderators, or everyone when "everyone can
moderate" is on.

### 3.2 Removing

- Anyone with moderation rights can remove a participant, but **never the
  host**.
- In a group session, removing someone offers two choices:
  - **Remove from session.** They can't rejoin this session, but stay in the
    group.
  - **Remove from group.** They're also removed as a member. Rejoining needs
    the waiting room again.
- Group membership can also be managed outside a session (the group's member
  list).
- A removed person can't rejoin the same session, not even through the
  waiting room.

### 3.3 Group roles

| Action | Owner | Admin | Member |
|---|---|---|---|
| Start or schedule a session for the group | ✓ | ✓ | ✓ |
| Invite people, approve and remove members | ✓ | ✓ | ✗ |
| Make or remove admins | ✓ | ✗ | ✗ |
| Rename or delete the group | ✓ | ✗ | ✗ |
| Transfer ownership | ✓ | ✗ | ✗ |

The owner can't be removed. If the owner deletes their account, ownership
passes to the longest-standing admin, otherwise the longest-standing member.

Group roles and session roles are separate: whoever starts a session is its
host, whatever their group role.

### 3.4 Session roles and permissions

| Action | Host | Moderator | Participant | Participant, "everyone can moderate" on |
|---|---|---|---|---|
| Mute someone's mic or camera | ✓ | ✓ | ✗ | ✓ |
| Ask someone to unmute | ✓ | ✓ | ✗ | ✓ |
| Admit from the waiting room | ✓ | ✓ | ✗ | ✓ |
| Remove someone (never the host) | ✓ | ✓ | ✗ | ✓ |
| Lock or unlock the session | ✓ | ✓ | ✗ | ✗ |
| Promote or demote moderators | ✓ | ✗ | ✗ | ✗ |
| Turn "everyone can moderate" on or off | ✓ | ✗ | ✗ | ✗ |
| Change mode | ✓ | ✗ | ✗ | ✗ |
| Hand over host | ✓ | ✗ | ✗ | ✗ |
| End the session for everyone | ✓ | ✗ | ✗ | ✗ |

Everyone can always mute or unmute themselves, turn their own camera on or off,
pin anyone on their own screen, and change their own volume for others.

### 3.5 Muting and unmuting

- **Mute** takes effect immediately. The person sees who muted them.
- **Unmute** is a request: the person gets "Alex asks you to unmute" with
  **Unmute** and **Not now**. Nobody can turn on someone else's mic or camera.
- Above 4 participants, people join with their mic off. They can unmute
  themselves.

### 3.6 Visibility in trainer mode

- Each participant picks **Everyone** or **Trainer only** when joining, and
  can change it at any time.
- "Trainer only" means the participant's **video** is sent only to the host,
  not to moderators. Their **audio** still goes to everyone.
- Others see a "trainer only" participant as an avatar tile with their name,
  mic status and speaking indicator, but no video.
- If the host role passes to someone else, "trainer only" video follows the
  new host.
- Switching a session from trainer mode to group mode doesn't expose anyone.
  "Trainer only" participants are asked "Switch to visible to everyone?", and
  stay trainer-only until they accept.

### 3.7 When the host leaves

- The host can hand over host to anyone before leaving.
- If the host just drops out, the session continues. After 2 minutes without
  them reconnecting, host passes to the longest-present moderator, otherwise to
  the longest-present participant.
- If the original host rejoins after a handover, they're a moderator unless the
  new host hands it back.
- The session ends when the last person leaves, or when the host ends it.

### 3.8 Scheduled sessions

- A session can **start now** or be **scheduled** for a date and time, with a
  title and optional description. In a group, any member can schedule; the
  person who scheduled it becomes the host.
- Invited people (group members, or everyone with the link for a one-off) get
  a reminder **15 minutes before**, by push notification in the Android app and
  by email as a fallback (which also covers web and iPhone users).
- The session opens **10 minutes early**. People who arrive before the host
  wait in a "starting soon" screen. When the host arrives, members go straight
  in and others enter the waiting room.
- The host can edit or cancel a scheduled session, and everyone invited is
  notified.
- A scheduled session the host never starts is marked missed 1 hour after its
  start time.
- No repeating schedules yet ("every Monday at 7"); that's a natural next step.

## 4. Architecture

```
  Android app (Flutter)              Web client (browser)
          │                                   │
          │  HTTPS (REST)                     │
          │  WebSocket: control + signalling  │
          │  WebRTC media (UDP, TCP fallback) │
          └─────────────────┬─────────────────┘
                            ▼
          ┌──────────────────────────────────────┐        ┌──────────────┐
          │ Go backend                           │        │ TURN relay   │
          │  control plane: accounts, groups,    │◄──────►│ (pion/turn)  │
          │  sessions, rules, waiting room       │        │ UDP 3478,    │
          │  media plane: SFU (Pion)             │        │ TLS 443      │
          └──────────────────┬───────────────────┘        └──────────────┘
                             ▼
                         Postgres
```

- **Control plane: the Go backend.** Accounts, groups, sessions, roles, the
  waiting room, permissions. It is the only authority on who may do what.
  Clients talk to it over REST, plus a WebSocket per live session for real-time
  control events.
- **Media plane: our SFU, built on Pion.** It only forwards audio and video
  packets, never re-encoding them. It enforces who receives which tracks,
  according to the rules held by the control plane.
- **TURN relay** for networks where phones can't connect directly. It must be
  reachable on TCP/TLS port 443 for strict networks.
- **Caddy** in front for HTTPS certificates. Caddy and TURN-over-TLS both want
  port 443, so they need a second IP address, or a TLS router that sends each
  connection by hostname (e.g. `turn.` vs `api.`) to the right one.
- Single server to start: Go backend (including the SFU), Postgres and TURN
  on one machine. These parts can be split later.

### 4.1 Media server: our own SFU on Pion

**Decision:** build the SFU ourselves with [Pion](https://github.com/pion/webrtc),
the Go WebRTC library. The main reason is to learn and understand WebRTC, so
the SFU is built in stages (section 4.4), each one teaching one concept and
working on its own.

What this means compared with an off-the-shelf SFU like LiveKit (itself built
on Pion):

| Needed for this design | With Pion, we build |
|---|---|
| Signalling: offers, answers, ICE candidates, renegotiation as people join and leave | Our own protocol, carried on the session WebSocket |
| NAT traversal | ICE with a public IP, plus `pion/turn` reachable over TLS on 443 |
| Forwarding | Reading RTP from each publisher and writing it to each allowed subscriber |
| Simulcast | Choosing a layer per subscriber, rewriting sequence numbers and timestamps when switching |
| Coping with bad networks | NACK and retransmission, keyframe requests (PLI), bandwidth estimation (TWCC) via `pion/interceptor` |
| Speaking indicators | Reading the audio-level RTP header extension |
| Permissions, mute, remove | Checks in the forwarding table |
| Reconnect after a network switch | ICE restart, on the server and in both clients |
| Clients | A small signalling library in Dart (`flutter_webrtc`) and in JavaScript (browser WebRTC) |

Expected effort: a demo with a few people in about 2–4 weeks; reliable
16-person sessions on mobile networks in several months, then ongoing tuning.

**Escape hatch.** The rest of the backend talks to the SFU through one small Go
interface (section 4.5). If the custom SFU ever holds the product back, LiveKit
can be swapped in behind that interface without changing the control plane or
the rules.

### 4.2 SFU design

The SFU runs in the same Go binary as the backend at first, as its own package
(`internal/sfu`). Signalling shares the session WebSocket, so a participant has
exactly one WebSocket and two peer connections.

```
               ┌──────────────────── Go backend ─────────────────────┐
  phone A ─WS──┤ session hub ── rules (roles, visibility, mute)      │
   │ │         │      │                                              │
   │ └─pub PC──┤ Room ── Participant A ── published tracks ──┐       │
   └───sub PC──┤      ├─ Participant B ── published tracks ──┼─ forwarding
               │      └─ …                                    │   table
               │        each subscriber: DownTracks (one per  ◄┘       │
               │        track it is allowed and wants to see)          │
               └─────────────────────────────────────────────────────┘
```

- **Two peer connections per participant.**
  - **Publish:** the client sends the offer for its camera and mic.
  - **Subscribe:** the server sends offers whenever the set of tracks the
    participant should receive changes.

  Keeping the directions separate avoids both sides sending offers at the same
  moment ("glare") and keeps renegotiation easy to reason about. LiveKit uses
  the same approach.
- **Room.** One per live session. Holds participants and the forwarding table:
  for every published track, which subscribers receive it. The table is
  recalculated from the rules whenever someone joins or leaves, changes
  visibility or role, or is muted.
- **Published track (up track).** Reads RTP packets from the publisher. With
  simulcast it holds three layers (high, medium, low).
- **Down track.** One per subscriber per track. It picks the layer to send and
  rewrites sequence numbers, timestamps and SSRC, so a layer switch looks like
  one continuous stream to the receiver. It also handles RTCP from the
  subscriber:
  - **NACK:** resend from a small packet buffer.
  - **PLI:** ask the publisher for a keyframe, rate-limited.
- **Layer choice** comes from two inputs:
  - the tile size the subscriber reports for that participant (off-screen
    means no video at all);
  - the subscriber's estimated bandwidth, from TWCC feedback.
- **Audio** is forwarded as is (Opus). The audio-level header extension drives
  speaking indicators, and the loudest speakers are sent to clients a few times
  a second.
- **Networking:**
  - All WebRTC traffic is multiplexed on a single UDP port, plus a TCP fallback
    port (Pion's `SettingEngine`), with the server's public IP set explicitly.
  - `pion/turn` runs alongside on UDP 3478 and TLS on 443, for networks that
    block everything else.

### 4.3 How the rules are enforced

| Rule | Enforcement |
|---|---|
| Waiting room | People in the waiting room have a WebSocket but no peer connections. The SFU only accepts an offer from an admitted participant. |
| Removed people can't rejoin | The hub closes their peer connections and WebSocket, and refuses joins to that session. |
| Locked session | The hub refuses new waiting-room entries. |
| "Trainer only" video | The forwarding table only creates a down track for that camera towards the current host. Others get the audio only. When the host changes, the table is recalculated. |
| Mute (by a moderator) | The SFU stops forwarding the track immediately, and the hub tells the person's app to mute locally (so their UI matches). |
| Unmute request | The hub sends `unmute_requested`. Only the person's own app can start sending again. |
| Roles | Stored in Postgres and cached in the hub. Every moderation event is checked against the role before anything happens. |
| Clients can't cheat | Everything above happens on the server. A modified app can only change what it sends, never what it receives. |

### 4.4 Build stages (the learning path)

Each stage is a working system and introduces one set of WebRTC concepts.
Pion's examples (`sfu-ws`, `broadcast`, `simulcast`, `rtcp-processing`) are
good references for each one.

| Stage | Builds | WebRTC concepts learned | Done when |
|---|---|---|---|
| **S1. Echo** | One browser sends its camera to the server, which sends it back | Peer connections, SDP offer and answer, ICE candidates, tracks, RTP | You see yourself through the server |
| **S2. Small room** | Up to 4 people, everyone forwards to everyone, single quality | Signalling protocol, renegotiation, forwarding RTP to many | 4 browsers on one Wi-Fi see each other |
| **S3. Real networks** | Server deployed, TURN on 443, the Android app joins | NAT, STUN and TURN, ICE candidate types, keyframes (PLI), NACK and retransmission | A phone on 4G and a laptop on Wi-Fi stay connected for 30 minutes |
| **S4. Simulcast** | Three layers per camera, per-subscriber layer choice from tile size | Simulcast (RIDs), SSRC and sequence-number rewriting, keyframe on layer switch | Switching a tile between small and large changes quality without freezing |
| **S5. Bandwidth** | TWCC-based estimation decides layers; off-screen tiles get nothing | Congestion control, `getStats`, packet loss and jitter | Throttling one phone lowers only that phone's quality |
| **S6. Session features** | Speaking indicators, mute, remove, "trainer only", ICE restart on network switch | Audio levels, track permissions, ICE restart | 16 participants for an hour with the moderation rules working |

Tools to use throughout:
- `chrome://webrtc-internals`
- `getStats` in the clients
- `tc netem` on Linux to simulate loss and latency
- Logging RTCP on the server

### 4.5 SFU interface

The control plane only uses this interface, so the SFU stays replaceable:

```go
type Media interface {
	OpenRoom(sessionID string) error
	CloseRoom(sessionID string) error
	Admit(sessionID, userID string) error          // allow the participant's offers
	Remove(sessionID, userID string) error         // close their connections
	Mute(sessionID, userID string, kind TrackKind) error
	SetVisibility(sessionID, userID string, v Visibility) error
	SetHost(sessionID, userID string) error         // recalculates "trainer only"
	Events(sessionID string) <-chan MediaEvent      // joined, left, speaking
}
```

### 4.6 Media settings

| Setting | Value |
|---|---|
| Video codec | VP8 with simulcast (widest support across Android and browsers) |
| Quality layers | About 720p / 360p / 180p for the host in trainer mode. Others cap at 540p. |
| Frame rate | 24 fps |
| Audio | Opus with echo cancellation, noise suppression and automatic gain on |
| Off-screen tiles | No down track, so nothing is sent |
| Tile quality | Requested from the tile's size on screen |

## 5. Data model (Postgres)

```sql
users (
  id uuid primary key,
  name text not null,
  email text unique not null,
  created_at timestamptz not null default now()
)

groups (
  id uuid primary key,
  name text not null,
  default_mode text not null check (default_mode in ('group', 'trainer')),
  created_at timestamptz not null default now()
)

group_members (
  group_id uuid references groups on delete cascade,
  user_id uuid references users on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
)

sessions (
  id uuid primary key,
  group_id uuid references groups on delete set null,   -- null for one-off
  host_id uuid not null references users,
  mode text not null check (mode in ('group', 'trainer')),
  everyone_can_moderate boolean not null default false,
  locked boolean not null default false,
  invite_code text unique not null,                     -- for the share link
  title text,
  description text,
  status text not null
    check (status in ('scheduled', 'live', 'ended', 'cancelled', 'missed')),
  scheduled_for timestamptz,                            -- null for start now
  started_at timestamptz,
  ended_at timestamptz
)

login_codes (
  email text not null,
  code_hash text not null,                              -- never store the code
  expires_at timestamptz not null,                      -- 10 minutes
  attempts int not null default 0,                      -- locked after 5
  primary key (email, code_hash)
)

auth_sessions (
  id uuid primary key,
  user_id uuid not null references users on delete cascade,
  refresh_token_hash text unique not null,
  device text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
)

push_tokens (
  user_id uuid references users on delete cascade,
  token text not null,                                  -- Firebase Cloud Messaging
  platform text not null check (platform in ('android', 'web')),
  primary key (user_id, token)
)

session_participants (
  session_id uuid references sessions on delete cascade,
  user_id uuid references users on delete cascade,
  role text not null check (role in ('host', 'moderator', 'participant')),
  state text not null check (state in ('waiting', 'admitted', 'removed', 'left')),
  visibility text not null default 'everyone'
    check (visibility in ('everyone', 'trainer_only')),
  first_joined_at timestamptz,
  last_seen_at timestamptz,
  primary key (session_id, user_id)
)
```

The group owner is the `group_members` row with role `owner`. A unique
partial index ensures exactly one per group.

Attendance comes from `session_participants`, updated from the SFU's joined
and left events (section 4.5).

## 6. Backend API

All endpoints need a signed-in user. `{id}` is a UUID.

### REST

| Method and path | Purpose |
|---|---|
| `POST /auth/code` | Email a 6-digit sign-in code (rate limited per email and IP) |
| `POST /auth/verify` | Exchange email and code for an access token (15 min) and a refresh token |
| `POST /auth/refresh` | New access token from the refresh token |
| `POST /auth/logout` | Revoke this device's refresh token |
| `DELETE /me` | Delete the account |
| `POST /me/push-tokens` | Register this device for push notifications |
| `GET /me` | Current user |
| `POST /groups` | Create a group |
| `GET /groups` | My groups |
| `GET /groups/{id}` | Group details and members |
| `PATCH /groups/{id}/members/{userId}` | Change a member's role (owner) |
| `DELETE /groups/{id}/members/{userId}` | Remove a member (owner or admin) |
| `POST /groups/{id}/transfer` | Transfer ownership (owner) |
| `POST /groups/{id}/invite` | Create a share link for the group |
| `POST /sessions` | Start now or schedule a session (one-off, or with `group_id`), choosing the mode |
| `GET /sessions` | My upcoming and live sessions |
| `PATCH /sessions/{id}` | Edit a scheduled session (host) |
| `POST /sessions/{id}/cancel` | Cancel a scheduled session (host) |
| `GET /sessions/{inviteCode}` | Session preview before joining: name, host, mode, how many people are in it |
| `POST /sessions/{id}/join` | Ask to join. Returns `admitted`, `waiting` or `refused`, and the WebSocket URL. |
| `POST /sessions/{id}/end` | End for everyone (host) |

### Session WebSocket: `GET /sessions/{id}/ws`

One connection per person, used both while waiting and while in the session.

Client → server:

| Event | Who may send it |
|---|---|
| `admit {userId}` / `deny {userId}` | Admitting roles |
| `mute {userId, track: mic\|camera}` | Moderating roles |
| `request_unmute {userId, track}` | Moderating roles |
| `remove {userId, scope: session\|group}` | Moderating roles, never on the host |
| `set_role {userId, role}` | Host |
| `set_settings {everyoneCanModerate?, locked?, mode?}` | Host. Lock is also allowed for moderators. |
| `transfer_host {userId}` | Host |
| `set_visibility {everyone\|trainer_only}` | The participant, about themselves |
| `unmute_response {accepted}` | The person who was asked |
| `layout {userId: tileSize}` | Everyone, about themselves: which participants are on screen and how big, so the SFU picks layers |
| `offer`, `answer`, `candidate` `{pc: publish\|subscribe, ...}` | Signalling for the two peer connections (admitted people only) |

Server → client:

| Event | Meaning |
|---|---|
| `state {...}` | Full session state on connect: participants, roles, settings, waiting list |
| `waiting_room_changed {...}` | Someone entered or left the waiting room (sent to admitting roles) |
| `admitted {iceServers}` / `denied` | Outcome for the person waiting. `iceServers` includes short-lived TURN credentials. |
| `participant_changed {...}` | Role, visibility or state changed |
| `settings_changed {...}` | Mode, lock or "everyone can moderate" changed |
| `muted_by {userId, track}` | You were muted, and by whom |
| `unmute_requested {byUserId, track}` | Show the unmute prompt |
| `removed {scope}` | You were removed |
| `host_changed {userId}` | New host; "trainer only" apps update their track permission |
| `speakers {userIds}` | Who is speaking, a few times a second |
| `offer`, `answer`, `candidate` `{pc, ...}` | Signalling from the SFU, mainly offers on the subscribe connection |
| `ended` | Session over |

## 7. Clients

### 7.1 Screens

1. **Sign-in**: email, then the 6-digit code.
2. **Live tab** (new, in the app): live now, upcoming sessions, my groups, and
   "Start now" or "Schedule".
3. **Start or schedule**: pick a group or one-off, the mode, and now or a date
   and time. Shows the share link.
4. **Pre-join**: camera preview, mic and camera toggles, name. In trainer mode,
   a visibility choice. A hint about using earbuds and placing the phone.
5. **Waiting room**, or **starting soon** before the host arrives: "Waiting for the host to let you in".
6. **In session**: video layout (below), a control bar (mic, camera, flip
   camera, participants, leave), and the participants sheet with moderation
   actions.
7. **Group page**: members and their roles, invite link, upcoming sessions,
   start or schedule a session.

The web client covers sign-in and screens 4–6, entered from a link.

### 7.2 Adaptive layouts

The same rules apply in the app and on the web, chosen by available width and
orientation.

| Size class | Group mode | Trainer mode (participant) | Trainer mode (trainer) |
|---|---|---|---|
| Compact (phone portrait, < 600 dp) | 2-column grid, 4–6 tiles per page | Trainer on top, others in a horizontal strip | 2-column grid, pages |
| Medium (phone landscape, small tablet) | 3 columns, about 6 tiles | Trainer large, vertical side strip | 3 columns, pages |
| Expanded (tablet, laptop, ≥ 840 dp) | Up to 4×4, all 16 | Trainer large plus a 2–3 column grid | Up to 4×4 |

Everywhere:

- Pin anyone to make them large. Unpin returns to the mode's layout.
- Your own camera is a small floating tile you can drag to a corner.
- Rotation and window resizing re-arrange the layout with a short animation.
- Tiles show the name, mic status and a speaking outline. "Trainer only"
  participants show an avatar.
- Each tile requests video quality matching its size, and off-screen pages
  receive none.

### 7.3 Android specifics

- A foreground service with the camera and microphone types, so the session
  keeps running when the screen locks or the app is in the background
  (required on Android 14).
- Keep the screen on, support landscape, the front camera by default, and
  Bluetooth earbuds.
- Ask for camera and microphone permission on the pre-join screen, with a
  short explanation.

## 8. Security and privacy

- Sign-in is passwordless: a 6-digit code emailed to the user, valid for 10
  minutes, stored only as a hash, locked after 5 wrong tries, and rate limited.
  Sending email needs a provider (e.g. Amazon SES, Postmark or Resend) and a
  domain set up for it (SPF and DKIM), or codes land in spam.
- All traffic is encrypted: HTTPS and WSS for control, and WebRTC media (DTLS
  and SRTP) to the SFU. The SFU can see media in transit. End-to-end
  encryption is possible later, but it limits some features.
- The SFU only accepts peer connections from people the hub has admitted, over
  their authenticated WebSocket. TURN credentials are short-lived and per
  user.
- Every rule in section 3 is checked on the backend, never only in the app.
- Rate limits on joining, waiting-room entries and invite links.
- No recording, and nothing about the media is stored.
- Account deletion in the app (required by Google Play), deleting the account,
  its memberships and its session history.
- For Google Play: a privacy policy and the Data safety form (camera,
  microphone, account data). New personal developer accounts need a closed
  test with at least 12 testers for 14 days before going public. Check the
  current requirements when releasing.

## 9. Capacity and cost (rough estimates)

These figures are estimates for planning, not measurements.

| | Trainer mode, 16 people | Group mode, 16 people |
|---|---|---|
| Upload per phone | ~1–2 Mbit/s | ~1 Mbit/s |
| Download per phone | ~1.5–3 Mbit/s | ~2–3 Mbit/s |
| Server outgoing traffic at peak | ~40 Mbit/s | ~50–60 Mbit/s |
| Per hour of session | ~15–20 GB | ~20–25 GB |

An SFU only forwards packets, so a 4-core server is plenty for a few sessions
at once. Bandwidth is the main cost. A server plan with several TB of included
traffic per month covers daily sessions.

## 10. Milestones

The SFU stages from section 4.4 are interleaved with the product work, so each
milestone gives something usable.

1. **S1–S2 in the browser:** echo, then a 4-person room on one Wi-Fi. Go
   service skeleton with the session WebSocket, no accounts yet.
2. **Backend foundations:** Postgres, email-code sign-in, users, one-off
   sessions, invite links.
3. **S3 and the Android app:** deploy with TURN, Android joins, pre-join
   screen, group-mode grid, mic and camera, leave.
4. **S4–S5:** simulcast, layer choice from tile size, bandwidth estimation,
   adaptive layouts on every screen size.
5. **Waiting room and moderation (S6):** admit and deny, mute, request unmute,
   remove, lock, roles, "everyone can moderate", host handover, speaking
   indicators, ICE restart.
6. **Trainer mode:** layouts, visibility choice, host-only video for "trainer
   only".
7. **Groups and scheduling:** create, invite, admins, members rejoin
   directly, remove from group, scheduled sessions with push and email
   reminders.
8. **Web client polish:** waiting room and the full session in the browser
   (Android Chrome, desktop, iPhone Safari).
9. **Release prep:** foreground service polish, account deletion, privacy
   policy, Play closed test, a 16-person, one-hour test session.

## 11. Repository layout

Everything stays in this repository. The Flutter app moves into `mobile/`
before backend work starts, in its own commit, so history stays easy to follow
(`git log --follow` still tracks files).

```
mobile/        Flutter app (Android, iOS, and later the web client)
server/        Go backend: control plane and SFU
  cmd/fitmeasure-server/
  internal/auth, groups, sessions, hub (session WebSocket), sfu, store
  migrations/
docs/          design docs, including this one
.github/       CI: builds the app from mobile/, tests and builds the server
```

## 12. Open questions

1. **Web client technology:** Flutter web (shares the app's code, including the
   signalling library) or a small JavaScript page (lighter and closer to the
   browser's WebRTC API)?
2. **Email provider** for sign-in codes and reminders, and a domain for it.
