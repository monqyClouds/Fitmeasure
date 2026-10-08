package relay

import (
	"io"
	"log/slog"
	"net"
	"strconv"
	"testing"

	"github.com/pion/turn/v5"
)

func startRelay(t *testing.T) *Server {
	t.Helper()
	s, err := Start(Config{
		PublicIP:     net.IPv4(127, 0, 0, 1),
		Host:         "127.0.0.1",
		RelayMinPort: 40000,
		RelayMaxPort: 40100,
		Log:          slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func newClient(t *testing.T, s *Server, username, password string) *turn.Client {
	t.Helper()
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	c, err := turn.NewClient(&turn.ClientConfig{
		TURNServerAddr: "127.0.0.1:" + strconv.Itoa(s.Port()),
		Username:       username,
		Password:       password,
		Realm:          "fitmeasure",
		Conn:           conn,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	if err := c.Listen(); err != nil {
		t.Fatal(err)
	}
	return c
}

func credentials(t *testing.T, s *Server) (string, string) {
	t.Helper()
	servers, err := s.ICEServers("tester")
	if err != nil {
		t.Fatal(err)
	}
	for _, srv := range servers {
		if srv.Username != "" {
			return srv.Username, srv.Credential.(string)
		}
	}
	t.Fatal("no TURN credentials in ICE servers")
	return "", ""
}

// The relay only forwards to the SFU's own address; anything else, such as
// a private network or a cloud metadata service, is refused.
func TestRelayOnlyToSFU(t *testing.T) {
	s := startRelay(t)
	user, pass := credentials(t, s)
	c := newClient(t, s, user, pass)

	if _, err := c.Allocate(); err != nil {
		t.Fatalf("allocate: %v", err)
	}
	if s.Allocations() != 1 {
		t.Fatalf("got %d allocations, want 1", s.Allocations())
	}
	if err := c.CreatePermission(&net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7882}); err != nil {
		t.Fatalf("permission to the SFU refused: %v", err)
	}
	for _, ip := range []net.IP{net.IPv4(169, 254, 169, 254), net.IPv4(10, 0, 0, 1), net.IPv4(8, 8, 8, 8)} {
		if err := c.CreatePermission(&net.UDPAddr{IP: ip, Port: 80}); err == nil {
			t.Errorf("permission to %s granted, want refused", ip)
		}
	}
}

func TestRelayRejectsBadCredentials(t *testing.T) {
	s := startRelay(t)
	user, _ := credentials(t, s)
	c := newClient(t, s, user, "wrong")
	if _, err := c.Allocate(); err == nil {
		t.Fatal("allocated with a wrong password")
	}
}

func TestICEServersURLs(t *testing.T) {
	s := startRelay(t)
	servers, err := s.ICEServers("tester")
	if err != nil {
		t.Fatal(err)
	}
	port := strconv.Itoa(s.Port())
	want := []string{"stun:127.0.0.1:" + port, "turn:127.0.0.1:" + port + "?transport=udp", "turn:127.0.0.1:" + port + "?transport=tcp"}
	var got []string
	for _, srv := range servers {
		got = append(got, srv.URLs...)
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}
