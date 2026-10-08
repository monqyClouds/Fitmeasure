# Fitmeasure server

Go backend for live video sessions. The media server (SFU) is built from
scratch on [Pion](https://github.com/pion/webrtc), in the stages described in
[`docs/live-sessions.md`](../docs/live-sessions.md#44-build-stages-the-learning-path).

| Stage | Status |
|---|---|
| S1. Echo: your camera goes to the server and comes back | ✅ |
| S2. Small room: up to 4 people, everyone sees everyone | ✅ |
| S3. Real networks: TURN, deployment, the Android app | next |
| S4. Simulcast | |
| S5. Bandwidth estimation | |
| S6. Session features | |

## Run it

Needs Go 1.24 or newer.

```sh
cd server
go run ./cmd/fitmeasure-server
```

Open <http://localhost:8080> in Chrome or Firefox. It opens the latest stage:

- **Small room** (`/room/`): enter a name and press **Join**. Open the page in
  more tabs, browsers or devices and join the same room; everyone sees
  everyone, up to four people. The log shows every signalling step, including
  the server's new offer each time someone joins or leaves.
- **Echo** (`/echo/`): press **Start**. The right-hand video has made the round
  trip through the server.

Both pages show live connection stats.

### From a phone or another computer

Browsers only allow camera access on `localhost` or over HTTPS. To open the
page from a phone on the same Wi-Fi, give the server a certificate. The easiest
way is [mkcert](https://github.com/FiloSottile/mkcert), which creates one your
devices trust:

```sh
mkcert -install
mkcert 192.168.1.20          # your computer's LAN IP
go run ./cmd/fitmeasure-server -tls-cert 192.168.1.20.pem -tls-key 192.168.1.20-key.pem
```

Then open `https://192.168.1.20:8080` on the phone. For the phone to trust the
certificate, install mkcert's root certificate on it (`mkcert -CAROOT` shows
where it is).

### Settings

Each setting can be a flag, an environment variable, or a line in `server/.env`
(git-ignored; copy `.env.example` to start). Flags beat environment variables,
which beat `.env`.

| Flag | Variable | Default | Meaning |
|---|---|---|---|
| `-addr` | `FITMEASURE_ADDR` | `:8080` | HTTP listen address |
| `-udp-port` | `FITMEASURE_UDP_PORT` | `0` | One UDP port for all media. `0` uses a random port per connection, which is fine on a LAN. A server behind a firewall should set one, e.g. `7882`. |
| `-public-ip` | `FITMEASURE_PUBLIC_IP` | | Public IP to advertise, for servers behind 1:1 NAT (most cloud VMs) |
| `-stun` | `FITMEASURE_STUN` | | Comma-separated STUN URLs for the server's own connections |
| `-tls-cert`, `-tls-key` | `FITMEASURE_TLS_CERT`, `FITMEASURE_TLS_KEY` | | Serve HTTPS |

For example, to use port 8282 locally:

```sh
echo 'FITMEASURE_ADDR=:8282' > .env
```

## Test

```sh
go vet ./...
go test -race ./...
```

`internal/sfu/echo_test.go` connects a Pion peer to the echo the same way a
browser does, sends VP8 video, and checks that the same payload comes back.

## Layout

```
cmd/fitmeasure-server/   main: flags, HTTP routes
internal/rtc/            the shared Pion API: codecs (VP8, Opus), interceptors, ICE settings
internal/signal/         signalling messages (offer, answer, candidate) over a WebSocket
internal/sfu/            media forwarding: echo.go is stage 1, room.go stage 2
web/static/              plain JavaScript test pages for the stages
```

## Things to look at while learning

- **`chrome://webrtc-internals`** (or `about:webrtc` in Firefox) while the echo
  runs: the full SDP, every ICE candidate pair tried, and graphs of bitrate,
  frame rate and packet loss.
- **The SDP** in the offer and answer: the `m=` lines (one per track), the
  `a=rtpmap` codecs (only VP8 and Opus survive the answer, because
  `internal/rtc` registers only those), `a=rtcp-fb` (NACK, PLI, transport-cc),
  and `a=candidate` lines.
- **Bitrate ramp-up:** the echo starts around 320×180 and climbs to 540p and
  above over about 20 seconds. The browser raises its sending rate as the
  server's transport-wide congestion control (TWCC) feedback shows the network
  can take it. Stage 5 uses the same feedback in the other direction.
- **Keyframes:** the server asks the browser for a keyframe (PLI) when the
  video track starts, and relays the browser's own PLI requests for the echoed
  video back to its encoder. The server can't make a keyframe itself; only the
  sender's encoder can. In a room every receiver's decoder may ask at once, so
  the server passes on at most one request per sender every 500 ms.
- **Two peer connections per person** in a room. On *publish* the browser
  offers and the server answers; on *subscribe* the server offers. Only one
  side ever offers on each connection, so offers never cross. In
  `chrome://webrtc-internals` they show up as two separate connections.
- **Renegotiation:** each join or leave changes what everyone else should
  receive, so the server sends each of them a new subscribe offer. Only one
  offer is in flight per person; changes made meanwhile go into a follow-up
  offer after the answer (`negotiate` and `handleAnswer` in `room.go`). A
  track that stops is not deleted from the SDP: its `m=` line stays, marked
  inactive.
- **Forwarding to many:** each incoming track is copied into one outgoing
  track on the server, which Pion writes to every subscriber's connection,
  rewriting the SSRC and payload type for each. Every participant receives
  every other at full quality, so the server's upload grows with the square of
  the room size. Simulcast (stage 4) and bandwidth estimation (stage 5)
  address that.
