// Package limit rate-limits requests by address, for the endpoints anyone
// can call without an account.
package limit

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// PerHour lets each address do something N times in any hour.
type PerHour struct {
	N int

	mu   sync.Mutex
	seen map[string][]time.Time
}

// Allow reports whether ip may go ahead now, and counts it if so.
func (l *PerHour) Allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.seen == nil {
		l.seen = map[string][]time.Time{}
	}
	now := time.Now()
	recent := l.seen[ip][:0]
	for _, t := range l.seen[ip] {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	if len(recent) >= l.N {
		l.seen[ip] = recent
		return false
	}
	l.seen[ip] = append(recent, now)
	// Forget addresses that have gone quiet, now and then.
	if len(l.seen) > 10000 {
		for k, ts := range l.seen {
			if len(ts) == 0 || now.Sub(ts[len(ts)-1]) > time.Hour {
				delete(l.seen, k)
			}
		}
	}
	return true
}

// ClientIP is the request's address; behind our nginx (a loopback peer),
// the one nginx passes on.
func ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		if real := r.Header.Get("X-Real-IP"); real != "" {
			return real
		}
	}
	return host
}

// BaseURL is where the request came to, for links back to this server:
// https, except plain http on a local address (a test or a LAN server).
func BaseURL(r *http.Request) string {
	scheme := "https"
	if r.TLS == nil && r.Header.Get("X-Forwarded-Proto") != "https" && isLocal(r.Host) {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

func isLocal(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		host = hostport
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}
