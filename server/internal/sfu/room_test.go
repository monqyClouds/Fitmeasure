package sfu

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"

	"github.com/monqyClouds/Fitmeasure/server/internal/relay"
	"github.com/monqyClouds/Fitmeasure/server/internal/rtc"
	"github.com/monqyClouds/Fitmeasure/server/internal/signal"
)

// startRooms serves rooms the way main does and returns the WebSocket URL
// prefix, to which tests append "{room}?name=…".
func startRooms(t *testing.T, max int) string {
	t.Helper()
	return serveRooms(t, &Rooms{MaxParticipants: max})
}

func serveRooms(t *testing.T, rooms *Rooms) string {
	t.Helper()
	rooms.API = newTestAPI(t)
	rooms.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	mux := http.NewServeMux()
	mux.Handle("GET /ws/rooms/{room}", rooms)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws/rooms/"
}

// received is one RTP payload a test peer got, and whose stream it came on.
type received struct {
	from    string
	payload []byte
}

// testPeer plays a browser in a room: it publishes a VP8 track whose payload
// is a marker naming it, and answers the server's subscribe offers.
type testPeer struct {
	t      *testing.T
	id     string
	ws     *websocket.Conn
	wsMu   sync.Mutex
	pub    *webrtc.PeerConnection
	sub    *webrtc.PeerConnection
	track  *webrtc.TrackLocalStaticSample
	media  chan received
	events chan signal.Message // everything except signalling

	// Sender reports about received streams whose SSRC matched the stream.
	senderReports chan *rtcp.SenderReport

	closing atomic.Bool // set once the test is tearing down
}

func joinRoom(t *testing.T, url, name string) *testPeer {
	t.Helper()
	return joinRoomWith(t, url, name, webrtc.ICETransportPolicyAll)
}

// joinRoomWith joins with the ICE servers from the welcome and the given
// policy; ICETransportPolicyRelay allows only paths through TURN.
func joinRoomWith(t *testing.T, url, name string, policy webrtc.ICETransportPolicy) *testPeer {
	t.Helper()
	ws := dial(t, url+"?name="+name)
	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	var welcome signal.Message
	if err := ws.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome.Type != signal.TypeWelcome || welcome.ID == "" {
		t.Fatalf("%s: got %+v, want a welcome", name, welcome)
	}
	_ = ws.SetReadDeadline(time.Time{})

	api := newTestAPI(t)
	p := &testPeer{
		t: t, id: welcome.ID, ws: ws,
		media:         make(chan received, 64),
		events:        make(chan signal.Message, 64),
		senderReports: make(chan *rtcp.SenderReport, 16),
	}
	var err error
	pcConfig := webrtc.Configuration{ICEServers: welcome.ICEServers, ICETransportPolicy: policy}
	if p.pub, err = api.NewPeerConnection(pcConfig); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.pub.Close() })
	if p.sub, err = api.NewPeerConnection(pcConfig); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.sub.Close() })

	if p.track, err = webrtc.NewTrackLocalStaticSample(rtc.VP8, "video", name); err != nil {
		t.Fatal(err)
	}
	if _, err := p.pub.AddTrack(p.track); err != nil {
		t.Fatal(err)
	}

	p.sub.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		go func() {
			for {
				packets, _, err := receiver.ReadRTCP()
				if err != nil {
					return
				}
				for _, pkt := range packets {
					if sr, ok := pkt.(*rtcp.SenderReport); ok && sr.SSRC == uint32(remote.SSRC()) {
						select {
						case p.senderReports <- sr:
						default:
						}
					}
				}
			}
		}()
		for {
			pkt, _, err := remote.ReadRTP()
			if err != nil {
				return
			}
			select {
			case p.media <- received{from: remote.StreamID(), payload: pkt.Payload}:
			default:
			}
		}
	})
	for pcName, pc := range map[string]*webrtc.PeerConnection{signal.PCPublish: p.pub, signal.PCSubscribe: p.sub} {
		pc.OnICECandidate(func(c *webrtc.ICECandidate) {
			if c != nil {
				init := c.ToJSON()
				p.send(signal.Message{Type: signal.TypeCandidate, PC: pcName, Candidate: &init})
			}
		})
	}

	// Cleanups run last-registered first, so this stops error reports before
	// the peer connections above are closed under the read loop.
	t.Cleanup(func() {
		p.closing.Store(true)
		ws.Close()
	})
	go p.readLoop()

	offer, err := p.pub.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.pub.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	p.send(signal.Message{Type: signal.TypeOffer, PC: signal.PCPublish, SDP: offer.SDP})
	return p
}

func (p *testPeer) send(m signal.Message) {
	p.wsMu.Lock()
	defer p.wsMu.Unlock()
	if err := p.ws.WriteJSON(m); err != nil {
		p.fail(err)
	}
}

// fail reports err unless the test is already tearing the peer down, when
// closed connections are expected.
func (p *testPeer) fail(err error) {
	if !p.closing.Load() {
		p.t.Error(err)
	}
}

func (p *testPeer) readLoop() {
	pcs := map[string]*webrtc.PeerConnection{signal.PCPublish: p.pub, signal.PCSubscribe: p.sub}
	for {
		var m signal.Message
		if err := p.ws.ReadJSON(&m); err != nil {
			return
		}
		switch m.Type {
		case signal.TypeAnswer:
			if err := p.pub.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: m.SDP}); err != nil {
				p.fail(err)
			}
		case signal.TypeOffer:
			if m.PC != signal.PCSubscribe {
				p.fail(fmt.Errorf("offer on %q, want subscribe", m.PC))
				continue
			}
			if err := p.sub.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: m.SDP}); err != nil {
				p.fail(err)
				continue
			}
			answer, err := p.sub.CreateAnswer(nil)
			if err != nil {
				p.fail(err)
				continue
			}
			if err := p.sub.SetLocalDescription(answer); err != nil {
				p.fail(err)
				continue
			}
			p.send(signal.Message{Type: signal.TypeAnswer, PC: signal.PCSubscribe, SDP: answer.SDP})
			p.events <- m
		case signal.TypeCandidate:
			if err := pcs[m.PC].AddICECandidate(*m.Candidate); err != nil {
				p.fail(err)
			}
		case signal.TypeError:
			p.fail(fmt.Errorf("server error: %s", m.Error))
		default:
			p.events <- m
		}
	}
}

func marker(id string) []byte { return []byte("fitmeasure-room-marker-" + id) }

// publishUntil keeps writing p's marker until stop closes.
func (p *testPeer) publishUntil(stop <-chan struct{}) {
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
			_ = p.track.WriteSample(media.Sample{Data: marker(p.id), Duration: 20 * time.Millisecond})
		}
	}
}

// Three people join one at a time; each must receive the other two, each on
// a stream named after its sender, and never their own.
func TestRoomEveryoneReceivesEveryoneElse(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)

	var peers []*testPeer
	for _, name := range []string{"ada", "bo", "cy"} {
		p := joinRoom(t, url, name)
		go p.publishUntil(stop)
		peers = append(peers, p)
	}

	for _, p := range peers {
		want := map[string]bool{}
		for _, q := range peers {
			if q != p {
				want[q.id] = true
			}
		}
		deadline := time.After(15 * time.Second)
		for len(want) > 0 {
			select {
			case r := <-p.media:
				if r.from == p.id {
					t.Fatalf("%s received its own video", p.id)
				}
				if !bytes.Contains(r.payload, marker(r.from)) {
					t.Fatalf("%s: payload on stream %s is %q, want that stream's marker", p.id, r.from, r.payload)
				}
				delete(want, r.from)
			case <-deadline:
				t.Fatalf("%s still waiting for video from %v after 15s", p.id, want)
			}
		}
	}
}

// When someone leaves, the others are told, and their subscribe connection
// is renegotiated without that person's track.
func TestRoomLeaveRenegotiates(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)

	a := joinRoom(t, url, "ada")
	go a.publishUntil(stop)
	b := joinRoom(t, url, "bo")
	go b.publishUntil(stop)

	// Wait until a receives b's video, so b's track is fully set up.
	deadline := time.After(15 * time.Second)
	for got := false; !got; {
		select {
		case r := <-a.media:
			got = r.from == b.id
		case <-deadline:
			t.Fatal("a never received b's video")
		}
	}

	b.ws.Close()

	var left, reoffered bool
	deadline = time.After(10 * time.Second)
	for !left || !reoffered {
		select {
		case m := <-a.events:
			switch {
			case m.Type == signal.TypeParticipantLeft && m.Participant != nil && m.Participant.ID == b.id:
				left = true
			case m.Type == signal.TypeOffer && !strings.Contains(m.SDP, "msid:"+b.id+" "):
				reoffered = true
			}
		case <-deadline:
			t.Fatalf("after b left: participant_left %v, offer without b's track %v", left, reoffered)
		}
	}
}

// With relay-only clients every packet goes through the TURN server, in both
// directions, and the room still works.
func TestRoomOverTURN(t *testing.T) {
	turn, err := relay.Start(relay.Config{
		PublicIP:     net.IPv4(127, 0, 0, 1),
		Host:         "127.0.0.1",
		RelayMinPort: 40200,
		RelayMaxPort: 40300,
		Log:          slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { turn.Close() })
	url := serveRooms(t, &Rooms{ClientICEServers: turn.ICEServers}) + "gym"

	stop := make(chan struct{})
	defer close(stop)
	a := joinRoomWith(t, url, "ada", webrtc.ICETransportPolicyRelay)
	go a.publishUntil(stop)
	b := joinRoomWith(t, url, "bo", webrtc.ICETransportPolicyRelay)
	go b.publishUntil(stop)

	for _, pair := range [][2]*testPeer{{a, b}, {b, a}} {
		to, from := pair[0], pair[1]
		deadline := time.After(15 * time.Second)
		for got := false; !got; {
			select {
			case r := <-to.media:
				got = r.from == from.id && bytes.Contains(r.payload, marker(from.id))
			case <-deadline:
				t.Fatalf("%s never received %s's video through TURN", to.id, from.id)
			}
		}
	}
	// Each client relays its publish and its subscribe connection.
	if n := turn.Allocations(); n < 4 {
		t.Fatalf("got %d TURN allocations, want at least 4", n)
	}
}

// The publisher's sender reports reach subscribers with the same clock
// mapping, under the SSRC of the stream the subscriber receives, so audio
// and video can be lined up by capture time.
func TestRoomForwardsSenderReports(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)

	a := joinRoom(t, url, "ada")
	go a.publishUntil(stop)
	b := joinRoom(t, url, "bo")

	deadline := time.After(15 * time.Second)
	for got := false; !got; {
		select {
		case r := <-b.media:
			got = r.from == a.id
		case <-deadline:
			t.Fatal("b never received a's video")
		}
	}

	senders := a.pub.GetSenders()
	ssrc := uint32(senders[0].GetParameters().Encodings[0].SSRC)
	want := &rtcp.SenderReport{SSRC: ssrc, NTPTime: 0xE8F0_1234_8000_0000, RTPTime: 123456, PacketCount: 7, OctetCount: 900}

	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	deadline = time.After(10 * time.Second)
	for {
		select {
		case <-tick.C:
			if err := a.pub.WriteRTCP([]rtcp.Packet{want}); err != nil {
				t.Fatal(err)
			}
		case sr := <-b.senderReports:
			if sr.NTPTime != want.NTPTime || sr.RTPTime != want.RTPTime || sr.PacketCount != want.PacketCount {
				t.Fatalf("got sender report %+v, want the publisher's clock mapping %+v", sr, want)
			}
			return
		case <-deadline:
			t.Fatal("no sender report reached the subscriber")
		}
	}
}

func TestRoomFull(t *testing.T) {
	url := startRooms(t, 2) + "gym"
	joinRoom(t, url, "ada")
	joinRoom(t, url, "bo")

	ws := dial(t, url+"?name=cy")
	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	var m signal.Message
	if err := ws.ReadJSON(&m); err != nil {
		t.Fatal(err)
	}
	if m.Type != signal.TypeError || !strings.Contains(m.Error, "full") {
		t.Fatalf("got %+v, want a room-full error", m)
	}
}

func TestRoomJoinedEvent(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada")
	b := joinRoom(t, url, "bo")

	select {
	case m := <-a.events:
		if m.Type != signal.TypeParticipantJoined || m.Participant == nil || m.Participant.ID != b.id || m.Participant.Name != "bo" {
			t.Fatalf("got %+v, want bo's participant_joined", m)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no participant_joined")
	}
}

func TestRoomRejectsBadName(t *testing.T) {
	url := startRooms(t, 0) + "Not%20OK"
	_, resp, err := websocket.DefaultDialer.Dial(url, nil)
	if err == nil {
		t.Fatal("dial succeeded")
	}
	if resp == nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %v, want 400", resp)
	}
}
