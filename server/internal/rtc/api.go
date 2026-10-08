// Package rtc builds the Pion WebRTC API shared by every peer connection the
// server creates: which codecs we accept, which RTP/RTCP helpers run, and how
// ICE finds network paths.
package rtc

import (
	"fmt"
	"net"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"
)

// Config controls how the server is reachable for media.
type Config struct {
	// UDPPort, when non-zero, multiplexes all WebRTC traffic over this single
	// UDP port instead of one random port per connection. Servers behind a
	// firewall need this, so only one port has to be opened.
	UDPPort int

	// PublicIP is advertised in ICE candidates instead of the machine's own
	// address. Set it when the server sits behind 1:1 NAT (most cloud VMs).
	PublicIP string

	// ICEServers are STUN/TURN servers handed to peer connections. The server
	// itself rarely needs them when it has a public IP.
	ICEServers []webrtc.ICEServer

	// IncludeLoopback offers 127.0.0.1 candidates, for tests on one machine.
	IncludeLoopback bool
}

// NewAPI returns a WebRTC API that only negotiates VP8 video and Opus audio,
// with the default interceptors: NACK (retransmission requests), RTCP sender
// and receiver reports, and transport-wide congestion control feedback.
func NewAPI(cfg Config) (*webrtc.API, error) {
	media := &webrtc.MediaEngine{}
	if err := registerCodecs(media); err != nil {
		return nil, err
	}

	interceptors := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(media, interceptors); err != nil {
		return nil, fmt.Errorf("register interceptors: %w", err)
	}

	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(cfg.IncludeLoopback)
	if cfg.UDPPort != 0 {
		mux, err := ice.NewMultiUDPMuxFromPort(cfg.UDPPort)
		if err != nil {
			return nil, fmt.Errorf("listen on UDP port %d: %w", cfg.UDPPort, err)
		}
		settings.SetICEUDPMux(mux)
	}
	if cfg.PublicIP != "" {
		if net.ParseIP(cfg.PublicIP) == nil {
			return nil, fmt.Errorf("invalid public IP %q", cfg.PublicIP)
		}
		err := settings.SetICEAddressRewriteRules(webrtc.ICEAddressRewriteRule{
			External:        []string{cfg.PublicIP},
			AsCandidateType: webrtc.ICECandidateTypeHost,
		})
		if err != nil {
			return nil, fmt.Errorf("set public IP: %w", err)
		}
	}

	return webrtc.NewAPI(
		webrtc.WithMediaEngine(media),
		webrtc.WithInterceptorRegistry(interceptors),
		webrtc.WithSettingEngine(settings),
	), nil
}

// Restricting codecs keeps forwarding simple: every participant sends and
// receives the same formats, so packets never need converting. VP8 is
// supported by every browser and Android, and works with simulcast.
func registerCodecs(media *webrtc.MediaEngine) error {
	videoFeedback := []webrtc.RTCPFeedback{
		{Type: webrtc.TypeRTCPFBGoogREMB},
		{Type: webrtc.TypeRTCPFBCCM, Parameter: "fir"},
		{Type: webrtc.TypeRTCPFBNACK},
		{Type: webrtc.TypeRTCPFBNACK, Parameter: "pli"},
	}
	codecs := []struct {
		params webrtc.RTPCodecParameters
		kind   webrtc.RTPCodecType
	}{
		{webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeVP8,
				ClockRate:    90000,
				RTCPFeedback: videoFeedback,
			},
			PayloadType: 96,
		}, webrtc.RTPCodecTypeVideo},
		{webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    webrtc.MimeTypeOpus,
				ClockRate:   48000,
				Channels:    2,
				SDPFmtpLine: "minptime=10;useinbandfec=1",
			},
			PayloadType: 111,
		}, webrtc.RTPCodecTypeAudio},
	}
	for _, c := range codecs {
		if err := media.RegisterCodec(c.params, c.kind); err != nil {
			return fmt.Errorf("register %s: %w", c.params.MimeType, err)
		}
	}
	return nil
}

// Codec capabilities for tracks the server sends, matching registerCodecs.
var (
	VP8  = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000}
	Opus = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}
)
