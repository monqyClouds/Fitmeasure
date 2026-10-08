# Fitmeasure server

Go backend for live video sessions. The media server (SFU) is built from
scratch on [Pion](https://github.com/pion/webrtc), in the stages described in
[`docs/live-sessions.md`](../docs/live-sessions.md#44-build-stages-the-learning-path).

| Stage | Status |
|---|---|
| S1. Echo: your camera goes to the server and comes back | ✅ |
| S2. Small room: up to 4 people, everyone sees everyone | ✅ |
| S3. Real networks: TURN, deployment, the Android app | built; the 30-minute phone-on-4G test is next |
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
| `-addr` | `FITMEASURE_ADDR` | `:8080` | HTTP listen address (unused with `-domain`) |
| `-udp-port` | `FITMEASURE_UDP_PORT` | `0` | One UDP port for all media. `0` uses a random port per connection, which is fine on a LAN. A server behind a firewall should set one, e.g. `7882`. |
| `-tcp-port` | `FITMEASURE_TCP_PORT` | `0` | Also accept media over TCP on this port, for networks that block UDP. `0` is off. |
| `-public-ip` | `FITMEASURE_PUBLIC_IP` | | Public IP to advertise in ICE candidates; TURN relays from it and only to it. Required for TURN. |
| `-stun` | `FITMEASURE_STUN` | | Comma-separated STUN URLs for the server's own connections |
| `-tls-cert`, `-tls-key` | `FITMEASURE_TLS_CERT`, `FITMEASURE_TLS_KEY` | | Serve HTTPS with these files |
| `-domain` | `FITMEASURE_DOMAIN` | | Serve HTTPS for this domain on port 443 with an automatic Let's Encrypt certificate, and redirect port 80 |
| `-acme-email` | `FITMEASURE_ACME_EMAIL` | | Email Let's Encrypt may contact about certificates |
| `-cert-dir` | `FITMEASURE_CERT_DIR` | `certs` | Where Let's Encrypt certificates are kept |
| `-turn-port` | `FITMEASURE_TURN_PORT` | `0` | Run TURN over UDP and TCP on this port, usually `3478`. `0` is off. |
| `-turn-domain` | `FITMEASURE_TURN_DOMAIN` | | Also serve TURN over TLS on port 443 for this hostname. Needs `-domain`. |
| `-turn-relay-ports` | `FITMEASURE_TURN_RELAY_PORTS` | `50000-50199` | UDP ports TURN relays from |

For example, to use port 8282 locally:

```sh
echo 'FITMEASURE_ADDR=:8282' > .env
```

### TURN on your own network

To try TURN locally, give the server your computer's LAN IP and a TURN port,
then tick **Relay only** on the room page so every packet goes through it:

```sh
go run ./cmd/fitmeasure-server -public-ip 192.168.0.134 -turn-port 3478
```

The page's **Publish path** and **Subscribe path** then read
`relay via TURN over udp …`.

## Deploy

The server runs as one binary on a Linux machine with a public IP. It serves
HTTPS and TURN over TLS together on port 443, sorting connections by the
hostname the client asks for (`internal/tlsmux`), and gets its certificates
from Let's Encrypt by itself. So nothing else is needed in front of it.

### First time

1. **DNS:** point two A records at the droplet's public IPv4 address:
   `live.somto.si` (the site) and `turn.somto.si` (TURN over TLS).
2. **Firewall:** in DigitalOcean's cloud firewall, or with `ufw` on the
   droplet, allow inbound:

   | Port | Protocol | For |
   |---|---|---|
   | 22 | TCP | SSH |
   | 80, 443 | TCP | HTTPS, Let's Encrypt, TURN over TLS |
   | 3478 | UDP and TCP | TURN |
   | 7882 | UDP | media straight to the SFU |
   | 7881 | TCP | media over TCP |

   The TURN relay ports (50000–50199) don't need opening: relayed media only
   travels from the TURN server to the SFU, inside the droplet.
3. **Settings:** on the droplet, create `/etc/fitmeasure/fitmeasure.env` from
   [`deploy/fitmeasure.env.example`](deploy/fitmeasure.env.example), with the
   droplet's public IP filled in.
4. **Install:** from this directory, run

   ```sh
   deploy/deploy.sh root@live.somto.si
   ```

   It builds for Linux, copies the binary and the systemd unit
   ([`deploy/fitmeasure.service`](deploy/fitmeasure.service)), and starts the
   service. The first HTTPS request fetches the certificates, which takes a
   few seconds.

Then open <https://live.somto.si>. Logs: `journalctl -u fitmeasure -f`.

### Updates

Run `deploy/deploy.sh root@live.somto.si` again.

### Behind an existing nginx

On a machine where nginx already serves other sites on 80 and 443 (the
current staging droplet), Fitmeasure listens on `127.0.0.1:8090` and nginx
proxies `live.somto.si` to it. Media and TURN don't go through nginx; they
use their own ports. TURN over TLS on 443 isn't available this way, because
nginx has 443.

1. **DNS:** an A record for `live.somto.si` pointing at the droplet's own
   public IP. On a droplet with a reserved IP, use the droplet's own address
   (`ip -4 addr show eth0`), not the reserved one: media replies leave from
   the droplet's own address, and clients must send to the same one.
2. **Settings:** `/etc/fitmeasure/fitmeasure.env` from
   [`deploy/fitmeasure-behind-nginx.env.example`](deploy/fitmeasure-behind-nginx.env.example).
3. **Install:** `deploy/deploy.sh root@<droplet>`.
4. **nginx:** copy [`deploy/nginx-site.conf`](deploy/nginx-site.conf) to
   `/etc/nginx/sites-available/live.somto.si`, link it into `sites-enabled`,
   then `nginx -t && systemctl reload nginx`.
5. **HTTPS:** `certbot --nginx -d live.somto.si`.

Open UDP 7882, TCP 7881 and UDP/TCP 3478 if a firewall is in the way.

## Test

```sh
go vet ./...
go test -race ./...
```

`internal/sfu/echo_test.go` connects a Pion peer to the echo the same way a
browser does, sends VP8 video, and checks that the same payload comes back.
`room_test.go` does the same for rooms, including one where clients may only
connect through TURN. `internal/relay` checks the TURN server refuses to relay
anywhere but the SFU, and `internal/tlsmux` that port 443 is shared correctly.

## Layout

```
cmd/fitmeasure-server/   main: flags, HTTP routes
internal/rtc/            the shared Pion API: codecs (VP8, Opus), interceptors, ICE settings
internal/signal/         signalling messages (offer, answer, candidate) over a WebSocket
internal/sfu/            media forwarding: echo.go is stage 1, room.go stage 2
internal/relay/          the TURN server and its short-lived credentials
internal/tlsmux/         shares port 443 between HTTPS and TURN over TLS
deploy/                  systemd unit, production settings and the deploy script
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
- **ICE candidate types** (stage 3). Each side lists every address it might
  be reached at: `host` (its own network addresses), `srflx` ("server
  reflexive": its public address as a STUN server saw it), and `relay` (an
  address on a TURN server). ICE tries pairs and keeps the best that works,
  preferring host, then srflx, then relay. The room page shows the chosen
  pair for each connection under **Publish path** and **Subscribe path**.
- **TURN** (`internal/relay`). For networks where nothing direct works, the
  client sends media to the TURN server, which relays it to the SFU. Clients
  are offered TURN over UDP, TCP, and TLS on 443, which looks like ordinary
  HTTPS to strict firewalls. Credentials are minted per person and expire
  after 12 hours, and the server only relays to the SFU, so it can't be used
  as a proxy to anywhere else.
- **NACK and PLI** on a lossy network. A lost packet is first asked for again
  (NACK); the server keeps a short buffer of what it sent each subscriber and
  resends from it. If a frame still can't be decoded, the receiver asks for a
  keyframe (PLI), which only the sender can make. The room page counts both
  under **Sending repairs** and **Receiving repairs**. To see them climb,
  add loss on Linux with `sudo tc qdisc add dev eth0 root netem loss 5%`
  (remove it with `sudo tc qdisc del dev eth0 root`).
