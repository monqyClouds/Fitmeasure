package shares

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const plank = `{"kind": "exercise", "exercise": {
	"name": "  Plank ", "muscle": "core", "equipment": "bodyweight", "tracking": "time",
	"notes": "Squeeze your glutes.",
	"videos": [
		{"url": "https://youtu.be/dQw4w9WgXcQ", "title": "Perfect plank"},
		{"url": "media/1/plank.mp4"},
		{"url": "javascript:alert(1)"}
	]}}`

const plan = `{"kind": "plan", "plan": {"name": "Push Pull", "schedule": "weekly", "days": [
	{"name": "Push", "weekday": 1, "items": [
		{"exercise": {"name": "Bench Press", "muscle": "chest", "equipment": "barbell", "tracking": "reps"},
		 "sets": 4, "reps": 8, "weightKg": 62.5, "restSec": 90},
		{"exercise": {"name": "Plank", "muscle": "core", "equipment": "bodyweight", "tracking": "time",
		  "videos": [{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}]},
		 "sets": 3, "durationSec": 45, "weightKg": -3}
	]},
	{"name": "", "weekday": 9, "items": []}
]}}`

func TestParse(t *testing.T) {
	s, err := Parse([]byte(plank))
	if err != nil {
		t.Fatal(err)
	}
	e := s.Exercise
	if e.Name != "Plank" || len(e.Videos) != 1 || e.Videos[0].Title != "Perfect plank" {
		t.Fatalf("only web links travel: %+v", e)
	}

	s, err = Parse([]byte(plan))
	if err != nil {
		t.Fatal(err)
	}
	d := s.Plan.Days
	if *d[0].Weekday != 1 || d[1].Weekday != nil || d[1].Name != "Day 2" {
		t.Fatalf("days: %+v", d)
	}
	if d[0].Items[1].WeightKg != nil || *d[0].Items[1].DurationSec != 45 {
		t.Fatalf("targets: %+v", d[0].Items[1])
	}

	for _, bad := range []string{
		`{"kind": "workout"}`,
		`{"kind": "exercise"}`,
		`{"kind": "exercise", "exercise": {"name": " "}}`,
		`{"kind": "plan", "plan": {"name": "Empty", "days": []}}`,
		`not json`,
	} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestStoreAndAPI(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	(&API{Store: store, AndroidPackage: "com.fitmeasure.fitmeasure", CreatesPerHour: 2}).Register(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	post := func(body string) (int, map[string]string) {
		res, err := http.Post(srv.URL+"/api/shares", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out map[string]string
		_ = json.NewDecoder(res.Body).Decode(&out)
		return res.StatusCode, out
	}

	code, out := post(plan)
	if code != http.StatusCreated || NormalizeID(out["id"]) != out["id"] || out["link"] != srv.URL+"/s/"+out["id"] {
		t.Fatalf("create: %d %v", code, out)
	}
	id := out["id"]
	if code, _ := post(`{"kind": "nope"}`); code != http.StatusBadRequest {
		t.Fatalf("bad share: %d", code)
	}

	res, _ := http.Get(srv.URL + "/api/shares/" + id)
	var got Share
	_ = json.NewDecoder(res.Body).Decode(&got)
	res.Body.Close()
	if got.Kind != KindPlan || got.Plan.Name != "Push Pull" || got.V != 1 {
		t.Fatalf("get: %+v", got)
	}

	// The page shows the plan, its targets and videos, and opens the app.
	res, _ = http.Get(srv.URL + "/s/" + id)
	page, _ := io.ReadAll(res.Body)
	res.Body.Close()
	for _, want := range []string{
		"<title>Push Pull · Fitmeasure</title>",
		"4 × 8 · 62.5 kg · rest 1:30",
		"3 × 0:45",
		"▶ 1 video",
		`og:image" content="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"`,
		"intent://" + strings.TrimPrefix(srv.URL, "http://") + "/s/" + id + "#Intent;scheme=https;package=com.fitmeasure.fitmeasure;end",
	} {
		if !strings.Contains(string(page), want) {
			t.Errorf("page is missing %q", want)
		}
	}

	if code, _ := post(plank); code != http.StatusCreated {
		t.Fatalf("second share: %d", code)
	}
	if code, _ := post(plank); code != http.StatusTooManyRequests {
		t.Fatalf("third share in an hour: %d, want 429", code)
	}

	res, _ = http.Get(srv.URL + "/s/zzzzzzzz")
	res.Body.Close()
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown share page: %d", res.StatusCode)
	}
}

func TestExpiry(t *testing.T) {
	dir := t.TempDir()
	store, _ := Open(dir)
	s, _ := Parse([]byte(plank))
	id, err := store.Create(s)
	if err != nil {
		t.Fatal(err)
	}
	// Opened recently: kept, and opening it keeps it longer.
	old := time.Now().Add(-300 * 24 * time.Hour)
	os.Chtimes(filepath.Join(dir, id+".json"), old, old)
	if _, err := store.Get(id); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Now().Add(200 * 24 * time.Hour) }
	store.Prune()
	if _, err := store.Get(id); err != nil {
		t.Fatal("a share opened 200 days ago was removed")
	}
	store.now = func() time.Time { return time.Now().Add(800 * 24 * time.Hour) }
	store.Prune()
	if _, err := os.Stat(filepath.Join(dir, id+".json")); !os.IsNotExist(err) {
		t.Fatal("a share unopened for over a year is still there")
	}
}
