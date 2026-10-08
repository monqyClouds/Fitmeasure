package sfu

// Stage 4: simulcast.
//
// A publisher's camera arrives as up to three layers, each a separate RTP
// stream named by a RID: by convention "q" (a quarter of the camera's
// size), "h" (half) and "f" (full). Each subscriber gets one of them per
// camera, chosen from how large that person's tile is on their screen, and
// can be moved between layers while watching.
//
// A decoder can only start on a keyframe, so a switch waits for the new
// layer's next keyframe (asked for with a PLI) while the old layer keeps
// playing. The layers' sequence numbers and timestamps are unrelated, so the
// SFU rewrites them to continue where the previous layer left off; to the
// subscriber it is one stream whose picture changes size.

import (
	"encoding/binary"
	"sort"
	"time"
)

// vp8Keyframe reports whether an RTP payload is the first packet of a VP8
// keyframe, and the picture size the keyframe declares.
//
// The payload starts with the VP8 payload descriptor (RFC 7741 section 4.2),
// then the VP8 frame itself, whose first byte's lowest bit is 0 for a
// keyframe (RFC 6386 section 9.1). A keyframe's header then holds the start
// code 9d 01 2a and the width and height.
func vp8Keyframe(payload []byte) (ok bool, width, height int) {
	if len(payload) < 1 {
		return false, 0, 0
	}
	d := payload[0]
	start := d&0x10 != 0
	partition := d & 0x07
	if !start || partition != 0 {
		return false, 0, 0 // not the start of the frame
	}
	i := 1
	if d&0x80 != 0 { // X: extension bits follow
		if len(payload) < 2 {
			return false, 0, 0
		}
		x := payload[1]
		i = 2
		if x&0x80 != 0 { // I: picture ID, 7 or 15 bits
			if len(payload) <= i {
				return false, 0, 0
			}
			if payload[i]&0x80 != 0 {
				i += 2
			} else {
				i++
			}
		}
		if x&0x40 != 0 { // L: TL0PICIDX
			i++
		}
		if x&0x30 != 0 { // T or K: TID/Y/KEYIDX
			i++
		}
	}
	if len(payload) <= i || payload[i]&0x01 != 0 {
		return false, 0, 0
	}
	frame := payload[i:]
	if len(frame) >= 10 && frame[3] == 0x9d && frame[4] == 0x01 && frame[5] == 0x2a {
		width = int(binary.LittleEndian.Uint16(frame[6:8]) & 0x3fff)
		height = int(binary.LittleEndian.Uint16(frame[8:10]) & 0x3fff)
	}
	return true, width, height
}

// layerInfo is what the SFU knows about one layer when choosing.
type layerInfo struct {
	rid           string
	width, height int // from its last keyframe; 0 until one has been seen
	bitrate       int // measured, in bit/s; 0 until measured
}

// cost is what a layer takes to send, in bit/s: as measured, or a typical
// figure until it has been.
func (l layerInfo) cost() int {
	if l.bitrate > 0 {
		return l.bitrate
	}
	switch l.rid {
	case "q":
		return 150_000
	case "h":
		return 500_000
	case "f":
		return 1_200_000
	}
	return 800_000
}

// ridRank orders layers whose size isn't known yet.
func ridRank(rid string) int {
	switch rid {
	case "q":
		return 0
	case "h":
		return 1
	case "f":
		return 2
	}
	return 1
}

// maxUpscale is how much a tile may enlarge a layer's picture before the
// next larger layer is worth its bandwidth.
const maxUpscale = 1.33

// sortLayers orders layers from smallest to largest: by height once known,
// by RID until then.
func sortLayers(live []layerInfo) []layerInfo {
	layers := append([]layerInfo(nil), live...)
	sort.Slice(layers, func(i, j int) bool {
		a, b := layers[i], layers[j]
		if a.height > 0 && b.height > 0 && a.height != b.height {
			return a.height < b.height
		}
		return ridRank(a.rid) < ridRank(b.rid)
	})
	return layers
}

// chooseIndex picks the layer for a tile of the given size in device pixels
// from layers sorted by sortLayers: the smallest whose picture covers the
// tile with at most maxUpscale enlargement, or the largest if none does.
// The picture fills the tile ("cover"), so the larger of the two ratios
// counts. Without a tile size it picks the middle layer.
func chooseIndex(layers []layerInfo, tileWidth, tileHeight int, haveTile bool) int {
	if !haveTile {
		return len(layers) / 2
	}
	for i, l := range layers {
		if l.width == 0 || l.height == 0 {
			continue
		}
		scale := max(float64(tileWidth)/float64(l.width), float64(tileHeight)/float64(l.height))
		if scale <= maxUpscale {
			return i
		}
	}
	return len(layers) - 1
}

// chooseLayer is chooseIndex on unsorted layers, returning the layer's RID.
func chooseLayer(live []layerInfo, tileWidth, tileHeight int, haveTile bool) (string, bool) {
	if len(live) == 0 {
		return "", false
	}
	layers := sortLayers(live)
	return layers[chooseIndex(layers, tileWidth, tileHeight, haveTile)].rid, true
}

// capIndex is the index in sorted layers of the largest one a cap allows:
// the capped layer itself, or if it isn't arriving, the largest smaller one.
func capIndex(layers []layerInfo, cap string) int {
	best := 0
	for i, l := range layers {
		if l.rid == cap {
			return i
		}
		if ridRank(l.rid) <= ridRank(cap) {
			best = i
		}
	}
	return best
}

// allocRequest is one camera a viewer receives, for allocate.
type allocRequest struct {
	area   int         // tile size in device pixels, so bigger tiles go first
	layers []layerInfo // as arriving, sorted by sortLayers
	want   int         // index of the layer the tile wants; -1 if off screen
}

// allocate shares a viewer's bandwidth between the cameras they watch. It
// returns, for each request, the index of the largest layer it may have
// (-1 for none).
//
// Every visible tile gets its smallest layer, whatever the budget: a small
// picture beats a frozen one, and the estimate will drop no lower than the
// connection can take. Then, round by round, each tile that wants more moves
// up one layer if the extra cost still fits, bigger tiles first, so a pinned
// person improves before the strip below them.
func allocate(budget int, reqs []allocRequest) []int {
	alloc := make([]int, len(reqs))
	remaining := budget
	order := make([]int, 0, len(reqs))
	for i, r := range reqs {
		if r.want < 0 || len(r.layers) == 0 {
			alloc[i] = -1
			continue
		}
		remaining -= r.layers[0].cost()
		order = append(order, i)
	}
	sort.SliceStable(order, func(a, b int) bool { return reqs[order[a]].area > reqs[order[b]].area })

	for upgraded := true; upgraded; {
		upgraded = false
		for _, i := range order {
			r, cur := reqs[i], alloc[i]
			if cur >= r.want || cur+1 >= len(r.layers) {
				continue
			}
			extra := r.layers[cur+1].cost() - r.layers[cur].cost()
			if extra <= remaining {
				remaining -= extra
				alloc[i]++
				upgraded = true
			}
		}
	}
	return alloc
}

// streamRewriter joins a series of RTP streams (one layer, then another)
// into one continuous stream: each switch is given sequence numbers and
// timestamps that carry on from the last packet sent.
type streamRewriter struct {
	clockRate uint32

	started   bool
	seqOffset uint16
	tsOffset  uint32
	lastSeq   uint16 // highest sequence number sent
	lastTS    uint32 // timestamp of that packet
	lastAt    time.Time
	firstSeq  uint16 // the new layer's first packet: anything older is dropped
}

// switchTo starts a new layer at the packet with this sequence number and
// timestamp, which must be the start of a keyframe for video.
func (r *streamRewriter) switchTo(seq uint16, ts uint32, now time.Time) {
	r.firstSeq = seq
	if !r.started {
		r.started = true
		r.seqOffset, r.tsOffset = 0, 0
		r.lastSeq, r.lastTS, r.lastAt = seq-1, ts, now
		return
	}
	// Continue one past the last sequence number, and as much later in
	// time as has really passed, at least one tick. Layers are read on
	// separate goroutines, so now can be a moment before lastAt.
	elapsed := uint32(1)
	if d := now.Sub(r.lastAt); d > 0 {
		elapsed = max(1, uint32(d.Seconds()*float64(r.clockRate)))
	}
	r.seqOffset = r.lastSeq + 1 - seq
	r.tsOffset = r.lastTS + elapsed - ts
}

// rewrite maps a packet of the current layer into the joined stream. It
// reports false for packets from before the switch (late or reordered),
// which would collide with numbers the previous layer already used.
func (r *streamRewriter) rewrite(seq uint16, ts uint32, now time.Time) (uint16, uint32, bool) {
	if !r.started || seqBefore(seq, r.firstSeq) {
		return 0, 0, false
	}
	outSeq := seq + r.seqOffset
	outTS := ts + r.tsOffset
	if seqBefore(r.lastSeq, outSeq) {
		r.lastSeq, r.lastTS, r.lastAt = outSeq, outTS, now
	}
	return outSeq, outTS, true
}

// seqBefore reports whether a comes before b, allowing for wrap-around.
func seqBefore(a, b uint16) bool {
	return a != b && b-a < 0x8000
}
