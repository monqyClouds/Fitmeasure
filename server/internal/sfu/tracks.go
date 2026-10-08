package sfu

import (
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

// layerTimeout is how long a layer may go without packets before it counts
// as stopped. Browsers stop sending their top layers when the upload can't
// carry them, and start again when it can.
const layerTimeout = 1500 * time.Millisecond

// keyframeRetry is how long a switch waits for a keyframe before asking
// again, in case the request or the keyframe was lost.
const keyframeRetry = time.Second

// upTrack is one track a participant publishes: their microphone, or their
// camera as one to three simulcast layers.
type upTrack struct {
	owner    *participant
	id       string // track ID for subscribers: unique, and stable across them
	kind     webrtc.RTPCodecType
	codec    webrtc.RTPCodecCapability
	receiver *webrtc.RTPReceiver

	closed atomic.Bool

	mu     sync.Mutex
	layers map[string]*layer // by RID; "" when the track isn't simulcast
	downs  map[*participant]*downTrack
}

// layer is one simulcast layer (or the whole track, without simulcast).
type layer struct {
	rid           string
	remote        *webrtc.TrackRemote
	width, height int
	lastPacket    time.Time
	lastKeyAsk    time.Time
	lastReport    *rtcp.SenderReport

	// Bitrate, measured over half-second windows and smoothed.
	bitrate     float64
	windowBytes int
	windowStart time.Time
}

// measure adds a packet's media to the layer's bitrate. Padding isn't
// counted: senders add it to probe bandwidth, not to carry the picture.
func (l *layer) measure(payloadBytes int, now time.Time) {
	if l.windowStart.IsZero() {
		l.windowStart = now
	}
	l.windowBytes += payloadBytes
	if elapsed := now.Sub(l.windowStart); elapsed >= 500*time.Millisecond {
		rate := float64(l.windowBytes*8) / elapsed.Seconds()
		if l.bitrate == 0 {
			l.bitrate = rate
		} else {
			l.bitrate = 0.7*l.bitrate + 0.3*rate
		}
		l.windowBytes, l.windowStart = 0, now
	}
}

func newUpTrack(owner *participant, remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) *upTrack {
	return &upTrack{
		owner:    owner,
		id:       owner.id + "-" + remote.ID(),
		kind:     remote.Kind(),
		codec:    remote.Codec().RTPCodecCapability,
		receiver: receiver,
		layers:   make(map[string]*layer),
		downs:    make(map[*participant]*downTrack),
	}
}

// addLayer registers a layer as it starts arriving.
func (t *upTrack) addLayer(remote *webrtc.TrackRemote) {
	t.mu.Lock()
	t.layers[remote.RID()] = &layer{rid: remote.RID(), remote: remote, lastPacket: time.Now()}
	t.mu.Unlock()
	t.retargetAll()
}

// readLayer forwards one layer's packets until it ends.
func (t *upTrack) readLayer(remote *webrtc.TrackRemote) {
	rid := remote.RID()
	for {
		pkt, _, err := remote.ReadRTP()
		if err != nil {
			return
		}
		key, width, height := true, 0, 0
		if t.kind == webrtc.RTPCodecTypeVideo {
			key, width, height = vp8Keyframe(pkt.Payload)
		}

		now := time.Now()
		t.mu.Lock()
		l := t.layers[rid]
		wasLive := now.Sub(l.lastPacket) < layerTimeout
		l.lastPacket = now
		l.measure(len(pkt.Payload), now)
		resized := width > 0 && (width != l.width || height != l.height)
		if resized {
			l.width, l.height = width, height
		}
		downs := t.downList()
		t.mu.Unlock()

		// A layer appearing, reappearing or changing size can change what
		// each subscriber should get.
		if resized || !wasLive {
			t.retargetAll()
		}
		for _, d := range downs {
			d.write(rid, pkt, key, now)
		}
	}
}

func (t *upTrack) downList() []*downTrack {
	list := make([]*downTrack, 0, len(t.downs))
	for _, d := range t.downs {
		list = append(list, d)
	}
	return list
}

// liveLayers are the layers that have sent packets recently.
func (t *upTrack) liveLayers() []layerInfo {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	var live []layerInfo
	for _, l := range t.layers {
		if now.Sub(l.lastPacket) < layerTimeout {
			live = append(live, layerInfo{rid: l.rid, width: l.width, height: l.height, bitrate: int(l.bitrate)})
		}
	}
	return live
}

// retargetAll re-chooses the layer for every subscriber.
func (t *upTrack) retargetAll() {
	t.mu.Lock()
	downs := t.downList()
	t.mu.Unlock()
	for _, d := range downs {
		d.retarget()
	}
}

// watchLayers re-chooses layers once a second, so subscribers move off a
// layer the publisher has stopped sending.
func (t *upTrack) watchLayers() {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for range tick.C {
		if t.closed.Load() {
			return
		}
		t.retargetAll()
	}
}

// requestKeyframe asks the publisher's encoder for a keyframe on one layer
// (PLI), at most once per keyframeInterval. Only the encoder can make one.
func (t *upTrack) requestKeyframe(rid string) {
	if t.kind != webrtc.RTPCodecTypeVideo {
		return
	}
	t.mu.Lock()
	l := t.layers[rid]
	if l == nil || time.Since(l.lastKeyAsk) < keyframeInterval {
		t.mu.Unlock()
		return
	}
	l.lastKeyAsk = time.Now()
	ssrc := uint32(l.remote.SSRC())
	t.mu.Unlock()
	_ = t.owner.pub.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
}

// readSenderReports passes one layer's sender reports to subscribers.
func (t *upTrack) readSenderReports(rid string) {
	read := t.receiver.ReadRTCP
	if rid != "" {
		read = func() ([]rtcp.Packet, interceptor.Attributes, error) { return t.receiver.ReadSimulcastRTCP(rid) }
	}
	t.mu.Lock()
	ssrc := uint32(t.layers[rid].remote.SSRC())
	t.mu.Unlock()
	for {
		packets, _, err := read()
		if err != nil {
			return
		}
		for _, p := range packets {
			sr, ok := p.(*rtcp.SenderReport)
			if !ok || sr.SSRC != ssrc {
				continue
			}
			t.mu.Lock()
			t.layers[rid].lastReport = sr
			downs := t.downList()
			t.mu.Unlock()
			for _, d := range downs {
				d.sendSenderReport(rid, sr)
			}
		}
	}
}

// lastSenderReport is the latest report for a layer, for a new subscriber.
func (t *upTrack) lastSenderReport(rid string) *rtcp.SenderReport {
	t.mu.Lock()
	defer t.mu.Unlock()
	if l := t.layers[rid]; l != nil {
		return l.lastReport
	}
	return nil
}

// downTrack is one subscriber's copy of an upTrack: its own outgoing track,
// carrying whichever layer suits that subscriber.
type downTrack struct {
	up     *upTrack
	sub    *participant
	local  *webrtc.TrackLocalStaticRTP
	sender *webrtc.RTPSender

	mu         sync.Mutex
	current    string // layer being forwarded, if forwarding
	forwarding bool
	target     string // layer wanted; becomes current at its next keyframe
	wanted     bool   // false while the tile is off screen: send nothing
	askedAt    time.Time
	rewriter   streamRewriter

	// The target layer's keyframe, collected while the current layer keeps
	// playing. A large keyframe can take half a second to arrive (the
	// publisher sends it at the layer's bitrate); switching at its first
	// packet would leave the subscriber with nothing to show meanwhile.
	pending   []*rtp.Packet
	pendingAt time.Time

	// The largest layer the subscriber's bandwidth allows (stage 5), set
	// by participant.allocate. Without a cap, the tile alone decides.
	cap            string
	capped         bool
	capChangedAt   time.Time
	lastCapDropped bool // the last change lowered the cap
	lowRounds      int  // allocation rounds in a row below the cap
}

// pendingTimeout drops a keyframe that never completes (say a packet was
// lost) and asks for another.
const pendingTimeout = 2 * time.Second

func newDownTrack(up *upTrack, sub *participant) (*downTrack, error) {
	// The stream ID is the owner's participant ID, so clients can match the
	// track to a person.
	local, err := webrtc.NewTrackLocalStaticRTP(up.codec, up.id, up.owner.id)
	if err != nil {
		return nil, err
	}
	return &downTrack{up: up, sub: sub, local: local, rewriter: streamRewriter{clockRate: up.codec.ClockRate}}, nil
}

// retarget chooses the layer for this subscriber from the layers arriving,
// the size of the publisher's tile on the subscriber's screen, and the cap
// the subscriber's bandwidth sets.
func (d *downTrack) retarget() {
	layers := sortLayers(d.up.liveLayers())
	if len(layers) == 0 {
		d.setTarget("", false)
		return
	}
	if d.up.kind == webrtc.RTPCodecTypeAudio {
		d.setTarget(layers[0].rid, true) // audio plays whatever the layout
		return
	}
	width, height, haveTile := d.sub.tileSize(d.up.owner.id)
	if haveTile && (width == 0 || height == 0) {
		d.setTarget("", false) // not on screen
		return
	}
	i := chooseIndex(layers, width, height, haveTile)
	d.mu.Lock()
	if d.capped {
		i = min(i, capIndex(layers, d.cap))
	}
	d.mu.Unlock()
	d.setTarget(layers[i].rid, true)
}

// capLevel is the index in layers of d's current cap (the largest layer if
// uncapped).
func (d *downTrack) capLevel(layers []layerInfo) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.capped {
		return len(layers) - 1
	}
	return capIndex(layers, d.cap)
}

// forceCap sets the cap to a layer regardless of holds, for probing.
func (d *downTrack) forceCap(rid string, now time.Time) {
	d.mu.Lock()
	changed := !d.capped || d.cap != rid
	d.cap, d.capped, d.capChangedAt = rid, true, now
	d.mu.Unlock()
	if changed {
		d.retarget()
	}
}

// How long a cap stays put before it may rise again, so the estimate has
// time to show whether the last change fitted: longer after a fall, so a
// connection near a layer's edge doesn't flip between two layers.
const (
	upgradeHold          = 3 * time.Second
	upgradeHoldAfterDrop = 10 * time.Second
)

// applyCap sets the bandwidth cap from one round of allocation. Each
// argument is the layer index the allocation gives at a share of the
// estimate:
//
//   - keep, at 118%: when GCC sees congestion it cuts its estimate to 85% of
//     what is getting through, so only an estimate below 85% of the current
//     layer's cost (keep < current) means trouble. Above that the estimate
//     is just hovering near the rate being sent. Down after two such rounds
//     (a second), or at once if even 150% of it (severe) wouldn't cover the
//     current layer.
//   - safe, at 85%: up only as far as this allows, and not until the hold
//     since the last change is over.
func (d *downTrack) applyCap(layers []layerInfo, keep, safe, severe, budget int, now time.Time) {
	if keep < 0 || len(layers) == 0 {
		return
	}
	d.mu.Lock()
	next := min(keep, max(safe, 0))
	if d.capped {
		cur := capIndex(layers, d.cap)
		next = cur
		switch {
		case keep < cur:
			d.lowRounds++
			if severe < cur || d.lowRounds >= 2 {
				next = keep
			}
		case safe > cur:
			d.lowRounds = 0
			hold := upgradeHold
			if d.lastCapDropped {
				hold = upgradeHoldAfterDrop
			}
			if now.Sub(d.capChangedAt) >= hold {
				next = safe
			}
		default:
			d.lowRounds = 0
		}
		if next != cur {
			d.lastCapDropped = next < cur
		}
	}
	rid := layers[next].rid
	changed := !d.capped || rid != d.cap
	if changed {
		d.cap, d.capped, d.capChangedAt, d.lowRounds = rid, true, now, 0
	}
	d.mu.Unlock()
	if changed {
		d.sub.log.Info("room: cap", "from", d.up.owner.name, "rid", rid, "budget", budget, "cost", layers[next].cost())
		d.retarget()
	}
}

func (d *downTrack) setTarget(rid string, wanted bool) {
	d.mu.Lock()
	if !wanted {
		d.wanted, d.forwarding, d.pending = false, false, nil
		d.mu.Unlock()
		return
	}
	if d.wanted && d.target == rid {
		d.mu.Unlock()
		return
	}
	d.target, d.wanted, d.pending = rid, true, nil
	switching := !d.forwarding || d.current != rid
	if switching {
		d.askedAt = time.Now()
	}
	d.mu.Unlock()
	if switching {
		d.up.requestKeyframe(rid)
	}
}

// write forwards a packet from layer rid if it's the layer this subscriber
// is on, switching layers at the target layer's keyframe.
func (d *downTrack) write(rid string, pkt *rtp.Packet, keyframe bool, now time.Time) {
	d.mu.Lock()
	if !d.wanted {
		d.mu.Unlock()
		return
	}
	if rid == d.target && (!d.forwarding || d.current != rid) {
		if !d.forwarding {
			// Nothing playing yet: start at the first keyframe packet.
			if !keyframe {
				d.waitForKeyframe(rid, now)
				return
			}
			d.current, d.forwarding = rid, true
			d.rewriter.switchTo(pkt.SequenceNumber, pkt.Timestamp, now)
			defer func() { go d.sendLatestSenderReport() }()
			if d.up.kind == webrtc.RTPCodecTypeVideo {
				defer d.logLayer(rid)
			}
		} else {
			// Switching: collect the keyframe, and switch once it's whole.
			frame := d.collectKeyframe(pkt, keyframe, now)
			if frame == nil {
				d.waitForKeyframe(rid, now)
				return
			}
			d.current = rid
			d.rewriter.switchTo(frame[0].SequenceNumber, frame[0].Timestamp, now)
			var out []*rtp.Packet
			for _, p := range frame {
				if seq, ts, ok := d.rewriter.rewrite(p.SequenceNumber, p.Timestamp, now); ok {
					out = append(out, rewritten(p, seq, ts))
				}
			}
			d.mu.Unlock()
			for _, p := range out {
				d.send(p)
			}
			d.logLayer(rid)
			// The new layer's clock mapping, so lip sync holds across the
			// switch without waiting for the publisher's next report.
			go d.sendLatestSenderReport()
			return
		}
	}
	if !d.forwarding || rid != d.current {
		d.mu.Unlock()
		return
	}
	seq, ts, ok := d.rewriter.rewrite(pkt.SequenceNumber, pkt.Timestamp, now)
	d.mu.Unlock()
	if ok {
		d.send(rewritten(pkt, seq, ts))
	}
}

func (d *downTrack) logLayer(rid string) {
	d.sub.log.Info("room: layer", "from", d.up.owner.name, "rid", rid)
}

// waitForKeyframe is called, with d.mu held, while the target layer's
// keyframe hasn't arrived; it unlocks and asks again if it's overdue.
func (d *downTrack) waitForKeyframe(rid string, now time.Time) {
	retry := now.Sub(d.askedAt) > keyframeRetry
	if retry {
		d.askedAt = now
	}
	d.mu.Unlock()
	if retry {
		d.up.requestKeyframe(rid)
	}
}

// collectKeyframe adds a target-layer packet to the keyframe being
// collected, and returns the keyframe's packets in order once it's whole:
// from its first packet to the one with the marker bit, none missing.
// Called with d.mu held.
func (d *downTrack) collectKeyframe(pkt *rtp.Packet, keyframe bool, now time.Time) []*rtp.Packet {
	if keyframe {
		d.pending, d.pendingAt = []*rtp.Packet{pkt}, now
	} else if len(d.pending) > 0 && pkt.Timestamp == d.pending[0].Timestamp {
		d.pending = append(d.pending, pkt)
	} else {
		if len(d.pending) > 0 && now.Sub(d.pendingAt) > pendingTimeout {
			d.pending = nil
		}
		return nil
	}

	var last *rtp.Packet
	for _, p := range d.pending {
		if p.Marker {
			last = p
		}
	}
	if last == nil {
		return nil
	}
	first := d.pending[0].SequenceNumber
	frame := make([]*rtp.Packet, last.SequenceNumber-first+1)
	for _, p := range d.pending {
		if i := p.SequenceNumber - first; int(i) < len(frame) {
			frame[i] = p
		}
	}
	d.pending = nil
	for _, p := range frame {
		if p == nil {
			return nil // a packet is missing: wait for the next keyframe
		}
	}
	return frame
}

// rewritten copies a packet with a new sequence number and timestamp. The
// packet is shared by every subscriber, so it isn't changed in place.
// Header extensions are dropped: their IDs were agreed with the publisher
// and can mean something else on the subscriber's connection.
func rewritten(pkt *rtp.Packet, seq uint16, ts uint32) *rtp.Packet {
	header := pkt.Header
	header.SequenceNumber = seq
	header.Timestamp = ts
	header.Extension = false
	header.Extensions = nil
	header.ExtensionProfile = 0
	return &rtp.Packet{Header: header, Payload: pkt.Payload}
}

func (d *downTrack) send(pkt *rtp.Packet) {
	if err := d.local.WriteRTP(pkt); err != nil && !errors.Is(err, io.ErrClosedPipe) {
		d.sub.log.Debug("room: forward", "err", err)
	}
}

// requestKeyframe passes a subscriber's keyframe request to the layer it
// is on, or is switching to.
func (d *downTrack) requestKeyframe() {
	d.mu.Lock()
	rid, ok := d.target, d.wanted
	d.mu.Unlock()
	if ok {
		d.up.requestKeyframe(rid)
	}
}

// sendSenderReport passes on the publisher's report for layer rid if it's
// the layer being forwarded, shifted by the same timestamp offset as the
// packets so it stays true for the joined stream.
func (d *downTrack) sendSenderReport(rid string, sr *rtcp.SenderReport) {
	if sr == nil {
		return
	}
	d.mu.Lock()
	if !d.forwarding || rid != d.current {
		d.mu.Unlock()
		return
	}
	shifted := *sr
	shifted.RTPTime += d.rewriter.tsOffset
	d.mu.Unlock()
	if out, ok := senderReportFor(d.sender, &shifted); ok {
		_ = d.sub.sub.WriteRTCP([]rtcp.Packet{out})
	}
}

// sendLatestSenderReport sends the newest report for the current layer, so
// a new subscriber can sync audio and video without waiting for the next.
func (d *downTrack) sendLatestSenderReport() {
	d.mu.Lock()
	rid, forwarding := d.current, d.forwarding
	d.mu.Unlock()
	if forwarding {
		d.sendSenderReport(rid, d.up.lastSenderReport(rid))
	}
}
