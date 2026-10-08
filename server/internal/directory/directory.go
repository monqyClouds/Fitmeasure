// Package directory keeps the rooms people have created: each has a short,
// unique ID that goes in its link (live.somto.si/r/k7f3qz) and a name for
// people to see. Rooms are saved to a file, so links survive restarts, and
// forgotten once nobody has used them for a while.
package directory

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

// IDLength is how many characters a room ID has.
const IDLength = 6

// idAlphabet leaves out characters that are easily mistaken for others
// (0/o, 1/l/i), so an ID read aloud or off a screen can be typed.
const idAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

// MaxNameLength is the longest room name, in characters.
const MaxNameLength = 60

// DefaultExpiry is how long a room is kept after it was last used.
const DefaultExpiry = 30 * 24 * time.Hour

// DefaultMaxRooms caps how many rooms are kept, against abuse.
const DefaultMaxRooms = 50000

var (
	ErrNoName   = errors.New("give the room a name")
	ErrTooMany  = errors.New("too many rooms; try again later")
	ErrNotFound = errors.New("no room with that ID")
)

// Room is one created room.
type Room struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// HostKey is given to whoever created the room: joining with it makes
	// them the host.
	HostKey  string    `json:"hostKey"`
	Created  time.Time `json:"created"`
	LastUsed time.Time `json:"lastUsed"`
}

// Directory is the set of rooms. The zero value isn't usable; use Open.
type Directory struct {
	path     string // "" keeps rooms in memory only
	expiry   time.Duration
	maxRooms int
	now      func() time.Time

	mu    sync.Mutex
	rooms map[string]*Room
	dirty bool
}

// Options for Open. Zero values mean the defaults.
type Options struct {
	Expiry   time.Duration
	MaxRooms int
	Now      func() time.Time // for tests
}

// Open loads the rooms saved at path, if any. With path "", rooms are kept
// in memory only.
func Open(path string, o Options) (*Directory, error) {
	d := &Directory{path: path, expiry: o.Expiry, maxRooms: o.MaxRooms, now: o.Now, rooms: map[string]*Room{}}
	if d.expiry == 0 {
		d.expiry = DefaultExpiry
	}
	if d.maxRooms == 0 {
		d.maxRooms = DefaultMaxRooms
	}
	if d.now == nil {
		d.now = time.Now
	}
	if path == "" {
		return d, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return d, nil
	}
	if err != nil {
		return nil, err
	}
	var rooms []*Room
	if err := json.Unmarshal(data, &rooms); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	for _, r := range rooms {
		d.rooms[r.ID] = r
	}
	d.prune()
	return d, nil
}

// NormalizeID turns what someone typed or pasted (" K7F-3QZ ", or a whole
// link) into an ID, or "" if it can't be one.
func NormalizeID(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.LastIndex(s, "/r/"); i >= 0 {
		s = s[i+3:]
		if j := strings.IndexAny(s, "/?#"); j >= 0 {
			s = s[:j]
		}
	}
	var b strings.Builder
	for _, c := range strings.ToLower(s) {
		switch {
		case c == '-' || c == ' ':
		case strings.ContainsRune(idAlphabet, c):
			b.WriteRune(c)
		default:
			return ""
		}
	}
	if b.Len() != IDLength {
		return ""
	}
	return b.String()
}

// Create makes a room called name, with a new ID and host key.
func (d *Directory) Create(name string) (Room, error) {
	name = cleanName(name)
	if name == "" {
		return Room{}, ErrNoName
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.prune()
	if len(d.rooms) >= d.maxRooms {
		return Room{}, ErrTooMany
	}
	id := randomString(idAlphabet, IDLength)
	for d.rooms[id] != nil {
		id = randomString(idAlphabet, IDLength)
	}
	now := d.now()
	r := &Room{ID: id, Name: name, HostKey: randomString(idAlphabet, 24), Created: now, LastUsed: now}
	d.rooms[id] = r
	d.dirty = true
	return *r, d.saveLocked()
}

// Get returns the room with id, if it exists and hasn't expired.
func (d *Directory) Get(id string) (Room, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	r := d.rooms[id]
	if r == nil || d.expired(r) {
		return Room{}, false
	}
	return *r, true
}

// Name is the room's name, if it exists.
func (d *Directory) Name(id string) (string, bool) {
	r, ok := d.Get(id)
	return r.Name, ok
}

// Touch records that the room was used now, keeping it from expiring.
func (d *Directory) Touch(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if r := d.rooms[id]; r != nil {
		r.LastUsed = d.now()
		d.dirty = true
	}
}

// IsHostKey reports whether key is the room's host key.
func (d *Directory) IsHostKey(id, key string) bool {
	if key == "" {
		return false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	r := d.rooms[id]
	return r != nil && subtle.ConstantTimeCompare([]byte(r.HostKey), []byte(key)) == 1
}

// Save writes the rooms to the file if anything changed since the last save.
func (d *Directory) Save() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.prune()
	return d.saveLocked()
}

// SaveEvery saves every interval until stop is closed, then once more.
func (d *Directory) SaveEvery(interval time.Duration, stop <-chan struct{}, onErr func(error)) {
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-tick.C:
		case <-stop:
			if err := d.Save(); err != nil {
				onErr(err)
			}
			return
		}
		if err := d.Save(); err != nil {
			onErr(err)
		}
	}
}

func (d *Directory) expired(r *Room) bool { return d.now().Sub(r.LastUsed) > d.expiry }

// prune forgets expired rooms. Called with d.mu held.
func (d *Directory) prune() {
	for id, r := range d.rooms {
		if d.expired(r) {
			delete(d.rooms, id)
			d.dirty = true
		}
	}
}

// saveLocked writes the file, atomically: a crash mid-write leaves the old
// one. Called with d.mu held.
func (d *Directory) saveLocked() error {
	if d.path == "" || !d.dirty {
		return nil
	}
	rooms := make([]*Room, 0, len(d.rooms))
	for _, r := range d.rooms {
		rooms = append(rooms, r)
	}
	data, err := json.Marshal(rooms)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(d.path), ".rooms-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // fails harmlessly once renamed
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), d.path); err != nil {
		return err
	}
	d.dirty = false
	return nil
}

// cleanName trims a name, folds runs of whitespace and drops control
// characters, and shortens it to MaxNameLength.
func cleanName(name string) string {
	name = strings.Join(strings.FieldsFunc(name, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsControl(r)
	}), " ")
	if r := []rune(name); len(r) > MaxNameLength {
		name = strings.TrimSpace(string(r[:MaxNameLength]))
	}
	return name
}

func randomString(alphabet string, n int) string {
	b := make([]byte, n)
	max := big.NewInt(int64(len(alphabet)))
	for i := range b {
		v, err := rand.Int(rand.Reader, max)
		if err != nil {
			panic(err) // crypto/rand doesn't fail on supported platforms
		}
		b[i] = alphabet[v.Int64()]
	}
	return string(b)
}
