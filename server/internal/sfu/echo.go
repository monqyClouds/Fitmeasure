// Package sfu forwards media between participants.
//
// Stage 1 (this file) is an echo: one participant sends camera and microphone
// to the server, and the server sends the same packets straight back. It
// exercises everything a real SFU needs except fan-out: signalling, ICE,
// receiving RTP, sending RTP, and relaying keyframe requests.
package sfu

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync/atomic"

	"github.com/gorilla/websocket"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"

	"github.com/monqyClouds/Fitmeasure/server/internal/rtc"
	"github.com/monqyClouds/Fitmeasure/server/internal/signal"
)

// Echo serves the stage 1 echo over a WebSocket.
type Echo struct {
	API        *webrtc.API
	ICEServers []webrtc.ICEServer
	Log        *slog.Logger
	Upgrader   websocket.Upgrader
}

func (e *Echo) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ws, err := e.Upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrade has already replied with an HTTP error.
	}
	conn := signal.NewConn(ws)
	defer conn.Close()

	log := e.Log.With("remote", r.RemoteAddr)
	log.Info("echo: connected")
	if err := e.run(conn, log); err != nil {
		log.Info("echo: ended", "reason", err)
	}
}

func (e *Echo) run(conn *signal.Conn, log *slog.Logger) error {
	pc, err := e.API.NewPeerConnection(webrtc.Configuration{ICEServers: e.ICEServers})
	if err != nil {
		return err
	}
	defer pc.Close()

	// Outgoing tracks carry the client's own media back to it. Each has a
	// sender; reading RTCP from it tells us what the client asks for.
	video, err := webrtc.NewTrackLocalStaticRTP(rtc.VP8, "video", "echo")
	if err != nil {
		return err
	}
	audio, err := webrtc.NewTrackLocalStaticRTP(rtc.Opus, "audio", "echo")
	if err != nil {
		return err
	}
	videoSender, err := pc.AddTrack(video)
	if err != nil {
		return err
	}
	audioSender, err := pc.AddTrack(audio)
	if err != nil {
		return err
	}

	// SSRC of the client's incoming video, once it arrives; keyframe requests
	// are addressed to it.
	var videoSSRC atomic.Uint32
	requestKeyframe := func() {
		if ssrc := videoSSRC.Load(); ssrc != 0 {
			_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
		}
	}

	go relayKeyframeRequests(videoSender, requestKeyframe)
	go drainRTCP(audioSender)

	pc.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		log.Info("echo: receiving track", "kind", remote.Kind(), "codec", remote.Codec().MimeType, "ssrc", remote.SSRC())
		out, sender := audio, audioSender
		if remote.Kind() == webrtc.RTPCodecTypeVideo {
			out, sender = video, videoSender
			videoSSRC.Store(uint32(remote.SSRC()))
			// Ask for a keyframe straight away, so the echo can start
			// decoding without waiting for the next periodic one.
			requestKeyframe()
		}
		// The client's sender reports, under the echo's SSRC, keep the
		// echoed audio and video in sync.
		go readSenderReports(receiver, remote, func(sr *rtcp.SenderReport) {
			if out, ok := senderReportFor(sender, sr); ok {
				_ = pc.WriteRTCP([]rtcp.Packet{out})
			}
		})
		forward(remote, out)
	})

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return // Gathering finished.
		}
		init := c.ToJSON()
		_ = conn.Send(signal.Message{Type: signal.TypeCandidate, Candidate: &init})
	})

	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		log.Info("echo: connection state", "state", s.String())
		if s == webrtc.PeerConnectionStateFailed || s == webrtc.PeerConnectionStateClosed {
			conn.Close() // Unblocks Receive below.
		}
	})

	// Candidates can arrive before the offer is applied; keep them until then.
	var pending []webrtc.ICECandidateInit
	for {
		msg, err := conn.Receive()
		if err != nil {
			if errors.Is(err, signal.ErrBadMessage) {
				_ = conn.Send(signal.Message{Type: signal.TypeError, Error: err.Error()})
				continue
			}
			return err
		}

		switch msg.Type {
		case signal.TypeOffer:
			if pc.RemoteDescription() != nil {
				_ = conn.Send(signal.Message{Type: signal.TypeError, Error: "already negotiated"})
				continue
			}
			answer, err := answerOffer(pc, msg.SDP)
			if err != nil {
				_ = conn.Send(signal.Message{Type: signal.TypeError, Error: err.Error()})
				return err
			}
			for _, c := range pending {
				if err := pc.AddICECandidate(c); err != nil {
					log.Warn("echo: bad candidate", "err", err)
				}
			}
			pending = nil
			if err := conn.Send(signal.Message{Type: signal.TypeAnswer, SDP: answer}); err != nil {
				return err
			}

		case signal.TypeCandidate:
			if msg.Candidate == nil {
				continue
			}
			if pc.RemoteDescription() == nil {
				pending = append(pending, *msg.Candidate)
				continue
			}
			if err := pc.AddICECandidate(*msg.Candidate); err != nil {
				log.Warn("echo: bad candidate", "err", err)
			}

		default:
			_ = conn.Send(signal.Message{Type: signal.TypeError, Error: "unknown message type " + msg.Type})
		}
	}
}

// answerOffer applies the client's offer and returns our answer. Candidates
// are sent separately as they're found ("trickle ICE"), so the answer goes out
// without waiting for gathering to finish.
func answerOffer(pc *webrtc.PeerConnection, sdp string) (string, error) {
	offer := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: sdp}
	if err := pc.SetRemoteDescription(offer); err != nil {
		return "", err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return "", err
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		return "", err
	}
	return answer.SDP, nil
}

// forward copies RTP packets from an incoming track to an outgoing one until
// the incoming track ends. The outgoing track rewrites SSRC and payload type
// to what was negotiated for the return direction.
func forward(in *webrtc.TrackRemote, out *webrtc.TrackLocalStaticRTP) {
	buf := make([]byte, 1500) // One RTP packet fits in a network MTU.
	for {
		n, _, err := in.Read(buf)
		if err != nil {
			return
		}
		if _, err := out.Write(buf[:n]); err != nil && !errors.Is(err, io.ErrClosedPipe) {
			return
		}
	}
}

// relayKeyframeRequests watches RTCP from the client about the video we send
// it. When its decoder needs a fresh keyframe (PLI or FIR) we can't make one
// ourselves, so we pass the request on to the client's encoder.
func relayKeyframeRequests(sender *webrtc.RTPSender, request func()) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		for _, p := range packets {
			switch p.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				request()
			}
		}
	}
}

// drainRTCP reads and discards RTCP so the interceptors (NACK, reports) see it.
func drainRTCP(sender *webrtc.RTPSender) {
	for {
		if _, _, err := sender.ReadRTCP(); err != nil {
			return
		}
	}
}
