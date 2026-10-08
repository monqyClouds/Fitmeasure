package sfu

import (
	"testing"
	"time"
)

// vp8Frame builds a VP8 RTP payload: a one-byte descriptor (S=1, PID=0)
// then a frame. Keyframes carry the start code and size.
func vp8Frame(key bool, width, height int, rest ...byte) []byte {
	if !key {
		return append([]byte{0x10, 0x01, 0x00, 0x00}, rest...)
	}
	return append([]byte{
		0x10,             // descriptor: start of partition 0
		0x00, 0x00, 0x00, // frame tag: keyframe
		0x9d, 0x01, 0x2a, // start code
		byte(width), byte(width >> 8),
		byte(height), byte(height >> 8),
	}, rest...)
}

func TestVP8Keyframe(t *testing.T) {
	ok, w, h := vp8Keyframe(vp8Frame(true, 960, 540))
	if !ok || w != 960 || h != 540 {
		t.Fatalf("keyframe: got %v %dx%d", ok, w, h)
	}
	if ok, _, _ := vp8Keyframe(vp8Frame(false, 0, 0)); ok {
		t.Fatal("interframe reported as keyframe")
	}
	// Not the start of the frame (S=0).
	if ok, _, _ := vp8Keyframe([]byte{0x00, 0x00, 0x00, 0x00}); ok {
		t.Fatal("continuation packet reported as keyframe")
	}
	// With the extension: X, I with a 15-bit picture ID, L and T.
	ext := append([]byte{0x90, 0xe0, 0x81, 0x23, 0x05, 0x40}, vp8Frame(true, 320, 180)[1:]...)
	if ok, w, h := vp8Keyframe(ext); !ok || w != 320 || h != 180 {
		t.Fatalf("keyframe with extension: got %v %dx%d", ok, w, h)
	}
	if ok, _, _ := vp8Keyframe(nil); ok {
		t.Fatal("empty payload reported as keyframe")
	}
}

func TestChooseLayer(t *testing.T) {
	three := []layerInfo{{"f", 960, 540, 0}, {"q", 240, 135, 0}, {"h", 480, 270, 0}}
	cases := []struct {
		name     string
		layers   []layerInfo
		w, h     int
		haveTile bool
		want     string
	}{
		{"small tile gets q", three, 200, 120, true, "q"},
		{"up to 33% upscaling still q", three, 300, 170, true, "q"},
		{"medium tile gets h", three, 600, 340, true, "h"},
		{"large tile gets f", three, 1080, 600, true, "f"},
		{"huge tile gets the largest", three, 2000, 1200, true, "f"},
		{"cover: a tall tile needs the height", three, 300, 700, true, "f"},
		{"no layout yet gets the middle", three, 0, 0, false, "h"},
		{"top layer dropped", three[1:], 1080, 600, true, "h"},
		{"sizes unknown yet: largest", []layerInfo{{"q", 0, 0, 0}, {"f", 0, 0, 0}}, 1080, 600, true, "f"},
		{"no simulcast", []layerInfo{{"", 640, 480, 0}}, 200, 100, true, ""},
	}
	for _, c := range cases {
		got, ok := chooseLayer(c.layers, c.w, c.h, c.haveTile)
		if !ok || got != c.want {
			t.Errorf("%s: got %q %v, want %q", c.name, got, ok, c.want)
		}
	}
	if _, ok := chooseLayer(nil, 100, 100, true); ok {
		t.Error("chose a layer with none arriving")
	}
}

func TestAllocate(t *testing.T) {
	layers := []layerInfo{
		{rid: "q", bitrate: 100_000},
		{rid: "h", bitrate: 400_000},
		{rid: "f", bitrate: 1_000_000},
	}
	big := allocRequest{area: 1000 * 600, layers: layers, want: 2}
	small := allocRequest{area: 300 * 200, layers: layers, want: 1}
	off := allocRequest{area: 0, layers: layers, want: -1}

	cases := []struct {
		name   string
		budget int
		reqs   []allocRequest
		want   []int
	}{
		{"plenty: everyone gets what their tile wants", 10_000_000, []allocRequest{big, small}, []int{2, 1}},
		{"too little for anything: smallest layers anyway", 50_000, []allocRequest{big, small}, []int{0, 0}},
		// 200k for both q layers leaves 400k: h for the big tile (+300k)
		// fits, then the small tile's h (+300k) doesn't.
		{"the bigger tile goes first", 600_000, []allocRequest{small, big}, []int{0, 1}},
		// 200k + 300k + 300k = 800k gives both h; f (+600k) needs 1.4M.
		{"one step each before anyone gets two", 900_000, []allocRequest{big, small}, []int{1, 1}},
		{"off screen gets nothing and costs nothing", 500_000, []allocRequest{off, big}, []int{-1, 1}},
		{"never above what the tile wants", 10_000_000, []allocRequest{small}, []int{1}},
	}
	for _, c := range cases {
		got := allocate(c.budget, c.reqs)
		for i := range c.want {
			if got[i] != c.want[i] {
				t.Errorf("%s: got %v, want %v", c.name, got, c.want)
				break
			}
		}
	}
}

func TestCapIndex(t *testing.T) {
	three := sortLayers([]layerInfo{{rid: "q"}, {rid: "h"}, {rid: "f"}})
	if i := capIndex(three, "h"); i != 1 {
		t.Errorf("cap h: got %d", i)
	}
	twoNoH := sortLayers([]layerInfo{{rid: "q"}, {rid: "f"}})
	if i := capIndex(twoNoH, "h"); i != 0 {
		t.Errorf("cap h with h missing: got %d, want q", i)
	}
}

func TestStreamRewriterJoinsLayers(t *testing.T) {
	r := streamRewriter{clockRate: 90000}
	now := time.Unix(1000, 0)

	// Layer one: sequence numbers 100.., timestamps 5000...
	r.switchTo(100, 5000, now)
	for i := uint16(0); i < 3; i++ {
		seq, ts, ok := r.rewrite(100+i, 5000+uint32(i)*3000, now)
		if !ok || seq != 100+i || ts != 5000+uint32(i)*3000 {
			t.Fatalf("first layer packet %d: got %d %d %v", i, seq, ts, ok)
		}
	}

	// 40 ms later, a different layer near the wrap-around point.
	later := now.Add(40 * time.Millisecond)
	r.switchTo(65534, 900_000, later)
	want := uint16(103)
	for _, in := range []uint16{65534, 65535, 0, 1} {
		seq, _, ok := r.rewrite(in, 900_000, later)
		if !ok || seq != want {
			t.Fatalf("second layer seq %d: got %d %v, want %d", in, seq, ok, want)
		}
		want++
	}
	_, ts, _ := r.rewrite(2, 900_000, later)
	if wantTS := uint32(5000 + 2*3000 + 3600); ts != wantTS {
		t.Fatalf("timestamp after the switch: got %d, want %d (40 ms on)", ts, wantTS)
	}

	// A late packet from before the switch is dropped, not given a number
	// the first layer already used.
	if _, _, ok := r.rewrite(65530, 899_000, later); ok {
		t.Fatal("packet from before the switch was forwarded")
	}
}

// The switch's clock reading can be a moment earlier than the last
// packet's, since layers are read concurrently; time must still move on.
func TestStreamRewriterSwitchWithEarlierClock(t *testing.T) {
	r := streamRewriter{clockRate: 90000}
	now := time.Unix(1000, 0)
	r.switchTo(10, 5000, now)
	r.rewrite(10, 5000, now)
	r.switchTo(500, 70000, now.Add(-time.Millisecond))
	_, ts, ok := r.rewrite(500, 70000, now)
	if !ok || ts != 5001 {
		t.Fatalf("got timestamp %d %v, want 5001 (one tick on)", ts, ok)
	}
}

func TestSeqBefore(t *testing.T) {
	for _, c := range []struct {
		a, b uint16
		want bool
	}{{1, 2, true}, {2, 1, false}, {65535, 0, true}, {0, 65535, false}, {5, 5, false}} {
		if got := seqBefore(c.a, c.b); got != c.want {
			t.Errorf("seqBefore(%d, %d) = %v", c.a, c.b, got)
		}
	}
}
