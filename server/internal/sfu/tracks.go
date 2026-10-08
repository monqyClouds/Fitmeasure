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
			live = append(live, layerInfo{rid: l.rid, width: l.width, height: l.height})
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

// retarget chooses the layer for this subscriber from the layers arriving
// and the size of the publisher's tile on the subscriber's screen.
func (d *downTrack) retarget() {
	live := d.up.liveLayers()
	width, height, haveTile := d.sub.tileSize(d.up.owner.id)
	if d.up.kind == webrtc.RTPCodecTypeAudio {
		width, height, haveTile = 0, 0, false // audio plays whatever the layout
	}
	if haveTile && (width == 0 || height == 0) {
		d.setTarget("", false) // not on screen
		return
	}
	rid, ok := chooseLayer(live, width, height, haveTile)
	d.setTarget(rid, ok)
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
