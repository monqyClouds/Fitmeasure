package sfu

import (
	"bytes"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"

	"github.com/monqyClouds/Fitmeasure/server/internal/rtc"
	"github.com/monqyClouds/Fitmeasure/server/internal/signal"
)

func newTestAPI(t *testing.T) *webrtc.API {
	t.Helper()
	api, err := rtc.NewAPI(rtc.Config{IncludeLoopback: true})
	if err != nil {
		t.Fatal(err)
	}
	return api
}

func startEcho(t *testing.T) string {
	t.Helper()
	echo := &Echo{API: newTestAPI(t), Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	srv := httptest.NewServer(echo)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	return ws
}

// A Pion peer plays the browser: it sends VP8 video to the echo and expects
// the same payload back on the track the server sends it.
func TestEchoReturnsVideo(t *testing.T) {
	ws := dial(t, startEcho(t))
	var wsMu sync.Mutex
	send := func(m signal.Message) {
		wsMu.Lock()
		defer wsMu.Unlock()
		if err := ws.WriteJSON(m); err != nil {
			t.Error(err)
		}
	}

	pc, err := newTestAPI(t).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })

	track, err := webrtc.NewTrackLocalStaticSample(rtc.VP8, "video", "client")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pc.AddTrack(track); err != nil {
		t.Fatal(err)
	}

	// A recognisable payload; VP8 packetisation adds a 1-byte descriptor in
	// front of it, and the echo must not touch the rest.
	marker := []byte("fitmeasure-echo-marker")
	echoed := make(chan []byte, 1)
	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		for {
			pkt, _, err := remote.ReadRTP()
			if err != nil {
				return
			}
			select {
			case echoed <- pkt.Payload:
			default:
			}
		}
	})
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			init := c.ToJSON()
			send(signal.Message{Type: signal.TypeCandidate, Candidate: &init})
		}
	})

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	send(signal.Message{Type: signal.TypeOffer, SDP: offer.SDP})

	go func() {
		for {
			var m signal.Message
			if err := ws.ReadJSON(&m); err != nil {
				return
			}
			switch m.Type {
			case signal.TypeAnswer:
				if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: m.SDP}); err != nil {
					t.Error(err)
				}
			case signal.TypeCandidate:
				if err := pc.AddICECandidate(*m.Candidate); err != nil {
					t.Error(err)
				}
			case signal.TypeError:
				t.Errorf("server error: %s", m.Error)
			}
		}
	}()

	deadline := time.After(15 * time.Second)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case payload := <-echoed:
			if !bytes.Contains(payload, marker) {
				t.Fatalf("echoed payload %q doesn't contain the marker", payload)
			}
			return
		case <-tick.C:
			if err := track.WriteSample(media.Sample{Data: marker, Duration: 20 * time.Millisecond}); err != nil {
				t.Fatal(err)
			}
		case <-deadline:
			t.Fatalf("no echo within 15s (connection state %s)", pc.ConnectionState())
		}
	}
}

func TestEchoRejectsUnknownAndMalformedMessages(t *testing.T) {
	ws := dial(t, startEcho(t))

	if err := ws.WriteMessage(websocket.TextMessage, []byte("not json")); err != nil {
		t.Fatal(err)
	}
	if err := ws.WriteJSON(signal.Message{Type: "hello"}); err != nil {
		t.Fatal(err)
	}

	for _, want := range []string{"malformed", "unknown message type hello"} {
		var m signal.Message
		_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
		if err := ws.ReadJSON(&m); err != nil {
			t.Fatal(err)
		}
		if m.Type != signal.TypeError || !strings.Contains(m.Error, want) {
			t.Fatalf("got %+v, want an error containing %q", m, want)
		}
	}
}

func TestEchoRejectsBadOffer(t *testing.T) {
	ws := dial(t, startEcho(t))
	if err := ws.WriteJSON(signal.Message{Type: signal.TypeOffer, SDP: "v=0 nonsense"}); err != nil {
		t.Fatal(err)
	}
	var m signal.Message
	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	if err := ws.ReadJSON(&m); err != nil {
		t.Fatal(err)
	}
	if m.Type != signal.TypeError {
		t.Fatalf("got %+v, want an error", m)
	}
}
