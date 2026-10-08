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
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/rtcp"
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

	mu    sync.Mutex // guards rooms and every room's membership; taken before room.mu
	rooms map[string]*room
}

func (rs *Rooms) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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
	defer conn.Close()

	id := newID()
	log := rs.Log.With("room", roomName, "participant", id, "name", name, "remote", r.RemoteAddr)
	p, err := newParticipant(rs.API, rs.ICEServers, id, name, conn, log)
	if err != nil {
		log.Error("room: create peer connections", "err", err)
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: "server error"})
		return
	}

	rm, others, tracks, err := rs.join(roomName, p)
	if err != nil {
		p.close()
		_ = conn.Send(signal.Message{Type: signal.TypeError, Error: err.Error()})
		return
	}
	defer rs.leave(rm, p)
	log.Info("room: joined", "others", len(others))

	p.pub.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		log.Info("room: publishing track", "kind", remote.Kind(), "codec", remote.Codec().MimeType, "ssrc", remote.SSRC())
		t, err := newUpTrack(p, remote)
		if err != nil {
			log.Error("room: create outgoing track", "err", err)
			return
		}
		if !rm.publish(t) {
			return
		}
		forward(remote, t.local)
		rm.unpublish(t)
	})

	self := signal.Participant{ID: p.id, Name: p.name}
	_ = conn.Send(signal.Message{Type: signal.TypeWelcome, ID: p.id, Participants: others})
	broadcast(rm.others(p), signal.Message{Type: signal.TypeParticipantJoined, Participant: &self})
	for _, t := range tracks {
		p.subscribe(t)
	}

	if err := p.signal(); err != nil {
		log.Info("room: left", "reason", err)
	}
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
		rm = &room{name: roomName, participants: make(map[string]*participant), tracks: make(map[*upTrack]bool)}
		rs.rooms[roomName] = rm
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
		others = append(others, signal.Participant{ID: q.id, Name: q.name})
	}
	tracks := make([]*upTrack, 0, len(rm.tracks))
	for t := range rm.tracks {
		tracks = append(tracks, t)
	}
	rm.participants[p.id] = p
	return rm, others, tracks, nil
}

// leave closes p's connections, stops forwarding its tracks to everyone else
// and tells them it left.
func (rs *Rooms) leave(rm *room, p *participant) {
	p.close()

	rs.mu.Lock()
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
	}
	rm.mu.Unlock()
	rs.mu.Unlock()

	for _, t := range published {
		rm.unpublish(t)
	}
	self := signal.Participant{ID: p.id, Name: p.name}
	broadcast(rm.others(p), signal.Message{Type: signal.TypeParticipantLeft, Participant: &self})
}

// room is one group of people who all see each other.
type room struct {
	name string

	mu           sync.Mutex
	participants map[string]*participant
	tracks       map[*upTrack]bool // every track being published in the room
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
		_ = q.conn.Send(m)
	}
}

// upTrack is one track a participant publishes: audio or video coming in from
// their publish connection, plus the single outgoing track that carries it to
// every subscriber.
type upTrack struct {
	owner  *participant
	remote *webrtc.TrackRemote
	local  *webrtc.TrackLocalStaticRTP

	closed          atomic.Bool
	lastKeyframeAsk atomic.Int64 // UnixNano of the last keyframe request
}

func newUpTrack(owner *participant, remote *webrtc.TrackRemote) (*upTrack, error) {
	// The stream ID is the owner's participant ID, so clients can match the
	// track to a person. The track ID only has to be unique.
	local, err := webrtc.NewTrackLocalStaticRTP(remote.Codec().RTPCodecCapability, owner.id+"-"+remote.ID(), owner.id)
	if err != nil {
		return nil, err
	}
	return &upTrack{owner: owner, remote: remote, local: local}, nil
}

// requestKeyframe asks the publisher's encoder for a keyframe (PLI), at most
// once per keyframeInterval. Only the encoder can make one; the server just
// passes on what subscribers' decoders ask for.
func (t *upTrack) requestKeyframe() {
	if t.remote.Kind() != webrtc.RTPCodecTypeVideo {
		return
	}
	now := time.Now().UnixNano()
	last := t.lastKeyframeAsk.Load()
	if now-last < int64(keyframeInterval) || !t.lastKeyframeAsk.CompareAndSwap(last, now) {
		return
	}
	_ = t.owner.pub.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: uint32(t.remote.SSRC())}})
}

// participant is one person in a room, with their signalling WebSocket and
// two peer connections.
type participant struct {
	id, name string
	conn     *signal.Conn
	pub      *webrtc.PeerConnection // their camera and mic, in
	sub      *webrtc.PeerConnection // everyone else's, out
	log      *slog.Logger

	mu            sync.Mutex
	closed        bool
	senders       map[*upTrack]*webrtc.RTPSender // what sub is sending them
	offerInFlight bool                           // a subscribe offer awaits its answer
	offerAgain    bool                           // tracks changed meanwhile; offer again after the answer
}

func newParticipant(api *webrtc.API, iceServers []webrtc.ICEServer, id, name string, conn *signal.Conn, log *slog.Logger) (*participant, error) {
	cfg := webrtc.Configuration{ICEServers: iceServers}
	pub, err := api.NewPeerConnection(cfg)
	if err != nil {
		return nil, err
	}
	sub, err := api.NewPeerConnection(cfg)
	if err != nil {
		pub.Close()
		return nil, err
	}
	p := &participant{id: id, name: name, conn: conn, pub: pub, sub: sub, log: log, senders: make(map[*upTrack]*webrtc.RTPSender)}

	for pcName, pc := range map[string]*webrtc.PeerConnection{signal.PCPublish: pub, signal.PCSubscribe: sub} {
		pc.OnICECandidate(func(c *webrtc.ICECandidate) {
			if c == nil {
				return // Gathering finished.
			}
			init := c.ToJSON()
			_ = conn.Send(signal.Message{Type: signal.TypeCandidate, PC: pcName, Candidate: &init})
		})
		pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
			log.Info("room: connection state", "pc", pcName, "state", s.String())
			if s == webrtc.PeerConnectionStateFailed {
				conn.Close() // Unblocks Receive in signal, which leaves the room.
			}
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

// subscribe starts sending t to p, then renegotiates.
func (p *participant) subscribe(t *upTrack) {
	p.mu.Lock()
	// Checking t.closed under p.mu means unpublish, which sets it before
	// calling unsubscribe (also under p.mu), can't miss this sender.
	if p.closed || t.closed.Load() || p.senders[t] != nil {
		p.mu.Unlock()
		return
	}
	sender, err := p.sub.AddTrack(t.local)
	if err != nil {
		p.mu.Unlock()
		p.log.Warn("room: add track", "err", err)
		return
	}
	p.senders[t] = sender
	p.mu.Unlock()

	// The subscriber's RTCP for this track: NACKs are answered by the
	// interceptors, keyframe requests go on to the publisher.
	go relayKeyframeRequests(sender, t.requestKeyframe)
	p.negotiate()
}

// unsubscribe stops sending t to p, then renegotiates. The track's m= line
// stays in the SDP, marked inactive; Pion may reuse it for a later track.
func (p *participant) unsubscribe(t *upTrack) {
	p.mu.Lock()
	sender := p.senders[t]
	delete(p.senders, t)
	if p.closed || sender == nil {
		p.mu.Unlock()
		return
	}
	err := p.sub.RemoveTrack(sender)
	p.mu.Unlock()
	if err != nil {
		p.log.Warn("room: remove track", "err", err)
	}
	p.negotiate()
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
	offer, err := p.sub.CreateOffer(nil)
	if err == nil {
		err = p.sub.SetLocalDescription(offer)
	}
	if err != nil {
		p.log.Error("room: create subscribe offer", "err", err)
		p.conn.Close()
		return
	}
	p.offerInFlight = true
	_ = p.conn.Send(signal.Message{Type: signal.TypeOffer, PC: signal.PCSubscribe, SDP: offer.SDP})
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
	tracks := make([]*upTrack, 0, len(p.senders))
	for t := range p.senders {
		tracks = append(tracks, t)
	}
	p.mu.Unlock()
	if err != nil {
		return err
	}

	// New tracks can't be decoded until a keyframe arrives; ask now rather
	// than wait for the next periodic one or the subscriber's own PLI.
	for _, t := range tracks {
		t.requestKeyframe()
	}
	if again {
		p.negotiate()
	}
	return nil
}

// signal handles p's signalling messages until the WebSocket closes.
func (p *participant) signal() error {
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
		_ = p.conn.Send(signal.Message{Type: signal.TypeError, Error: text})
	}

	for {
		msg, err := p.conn.Receive()
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
			if err := p.conn.Send(signal.Message{Type: signal.TypeAnswer, PC: signal.PCPublish, SDP: answer}); err != nil {
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

// newID returns a short random participant ID.
func newID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
