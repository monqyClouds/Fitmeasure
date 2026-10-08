// Package rtc builds the Pion WebRTC APIs the server's peer connections use:
// which codecs we accept, which RTP/RTCP helpers run, and how ICE finds
// network paths.
package rtc

import (
	"fmt"
	"net"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/interceptor/pkg/gcc"
	"github.com/pion/interceptor/pkg/report"
	"github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

// Config controls how the server is reachable for media.
type Config struct {
	// UDPPort, when non-zero, multiplexes all WebRTC traffic over this single
	// UDP port instead of one random port per connection. Servers behind a
	// firewall need this, so only one port has to be opened.
	UDPPort int

	// TCPPort, when non-zero, also accepts WebRTC media over TCP on this port
	// ("ICE-TCP"). Some networks block UDP but allow outgoing TCP; this lets
	// those clients reach the server directly before falling back to TURN.
	TCPPort int

	// PublicIP is advertised in ICE candidates instead of the machine's own
	// address. Set it when the server sits behind 1:1 NAT (most cloud VMs).
	PublicIP string

	// ICEServers are STUN/TURN servers handed to peer connections. The server
	// itself rarely needs them when it has a public IP.
	ICEServers []webrtc.ICEServer

	// IncludeLoopback offers 127.0.0.1 candidates, for tests on one machine.
	IncludeLoopback bool
}

// Factory builds Pion APIs that share one set of network settings, so the
// UDP and TCP ports are opened once however many APIs there are.
type Factory struct {
	settings webrtc.SettingEngine
}

// NewFactory opens the ports in cfg.
func NewFactory(cfg Config) (*Factory, error) {
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(cfg.IncludeLoopback)
	if cfg.UDPPort != 0 {
		mux, err := ice.NewMultiUDPMuxFromPort(cfg.UDPPort)
		if err != nil {
			return nil, fmt.Errorf("listen on UDP port %d: %w", cfg.UDPPort, err)
		}
		settings.SetICEUDPMux(mux)
	}
	if cfg.TCPPort != 0 {
		ln, err := net.ListenTCP("tcp", &net.TCPAddr{Port: cfg.TCPPort})
		if err != nil {
			return nil, fmt.Errorf("listen on TCP port %d: %w", cfg.TCPPort, err)
		}
		settings.SetICETCPMux(webrtc.NewICETCPMux(nil, ln, 8))
		settings.SetNetworkTypes([]webrtc.NetworkType{
			webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6,
			webrtc.NetworkTypeTCP4, webrtc.NetworkTypeTCP6,
		})
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
	return &Factory{settings: settings}, nil
}

// NewAPI returns a WebRTC API that only negotiates VP8 video and Opus audio,
// with NACK (retransmission requests), RTCP receiver reports and
// transport-wide congestion control feedback. Sender reports are forwarded
// from publishers rather than generated; see newInterceptors.
func NewAPI(cfg Config) (*webrtc.API, error) {
	f, err := NewFactory(cfg)
	if err != nil {
		return nil, err
	}
	return f.API()
}

// API returns an API for any number of peer connections.
func (f *Factory) API() (*webrtc.API, error) {
	return f.build(nil)
}

// EstimatingAPI returns an API for one peer connection that also estimates
// how fast it can send to the other side, with Google Congestion Control
// (GCC), the algorithm Chrome uses for its own sending.
//
// Every outgoing packet gets a transport-wide sequence number (a header
// extension); the receiver reports when each one arrived (TWCC feedback);
// growing delays and losses mean the path is full. The estimator arrives on
// the channel once the peer connection has been created.
func (f *Factory) EstimatingAPI() (*webrtc.API, <-chan cc.BandwidthEstimator, error) {
	estimators := make(chan cc.BandwidthEstimator, 1)
	api, err := f.build(func(media *webrtc.MediaEngine, r *interceptor.Registry) error {
		controller, err := cc.NewInterceptor(func() (cc.BandwidthEstimator, error) {
			return gcc.NewSendSideBWE(
				gcc.SendSideBWEInitialBitrate(InitialEstimate),
				gcc.SendSideBWEMinBitrate(100_000),
				gcc.SendSideBWEMaxBitrate(8_000_000),
				// Packets go out as they arrive from publishers. Pacing
				// them would only add delay; the SFU controls its rate by
				// choosing layers instead.
				gcc.SendSideBWEPacer(gcc.NewNoOpPacer()),
			)
		})
		if err != nil {
			return err
		}
		controller.OnNewPeerConnection(func(_ string, e cc.BandwidthEstimator) {
			select {
			case estimators <- e:
			default:
			}
		})
		r.Add(controller)
		// Added after the controller so it runs first on the way out, and
		// the controller sees the sequence numbers it stamps.
		return webrtc.ConfigureTWCCHeaderExtensionSender(media, r)
	})
	return api, estimators, err
}

// InitialEstimate is where a viewer's bandwidth estimate starts, in bit/s,
// before any feedback has arrived.
const InitialEstimate = 1_000_000

func (f *Factory) build(extra func(*webrtc.MediaEngine, *interceptor.Registry) error) (*webrtc.API, error) {
	media := &webrtc.MediaEngine{}
	if err := registerCodecs(media); err != nil {
		return nil, err
	}
	interceptors, err := newInterceptors(media)
	if err != nil {
		return nil, err
	}
	if extra != nil {
		if err := extra(media, interceptors); err != nil {
			return nil, fmt.Errorf("register bandwidth estimation: %w", err)
		}
	}
	return webrtc.NewAPI(
		webrtc.WithMediaEngine(media),
		webrtc.WithInterceptorRegistry(interceptors),
		webrtc.WithSettingEngine(f.settings),
	), nil
}

// newInterceptors registers Pion's default RTP and RTCP helpers except one:
// generated sender reports.
//
// A sender report ties a stream's RTP timestamps to wall-clock time, and
// receivers line audio up with video by it (lip sync). Pion would stamp the
// tracks the SFU sends with the time each packet was forwarded. Video waits
// longer than audio in the sender's upload queue, so it would look as if it
// was captured later than it was, and receivers would play audio ahead of
// it. Instead the SFU forwards each publisher's own sender reports, which
// carry capture time (see sfu.forwardSenderReports).
func newInterceptors(media *webrtc.MediaEngine) (*interceptor.Registry, error) {
	r := &interceptor.Registry{}
	if err := webrtc.ConfigureNack(media, r); err != nil {
		return nil, fmt.Errorf("register NACK: %w", err)
	}
	receiverReports, err := report.NewReceiverInterceptor()
	if err != nil {
		return nil, fmt.Errorf("register receiver reports: %w", err)
	}
	r.Add(receiverReports)
	if err := webrtc.ConfigureSimulcastExtensionHeaders(media); err != nil {
		return nil, fmt.Errorf("register simulcast headers: %w", err)
	}
	if err := webrtc.ConfigureStatsInterceptor(r); err != nil {
		return nil, fmt.Errorf("register stats: %w", err)
	}
	if err := webrtc.ConfigureTWCCSender(media, r); err != nil {
		return nil, fmt.Errorf("register TWCC: %w", err)
	}
	return r, nil
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
	// Each audio packet's loudness, in a header extension (RFC 6464), so the
	// server can tell who is speaking without decoding any audio.
	return media.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: sdp.AudioLevelURI}, webrtc.RTPCodecTypeAudio,
	)
}

// Codec capabilities for tracks the server sends, matching registerCodecs.
var (
	VP8  = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000}
	Opus = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}
)
