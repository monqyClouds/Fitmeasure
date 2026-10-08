package shares

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"

	"github.com/monqyClouds/Fitmeasure/server/internal/limit"
)

// API serves shares over HTTP:
//
//	POST /api/shares       a Share  → 201 {"id", "link"}
//	GET  /api/shares/{id}  → 200 the Share, or 404
//	GET  /s/{id}           a page showing it, with a button to open it in the app
type API struct {
	Store *Store

	// AndroidPackage, when set, is the app the page's button opens.
	AndroidPackage string

	// CreatesPerHour per address; 0 means 60.
	CreatesPerHour int

	Log *slog.Logger

	once    sync.Once
	creates *limit.PerHour
}

// Register adds the API's routes to mux.
func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/shares", a.create)
	mux.HandleFunc("GET /api/shares/{id}", a.get)
	mux.HandleFunc("GET /s/{id}", a.page)
}

func (a *API) create(w http.ResponseWriter, r *http.Request) {
	a.once.Do(func() {
		n := a.CreatesPerHour
		if n == 0 {
			n = 60
		}
		a.creates = &limit.PerHour{N: n}
	})
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "that's too much to share at once")
		return
	}
	s, err := Parse(data)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if !a.creates.Allow(limit.ClientIP(r)) {
		writeError(w, http.StatusTooManyRequests, "too many shares; try again later")
		return
	}
	id, err := a.Store.Create(s)
	if err != nil {
		if a.Log != nil {
			a.Log.Error("shares: save", "err", err)
		}
		writeError(w, http.StatusInternalServerError, "couldn't save the share")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id, "link": link(r, id)})
}

func (a *API) get(w http.ResponseWriter, r *http.Request) {
	s, err := a.Store.Get(NormalizeID(r.PathValue("id")))
	if err != nil {
		writeError(w, http.StatusNotFound, ErrNotFound.Error())
		return
	}
	writeJSON(w, http.StatusOK, s)
}

func link(r *http.Request, id string) string { return limit.BaseURL(r) + "/s/" + id }

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// --- The page ---------------------------------------------------------------

//go:embed page.html
var pageHTML string

var pageTemplate = template.Must(template.New("share").Parse(pageHTML))

type pageVideo struct {
	URL, Title, Thumb, Source string
}

type pageExercise struct {
	Name, Tags, Notes, Targets string
	Videos                     []pageVideo
}

type pageDay struct {
	Name      string
	Exercises []pageExercise
}

type pageData struct {
	Found    bool
	Kind     string // "Exercise" or "Plan"
	Title    string
	Summary  string
	Image    string // for link previews
	Exercise *pageExercise
	Days     []pageDay
	AppLink  template.URL
	Link     string
}

func (a *API) page(w http.ResponseWriter, r *http.Request) {
	id := NormalizeID(r.PathValue("id"))
	data := pageData{Link: link(r, id)}
	if a.AndroidPackage != "" {
		data.AppLink = template.URL(fmt.Sprintf("intent://%s/s/%s#Intent;scheme=https;package=%s;end", r.Host, id, a.AndroidPackage))
	}
	s, err := a.Store.Get(id)
	if errors.Is(err, ErrNotFound) {
		w.WriteHeader(http.StatusNotFound)
	} else if err == nil {
		data.Found = true
		data.Title = s.Title()
		if s.Kind == KindExercise {
			e := toPage(*s.Exercise, "")
			data.Kind = "Exercise"
			data.Exercise = &e
			data.Summary = e.Tags
			if n := len(e.Videos); n > 0 {
				data.Summary += fmt.Sprintf(" · %d %s", n, plural(n, "video", "videos"))
			}
			for _, v := range e.Videos {
				if v.Thumb != "" {
					data.Image = v.Thumb
					break
				}
			}
		} else {
			data.Kind = "Plan"
			exercises := 0
			for _, d := range s.Plan.Days {
				day := pageDay{Name: d.Name}
				for _, it := range d.Items {
					e := toPage(it.Exercise, targets(it))
					day.Exercises = append(day.Exercises, e)
					exercises++
					if data.Image == "" && len(e.Videos) > 0 {
						data.Image = e.Videos[0].Thumb
					}
				}
				data.Days = append(data.Days, day)
			}
			data.Summary = fmt.Sprintf("%d %s · %d %s", len(s.Plan.Days), plural(len(s.Plan.Days), "day", "days"), exercises, plural(exercises, "exercise", "exercises"))
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = pageTemplate.Execute(w, data)
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

func toPage(e Exercise, targets string) pageExercise {
	p := pageExercise{Name: e.Name, Notes: e.Notes, Targets: targets}
	var tags []string
	for _, t := range []string{e.Muscle, e.Equipment} {
		if t != "" {
			tags = append(tags, strings.ToUpper(t[:1])+t[1:])
		}
	}
	p.Tags = strings.Join(tags, " · ")
	for _, v := range e.Videos {
		pv := pageVideo{URL: v.URL, Title: v.Title, Source: source(v.URL)}
		if id := youTubeID(v.URL); id != "" {
			pv.Thumb = "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg"
		}
		if pv.Title == "" {
			pv.Title = pv.Source
		}
		p.Videos = append(p.Videos, pv)
	}
	return p
}

var youTubeIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)

// youTubeID is the video ID in a YouTube link, or "".
func youTubeID(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.TrimPrefix(strings.TrimPrefix(strings.ToLower(u.Host), "www."), "m.")
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	var id string
	switch host {
	case "youtu.be":
		id = parts[0]
	case "youtube.com", "youtube-nocookie.com":
		if parts[0] == "watch" {
			id = u.Query().Get("v")
		} else if len(parts) >= 2 && (parts[0] == "shorts" || parts[0] == "embed" || parts[0] == "live") {
			id = parts[1]
		}
	}
	if youTubeIDPattern.MatchString(id) {
		return id
	}
	return ""
}

func source(raw string) string {
	if youTubeID(raw) != "" {
		return "YouTube"
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	return strings.TrimPrefix(strings.TrimPrefix(u.Host, "www."), "m.")
}

// targets reads an item's targets as the app shows them: "3 × 10 · 60 kg",
// "3 × 1:00", rest included.
func targets(it Item) string {
	var parts []string
	switch it.Exercise.Tracking {
	case "time":
		if it.DurationSec != nil {
			parts = append(parts, fmt.Sprintf("%d × %s", it.Sets, clock(*it.DurationSec)))
		} else {
			parts = append(parts, fmt.Sprintf("%d sets", it.Sets))
		}
	case "distance":
		parts = append(parts, fmt.Sprintf("%d %s", it.Sets, plural(it.Sets, "set", "sets")))
		if it.DistanceKm != nil {
			parts = append(parts, trim(*it.DistanceKm)+" km")
		}
		if it.DurationSec != nil {
			parts = append(parts, clock(*it.DurationSec))
		}
	default:
		if it.Reps != nil {
			parts = append(parts, fmt.Sprintf("%d × %d", it.Sets, *it.Reps))
		} else {
			parts = append(parts, fmt.Sprintf("%d sets", it.Sets))
		}
		if it.WeightKg != nil {
			parts = append(parts, trim(*it.WeightKg)+" kg")
		}
	}
	if it.RestSec != nil {
		parts = append(parts, "rest "+clock(*it.RestSec))
	}
	return strings.Join(parts, " · ")
}

func clock(secs int) string { return fmt.Sprintf("%d:%02d", secs/60, secs%60) }

func trim(v float64) string {
	if v == math.Trunc(v) {
		return fmt.Sprintf("%.0f", v)
	}
	return strings.TrimRight(fmt.Sprintf("%.2f", v), "0")
}
