package directory

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"
)

// API serves the directory over HTTP:
//
//	POST /api/rooms        {"name": "Tuesday HIIT"}  → 201 {"id", "name", "hostKey", "link"}
//	GET  /api/rooms/{id}   → 200 {"id", "name", "people"}, or 404
//
// Anyone may create a room (there are no accounts yet), so creation is
// limited per address.
type API struct {
	Dir *Directory

	// People, when set, says how many are in a room now.
	People func(id string) int

	// CreatesPerHour per address; 0 means 30.
	CreatesPerHour int

	Log *slog.Logger

	mu      sync.Mutex
	creates map[string][]time.Time
}

// Register adds the API's routes to mux.
func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/rooms", a.create)
	mux.HandleFunc("GET /api/rooms/{id}", a.get)
}

type roomJSON struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	HostKey string `json:"hostKey,omitempty"`
	Link    string `json:"link,omitempty"`
	People  *int   `json:"people,omitempty"`
}

func (a *API) create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "expected {\"name\": \"…\"}")
		return
	}
	if !a.allow(clientIP(r)) {
		writeError(w, http.StatusTooManyRequests, "too many rooms created; try again later")
		return
	}
	room, err := a.Dir.Create(req.Name)
	switch {
	case errors.Is(err, ErrNoName):
		writeError(w, http.StatusBadRequest, err.Error())
		return
	case errors.Is(err, ErrTooMany):
		writeError(w, http.StatusServiceUnavailable, err.Error())
		return
	case err != nil:
		// Created, but not saved: it works until a restart.
		if a.Log != nil {
			a.Log.Error("rooms: save", "err", err)
		}
	}
	writeJSON(w, http.StatusCreated, roomJSON{
		ID:      room.ID,
		Name:    room.Name,
		HostKey: room.HostKey,
		Link:    Link(r, room.ID),
	})
}

func (a *API) get(w http.ResponseWriter, r *http.Request) {
	id := NormalizeID(r.PathValue("id"))
	room, ok := a.Dir.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, ErrNotFound.Error())
		return
	}
	out := roomJSON{ID: room.ID, Name: room.Name, Link: Link(r, room.ID)}
	if a.People != nil {
		n := a.People(room.ID)
		out.People = &n
	}
	writeJSON(w, http.StatusOK, out)
}

// Link is the room's shareable address, on the host the request came to.
func Link(r *http.Request, id string) string {
	scheme := "https"
	if r.TLS == nil && r.Header.Get("X-Forwarded-Proto") != "https" && isLoopbackHost(r.Host) {
		scheme = "http"
	}
	return scheme + "://" + r.Host + "/r/" + id
}

func isLoopbackHost(hostport string) bool {
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

// allow reports whether ip may create another room now, and counts it.
func (a *API) allow(ip string) bool {
	limit := a.CreatesPerHour
	if limit == 0 {
		limit = 30
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creates == nil {
		a.creates = map[string][]time.Time{}
	}
	now := time.Now()
	recent := a.creates[ip][:0]
	for _, t := range a.creates[ip] {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	if len(recent) >= limit {
		a.creates[ip] = recent
		return false
	}
	a.creates[ip] = append(recent, now)
	// Forget addresses that have gone quiet, now and then.
	if len(a.creates) > 10000 {
		for k, ts := range a.creates {
			if len(ts) == 0 || now.Sub(ts[len(ts)-1]) > time.Hour {
				delete(a.creates, k)
			}
		}
	}
	return true
}

// clientIP is the request's address; behind our nginx (a loopback peer),
// the one nginx passes on.
func clientIP(r *http.Request) string {
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
