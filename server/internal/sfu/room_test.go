package sfu

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/sdp/v3"
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
	// SFU_TEST_LOG=1 shows the server's log while debugging a test.
	var logs io.Writer = io.Discard
	if os.Getenv("SFU_TEST_LOG") != "" {
		logs = os.Stderr
	}
	rooms.Log = slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
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
	seq     uint16
	ts      uint32
	at      time.Time
}

// testPeer plays a browser in a room: it publishes a VP8 track whose payload
// is a marker naming it, and answers the server's subscribe offers.
type testPeer struct {
	t      *testing.T
	id     string
	resume string // token from the welcome
	ws     *websocket.Conn
	wsMu   sync.Mutex
	pub    *webrtc.PeerConnection
	sub    *webrtc.PeerConnection
	track  *webrtc.TrackLocalStaticSample
	media  chan received
	events chan signal.Message // everything except signalling

	// Sender reports about received streams whose SSRC matched the stream.
	senderReports chan *rtcp.SenderReport

	// Every video packet received, in order, for checking continuity.
	videoMu  sync.Mutex
	videoLog []received

	// Simulcast layers by RID, when published with simulcast.
	layers    map[string]*webrtc.TrackLocalStaticRTP
	simSender *webrtc.RTPSender

	closing atomic.Bool // set once the test is tearing down
	dropped atomic.Bool // offline between drop and reconnect: sends fail
	// expectErrors passes server errors to events instead of failing the
	// test, for tests of what's refused.
	expectErrors atomic.Bool
}

func joinRoom(t *testing.T, url, name string) *testPeer {
	t.Helper()
	return joinRoomWith(t, url, name, webrtc.ICETransportPolicyAll)
}

// joinRoomWith joins with the ICE servers from the welcome and the given
// policy; ICETransportPolicyRelay allows only paths through TURN.
func joinRoomWith(t *testing.T, url, name string, policy webrtc.ICETransportPolicy) *testPeer {
	t.Helper()
	return joinRoomOpts(t, url, name, policy, false)
}

// joinRoomSimulcast publishes the camera as three layers; see publishLayersUntil.
func joinRoomSimulcast(t *testing.T, url, name string) *testPeer {
	t.Helper()
	return joinRoomOpts(t, url, name, webrtc.ICETransportPolicyAll, true)
}

func joinRoomOpts(t *testing.T, url, name string, policy webrtc.ICETransportPolicy, simulcast bool) *testPeer {
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
		t: t, id: welcome.ID, resume: welcome.Resume, ws: ws,
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

	if simulcast {
		p.layers = map[string]*webrtc.TrackLocalStaticRTP{}
		var sender *webrtc.RTPSender
		for _, rid := range []string{"q", "h", "f"} {
			layer, err := webrtc.NewTrackLocalStaticRTP(rtc.VP8, "video", name, webrtc.WithRTPStreamID(rid))
			if err != nil {
				t.Fatal(err)
			}
			p.layers[rid] = layer
			if sender == nil {
				if sender, err = p.pub.AddTrack(layer); err != nil {
					t.Fatal(err)
				}
			} else if err := sender.AddEncoding(layer); err != nil {
				t.Fatal(err)
			}
		}
		p.simSender = sender
	} else {
		if p.track, err = webrtc.NewTrackLocalStaticSample(rtc.VP8, "video", name); err != nil {
			t.Fatal(err)
		}
		if _, err := p.pub.AddTrack(p.track); err != nil {
			t.Fatal(err)
		}
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
			r := received{from: remote.StreamID(), payload: pkt.Payload, seq: pkt.SequenceNumber, ts: pkt.Timestamp, at: time.Now()}
			if remote.Kind() == webrtc.RTPCodecTypeVideo {
				p.videoMu.Lock()
				p.videoLog = append(p.videoLog, r)
				p.videoMu.Unlock()
			}
			select {
			case p.media <- r:
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
	if err := p.ws.WriteJSON(m); err != nil && !p.dropped.Load() {
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

// leave closes the WebSocket properly, as the Leave button does.
func (p *testPeer) leave() {
	p.closing.Store(true) // it's gone: errors from here on are expected
	p.wsMu.Lock()
	_ = p.ws.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
	ws := p.ws
	p.wsMu.Unlock()
	// Like a browser, wait for the server's close (the read loop ends)
	// before cutting the connection.
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	time.Sleep(100 * time.Millisecond)
	ws.Close()
}

// drop cuts the WebSocket without a close message, like a phone losing its
// network.
func (p *testPeer) drop() {
	p.wsMu.Lock()
	defer p.wsMu.Unlock()
	p.dropped.Store(true)
	p.ws.Close()
}

// reconnect opens a new WebSocket with the resume token, as a client does
// after its connection dropped, and reads from it.
func (p *testPeer) reconnect(url string) {
	ws, _, err := websocket.DefaultDialer.Dial(url+"?resume="+p.resume, nil)
	if err != nil {
		p.t.Fatal(err)
	}
	p.t.Cleanup(func() { ws.Close() })
	p.wsMu.Lock()
	p.ws = ws
	p.dropped.Store(false)
	p.wsMu.Unlock()
	go p.readLoop()
}

func (p *testPeer) readLoop() {
	pcs := map[string]*webrtc.PeerConnection{signal.PCPublish: p.pub, signal.PCSubscribe: p.sub}
	p.wsMu.Lock()
	ws := p.ws
	p.wsMu.Unlock()
	for {
		var m signal.Message
		if err := ws.ReadJSON(&m); err != nil {
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
			if p.expectErrors.Load() {
				p.events <- m
				continue
			}
			p.fail(fmt.Errorf("server error: %s", m.Error))
		default:
			p.events <- m
		}
	}
}

func marker(id string) []byte { return []byte("fitmeasure-room-marker-" + id) }

// publishUntil keeps writing p's marker until stop closes.
// layerSizes are the picture sizes the test publisher's layers declare.
var layerSizes = map[string][2]int{"q": {240, 136}, "h": {480, 270}, "f": {960, 540}}

// layerFiller pads each layer's frames so the layers' bitrates differ
// like real ones: at 50 frames a second, about 40, 160 and 440 kbit/s.
var layerFiller = map[string]int{"q": 100, "h": 400, "f": 1100}

// publishLayersUntil sends each simulcast layer as VP8 frames whose payload
// names the layer ("layer-q" …), with a keyframe declaring the layer's size
// every tenth frame. It builds the RTP packets itself, because a receiver
// tells simulcast layers apart by their MID and RID header extensions,
// which browsers add but Pion's sending side leaves to the application.
func (p *testPeer) publishLayersUntil(stop <-chan struct{}) {
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()

	// The extension IDs and MID are only known once negotiated.
	var midID, ridID uint8
	var mid string
	for midID == 0 || ridID == 0 || mid == "" {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		for _, ext := range p.simSender.GetParameters().HeaderExtensions {
			switch ext.URI {
			case sdp.SDESMidURI:
				midID = uint8(ext.ID)
			case sdp.SDESRTPStreamIDURI:
				ridID = uint8(ext.ID)
			}
		}
		for _, tr := range p.pub.GetTransceivers() {
			if tr.Sender() == p.simSender {
				mid = tr.Mid()
			}
		}
	}

	// Each layer numbers its packets differently; "h" wraps around soon.
	seq := map[string]uint16{"q": 100, "h": 65500, "f": 30000}
	ts := map[string]uint32{"q": 1_000, "h": 4_000_000_000, "f": 77}
	for n := 0; ; n++ {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		for rid, layer := range p.layers {
			// An interframe is one packet; a keyframe is three, like a
			// real one split to fit the MTU, the last with the marker bit.
			filler := make([]byte, layerFiller[rid])
			payloads := [][]byte{append(append([]byte{0x10, 0x01, 0x00, 0x00}, "layer-"+rid...), filler...)}
			if n%10 == 0 {
				size := layerSizes[rid]
				payloads = [][]byte{
					append([]byte{0x10, 0x00, 0x00, 0x00, 0x9d, 0x01, 0x2a,
						byte(size[0]), byte(size[0] >> 8), byte(size[1]), byte(size[1] >> 8)}, "layer-"+rid...),
					{0x00, 0xaa, 0xaa},
					{0x00, 0xbb, 0xbb},
				}
			}
			for i, payload := range payloads {
				pkt := &rtp.Packet{
					Header: rtp.Header{
						Version: 2, PayloadType: 96, Marker: i == len(payloads)-1,
						SequenceNumber: seq[rid], Timestamp: ts[rid],
					},
					Payload: payload,
				}
				_ = pkt.Header.SetExtension(midID, []byte(mid))
				_ = pkt.Header.SetExtension(ridID, []byte(rid))
				_ = layer.WriteRTP(pkt)
				seq[rid]++
			}
			ts[rid] += 1800
		}
	}
}

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

	b.leave()

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

// layerSince returns which layers' frames b received from a since the given
// index of its video log, and the log's new length.
func (p *testPeer) layersSince(from string, i int) (map[string]int, int) {
	p.videoMu.Lock()
	defer p.videoMu.Unlock()
	seen := map[string]int{}
	for _, r := range p.videoLog[i:] {
		if r.from != from {
			continue
		}
		for rid := range layerSizes {
			if bytes.Contains(r.payload, []byte("layer-"+rid)) {
				seen[rid]++
			}
		}
	}
	return seen, len(p.videoLog)
}

// waitForLayer waits until b gets only the given layer of a's camera. The
// wait allows for the bandwidth cap's hold after a drop (10 s).
func waitForLayer(t *testing.T, b *testPeer, from, rid string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	_, mark := b.layersSince(from, 0)
	for time.Now().Before(deadline) {
		time.Sleep(300 * time.Millisecond)
		seen, next := b.layersSince(from, mark)
		mark = next
		if len(seen) == 1 && seen[rid] > 0 {
			return
		}
	}
	seen, _ := b.layersSince(from, 0)
	t.Fatalf("never settled on layer %q; frames per layer overall: %v", rid, seen)
}

// A subscriber gets the layer that suits its tile, moves between layers as
// the tile changes size, and gets nothing while it's off screen. Across the
// switches, the stream it receives stays continuous: sequence numbers rise
// by exactly one and timestamps never go back.
func TestRoomSimulcastLayers(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)

	a := joinRoomSimulcast(t, url, "ada")
	go a.publishLayersUntil(stop)
	b := joinRoom(t, url, "bo")

	// Without a layout, the middle layer.
	waitForLayer(t, b, a.id, "h")

	layout := func(tiles ...signal.Tile) {
		b.send(signal.Message{Type: signal.TypeLayout, Tiles: tiles})
	}
	layout(signal.Tile{ID: a.id, Width: 1080, Height: 608})
	waitForLayer(t, b, a.id, "f")
	layout(signal.Tile{ID: a.id, Width: 300, Height: 170})
	waitForLayer(t, b, a.id, "q")
	layout(signal.Tile{ID: a.id, Width: 600, Height: 340})
	waitForLayer(t, b, a.id, "h")

	// Off screen: a is left out of the layout, and its video stops.
	layout()
	time.Sleep(500 * time.Millisecond)
	_, mark := b.layersSince(a.id, 0)
	time.Sleep(time.Second)
	if seen, _ := b.layersSince(a.id, mark); len(seen) > 0 {
		t.Fatalf("still receiving video while off screen: %v", seen)
	}

	// Sorted by sequence number (a lost packet's retransmission arrives
	// late), the stream must have no gaps or repeats, and its timestamps
	// must never go back.
	b.videoMu.Lock()
	defer b.videoMu.Unlock()
	var stream []received
	var ext int64 // sequence number extended past 16 bits
	for _, r := range b.videoLog {
		if r.from != a.id {
			continue
		}
		if len(stream) == 0 {
			ext = int64(r.seq)
		} else {
			ext += int64(int16(r.seq - stream[len(stream)-1].seq))
		}
		r.at = time.Unix(0, ext) // reuse the field to sort by
		stream = append(stream, r)
	}
	if len(stream) == 0 {
		t.Fatal("no video received")
	}
	sort.Slice(stream, func(i, j int) bool { return stream[i].at.Before(stream[j].at) })
	for i := 1; i < len(stream); i++ {
		prev, r := stream[i-1], stream[i]
		if r.seq != prev.seq+1 {
			t.Fatalf("sequence numbers jump from %d to %d", prev.seq, r.seq)
		}
		if int32(r.ts-prev.ts) < 0 {
			t.Fatalf("timestamp goes back from %d to %d at sequence number %d", prev.ts, r.ts, r.seq)
		}
	}
}

// Each viewer's layers fit their own bandwidth: one on a slow connection
// gets the small layer, while another watching the same camera, with room
// to spare, still gets the full one.
func TestRoomBandwidthCapsLayers(t *testing.T) {
	// Less than even the smallest layer, so the outcome doesn't depend on
	// the layers' measured bitrates (which vary with how fast the test runs).
	var boBudget atomic.Int64
	boBudget.Store(10_000)
	url := serveRooms(t, &Rooms{testBudget: func(name string) func() int {
		if name == "bo" {
			return func() int { return int(boBudget.Load()) }
		}
		return func() int { return 10_000_000 }
	}}) + "gym"
	stop := make(chan struct{})
	defer close(stop)

	a := joinRoomSimulcast(t, url, "ada")
	go a.publishLayersUntil(stop)
	b := joinRoom(t, url, "bo")
	c := joinRoom(t, url, "cy")
	big := signal.Tile{ID: a.id, Width: 1080, Height: 608}
	for _, p := range []*testPeer{b, c} {
		p.send(signal.Message{Type: signal.TypeLayout, Tiles: []signal.Tile{big}})
	}

	waitForLayer(t, c, a.id, "f")
	waitForLayer(t, b, a.id, "q")

	// More bandwidth for b lifts its cap, after the hold, to the full
	// layer its tile wants.
	boBudget.Store(10_000_000)
	waitForLayer(t, b, a.id, "f")
}

// With a real estimator (GCC fed by the viewer's TWCC feedback), the
// viewer is told the server's estimate of its bandwidth, and the estimate
// moves off its starting value once feedback arrives.
func TestRoomSendsEstimate(t *testing.T) {
	factory, err := rtc.NewFactory(rtc.Config{IncludeLoopback: true})
	if err != nil {
		t.Fatal(err)
	}
	url := serveRooms(t, &Rooms{SubscriberAPI: factory.EstimatingAPI}) + "gym"
	stop := make(chan struct{})
	defer close(stop)

	a := joinRoomSimulcast(t, url, "ada")
	go a.publishLayersUntil(stop)
	b := joinRoom(t, url, "bo")

	deadline := time.After(20 * time.Second)
	var estimates []int
	for {
		select {
		case m := <-b.events:
			if m.Type != signal.TypeEstimate {
				continue
			}
			if m.Bitrate <= 0 {
				t.Fatalf("estimate of %d bit/s", m.Bitrate)
			}
			estimates = append(estimates, m.Bitrate)
			if m.Bitrate != rtc.InitialEstimate {
				return
			}
		case <-deadline:
			t.Fatalf("the estimate never moved from its starting value: %v", estimates)
		}
	}
}

// waitEvent waits for an event of the given type that ok accepts.
func waitEvent(t *testing.T, p *testPeer, typ string, ok func(signal.Message) bool) signal.Message {
	t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case m := <-p.events:
			if m.Type == typ && ok(m) {
				return m
			}
		case <-deadline:
			t.Fatalf("no %s event matching", typ)
			return signal.Message{}
		}
	}
}

// The server tells everyone who is speaking, from the loudness each audio
// packet carries (RFC 6464), and stops counting someone once they're quiet.
func TestRoomSpeakers(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada")
	b := joinRoom(t, url, "bo")

	// a also publishes a microphone: Opus packets with an audio level.
	mic, err := webrtc.NewTrackLocalStaticRTP(rtc.Opus, "audio", "ada")
	if err != nil {
		t.Fatal(err)
	}
	sender, err := a.pub.AddTrack(mic)
	if err != nil {
		t.Fatal(err)
	}
	// Renegotiate only once the first offer has been answered.
	for deadline := time.Now().Add(5 * time.Second); a.pub.SignalingState() != webrtc.SignalingStateStable; {
		if time.Now().After(deadline) {
			t.Fatal("first publish offer never answered")
		}
		time.Sleep(20 * time.Millisecond)
	}
	offer, err := a.pub.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.pub.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	a.send(signal.Message{Type: signal.TypeOffer, PC: signal.PCPublish, SDP: offer.SDP})

	var level atomic.Int32
	level.Store(20) // loud
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		var extID uint8
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		for seq := uint16(0); ; seq++ {
			select {
			case <-stop:
				return
			case <-tick.C:
			}
			for _, ext := range sender.GetParameters().HeaderExtensions {
				if ext.URI == sdp.AudioLevelURI {
					extID = uint8(ext.ID)
				}
			}
			if extID == 0 {
				continue
			}
			pkt := &rtp.Packet{Header: rtp.Header{Version: 2, PayloadType: 111, SequenceNumber: seq, Timestamp: uint32(seq) * 960}, Payload: []byte{0xfc, 0xff, 0xfe}}
			payload, _ := rtp.AudioLevelExtension{Level: uint8(level.Load()), Voice: true}.Marshal()
			_ = pkt.Header.SetExtension(extID, payload)
			_ = mic.WriteRTP(pkt)
		}
	}()

	contains := func(list []string, id string) bool {
		for _, x := range list {
			if x == id {
				return true
			}
		}
		return false
	}
	waitEvent(t, b, signal.TypeSpeakers, func(m signal.Message) bool { return contains(m.Speakers, a.id) })
	level.Store(127) // silence
	waitEvent(t, b, signal.TypeSpeakers, func(m signal.Message) bool { return !contains(m.Speakers, a.id) })
}

// Turning a camera off tells everyone and stops forwarding it; turning it
// back on resumes it.
func TestRoomCameraOff(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)
	a := joinRoom(t, url, "ada")
	go a.publishUntil(stop)
	b := joinRoom(t, url, "bo")

	received := func() int {
		b.videoMu.Lock()
		defer b.videoMu.Unlock()
		n := 0
		for _, r := range b.videoLog {
			if r.from == a.id {
				n++
			}
		}
		return n
	}
	deadline := time.Now().Add(10 * time.Second)
	for received() == 0 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if received() == 0 {
		t.Fatal("b never received a's video")
	}

	off, on := false, true
	a.send(signal.Message{Type: signal.TypeState, Camera: &off})
	m := waitEvent(t, b, signal.TypeParticipantChanged, func(m signal.Message) bool { return m.Participant.ID == a.id })
	if m.Participant.Camera || !m.Participant.Mic {
		t.Fatalf("got %+v, want camera off and mic still on", m.Participant)
	}
	time.Sleep(500 * time.Millisecond)
	before := received()
	time.Sleep(time.Second)
	if after := received(); after != before {
		t.Fatalf("still forwarding a's video with the camera off (%d more packets)", after-before)
	}

	a.send(signal.Message{Type: signal.TypeState, Camera: &on})
	deadline = time.Now().Add(10 * time.Second)
	for received() == before && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if received() == before {
		t.Fatal("video didn't resume with the camera back on")
	}
}

// A dropped WebSocket (no close message) keeps the person in the room for
// the grace period. Reconnecting with the resume token brings them back:
// nobody sees them leave, they get the room as it is now and an ICE restart
// offer, and media carries on.
func TestRoomResume(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)
	a := joinRoom(t, url, "ada")
	go a.publishUntil(stop)
	b := joinRoom(t, url, "bo")

	count := func() int {
		b.videoMu.Lock()
		defer b.videoMu.Unlock()
		return len(b.videoLog)
	}
	deadline := time.Now().Add(10 * time.Second)
	for count() == 0 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}

	b.drop()
	time.Sleep(time.Second)
	b.reconnect(url)

	resumed := waitEvent(t, b, signal.TypeResumed, func(signal.Message) bool { return true })
	if resumed.ID != b.id || len(resumed.Participants) != 1 || resumed.Participants[0].ID != a.id {
		t.Fatalf("got %+v, want b's ID and a in the room", resumed)
	}
	offer := waitEvent(t, b, signal.TypeOffer, func(signal.Message) bool { return true })
	if !strings.Contains(offer.SDP, "a=ice-ufrag") {
		t.Fatalf("no ICE credentials in the offer after resuming")
	}

	before := count()
	deadline = time.Now().Add(10 * time.Second)
	for count() == before && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if count() == before {
		t.Fatal("no video after resuming")
	}

	// a never saw b leave.
	for {
		select {
		case m := <-a.events:
			if m.Type == signal.TypeParticipantLeft {
				t.Fatalf("a was told b left: %+v", m)
			}
			continue
		default:
		}
		break
	}
}

// A close with 1001 ("going away") is a dropped connection, not a leave:
// Dart's WebSocket sends it when its keep-alive pings go unanswered.
func TestRoomGoingAwayKeepsPlace(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada")
	b := joinRoom(t, url, "bo")

	b.wsMu.Lock()
	b.dropped.Store(true)
	_ = b.ws.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseGoingAway, ""))
	b.ws.Close()
	b.wsMu.Unlock()
	time.Sleep(time.Second)
	b.reconnect(url)
	waitEvent(t, b, signal.TypeResumed, func(signal.Message) bool { return true })
	for {
		select {
		case m := <-a.events:
			if m.Type == signal.TypeParticipantLeft {
				t.Fatalf("a was told b left: %+v", m)
			}
			continue
		default:
		}
		break
	}
}

// Without a resume, the person leaves once the grace period is over.
func TestRoomResumeGraceExpires(t *testing.T) {
	url := serveRooms(t, &Rooms{ResumeGrace: time.Second}) + "gym"
	a := joinRoom(t, url, "ada")
	b := joinRoom(t, url, "bo")
	b.drop()
	waitEvent(t, a, signal.TypeParticipantLeft, func(m signal.Message) bool { return m.Participant.ID == b.id })

	// The token no longer works.
	ws := dial(t, url+"?resume="+b.resume)
	var m signal.Message
	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	if err := ws.ReadJSON(&m); err != nil || m.Type != signal.TypeError {
		t.Fatalf("got %+v %v, want an error", m, err)
	}
}

// expectError sends m from p and waits for the server to refuse it.
func expectError(t *testing.T, p *testPeer, m signal.Message, want string) {
	t.Helper()
	p.expectErrors.Store(true)
	p.send(m)
	got := waitEvent(t, p, signal.TypeError, func(signal.Message) bool { return true })
	if !strings.Contains(got.Error, want) {
		t.Fatalf("%s: got error %q, want one about %q", m.Type, got.Error, want)
	}
}

func role(t *testing.T, p *testPeer, of *testPeer, want string) {
	t.Helper()
	waitEvent(t, p, signal.TypeParticipantChanged, func(m signal.Message) bool {
		return m.Participant.ID == of.id && m.Participant.Role == want
	})
}

// The host and moderators can mute and remove; participants can't; nobody
// can remove the host; only the host changes roles.
func TestModerationRoles(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada") // host: first in
	b := joinRoom(t, url, "bo")
	c := joinRoom(t, url, "cy")

	expectError(t, b, signal.Message{Type: signal.TypeMute, ID: c.id, Track: "mic"}, "only the host and moderators")

	a.send(signal.Message{Type: signal.TypeMute, ID: c.id, Track: "mic"})
	muted := waitEvent(t, c, signal.TypeMutedBy, func(signal.Message) bool { return true })
	if muted.ID != a.id || muted.Track != "mic" {
		t.Fatalf("got %+v, want muted by a", muted)
	}
	waitEvent(t, b, signal.TypeParticipantChanged, func(m signal.Message) bool {
		return m.Participant.ID == c.id && !m.Participant.Mic
	})

	a.send(signal.Message{Type: signal.TypeRequestUnmute, ID: c.id, Track: "mic"})
	waitEvent(t, c, signal.TypeUnmuteRequested, func(m signal.Message) bool { return m.ID == a.id })

	a.send(signal.Message{Type: signal.TypeSetRole, ID: b.id, Role: signal.RoleModerator})
	role(t, b, b, signal.RoleModerator)
	b.send(signal.Message{Type: signal.TypeMute, ID: c.id, Track: "camera"})
	waitEvent(t, c, signal.TypeMutedBy, func(m signal.Message) bool { return m.Track == "camera" })

	expectError(t, b, signal.Message{Type: signal.TypeSetRole, ID: c.id, Role: signal.RoleModerator}, "only the host")
	expectError(t, b, signal.Message{Type: signal.TypeRemove, ID: a.id}, "host can't be removed")

	c.closing.Store(true) // its connection is about to be closed under it
	b.send(signal.Message{Type: signal.TypeRemove, ID: c.id})
	waitEvent(t, c, signal.TypeRemoved, func(signal.Message) bool { return true })
	// No grace period for a removal: everyone hears at once.
	waitEvent(t, a, signal.TypeParticipantLeft, func(m signal.Message) bool { return m.Participant.ID == c.id })
}

// When the host leaves, the longest-present moderator takes over, otherwise
// the longest-present participant.
func TestModerationHostSuccession(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada")
	b := joinRoom(t, url, "bo")
	c := joinRoom(t, url, "cy")

	a.send(signal.Message{Type: signal.TypeSetRole, ID: c.id, Role: signal.RoleModerator})
	role(t, b, c, signal.RoleModerator)
	a.leave()
	role(t, b, c, signal.RoleHost) // the moderator, though b has been here longer

	c.leave()
	role(t, b, b, signal.RoleHost)
}

// A locked room turns new people away; only the host and moderators lock.
func TestModerationLock(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada")
	b := joinRoom(t, url, "bo")

	on := true
	expectError(t, b, signal.Message{Type: signal.TypeSetSettings, Locked: &on}, "only the host and moderators")
	a.send(signal.Message{Type: signal.TypeSetSettings, Locked: &on})
	settings := waitEvent(t, b, signal.TypeSettings, func(signal.Message) bool { return true })
	if settings.Locked == nil || !*settings.Locked {
		t.Fatalf("got %+v, want locked", settings)
	}

	ws := dial(t, url+"?name=cy")
	var m signal.Message
	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	if err := ws.ReadJSON(&m); err != nil || m.Type != signal.TypeError || !strings.Contains(m.Error, "locked") {
		t.Fatalf("got %+v %v, want a locked error", m, err)
	}
}

// "Trainer only" video reaches the host and nobody else, and follows the
// host role when it's handed over.
func TestModerationTrainerOnly(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)
	a := joinRoom(t, url, "ada") // host
	b := joinRoom(t, url, "bo")
	go b.publishUntil(stop)
	c := joinRoom(t, url, "cy")

	b.send(signal.Message{Type: signal.TypeState, Visibility: signal.VisibilityTrainerOnly})
	waitEvent(t, c, signal.TypeParticipantChanged, func(m signal.Message) bool {
		return m.Participant.ID == b.id && m.Participant.Visibility == signal.VisibilityTrainerOnly
	})

	frames := func(p *testPeer) int {
		p.videoMu.Lock()
		defer p.videoMu.Unlock()
		n := 0
		for _, r := range p.videoLog {
			if r.from == b.id {
				n++
			}
		}
		return n
	}
	flowing := func(p *testPeer) bool {
		before := frames(p)
		time.Sleep(time.Second)
		return frames(p) > before
	}
	waitFlowing := func(p *testPeer, want bool) {
		t.Helper()
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			if flowing(p) == want {
				return
			}
		}
		t.Fatalf("%s receiving b's video: got %v, want %v", p.id, !want, want)
	}
	waitFlowing(a, true)
	waitFlowing(c, false)

	a.send(signal.Message{Type: signal.TypeTransferHost, ID: c.id})
	role(t, a, c, signal.RoleHost)
	waitFlowing(c, true)
	waitFlowing(a, false)
}

// Someone who chooses "trainer only" also sees only the trainer: other
// people's video stops reaching them, including video that was already
// flowing, and comes back when they switch it off.
func TestModerationTrainerOnlySeesOnlyTrainer(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	stop := make(chan struct{})
	defer close(stop)
	a := joinRoom(t, url, "ada") // host
	go a.publishUntil(stop)
	b := joinRoom(t, url, "bo")
	go b.publishUntil(stop)
	c := joinRoom(t, url, "cy")

	from := func(sender *testPeer) func() bool {
		return func() bool {
			count := func() int {
				c.videoMu.Lock()
				defer c.videoMu.Unlock()
				n := 0
				for _, r := range c.videoLog {
					if r.from == sender.id {
						n++
					}
				}
				return n
			}
			before := count()
			time.Sleep(time.Second)
			return count() > before
		}
	}
	wait := func(flowing func() bool, want bool, what string) {
		t.Helper()
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			if flowing() == want {
				return
			}
		}
		t.Fatalf("c receiving %s: got %v, want %v", what, !want, want)
	}
	wait(from(b), true, "b's video before")

	c.send(signal.Message{Type: signal.TypeState, Visibility: signal.VisibilityTrainerOnly})
	wait(from(b), false, "b's video, trainer only")
	wait(from(a), true, "the host's video, trainer only")

	c.send(signal.Message{Type: signal.TypeState, Visibility: signal.VisibilityEveryone})
	wait(from(b), true, "b's video after")
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

// fakeDirectory has one room, "k7f3qz", called "Tuesday HIIT", whose host
// key is "secret".
type fakeDirectory struct{ touched atomic.Int32 }

func (*fakeDirectory) Name(id string) (string, bool) {
	return "Tuesday HIIT", id == "k7f3qz"
}
func (*fakeDirectory) IsHostKey(id, key string) bool { return id == "k7f3qz" && key == "secret" }
func (d *fakeDirectory) Touch(string)                { d.touched.Add(1) }

func welcomeOrError(t *testing.T, url string) signal.Message {
	t.Helper()
	ws := dial(t, url)
	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	var m signal.Message
	if err := ws.ReadJSON(&m); err != nil {
		t.Fatal(err)
	}
	ws.Close()
	return m
}

// With a directory, only created rooms can be joined, and the welcome
// carries the room's name.
func TestRoomDirectory(t *testing.T) {
	dir := &fakeDirectory{}
	prefix := serveRooms(t, &Rooms{Directory: dir})

	if m := welcomeOrError(t, prefix+"nosuch?name=ada"); m.Type != signal.TypeError || m.Error != "no room with that ID" {
		t.Fatalf("got %+v, want no such room", m)
	}
	m := welcomeOrError(t, prefix+"k7f3qz?name=ada")
	if m.Type != signal.TypeWelcome || m.RoomName != "Tuesday HIIT" {
		t.Fatalf("got %+v, want a welcome to Tuesday HIIT", m)
	}
	if dir.touched.Load() == 0 {
		t.Fatal("the room wasn't marked as used")
	}
}

// The room's creator, joining with its host key, hosts it, taking over
// from whoever opened it first; and gets in even when it's locked.
func TestRoomCreatorHosts(t *testing.T) {
	url := serveRooms(t, &Rooms{Directory: &fakeDirectory{}}) + "k7f3qz"
	a := joinRoom(t, url, "ada") // first in: standing in as host
	on := true
	a.send(signal.Message{Type: signal.TypeSetSettings, Locked: &on})
	waitEvent(t, a, signal.TypeSettings, func(m signal.Message) bool { return m.Locked != nil && *m.Locked })

	c := joinRoom(t, url, "coach&key=secret")
	waitEvent(t, a, signal.TypeParticipantJoined, func(m signal.Message) bool {
		return m.Participant.ID == c.id && m.Participant.Role == signal.RoleHost
	})
	role(t, a, a, signal.RoleModerator)

	// A wrong key is just a guest, and the room is locked.
	if m := welcomeOrError(t, url+"?name=bo&key=guess"); m.Type != signal.TypeError || !strings.Contains(m.Error, "locked") {
		t.Fatalf("got %+v, want the room locked", m)
	}
}

func workoutIs(t *testing.T, p *testPeer, ok func(*signal.Workout) bool) *signal.Workout {
	t.Helper()
	return waitEvent(t, p, signal.TypeWorkout, func(m signal.Message) bool { return ok(m.Workout) }).Workout
}

// The host runs a workout for the room: one clock on the server, moving on
// by itself at the end of each timed step, and waiting at an untimed one.
func TestWorkoutRunsForEveryone(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada") // host
	b := joinRoom(t, url, "bo")

	steps := []signal.WorkoutStep{
		{Kind: signal.StepWork, Title: "Plank", Seconds: 1, Set: 1, Sets: 1},
		{Kind: signal.StepRest, Title: "Rest", Seconds: 1},
		{Kind: signal.StepWork, Title: "Push-ups", Detail: "10 reps"},
	}
	expectError(t, b, signal.Message{Type: signal.TypeWorkoutLoad, Workout: &signal.Workout{Steps: steps}}, "only the host and moderators")
	expectError(t, a, signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutStart}, "no workout")
	expectError(t, a, signal.Message{Type: signal.TypeWorkoutLoad, Workout: &signal.Workout{Steps: []signal.WorkoutStep{{Kind: "nap"}}}}, "work, rest or break")

	a.send(signal.Message{Type: signal.TypeWorkoutLoad, Workout: &signal.Workout{Title: "Core", Steps: steps}})
	w := workoutIs(t, b, func(w *signal.Workout) bool { return w != nil && w.Title == "Core" })
	if w.Index != 0 || w.Running || w.RemainingMs != 1000 || len(w.Steps) != 3 {
		t.Fatalf("loaded: %+v", w)
	}

	start := time.Now()
	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutStart})
	workoutIs(t, b, func(w *signal.Workout) bool { return w.Running && w.Index == 0 })
	workoutIs(t, b, func(w *signal.Workout) bool { return w.Index == 1 })
	w = workoutIs(t, b, func(w *signal.Workout) bool { return w.Index == 2 })
	if took := time.Since(start); took < 1900*time.Millisecond || took > 3*time.Second {
		t.Fatalf("two one-second steps took %v", took)
	}
	if !w.Running || w.RemainingMs != 0 {
		t.Fatalf("untimed step: %+v", w)
	}

	// Someone joining now catches up.
	c := joinRoom(t, url, "cy")
	workoutIs(t, c, func(w *signal.Workout) bool { return w != nil && w.Index == 2 })

	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutNext})
	workoutIs(t, b, func(w *signal.Workout) bool { return w.Finished && !w.Running })

	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutStop})
	workoutIs(t, b, func(w *signal.Workout) bool { return w == nil })
}

// A water break interrupts a step, which then carries on with the time it
// had left; pausing holds the clock.
func TestWorkoutBreakAndPause(t *testing.T) {
	url := startRooms(t, 0) + "gym"
	a := joinRoom(t, url, "ada")

	a.send(signal.Message{Type: signal.TypeWorkoutLoad, Workout: &signal.Workout{Steps: []signal.WorkoutStep{
		{Kind: signal.StepWork, Title: "Wall sit", Seconds: 30},
	}}})
	workoutIs(t, a, func(w *signal.Workout) bool { return w != nil })
	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutStart})
	workoutIs(t, a, func(w *signal.Workout) bool { return w.Running })
	time.Sleep(500 * time.Millisecond)

	expectError(t, a, signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutBreak, Seconds: 5}, "10 seconds to 15 minutes")
	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutBreak, Seconds: 60})
	w := workoutIs(t, a, func(w *signal.Workout) bool { return len(w.Steps) == 2 })
	if w.Index != 0 || w.Steps[0].Kind != signal.StepBreak || w.Steps[0].Title != "Water break" || !w.Running {
		t.Fatalf("break: %+v", w)
	}

	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutNext})
	w = workoutIs(t, a, func(w *signal.Workout) bool { return w.Index == 1 })
	if w.RemainingMs > 29600 || w.RemainingMs < 28000 {
		t.Fatalf("the wall sit should carry on with about 29.5 s left, has %d ms", w.RemainingMs)
	}

	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutPause})
	paused := workoutIs(t, a, func(w *signal.Workout) bool { return !w.Running })
	time.Sleep(300 * time.Millisecond)
	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutStart})
	resumed := workoutIs(t, a, func(w *signal.Workout) bool { return w.Running })
	if d := paused.RemainingMs - resumed.RemainingMs; d < 0 || d > 100 {
		t.Fatalf("the clock moved %d ms while paused", d)
	}

	// Back to the break, from the start.
	a.send(signal.Message{Type: signal.TypeWorkoutControl, Action: signal.WorkoutPrev})
	w = workoutIs(t, a, func(w *signal.Workout) bool { return w.Index == 0 })
	if w.RemainingMs < 59000 {
		t.Fatalf("prev: %+v", w)
	}
}
