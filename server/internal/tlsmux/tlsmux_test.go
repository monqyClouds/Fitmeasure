package tlsmux

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"testing"
	"time"
)

func selfSigned(t *testing.T, hosts ...string) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: hosts[0]},
		DNSNames:     hosts,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// Connections are sorted by the hostname the client asks for.
func TestRoutesBySNI(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	cfg := &tls.Config{Certificates: []tls.Certificate{selfSigned(t, "live.test", "turn.test")}}
	m := New(ln, cfg, "turn.test")
	go m.Serve()
	t.Cleanup(func() { m.Close() })

	for _, tc := range []struct {
		host string
		want net.Listener
	}{
		{"turn.test", m.TURN()},
		{"live.test", m.HTTP()},
		{"other.test", m.HTTP()},
	} {
		accepted := make(chan net.Conn, 1)
		go func() {
			c, err := tc.want.Accept()
			if err == nil {
				accepted <- c
			}
		}()

		client, err := tls.Dial("tcp", ln.Addr().String(), &tls.Config{ServerName: tc.host, InsecureSkipVerify: true})
		if err != nil {
			t.Fatalf("%s: %v", tc.host, err)
		}
		if _, err := client.Write([]byte("hi")); err != nil {
			t.Fatal(err)
		}

		select {
		case c := <-accepted:
			buf := make([]byte, 2)
			if _, err := c.Read(buf); err != nil || string(buf) != "hi" {
				t.Fatalf("%s: read %q, %v", tc.host, buf, err)
			}
			c.Close()
		case <-time.After(5 * time.Second):
			t.Fatalf("%s: connection didn't reach the expected listener", tc.host)
		}
		client.Close()
	}
}
