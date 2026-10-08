package directory

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync"

	"github.com/monqyClouds/Fitmeasure/server/internal/limit"
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

	once    sync.Once
	creates *limit.PerHour
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
	a.once.Do(func() {
		n := a.CreatesPerHour
		if n == 0 {
			n = 30
		}
		a.creates = &limit.PerHour{N: n}
	})
	if !a.creates.Allow(limit.ClientIP(r)) {
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
func Link(r *http.Request, id string) string { return limit.BaseURL(r) + "/r/" + id }

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
