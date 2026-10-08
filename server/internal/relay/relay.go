// Package relay runs the TURN server that clients fall back to when they
// can't reach the SFU directly.
//
// Most of the time a phone reaches the SFU directly: the SFU has a public IP,
// and ICE finds the path. TURN is for the rest: networks that block UDP, or
// only let traffic out on port 443. The client then sends its media to the
// TURN server over UDP, TCP or TLS, and the TURN server relays it on to the
// SFU over UDP. Here both run in one process on one machine, so the relay leg
// never leaves the server.
//
// Credentials are short-lived and minted per participant (the "TURN REST"
// scheme): the username is "expiry:participant" and the password an HMAC of
// it with a secret only this process knows. Nothing has to be stored, and a
// leaked credential stops working by itself.
package relay

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"github.com/pion/webrtc/v4"
)

// Config describes how the TURN server listens and what it relays to.
type Config struct {
	// PublicIP is where relayed media leaves from, and the only address the
	// server relays to: the SFU on the same machine. Without that limit, an
	// open TURN server lets anyone with credentials reach any address the
	// server can, including private ones such as a cloud metadata service.
	PublicIP net.IP

	// Port for TURN over UDP and plain TCP, usually 3478.
	Port int

	// TLSListener, when set, accepts TURN over TLS (turns:). It is usually
	// port 443, shared with HTTPS, for networks that allow nothing else.
	TLSListener net.Listener

	// RelayMinPort and RelayMaxPort bound the UDP ports allocated for
	// relaying, so a firewall only needs that range open.
	RelayMinPort, RelayMaxPort uint16

	// Host is the name or address clients use in turn: URLs, and TLSHost the
	// name in turns: URLs (which must match the TLS certificate).
	Host, TLSHost string
	TLSPort       int

	// CredentialTTL is how long minted credentials stay valid.
	CredentialTTL time.Duration

	Log *slog.Logger
}

// Server is a running TURN server.
type Server struct {
	cfg    Config
	secret string
	turn   *turn.Server
}

// Start listens and serves TURN until Close.
func Start(cfg Config) (*Server, error) {
	if cfg.PublicIP == nil {
		return nil, fmt.Errorf("relay: a public IP is required")
	}
	if cfg.CredentialTTL == 0 {
		cfg.CredentialTTL = 12 * time.Hour
	}
	secretBytes := make([]byte, 32)
	if _, err := rand.Read(secretBytes); err != nil {
		return nil, err
	}
	secret := hex.EncodeToString(secretBytes)

	udp, tcp, err := listen(cfg.Port)
	if err != nil {
		return nil, err
	}
	cfg.Port = udp.LocalAddr().(*net.UDPAddr).Port // in case it was 0

	relayAddrs := func() turn.RelayAddressGenerator {
		return &turn.RelayAddressGeneratorPortRange{
			RelayAddress: cfg.PublicIP,
			Address:      "0.0.0.0",
			MinPort:      cfg.RelayMinPort,
			MaxPort:      cfg.RelayMaxPort,
		}
	}
	onlyToSFU := func(_ net.Addr, peer net.IP) bool {
		return peer.Equal(cfg.PublicIP)
	}
	listeners := []turn.ListenerConfig{{Listener: tcp, RelayAddressGenerator: relayAddrs(), PermissionHandler: onlyToSFU}}
	if cfg.TLSListener != nil {
		listeners = append(listeners, turn.ListenerConfig{Listener: cfg.TLSListener, RelayAddressGenerator: relayAddrs(), PermissionHandler: onlyToSFU})
	}

	logs := logging.NewDefaultLoggerFactory()
	logs.DefaultLogLevel = logging.LogLevelWarn
	srv, err := turn.NewServer(turn.ServerConfig{
		Realm:             "fitmeasure",
		AuthHandler:       turn.LongTermTURNRESTAuthHandler(secret, logs.NewLogger("turn")),
		PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: udp, RelayAddressGenerator: relayAddrs(), PermissionHandler: onlyToSFU}},
		ListenerConfigs:   listeners,
		LoggerFactory:     logs,
	})
	if err != nil {
		udp.Close()
		tcp.Close()
		return nil, fmt.Errorf("relay: %w", err)
	}
	return &Server{cfg: cfg, secret: secret, turn: srv}, nil
}

// listen opens UDP and TCP on the same port. For port 0 it picks a free UDP
// port and tries again if TCP happens to be taken there.
func listen(port int) (net.PacketConn, net.Listener, error) {
	for attempt := 0; ; attempt++ {
		addr := net.JoinHostPort("", strconv.Itoa(port))
		udp, err := net.ListenPacket("udp4", addr)
		if err != nil {
			return nil, nil, fmt.Errorf("relay: listen UDP %s: %w", addr, err)
		}
		addr = net.JoinHostPort("", strconv.Itoa(udp.LocalAddr().(*net.UDPAddr).Port))
		tcp, err := net.Listen("tcp4", addr)
		if err == nil {
			return udp, tcp, nil
		}
		udp.Close()
		if port != 0 || attempt == 9 {
			return nil, nil, fmt.Errorf("relay: listen TCP %s: %w", addr, err)
		}
	}
}

// Port is the UDP and TCP port the server listens on.
func (s *Server) Port() int { return s.cfg.Port }

// Allocations is the number of relays currently in use.
func (s *Server) Allocations() int { return s.turn.AllocationCount() }

// Close stops the server.
func (s *Server) Close() error {
	return s.turn.Close()
}

// ICEServers returns the STUN and TURN servers a participant's browser or app
// should use, with credentials minted for them. Clients try every URL and ICE
// keeps whichever path works best; direct paths to the SFU win over relays.
func (s *Server) ICEServers(participant string) ([]webrtc.ICEServer, error) {
	username, password, err := turn.GenerateLongTermTURNRESTCredentials(s.secret, participant, s.cfg.CredentialTTL)
	if err != nil {
		return nil, err
	}
	hostPort := net.JoinHostPort(s.cfg.Host, strconv.Itoa(s.cfg.Port))
	urls := []string{
		"turn:" + hostPort + "?transport=udp",
		"turn:" + hostPort + "?transport=tcp",
	}
	if s.cfg.TLSListener != nil && s.cfg.TLSHost != "" {
		urls = append(urls, "turns:"+net.JoinHostPort(s.cfg.TLSHost, strconv.Itoa(s.cfg.TLSPort))+"?transport=tcp")
	}
	return []webrtc.ICEServer{
		// The TURN server also answers STUN, which tells a client its public
		// address (a "server reflexive" candidate).
		{URLs: []string{"stun:" + hostPort}},
		{URLs: urls, Username: username, Credential: password},
	}, nil
}
