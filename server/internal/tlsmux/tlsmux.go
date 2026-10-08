// Package tlsmux shares one TLS port between HTTPS and TURN over TLS.
//
// Strict networks (some offices, hotels, schools) only let traffic out on port
// 443, so TURN must be reachable there too, but HTTPS already uses it. Both
// speak TLS, and in its first message (the ClientHello) a TLS client names
// the host it wants (SNI). The mux finishes the handshake, then hands the
// connection to TURN if it asked for the TURN hostname and to HTTP otherwise.
package tlsmux

import (
	"crypto/tls"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/acme"
)

const handshakeTimeout = 10 * time.Second

// Mux accepts TLS connections and sorts them by requested hostname.
type Mux struct {
	ln       net.Listener
	config   *tls.Config
	turnHost string
	http     *listener
	turn     *listener
}

// New wraps ln. Connections asking for turnHost go to TURN(); everything else
// to HTTP(). Call Serve to start accepting.
func New(ln net.Listener, config *tls.Config, turnHost string) *Mux {
	return &Mux{
		ln:       ln,
		config:   config,
		turnHost: turnHost,
		http:     newListener(ln.Addr()),
		turn:     newListener(ln.Addr()),
	}
}

// HTTP returns a listener of TLS connections meant for the web server.
func (m *Mux) HTTP() net.Listener { return m.http }

// TURN returns a listener of TLS connections meant for the TURN server.
func (m *Mux) TURN() net.Listener { return m.turn }

// Serve accepts connections until the underlying listener is closed.
func (m *Mux) Serve() error {
	defer m.http.Close()
	defer m.turn.Close()
	for {
		conn, err := m.ln.Accept()
		if err != nil {
			return err
		}
		go m.route(conn)
	}
}

// Close stops accepting.
func (m *Mux) Close() error { return m.ln.Close() }

func (m *Mux) route(conn net.Conn) {
	tlsConn := tls.Server(conn, m.config)
	_ = conn.SetDeadline(time.Now().Add(handshakeTimeout))
	if err := tlsConn.Handshake(); err != nil {
		conn.Close()
		return
	}
	_ = conn.SetDeadline(time.Time{})

	state := tlsConn.ConnectionState()
	switch {
	case state.NegotiatedProtocol == acme.ALPNProto:
		// A Let's Encrypt validation (TLS-ALPN-01): the handshake itself
		// answered it, nothing more to say.
		tlsConn.Close()
	case m.turnHost != "" && state.ServerName == m.turnHost:
		m.turn.deliver(tlsConn)
	default:
		m.http.deliver(tlsConn)
	}
}

// listener is a net.Listener fed by the mux.
type listener struct {
	addr      net.Addr
	conns     chan net.Conn
	done      chan struct{}
	closeOnce sync.Once
}

func newListener(addr net.Addr) *listener {
	return &listener{addr: addr, conns: make(chan net.Conn), done: make(chan struct{})}
}

func (l *listener) deliver(c net.Conn) {
	select {
	case l.conns <- c:
	case <-l.done:
		c.Close()
	}
}

func (l *listener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *listener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return nil
}

func (l *listener) Addr() net.Addr { return l.addr }
