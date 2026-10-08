// Command fitmeasure-server runs the Fitmeasure live sessions backend.
//
// For now it serves the SFU's test stages: small rooms at /room/ (WebSocket
// /ws/rooms/{room}) and the echo at /echo/ (WebSocket /ws/echo), plus an
// optional TURN server for clients that can't reach it directly.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/pion/webrtc/v4"
	"golang.org/x/crypto/acme"
	"golang.org/x/crypto/acme/autocert"

	"github.com/monqyClouds/Fitmeasure/server/internal/relay"
	"github.com/monqyClouds/Fitmeasure/server/internal/rtc"
	"github.com/monqyClouds/Fitmeasure/server/internal/sfu"
	"github.com/monqyClouds/Fitmeasure/server/internal/tlsmux"
	"github.com/monqyClouds/Fitmeasure/server/web"
)

type config struct {
	addr       string
	udpPort    int
	tcpPort    int
	publicIP   string
	stun       string
	tlsCert    string
	tlsKey     string
	domain     string
	turnDomain string
	turnPort   int
	relayPorts string
	certDir    string
	acmeEmail  string
	bwe        bool
}

func main() {
	// Settings come from flags, then environment variables, then .env in the
	// working directory, then the defaults below.
	if err := loadEnvFile(".env"); err != nil {
		slog.Error("reading .env", "err", err)
		os.Exit(2)
	}
	var c config
	flag.StringVar(&c.addr, "addr", envString("FITMEASURE_ADDR", ":8080"), "HTTP listen address, unless -domain is set (env FITMEASURE_ADDR)")
	flag.IntVar(&c.udpPort, "udp-port", envInt("FITMEASURE_UDP_PORT", 0), "single UDP port for all WebRTC media, 0 = a random port per connection (env FITMEASURE_UDP_PORT)")
	flag.IntVar(&c.tcpPort, "tcp-port", envInt("FITMEASURE_TCP_PORT", 0), "TCP port for WebRTC media when UDP is blocked, 0 = off (env FITMEASURE_TCP_PORT)")
	flag.StringVar(&c.publicIP, "public-ip", envString("FITMEASURE_PUBLIC_IP", ""), "public IP to advertise in ICE candidates and relay from; required for TURN (env FITMEASURE_PUBLIC_IP)")
	flag.StringVar(&c.stun, "stun", envString("FITMEASURE_STUN", ""), "comma-separated STUN URLs for the server's peer connections, e.g. stun:stun.l.google.com:19302 (env FITMEASURE_STUN)")
	flag.StringVar(&c.tlsCert, "tls-cert", envString("FITMEASURE_TLS_CERT", ""), "TLS certificate file; browsers only allow camera access over HTTPS, except on localhost (env FITMEASURE_TLS_CERT)")
	flag.StringVar(&c.tlsKey, "tls-key", envString("FITMEASURE_TLS_KEY", ""), "TLS key file (env FITMEASURE_TLS_KEY)")
	flag.StringVar(&c.domain, "domain", envString("FITMEASURE_DOMAIN", ""), "serve HTTPS for this domain on :443 with a Let's Encrypt certificate, and redirect :80 to it (env FITMEASURE_DOMAIN)")
	flag.StringVar(&c.turnDomain, "turn-domain", envString("FITMEASURE_TURN_DOMAIN", ""), "also serve TURN over TLS on :443 for this domain; needs -domain and -turn-port (env FITMEASURE_TURN_DOMAIN)")
	flag.IntVar(&c.turnPort, "turn-port", envInt("FITMEASURE_TURN_PORT", 0), "TURN over UDP and TCP on this port, usually 3478; 0 = no TURN (env FITMEASURE_TURN_PORT)")
	flag.StringVar(&c.relayPorts, "turn-relay-ports", envString("FITMEASURE_TURN_RELAY_PORTS", "50000-50199"), "UDP port range TURN relays from (env FITMEASURE_TURN_RELAY_PORTS)")
	flag.StringVar(&c.certDir, "cert-dir", envString("FITMEASURE_CERT_DIR", "certs"), "where Let's Encrypt certificates are kept, with -domain (env FITMEASURE_CERT_DIR)")
	flag.StringVar(&c.acmeEmail, "acme-email", envString("FITMEASURE_ACME_EMAIL", ""), "email Let's Encrypt may contact about certificates (env FITMEASURE_ACME_EMAIL)")
	flag.BoolVar(&c.bwe, "bwe", envString("FITMEASURE_BWE", "on") != "off", "fit each viewer's layers to an estimate of their bandwidth; FITMEASURE_BWE=off chooses by tile size only (env FITMEASURE_BWE)")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	if err := run(log, c); err != nil {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger, c config) error {
	if c.turnDomain != "" && (c.domain == "" || c.turnPort == 0) {
		return errors.New("-turn-domain needs -domain and -turn-port")
	}
	if c.domain != "" && c.tlsCert != "" {
		return errors.New("use either -domain (automatic certificates) or -tls-cert, not both")
	}

	rtcCfg := rtc.Config{UDPPort: c.udpPort, TCPPort: c.tcpPort, PublicIP: c.publicIP}
	if c.stun != "" {
		rtcCfg.ICEServers = []webrtc.ICEServer{{URLs: strings.Split(c.stun, ",")}}
	}
	factory, err := rtc.NewFactory(rtcCfg)
	if err != nil {
		return err
	}
	api, err := factory.API()
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// With a domain, :443 carries HTTPS and, by hostname, TURN over TLS.
	var mux *tlsmux.Mux
	var certs *autocert.Manager
	if c.domain != "" {
		hosts := []string{c.domain}
		if c.turnDomain != "" {
			hosts = append(hosts, c.turnDomain)
		}
		certs = &autocert.Manager{
			Prompt:     autocert.AcceptTOS,
			HostPolicy: autocert.HostWhitelist(hosts...),
			Cache:      autocert.DirCache(c.certDir),
			Email:      c.acmeEmail,
		}
		tlsCfg := &tls.Config{
			GetCertificate: certs.GetCertificate,
			// No HTTP/2: WebSockets need HTTP/1.1, and nothing here gains
			// from h2. acme-tls/1 lets Let's Encrypt validate over :443.
			NextProtos: []string{"http/1.1", acme.ALPNProto},
			MinVersion: tls.VersionTLS12,
		}
		ln, err := net.Listen("tcp", ":443")
		if err != nil {
			return err
		}
		mux = tlsmux.New(ln, tlsCfg, c.turnDomain)
		go func() { _ = mux.Serve() }()
		defer mux.Close()
	}

	var turn *relay.Server
	if c.turnPort != 0 {
		ip := net.ParseIP(c.publicIP)
		if ip == nil {
			return errors.New("TURN needs -public-ip: the address it relays from and to")
		}
		lo, hi, err := parsePortRange(c.relayPorts)
		if err != nil {
			return err
		}
		host := c.domain
		if host == "" {
			host = c.publicIP
		}
		turnCfg := relay.Config{
			PublicIP: ip, Port: c.turnPort,
			RelayMinPort: lo, RelayMaxPort: hi,
			Host: host, TLSHost: c.turnDomain, TLSPort: 443,
			Log: log,
		}
		if c.turnDomain != "" {
			turnCfg.TLSListener = mux.TURN()
		}
		if turn, err = relay.Start(turnCfg); err != nil {
			return err
		}
		defer turn.Close()
		log.Info("TURN listening", "port", c.turnPort, "relay_ports", c.relayPorts, "tls_host", c.turnDomain)
	}

	rooms := &sfu.Rooms{API: api, ICEServers: rtcCfg.ICEServers, Log: log}
	if c.bwe {
		rooms.SubscriberAPI = factory.EstimatingAPI
	}
	if turn != nil {
		rooms.ClientICEServers = turn.ICEServers
	}

	routes := http.NewServeMux()
	routes.Handle("GET /ws/echo", &sfu.Echo{API: api, ICEServers: rtcCfg.ICEServers, Log: log})
	routes.Handle("GET /ws/rooms/{room}", rooms)
	routes.Handle("GET /", web.Handler())
	routes.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})

	srv := &http.Server{Addr: c.addr, Handler: routes, ReadHeaderTimeout: 10 * time.Second}
	var redirect *http.Server
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
		if redirect != nil {
			_ = redirect.Shutdown(shutdown)
		}
	}()

	log.Info("listening", "addr", c.addr, "domain", c.domain, "tls", c.tlsCert != "", "udp_port", c.udpPort, "tcp_port", c.tcpPort, "public_ip", c.publicIP)
	switch {
	case c.domain != "":
		// :80 answers Let's Encrypt's HTTP challenges and sends everything
		// else to HTTPS.
		redirect = &http.Server{Addr: ":80", Handler: certs.HTTPHandler(nil), ReadHeaderTimeout: 10 * time.Second}
		go func() {
			if err := redirect.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Error("port 80", "err", err)
			}
		}()
		err = srv.Serve(mux.HTTP())
	case c.tlsCert != "":
		err = srv.ListenAndServeTLS(c.tlsCert, c.tlsKey)
	default:
		err = srv.ListenAndServe()
	}
	if errors.Is(err, http.ErrServerClosed) || errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

// parsePortRange parses "50000-50199".
func parsePortRange(s string) (uint16, uint16, error) {
	a, b, ok := strings.Cut(s, "-")
	lo, err1 := strconv.ParseUint(strings.TrimSpace(a), 10, 16)
	hi, err2 := strconv.ParseUint(strings.TrimSpace(b), 10, 16)
	if !ok || err1 != nil || err2 != nil || lo == 0 || lo > hi {
		return 0, 0, fmt.Errorf("invalid port range %q, want e.g. 50000-50199", s)
	}
	return uint16(lo), uint16(hi), nil
}
