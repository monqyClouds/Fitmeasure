package sfu

// Stage 2 (this file) is a small room: up to four people, and everyone
// receives everyone else's camera and microphone at a single quality.
//
// It adds three things to the echo:
//
//   - Forwarding to many. Each published track gets one outgoing track on the
//     server, added to every other participant's connection. Pion's
//     TrackLocalStaticRTP writes each packet to every connection it is bound
//     to, rewriting SSRC and payload type for each one.
//   - Two peer connections per participant. On "publish" the client offers
//     its camera and mic and the server answers, as in the echo. On
//     "subscribe" the server offers the tracks of everyone else. Keeping the
//     directions apart means only one side ever offers on each connection, so
//     offers never cross ("glare").
//   - Renegotiation. When someone joins or leaves, the set of tracks each
//     subscriber receives changes, so the server sends a new offer on their
//     subscribe connection. Only one offer is in flight at a time; changes made
//     meanwhile are rolled into a follow-up offer once the answer arrives.

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/webrtc/v4"

	"github.com/monqyClouds/Fitmeasure/server/internal/signal"
)

// DefaultMaxParticipants is the room size for stage 2. Every participant
// receives every other one at full quality, so cost grows with the square of
// the room size; simulcast (stage 4) and bandwidth estimation (stage 5) are
// what make larger rooms work.
const DefaultMaxParticipants = 4

// keyframeInterval limits how often we ask a publisher for a keyframe. Every
// subscriber's decoder may ask at once (say, when one joins), and a keyframe
// is several times the size of a normal frame.
const keyframeInterval = 500 * time.Millisecond

var roomNamePattern = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)

var errRoomFull = errors.New("room is full")

// Rooms serves rooms over WebSockets at a path with a {room} wildcard, e.g.
// /ws/rooms/{room}?name=Alex. Rooms are created on first join and removed
// when the last person leaves.
type Rooms struct {
	API             *webrtc.API
	ICEServers      []webrtc.ICEServer
	Log             *slog.Logger
	Upgrader        websocket.Upgrader
	MaxParticipants int // 0 means DefaultMaxParticipants

	// ClientICEServers, when set, returns the STUN and TURN servers a
	// participant's client should use, with credentials minted for them.
	ClientICEServers func(participantID string) ([]webrtc.ICEServer, error)

	// SubscriberAPI, when set, builds the API for each participant's
	// subscribe connection, with an estimator of how fast the server can
	// send to them (rtc.Factory.EstimatingAPI). Layers are then chosen to
	// fit that estimate as well as the tile sizes. Without it, API is used
	// and only tile sizes count.
	SubscriberAPI func() (*webrtc.API, <-chan cc.BandwidthEstimator, error)

	// ResumeGrace is how long someone whose WebSocket dropped (rather than
	// closed) stays in the room, waiting to reconnect: a phone moving from
	// Wi-Fi to 4G loses its connections. 0 means DefaultResumeGrace.
	ResumeGrace time.Duration

	// testBudget, in tests, replaces the estimate for a participant (by
	// name), in bit/s.
	testBudget func(name string) func() int

	mu     sync.Mutex // guards rooms, tokens and every room's membership; taken before room.mu
	rooms  map[string]*room
	tokens map[string]*participant // resume tokens
}

// DefaultResumeGrace is long enough for a phone to change networks.
const DefaultResumeGrace = 20 * time.Second

func (rs *Rooms) resumeGrace() time.Duration {
	if rs.ResumeGrace > 0 {
		return rs.ResumeGrace
	}
	return DefaultResumeGrace
}

// resume hands a reconnected WebSocket to the participant whose token it
// carries, if they're still waiting in the room.
func (rs *Rooms) resume(w http.ResponseWriter, r *http.Request, token string) {
	rs.mu.Lock()
	p := rs.tokens[token]
	rs.mu.Unlock()

	ws, err := rs.Upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn := signal.NewConn(ws)
	if p == nil {
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: "session expired"})
		conn.Close()
		return
	}
	old := p.getConn()
	select {
	case p.resumeCh <- conn:
		// If the old connection hasn't noticed it's dead yet (a phone that
		// switched networks leaves it hanging until pings time out), end
		// its read loop now so the new one takes over.
		old.Close()
	default:
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: "already resuming"})
		conn.Close()
	}
}

// deliberateLeave reports whether the WebSocket was closed by the client on
// purpose, rather than dropped.
func deliberateLeave(err error) bool {
	return websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway, websocket.CloseNoStatusReceived)
}

func (rs *Rooms) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if token := r.URL.Query().Get("resume"); token != "" {
		rs.resume(w, r, token)
		return
	}
	roomName := r.PathValue("room")
	if !roomNamePattern.MatchString(roomName) {
		http.Error(w, "room names are 1 to 40 lowercase letters, digits or dashes", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" {
		name = "Guest"
	}
	if runes := []rune(name); len(runes) > 40 {
		name = string(runes[:40])
	}

	ws, err := rs.Upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrade has already replied with an HTTP error.
	}
	conn := signal.NewConn(ws)

	id := newID()
	log := rs.Log.With("room", roomName, "participant", id, "name", name, "remote", r.RemoteAddr)
	subAPI := rs.API
	var estimators <-chan cc.BandwidthEstimator
	if rs.SubscriberAPI != nil {
		if subAPI, estimators, err = rs.SubscriberAPI(); err != nil {
			log.Error("room: subscriber API", "err", err)
			return
		}
	}
	p, err := newParticipant(rs.API, subAPI, rs.ICEServers, id, name, conn, log)
	if err != nil {
		log.Error("room: create peer connections", "err", err)
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: "server error"})
		conn.Close()
		return
	}
	defer func() { p.getConn().Close() }()

	rm, others, tracks, err := rs.join(roomName, p)
	if err != nil {
		p.close()
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: err.Error()})
		return
	}
	defer rs.leave(rm, p)
	p.room = rm
	log.Info("room: joined", "others", len(others))

	// Bandwidth: share the estimate between the cameras p watches.
	switch {
	case rs.testBudget != nil:
		go p.allocateLoop(rs.testBudget(name))
	case estimators != nil:
		select {
		case e := <-estimators:
			go p.allocateLoop(e.GetTargetBitrate)
		default:
			log.Warn("room: no bandwidth estimator")
		}
	}

	// OnTrack fires once per simulcast layer; the layers of one camera share
	// a receiver, and become one upTrack.
	p.pub.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		log.Info("room: publishing track", "kind", remote.Kind(), "codec", remote.Codec().MimeType, "rid", remote.RID(), "ssrc", remote.SSRC())
		t, first := p.upTrackFor(remote, receiver)
		t.addLayer(remote)
		if first {
			if !rm.publish(t) {
				return
			}
			if t.kind == webrtc.RTPCodecTypeVideo {
				go t.watchLayers()
			}
		}
		go t.readSenderReports(remote.RID())
		t.readLayer(remote)
		if p.layerEnded(t) {
			rm.unpublish(t)
		}
	})

	welcome := signal.Message{Type: signal.TypeWelcome, ID: p.id, Participants: others, Resume: p.token}
	welcome.ICEServers = rs.clientICEServers(p, log)
	self := p.info()
	_ = p.send(welcome)
	broadcast(rm.others(p), signal.Message{Type: signal.TypeParticipantJoined, Participant: &self})
	for _, t := range tracks {
		p.subscribe(t)
	}

	// Handle p's messages. If the WebSocket drops rather than closes, p
	// stays in the room for the grace period, in case they reconnect.
	for {
		err := p.signal()
		if deliberateLeave(err) {
			log.Info("room: left", "reason", err)
			return
		}
		log.Info("room: connection lost, waiting for a resume", "reason", err)
		select {
		case c := <-p.resumeCh:
			p.setConn(c)
			log.Info("room: resumed")
			p.resumed(rs.clientICEServers(p, log))
		case <-time.After(rs.resumeGrace()):
			log.Info("room: left", "reason", "didn't resume in time")
			return
		}
	}
}

func (rs *Rooms) clientICEServers(p *participant, log *slog.Logger) []webrtc.ICEServer {
	if rs.ClientICEServers == nil {
		return nil
	}
	servers, err := rs.ClientICEServers(p.id)
	if err != nil {
		log.Error("room: mint TURN credentials", "err", err)
	}
	return servers
}

// join adds p to the named room, creating it if needed. It returns the people
// already there and the tracks they publish.
func (rs *Rooms) join(roomName string, p *participant) (*room, []signal.Participant, []*upTrack, error) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if rs.rooms == nil {
		rs.rooms = make(map[string]*room)
	}
	rm := rs.rooms[roomName]
	if rm == nil {
		rm = &room{name: roomName, done: make(chan struct{}), participants: make(map[string]*participant), tracks: make(map[*upTrack]bool)}
		rs.rooms[roomName] = rm
		go rm.watchSpeakers()
	}

	max := rs.MaxParticipants
	if max == 0 {
		max = DefaultMaxParticipants
	}

	rm.mu.Lock()
	defer rm.mu.Unlock()
	if len(rm.participants) >= max {
		return nil, nil, nil, errRoomFull
	}
	others := make([]signal.Participant, 0, len(rm.participants))
	for _, q := range rm.participants {
		others = append(others, q.info())
	}
	tracks := make([]*upTrack, 0, len(rm.tracks))
	for t := range rm.tracks {
		tracks = append(tracks, t)
	}
	rm.participants[p.id] = p
	if rs.tokens == nil {
		rs.tokens = make(map[string]*participant)
	}
	rs.tokens[p.token] = p
	return rm, others, tracks, nil
}

// leave closes p's connections, stops forwarding its tracks to everyone else
// and tells them it left.
func (rs *Rooms) leave(rm *room, p *participant) {
	p.close()

	rs.mu.Lock()
	delete(rs.tokens, p.token)
	rm.mu.Lock()
	delete(rm.participants, p.id)
	var published []*upTrack
	for t := range rm.tracks {
		if t.owner == p {
			published = append(published, t)
		}
	}
	if len(rm.participants) == 0 {
		delete(rs.rooms, rm.name)
		close(rm.done)
	}
	rm.mu.Unlock()
	rs.mu.Unlock()

	for _, t := range published {
		rm.unpublish(t)
	}
	self := p.info()
	broadcast(rm.others(p), signal.Message{Type: signal.TypeParticipantLeft, Participant: &self})
}

// room is one group of people who all see each other.
type room struct {
	name string
	done chan struct{} // closed when the last person leaves

	mu           sync.Mutex
	participants map[string]*participant
	tracks       map[*upTrack]bool // every track being published in the room
}

// speakingLevel: audio louder than this (in -dBov: 0 is the loudest, 127
// silence) counts as speech. Quiet rooms with noise suppression sit well
// above 60.
const speakingLevel = 50

// speakingHold is how long someone counts as speaking after their last loud
// packet, so the indicator doesn't flicker between words.
const speakingHold = 500 * time.Millisecond

// watchSpeakers tells everyone who is speaking whenever that changes, until
// the room closes.
func (rm *room) watchSpeakers() {
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	var last string
	for {
		select {
		case <-rm.done:
			return
		case now := <-tick.C:
			everyone := rm.others(nil)
			var speaking []string
			for _, p := range everyone {
				if p.speaking(now) {
					speaking = append(speaking, p.id)
				}
			}
			sort.Strings(speaking)
			if key := strings.Join(speaking, ","); key != last {
				last = key
				broadcast(everyone, signal.Message{Type: signal.TypeSpeakers, Speakers: speaking})
			}
		}
	}
}

// others returns everyone in the room except p.
func (rm *room) others(p *participant) []*participant {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	list := make([]*participant, 0, len(rm.participants))
	for _, q := range rm.participants {
		if q != p {
			list = append(list, q)
		}
	}
	return list
}

// publish makes t available in the room and subscribes everyone else to it.
// It reports false if t's owner has already left.
func (rm *room) publish(t *upTrack) bool {
	rm.mu.Lock()
	if rm.participants[t.owner.id] != t.owner {
		rm.mu.Unlock()
		return false
	}
	rm.tracks[t] = true
	rm.mu.Unlock()

	for _, q := range rm.others(t.owner) {
		q.subscribe(t)
	}
	return true
}

// unpublish removes t from the room and from every subscriber. It is safe to
// call more than once.
func (rm *room) unpublish(t *upTrack) {
	if !t.closed.CompareAndSwap(false, true) {
		return
	}
	rm.mu.Lock()
	delete(rm.tracks, t)
	rm.mu.Unlock()

	for _, q := range rm.others(t.owner) {
		q.unsubscribe(t)
	}
}

func broadcast(to []*participant, m signal.Message) {
	for _, q := range to {
		_ = q.send(m)
	}
}

// participant is one person in a room, with their signalling WebSocket and
// two peer connections.
type participant struct {
	id, name string
	token    string                      // secret, for resuming after a dropped WebSocket
	conn     atomic.Pointer[signal.Conn] // the current WebSocket; replaced on resume
	resumeCh chan *signal.Conn           // a reconnected WebSocket, from Rooms.resume
	pub      *webrtc.PeerConnection      // their camera and mic, in
	sub      *webrtc.PeerConnection      // everyone else's, out
	log      *slog.Logger
	lastLoud atomic.Int64 // UnixNano of their last packet louder than speakingLevel

	mu            sync.Mutex
	closed        bool
	downs         map[*upTrack]*downTrack          // what sub is sending them
	published     map[*webrtc.RTPReceiver]*upTrack // what pub is receiving from them
	liveLayers    map[*upTrack]int                 // layers still arriving, per published track
	tiles         map[string]signal.Tile           // their layout, by participant ID
	haveLayout    bool                             // whether they've sent one
	probe         prober                           // bandwidth probing, used by allocateLoop only
	room          *room                            // set once joined
	mic, camera   bool                             // as they last reported
	offerInFlight bool                             // a subscribe offer awaits its answer
	offerAgain    bool                             // tracks changed meanwhile; offer again after the answer
	iceRestart    bool                             // the next subscribe offer restarts ICE
}

func newParticipant(pubAPI, subAPI *webrtc.API, iceServers []webrtc.ICEServer, id, name string, conn *signal.Conn, log *slog.Logger) (*participant, error) {
	cfg := webrtc.Configuration{ICEServers: iceServers}
	pub, err := pubAPI.NewPeerConnection(cfg)
	if err != nil {
		return nil, err
	}
	sub, err := subAPI.NewPeerConnection(cfg)
	if err != nil {
		pub.Close()
		return nil, err
	}
	p := &participant{
		id: id, name: name, token: newToken(), resumeCh: make(chan *signal.Conn, 1),
		pub: pub, sub: sub, log: log,
		downs:      make(map[*upTrack]*downTrack),
		published:  make(map[*webrtc.RTPReceiver]*upTrack),
		liveLayers: make(map[*upTrack]int),
		mic:        true,
		camera:     true,
	}
	p.conn.Store(conn)

	for pcName, pc := range map[string]*webrtc.PeerConnection{signal.PCPublish: pub, signal.PCSubscribe: sub} {
		pc.OnICECandidate(func(c *webrtc.ICECandidate) {
			if c == nil {
				return // Gathering finished.
			}
			init := c.ToJSON()
			_ = p.send(signal.Message{Type: signal.TypeCandidate, PC: pcName, Candidate: &init})
		})
		pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
			// A failed connection is left for the client to restart (ICE
			// restart); if the client is gone too, its WebSocket goes.
			log.Info("room: connection state", "pc", pcName, "state", s.String())
		})
	}
	return p, nil
}

// close shuts both peer connections and stops any further subscribing.
func (p *participant) close() {
	p.mu.Lock()
	p.closed = true
	p.mu.Unlock()
	_ = p.pub.Close()
	_ = p.sub.Close()
}

// upTrackFor returns the upTrack for a receiver, creating it for the
// receiver's first layer.
func (p *participant) upTrackFor(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) (*upTrack, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	t, ok := p.published[receiver]
	if !ok {
		t = newUpTrack(p, remote, receiver)
		p.published[receiver] = t
	}
	p.liveLayers[t]++
	return t, !ok
}

// layerEnded records that one of t's layers stopped, and reports whether
// it was the last.
func (p *participant) layerEnded(t *upTrack) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.liveLayers[t]--
	if p.liveLayers[t] > 0 {
		return false
	}
	delete(p.liveLayers, t)
	delete(p.published, t.receiver)
	return true
}

// subscribe starts sending t to p, then renegotiates.
func (p *participant) subscribe(t *upTrack) {
	p.mu.Lock()
	// Checking t.closed under p.mu means unpublish, which sets it before
	// calling unsubscribe (also under p.mu), can't miss this subscriber.
	if p.closed || t.closed.Load() || p.downs[t] != nil {
		p.mu.Unlock()
		return
	}
	d, err := newDownTrack(t, p)
	if err == nil {
		d.sender, err = p.sub.AddTrack(d.local)
	}
	if err != nil {
		p.mu.Unlock()
		p.log.Warn("room: add track", "err", err)
		return
	}
	p.downs[t] = d
	t.mu.Lock()
	t.downs[p] = d
	t.mu.Unlock()
	p.mu.Unlock()

	// The subscriber's RTCP for this track: NACKs are answered by the
	// interceptors, keyframe requests go on to the publisher.
	go relayKeyframeRequests(d.sender, d.requestKeyframe)
	d.retarget()
	p.negotiate()
}

// unsubscribe stops sending t to p, then renegotiates. The track's m= line
// stays in the SDP, marked inactive; Pion may reuse it for a later track.
func (p *participant) unsubscribe(t *upTrack) {
	p.mu.Lock()
	d := p.downs[t]
	delete(p.downs, t)
	t.mu.Lock()
	delete(t.downs, p)
	t.mu.Unlock()
	if p.closed || d == nil {
		p.mu.Unlock()
		return
	}
	err := p.sub.RemoveTrack(d.sender)
	p.mu.Unlock()
	if err != nil {
		p.log.Warn("room: remove track", "err", err)
	}
	p.negotiate()
}

// send writes a message to p's current WebSocket.
func (p *participant) send(m signal.Message) error {
	return p.getConn().Send(m)
}

func (p *participant) getConn() *signal.Conn { return p.conn.Load() }

// setConn switches p to a reconnected WebSocket.
func (p *participant) setConn(c *signal.Conn) {
	if old := p.conn.Swap(c); old != nil && old != c {
		old.Close()
	}
}

// restartICE renegotiates the subscribe connection with new ICE
// credentials, after an offer in flight if there is one.
func (p *participant) restartICE() {
	p.mu.Lock()
	p.iceRestart = true
	p.mu.Unlock()
	p.negotiate()
}

// resumed brings p back after reconnecting: the room as it is now (they may
// have missed joins, leaves and offers), then an ICE restart on the
// subscribe connection. The client restarts ICE on the publish connection.
func (p *participant) resumed(iceServers []webrtc.ICEServer) {
	var others []signal.Participant
	if p.room != nil {
		for _, q := range p.room.others(p) {
			others = append(others, q.info())
		}
	}
	_ = p.send(signal.Message{Type: signal.TypeResumed, ID: p.id, Participants: others, ICEServers: iceServers, Resume: p.token})

	// Any offer sent while the WebSocket was down was lost.
	p.mu.Lock()
	p.offerInFlight, p.offerAgain, p.iceRestart = false, false, true
	p.mu.Unlock()
	p.negotiate()
}

// info is how p appears to everyone else.
func (p *participant) info() signal.Participant {
	p.mu.Lock()
	defer p.mu.Unlock()
	return signal.Participant{ID: p.id, Name: p.name, Mic: p.mic, Camera: p.camera}
}

// cameraOn reports whether p's camera is on; video from an off camera
// isn't forwarded at all.
func (p *participant) cameraOn() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.camera
}

// speaking reports whether p's microphone is on and was loud just now.
func (p *participant) speaking(now time.Time) bool {
	p.mu.Lock()
	mic := p.mic
	p.mu.Unlock()
	return mic && now.UnixNano()-p.lastLoud.Load() < int64(speakingHold)
}

// setState records p's microphone and camera, tells everyone else, and
// pauses or resumes forwarding p's video to match the camera.
func (p *participant) setState(mic, camera *bool) {
	p.mu.Lock()
	if mic != nil {
		p.mic = *mic
	}
	cameraChanged := camera != nil && *camera != p.camera
	if camera != nil {
		p.camera = *camera
	}
	published := make([]*upTrack, 0, len(p.published))
	for _, t := range p.published {
		published = append(published, t)
	}
	rm := p.room
	p.mu.Unlock()

	if rm == nil {
		return
	}
	self := p.info()
	broadcast(rm.others(p), signal.Message{Type: signal.TypeParticipantChanged, Participant: &self})
	if cameraChanged {
		for _, t := range published {
			t.retargetAll()
		}
	}
}

// tileSize is how big the owner's tile is on p's screen. haveTile is false
// until p sends a layout; a person missing from it has size 0×0.
func (p *participant) tileSize(owner string) (width, height int, haveTile bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.haveLayout {
		return 0, 0, false
	}
	tile := p.tiles[owner]
	return tile.Width, tile.Height, true
}

// audioBitrate is set aside for each audio track in a viewer's budget.
const audioBitrate = 40_000

// allocateLoop shares p's bandwidth between the cameras p watches, twice a
// second, and tells p the estimate every few seconds, until p leaves.
func (p *participant) allocateLoop(budget func() int) {
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	var told time.Time
	for now := range tick.C {
		p.mu.Lock()
		closed := p.closed
		var video []*downTrack
		audio := 0
		for _, d := range p.downs {
			if d.up.kind == webrtc.RTPCodecTypeVideo {
				video = append(video, d)
			} else {
				audio++
			}
		}
		p.mu.Unlock()
		if closed {
			return
		}

		bitrate := budget()
		p.allocate(bitrate-audio*audioBitrate, video, now)
		if now.Sub(told) >= 2*time.Second {
			told = now
			_ = p.send(signal.Message{Type: signal.TypeEstimate, Bitrate: bitrate})
		}
	}
}

// allocate caps each camera p watches to what the budget allows, and
// probes for more when a tile wants more than the budget allows.
func (p *participant) allocate(budget int, downs []*downTrack, now time.Time) {
	reqs := make([]allocRequest, len(downs))
	for i, d := range downs {
		layers := sortLayers(d.up.liveLayers())
		width, height, haveTile := p.tileSize(d.up.owner.id)
		want := -1
		if len(layers) > 0 && (!haveTile || (width > 0 && height > 0)) {
			want = chooseIndex(layers, width, height, haveTile)
		}
		if !haveTile {
			width, height = 1, 1
		}
		reqs[i] = allocRequest{area: width * height, layers: layers, want: want}
	}
	full := allocate(budget, reqs)
	keep := allocate(budget*118/100, reqs)
	safe := allocate(budget*85/100, reqs)
	severe := allocate(budget*150/100, reqs)

	probing := p.probe.step(downs, reqs, full, budget, now, p.log)
	for i, d := range downs {
		if d == probing {
			continue // the probe holds its cap for now
		}
		d.applyCap(reqs[i].layers, keep[i], safe[i], severe[i], budget, now)
	}
}

// prober finds out whether a viewer can take more than the estimate says.
//
// GCC only trusts what it has seen: its estimate stays near 1.5 times what
// is actually sent. A viewer receiving only small layers would never earn
// the estimate to move up, however fast their connection. So when a tile
// wants a better layer than the estimate allows, the prober sends it. While
// the path copes, GCC raises its estimate by up to about 8% a second; once
// the estimate covers the new layer, the layer stays. If instead the
// estimate falls (delay or loss: the path is full), or doesn't get there
// within probeLength, the layer goes back and the next try waits twice as
// long.
type prober struct {
	target      *downTrack
	level       int // the layer index being tried
	startBudget int // the estimate when the probe began
	until       time.Time
	next        time.Time
	backoff     time.Duration
}

const (
	probeLength     = 15 * time.Second
	probeMinBackoff = 10 * time.Second
	probeMaxBackoff = time.Minute
)

// step advances probing by one allocation round and returns the downTrack
// being probed, if any, whose cap the caller must leave alone.
func (pr *prober) step(downs []*downTrack, reqs []allocRequest, full []int, budget int, now time.Time, log interface {
	Info(string, ...any)
}) *downTrack {
	if pr.backoff == 0 {
		pr.backoff = probeMinBackoff
	}
	index := func(d *downTrack) int {
		for i := range downs {
			if downs[i] == d {
				return i
			}
		}
		return -1
	}

	if pr.target != nil {
		i := index(pr.target)
		switch {
		case i < 0:
			pr.target = nil // unsubscribed meanwhile
		case full[i] >= pr.level:
			// The estimate now affords the probed layer: keep it.
			log.Info("room: probe succeeded", "from", pr.target.up.owner.name, "rid", reqs[i].layers[min(pr.level, len(reqs[i].layers)-1)].rid)
			pr.target, pr.backoff, pr.next = nil, probeMinBackoff, now.Add(probeMinBackoff)
		case now.After(pr.until) || budget < pr.startBudget*8/10:
			// The estimate fell, or never got there: the path can't take
			// it. Back off.
			log.Info("room: probe failed", "from", pr.target.up.owner.name, "budget", budget, "start", pr.startBudget)
			pr.target = nil
			pr.backoff = min(2*pr.backoff, probeMaxBackoff)
			pr.next = now.Add(pr.backoff)
		default:
			return pr.target
		}
		return nil
	}

	if now.Before(pr.next) {
		return nil
	}
	// The biggest tile held below what it wants.
	best := -1
	for i, r := range reqs {
		if r.want < 0 || full[i] >= r.want || full[i]+1 >= len(r.layers) {
			continue
		}
		if downs[i].capLevel(r.layers) > full[i] {
			continue // already above the allocation (not yet lowered)
		}
		if best < 0 || r.area > reqs[best].area {
			best = i
		}
	}
	if best < 0 {
		return nil
	}
	d, level := downs[best], full[best]+1
	pr.target, pr.level, pr.startBudget, pr.until = d, level, budget, now.Add(probeLength)
	log.Info("room: probing", "from", d.up.owner.name, "rid", reqs[best].layers[level].rid, "budget", budget)
	d.forceCap(reqs[best].layers[level].rid, now)
	return d
}

// setLayout records p's tile sizes and re-chooses every layer p receives.
func (p *participant) setLayout(tiles []signal.Tile) {
	p.mu.Lock()
	p.haveLayout = true
	p.tiles = make(map[string]signal.Tile, len(tiles))
	for _, tile := range tiles {
		p.tiles[tile.ID] = tile
	}
	downs := make([]*downTrack, 0, len(p.downs))
	for _, d := range p.downs {
		downs = append(downs, d)
	}
	p.mu.Unlock()
	for _, d := range downs {
		d.retarget()
	}
}

// negotiate sends a new offer on the subscribe connection describing the
// tracks p should now receive. If an offer is already waiting for an answer,
// it notes that another is needed instead.
func (p *participant) negotiate() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	if p.offerInFlight {
		p.offerAgain = true
		return
	}
	var opts *webrtc.OfferOptions
	if p.iceRestart {
		// New ICE credentials: the client gathers fresh candidates, from
		// whatever network it's on now.
		opts = &webrtc.OfferOptions{ICERestart: true}
		p.iceRestart = false
	}
	offer, err := p.sub.CreateOffer(opts)
	if err == nil {
		err = p.sub.SetLocalDescription(offer)
	}
	if err != nil {
		p.log.Error("room: create subscribe offer", "err", err)
		p.getConn().Close()
		return
	}
	p.offerInFlight = true
	_ = p.send(signal.Message{Type: signal.TypeOffer, PC: signal.PCSubscribe, SDP: offer.SDP})
}

// handleAnswer applies the client's answer to our subscribe offer.
func (p *participant) handleAnswer(sdp string) error {
	p.mu.Lock()
	if !p.offerInFlight {
		p.mu.Unlock()
		return errors.New("no subscribe offer is waiting for an answer")
	}
	err := p.sub.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: sdp})
	p.offerInFlight = false
	again := p.offerAgain
	p.offerAgain = false
	downs := make([]*downTrack, 0, len(p.downs))
	for _, d := range p.downs {
		downs = append(downs, d)
	}
	p.mu.Unlock()
	if err != nil {
		return err
	}

	// New tracks can't be decoded until a keyframe arrives; ask now rather
	// than wait for the next periodic one or the subscriber's own PLI.
	for _, d := range downs {
		d.requestKeyframe()
	}
	if again {
		p.negotiate()
	}
	return nil
}

// signal handles p's signalling messages until the WebSocket closes.
func (p *participant) signal() error {
	conn := p.getConn()
	// Candidates can arrive before the matching description is applied.
	pending := map[string][]webrtc.ICECandidateInit{}
	pcs := map[string]*webrtc.PeerConnection{signal.PCPublish: p.pub, signal.PCSubscribe: p.sub}
	addPending := func(name string) {
		for _, c := range pending[name] {
			if err := pcs[name].AddICECandidate(c); err != nil {
				p.log.Warn("room: bad candidate", "pc", name, "err", err)
			}
		}
		delete(pending, name)
	}
	sendError := func(text string) {
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: text})
	}

	for {
		msg, err := conn.Receive()
		if err != nil {
			if errors.Is(err, signal.ErrBadMessage) {
				sendError(err.Error())
				continue
			}
			return err
		}

		switch msg.Type {
		case signal.TypeOffer:
			// Repeated offers are renegotiation, e.g. the client adding its
			// microphone later.
			if msg.PC != signal.PCPublish {
				sendError("offers are only accepted on the publish connection")
				continue
			}
			answer, err := answerOffer(p.pub, msg.SDP)
			if err != nil {
				sendError(err.Error())
				return err
			}
			addPending(signal.PCPublish)
			if err := conn.Send(signal.Message{Type: signal.TypeAnswer, PC: signal.PCPublish, SDP: answer}); err != nil {
				return err
			}

		case signal.TypeAnswer:
			if msg.PC != signal.PCSubscribe {
				sendError("answers are only accepted on the subscribe connection")
				continue
			}
			if err := p.handleAnswer(msg.SDP); err != nil {
				sendError(err.Error())
				return err
			}
			addPending(signal.PCSubscribe)

		case signal.TypeLayout:
			p.setLayout(msg.Tiles)

		case signal.TypeState:
			p.setState(msg.Mic, msg.Camera)

		case signal.TypeRestartICE:
			p.restartICE()

		case signal.TypeCandidate:
			pc := pcs[msg.PC]
			if pc == nil {
				sendError("unknown peer connection " + msg.PC)
				continue
			}
			if msg.Candidate == nil {
				continue
			}
			if pc.RemoteDescription() == nil {
				pending[msg.PC] = append(pending[msg.PC], *msg.Candidate)
				continue
			}
			if err := pc.AddICECandidate(*msg.Candidate); err != nil {
				p.log.Warn("room: bad candidate", "pc", msg.PC, "err", err)
			}

		default:
			sendError("unknown message type " + msg.Type)
		}
	}
}

// newToken returns a resume token: long and random, since it's a secret.
func newToken() string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// newID returns a short random participant ID.
func newID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
