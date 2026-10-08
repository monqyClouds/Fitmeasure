// Command fitmeasure-server runs the Fitmeasure live sessions backend.
//
// For now it serves stage 1 of the SFU: an echo test page at / and its
// WebSocket at /ws/echo.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/monqyClouds/Fitmeasure/server/internal/rtc"
	"github.com/monqyClouds/Fitmeasure/server/internal/sfu"
	"github.com/monqyClouds/Fitmeasure/server/web"
)

func main() {
	addr := flag.String("addr", ":8080", "HTTP listen address")
	udpPort := flag.Int("udp-port", 0, "single UDP port for all WebRTC media (0 = a random port per connection)")
	publicIP := flag.String("public-ip", "", "public IP to advertise in ICE candidates, when behind 1:1 NAT")
	stun := flag.String("stun", "", "comma-separated STUN URLs for the server's peer connections, e.g. stun:stun.l.google.com:19302")
	tlsCert := flag.String("tls-cert", "", "TLS certificate file; browsers only allow camera access over HTTPS, except on localhost")
	tlsKey := flag.String("tls-key", "", "TLS key file")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	if err := run(log, *addr, *udpPort, *publicIP, *stun, *tlsCert, *tlsKey); err != nil {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger, addr string, udpPort int, publicIP, stun, tlsCert, tlsKey string) error {
	cfg := rtc.Config{UDPPort: udpPort, PublicIP: publicIP}
	if stun != "" {
		cfg.ICEServers = []webrtc.ICEServer{{URLs: strings.Split(stun, ",")}}
	}
	api, err := rtc.NewAPI(cfg)
	if err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.Handle("GET /ws/echo", &sfu.Echo{API: api, ICEServers: cfg.ICEServers, Log: log})
	mux.Handle("GET /", web.Handler())
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})

	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()

	log.Info("listening", "addr", addr, "tls", tlsCert != "", "udp_port", udpPort, "public_ip", publicIP)
	if tlsCert != "" {
		err = srv.ListenAndServeTLS(tlsCert, tlsKey)
	} else {
		err = srv.ListenAndServe()
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
