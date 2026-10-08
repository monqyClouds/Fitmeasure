package directory

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNormalizeID(t *testing.T) {
	for in, want := range map[string]string{
		"k7f3qz":                             "k7f3qz",
		" K7F-3QZ ":                          "k7f3qz",
		"k7f 3qz":                            "k7f3qz",
		"https://live.somto.si/r/k7f3qz":     "k7f3qz",
		"https://live.somto.si/r/k7f3qz?x=1": "k7f3qz",
		"Join me: https://x.y/r/K7F3QZ/":     "k7f3qz",
		"k7f3q":                              "", // too short
		"k7f3qzz":                            "", // too long
		"k0f3qz":                             "", // 0 is never used
		"k7f3q!":                             "",
	} {
		if got := NormalizeID(in); got != want {
			t.Errorf("NormalizeID(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCreateSaveLoadExpire(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rooms.json")
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	d, err := Open(path, Options{Now: clock})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Create("  \t "); err != ErrNoName {
		t.Fatalf("blank name: got %v, want ErrNoName", err)
	}
	r, err := d.Create("  Tuesday \n HIIT  ")
	if err != nil {
		t.Fatal(err)
	}
	if r.Name != "Tuesday HIIT" || NormalizeID(r.ID) != r.ID || len(r.HostKey) < 20 {
		t.Fatalf("got %+v", r)
	}
	long, _ := d.Create(strings.Repeat("é", 100))
	if n := len([]rune(long.Name)); n != MaxNameLength {
		t.Fatalf("long name kept %d characters, want %d", n, MaxNameLength)
	}
	if !d.IsHostKey(r.ID, r.HostKey) || d.IsHostKey(r.ID, "") || d.IsHostKey(r.ID, "nope") || d.IsHostKey(long.ID, r.HostKey) {
		t.Fatal("host keys mixed up")
	}

	// Saved as soon as created: a restart keeps it.
	d2, err := Open(path, Options{Now: clock})
	if err != nil {
		t.Fatal(err)
	}
	if name, ok := d2.Name(r.ID); !ok || name != "Tuesday HIIT" {
		t.Fatalf("after reopening: %q %v", name, ok)
	}

	// Used rooms last; unused ones are forgotten after the expiry.
	now = now.Add(20 * 24 * time.Hour)
	d2.Touch(r.ID)
	now = now.Add(20 * 24 * time.Hour)
	if _, ok := d2.Get(r.ID); !ok {
		t.Fatal("a room used 20 days ago expired")
	}
	if _, ok := d2.Get(long.ID); ok {
		t.Fatal("a room unused for 40 days is still there")
	}
	if err := d2.Save(); err != nil {
		t.Fatal(err)
	}
	d3, _ := Open(path, Options{Now: clock})
	if _, ok := d3.Get(long.ID); ok {
		t.Fatal("the expired room was saved")
	}
	if _, ok := d3.Get(r.ID); !ok {
		t.Fatal("the used room wasn't saved")
	}
}

func TestMaxRooms(t *testing.T) {
	d, _ := Open("", Options{MaxRooms: 2})
	d.Create("a")
	d.Create("b")
	if _, err := d.Create("c"); err != ErrTooMany {
		t.Fatalf("got %v, want ErrTooMany", err)
	}
}

func TestAPI(t *testing.T) {
	d, _ := Open("", Options{})
	mux := http.NewServeMux()
	(&API{Dir: d, People: func(string) int { return 3 }, CreatesPerHour: 2}).Register(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	create := func(body string) (*http.Response, map[string]any) {
		res, err := http.Post(srv.URL+"/api/rooms", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(res.Body).Decode(&out)
		return res, out
	}

	res, room := create(`{"name": "Tuesday HIIT"}`)
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("create: %d %v", res.StatusCode, room)
	}
	id := room["id"].(string)
	if room["hostKey"] == "" || room["link"] != srv.URL+"/r/"+id {
		t.Fatalf("create: %v", room)
	}
	if res, out := create(`{"name": ""}`); res.StatusCode != http.StatusBadRequest {
		t.Fatalf("blank name: %d %v", res.StatusCode, out)
	}
	if res, _ := create(`{"name": "Third"}`); res.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("third create in an hour: %d, want 429", res.StatusCode)
	}

	// Anyone can look a room up by ID (as typed), but not get its host key.
	res, err := http.Get(srv.URL + "/api/rooms/" + strings.ToUpper(id[:3]) + "-" + id[3:])
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.NewDecoder(res.Body).Decode(&got)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || got["name"] != "Tuesday HIIT" || got["people"] != 3.0 || got["hostKey"] != nil {
		t.Fatalf("get: %d %v", res.StatusCode, got)
	}

	res, _ = http.Get(srv.URL + "/api/rooms/zzzzzz")
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown room: %d, want 404", res.StatusCode)
	}
}
