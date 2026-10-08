// Package shares keeps exercises and plans people share from the app: a
// snapshot, with its video links, behind a short link (live.somto.si/s/…)
// that opens in the app to import it, or in a browser as a preview.
//
// A share is a snapshot: editing the exercise or plan afterwards doesn't
// change it. Shares unopened for a year are forgotten.
package shares

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

// IDLength is how many characters a share ID has.
const IDLength = 8

// idAlphabet leaves out characters easily mistaken for others, as room IDs do.
const idAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

// Limits on what's shared.
const (
	MaxBytes          = 64 << 10
	maxDays           = 14
	maxItemsPerDay    = 40
	maxVideos         = 20
	maxText           = 60
	maxNotes          = 1000
	DefaultExpiry     = 365 * 24 * time.Hour
	KindExercise      = "exercise"
	KindPlan          = "plan"
	currentVersion    = 1
	maxURL            = 500
	maxPositiveNumber = 100000
)

var (
	ErrNotFound = errors.New("nothing is shared at that link")
	errInvalid  = errors.New("invalid share")
)

// Video is a link to a video showing an exercise.
type Video struct {
	URL   string `json:"url"`
	Title string `json:"title,omitempty"`
}

// Exercise is an exercise as shared: what it is, and its videos.
type Exercise struct {
	Name      string  `json:"name"`
	Muscle    string  `json:"muscle"`
	Equipment string  `json:"equipment"`
	Tracking  string  `json:"tracking"`
	Notes     string  `json:"notes,omitempty"`
	Videos    []Video `json:"videos,omitempty"`
}

// Item is an exercise in a plan day, with its targets.
type Item struct {
	Exercise    Exercise `json:"exercise"`
	Sets        int      `json:"sets"`
	Reps        *int     `json:"reps,omitempty"`
	WeightKg    *float64 `json:"weightKg,omitempty"`
	DurationSec *int     `json:"durationSec,omitempty"`
	DistanceKm  *float64 `json:"distanceKm,omitempty"`
	RestSec     *int     `json:"restSec,omitempty"`
}

// Day is a plan's training day.
type Day struct {
	Name    string `json:"name"`
	Weekday *int   `json:"weekday,omitempty"` // 1 = Monday; weekly plans only
	Items   []Item `json:"items"`
}

// Plan is a whole plan.
type Plan struct {
	Name     string `json:"name"`
	Schedule string `json:"schedule"` // "weekly" or "rotation"
	Days     []Day  `json:"days"`
}

// Share is what's shared: one exercise, or a plan.
type Share struct {
	V        int       `json:"v"`
	Kind     string    `json:"kind"`
	Exercise *Exercise `json:"exercise,omitempty"`
	Plan     *Plan     `json:"plan,omitempty"`
}

// Title is what the share is called.
func (s *Share) Title() string {
	if s.Kind == KindPlan {
		return s.Plan.Name
	}
	return s.Exercise.Name
}

// Parse reads and checks a share, as sent by the app.
func Parse(data []byte) (*Share, error) {
	if len(data) > MaxBytes {
		return nil, fmt.Errorf("%w: too big", errInvalid)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	var s Share
	if err := dec.Decode(&s); err != nil {
		return nil, fmt.Errorf("%w: %v", errInvalid, err)
	}
	s.V = currentVersion
	switch s.Kind {
	case KindExercise:
		if s.Exercise == nil {
			return nil, fmt.Errorf("%w: no exercise", errInvalid)
		}
		s.Plan = nil
		if err := s.Exercise.clean(); err != nil {
			return nil, err
		}
	case KindPlan:
		if s.Plan == nil {
			return nil, fmt.Errorf("%w: no plan", errInvalid)
		}
		s.Exercise = nil
		if err := s.Plan.clean(); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("%w: kind must be exercise or plan", errInvalid)
	}
	return &s, nil
}

func (e *Exercise) clean() error {
	e.Name = clip(e.Name, maxText)
	if e.Name == "" {
		return fmt.Errorf("%w: an exercise needs a name", errInvalid)
	}
	e.Muscle, e.Equipment, e.Tracking = clip(e.Muscle, 20), clip(e.Equipment, 20), clip(e.Tracking, 20)
	e.Notes = clip(e.Notes, maxNotes)
	if len(e.Videos) > maxVideos {
		e.Videos = e.Videos[:maxVideos]
	}
	videos := e.Videos[:0]
	for _, v := range e.Videos {
		u, err := url.Parse(strings.TrimSpace(v.URL))
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(v.URL) > maxURL {
			continue // only web links travel; files on a phone don't
		}
		videos = append(videos, Video{URL: u.String(), Title: clip(v.Title, 120)})
	}
	e.Videos = videos
	return nil
}

func (p *Plan) clean() error {
	p.Name = clip(p.Name, maxText)
	if p.Name == "" {
		return fmt.Errorf("%w: a plan needs a name", errInvalid)
	}
	if p.Schedule != "weekly" && p.Schedule != "rotation" {
		p.Schedule = "rotation"
	}
	if len(p.Days) == 0 || len(p.Days) > maxDays {
		return fmt.Errorf("%w: a plan has 1 to %d days", errInvalid, maxDays)
	}
	for i := range p.Days {
		d := &p.Days[i]
		d.Name = clip(d.Name, maxText)
		if d.Name == "" {
			d.Name = fmt.Sprintf("Day %d", i+1)
		}
		if d.Weekday != nil && (*d.Weekday < 1 || *d.Weekday > 7 || p.Schedule != "weekly") {
			d.Weekday = nil
		}
		if len(d.Items) > maxItemsPerDay {
			return fmt.Errorf("%w: a day has at most %d exercises", errInvalid, maxItemsPerDay)
		}
		for j := range d.Items {
			it := &d.Items[j]
			if err := it.Exercise.clean(); err != nil {
				return err
			}
			if it.Sets < 1 || it.Sets > 50 {
				it.Sets = 3
			}
			it.Reps = positiveInt(it.Reps)
			it.DurationSec = positiveInt(it.DurationSec)
			it.RestSec = positiveInt(it.RestSec)
			it.WeightKg = positiveFloat(it.WeightKg)
			it.DistanceKm = positiveFloat(it.DistanceKm)
		}
	}
	return nil
}

func positiveInt(v *int) *int {
	if v == nil || *v <= 0 || *v > maxPositiveNumber {
		return nil
	}
	return v
}

func positiveFloat(v *float64) *float64 {
	if v == nil || *v <= 0 || *v > maxPositiveNumber {
		return nil
	}
	return v
}

// clip trims s and shortens it to n characters.
func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > n {
		s = strings.TrimSpace(string([]rune(s)[:n]))
	}
	return s
}

// Store keeps shares as files in a folder, one per share. A file's
// modification time is when it was last opened.
type Store struct {
	dir    string
	expiry time.Duration
	now    func() time.Time
}

// Open uses dir for shares, creating it if needed.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir, expiry: DefaultExpiry, now: time.Now}, nil
}

// Create saves s and returns its ID.
func (st *Store) Create(s *Share) (string, error) {
	data, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	for {
		id := randomID()
		f, err := os.OpenFile(st.path(id), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		_, werr := f.Write(data)
		if cerr := f.Close(); werr == nil {
			werr = cerr
		}
		if werr != nil {
			os.Remove(f.Name())
			return "", werr
		}
		return id, nil
	}
}

// Get returns the share with id, and marks it as opened.
func (st *Store) Get(id string) (*Share, error) {
	if NormalizeID(id) != id {
		return nil, ErrNotFound
	}
	path := st.path(id)
	info, err := os.Stat(path)
	if err != nil {
		return nil, ErrNotFound
	}
	now := st.now()
	if now.Sub(info.ModTime()) > st.expiry {
		os.Remove(path)
		return nil, ErrNotFound
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, ErrNotFound
	}
	var s Share
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, ErrNotFound
	}
	_ = os.Chtimes(path, now, now)
	return &s, nil
}

// Prune deletes shares unopened for longer than the expiry.
func (st *Store) Prune() {
	entries, _ := os.ReadDir(st.dir)
	for _, e := range entries {
		if info, err := e.Info(); err == nil && st.now().Sub(info.ModTime()) > st.expiry {
			os.Remove(filepath.Join(st.dir, e.Name()))
		}
	}
}

func (st *Store) path(id string) string { return filepath.Join(st.dir, id+".json") }

// NormalizeID turns what was typed or pasted into a share ID, or "".
func NormalizeID(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if len(s) != IDLength {
		return ""
	}
	for _, c := range s {
		if !strings.ContainsRune(idAlphabet, c) {
			return ""
		}
	}
	return s
}

func randomID() string {
	b := make([]byte, IDLength)
	max := big.NewInt(int64(len(idAlphabet)))
	for i := range b {
		v, err := rand.Int(rand.Reader, max)
		if err != nil {
			panic(err)
		}
		b[i] = idAlphabet[v.Int64()]
	}
	return string(b)
}
