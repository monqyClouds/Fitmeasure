# Fitmeasure server

Go backend for live video sessions. The media server (SFU) is built from
scratch on [Pion](https://github.com/pion/webrtc), in the stages described in
[`docs/live-sessions.md`](../docs/live-sessions.md#44-build-stages-the-learning-path).

| Stage | Status |
|---|---|
| S1. Echo: your camera goes to the server and comes back | ✅ |
| S2. Small room: up to 4 people, everyone sees everyone | next |
| S3. Real networks: TURN, deployment, the Android app | |
| S4. Simulcast | |
| S5. Bandwidth estimation | |
| S6. Session features | |

## Run it

Needs Go 1.24 or newer.

```sh
cd server
go run ./cmd/fitmeasure-server
```

Open <http://localhost:8080> in Chrome or Firefox, press **Start** and allow
the camera. The right-hand video has made the round trip through the server.
The page lists every signalling step and live connection stats.

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
internal/sfu/            media forwarding: echo.go is stage 1
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
  sender's encoder can. This matters much more once one sender has many
  receivers (stage 2).
