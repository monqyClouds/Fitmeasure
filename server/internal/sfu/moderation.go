package sfu

// Stage 6: roles and moderation, as in docs/live-sessions.md section 3.
//
// Every rule is checked here, on the server: a modified app can only change
// what it sends, never what it is allowed to do or to receive.
//
// Until there are accounts, roles are provisional: whoever opens a room is
// its host. A removed person can come back under another name, since there
// is nothing yet to recognise them by.

import (
	"errors"
	"sort"

	"github.com/monqyClouds/Fitmeasure/server/internal/signal"
)

var errRoomLocked = errors.New("room is locked")

// moderationTypes are the messages moderate handles.
var moderationTypes = map[string]bool{
	signal.TypeSetRole:       true,
	signal.TypeTransferHost:  true,
	signal.TypeMute:          true,
	signal.TypeRequestUnmute: true,
	signal.TypeRemove:        true,
	signal.TypeSetSettings:   true,
}

// moderate carries out one moderation message from p, if p's role allows
// it, and returns what to tell p if not ("" when done).
func (rm *room) moderate(p *participant, msg signal.Message) string {
	if msg.Type == signal.TypeSetSettings {
		return rm.setSettings(p, msg)
	}

	target := rm.find(msg.ID)
	if target == nil {
		return "nobody with that ID is here"
	}
	role := p.getRole()

	switch msg.Type {
	case signal.TypeSetRole:
		if role != signal.RoleHost {
			return "only the host can change roles"
		}
		if target == p || target.getRole() == signal.RoleHost {
			return "use transfer_host to change the host"
		}
		if msg.Role != signal.RoleModerator && msg.Role != signal.RoleParticipant {
			return "the role must be moderator or participant"
		}
		target.setRole(msg.Role)
		rm.announce(target)

	case signal.TypeTransferHost:
		if role != signal.RoleHost {
			return "only the host can hand over host"
		}
		if target == p {
			return "you're already the host"
		}
		rm.setHost(target)

	case signal.TypeMute:
		if !rm.canModerate(p) {
			return "only the host and moderators can mute others"
		}
		off := false
		switch msg.Track {
		case "mic":
			target.setState(&off, nil, "")
		case "camera":
			target.setState(nil, &off, "")
		default:
			return "track must be mic or camera"
		}
		// Forwarding has already stopped; the person's app mutes locally
		// so its controls match. Only they can unmute.
		_ = target.send(signal.Message{Type: signal.TypeMutedBy, ID: p.id, Track: msg.Track})

	case signal.TypeRequestUnmute:
		if !rm.canModerate(p) {
			return "only the host and moderators can ask others to unmute"
		}
		if msg.Track != "mic" && msg.Track != "camera" {
			return "track must be mic or camera"
		}
		_ = target.send(signal.Message{Type: signal.TypeUnmuteRequested, ID: p.id, Track: msg.Track})

	case signal.TypeRemove:
		if !rm.canModerate(p) {
			return "only the host and moderators can remove people"
		}
		if target.getRole() == signal.RoleHost {
			return "the host can't be removed"
		}
		if target == p {
			return "use Leave to leave"
		}
		target.removed.Store(true)
		_ = target.send(signal.Message{Type: signal.TypeRemoved})
		target.getConn().Close() // their handler sees removed and leaves at once
	}
	return ""
}

// setSettings changes the room's lock (host and moderators) or "everyone can
// moderate" (host only), and tells everyone.
func (rm *room) setSettings(p *participant, msg signal.Message) string {
	role := p.getRole()
	if msg.EveryoneCanModerate != nil && role != signal.RoleHost {
		return "only the host can let everyone moderate"
	}
	if msg.Locked != nil && role != signal.RoleHost && role != signal.RoleModerator {
		return "only the host and moderators can lock the room"
	}
	rm.mu.Lock()
	if msg.Locked != nil {
		rm.locked = *msg.Locked
	}
	if msg.EveryoneCanModerate != nil {
		rm.everyoneCanModerate = *msg.EveryoneCanModerate
	}
	rm.mu.Unlock()
	broadcast(rm.others(nil), rm.settings())
	return ""
}

// settings is the room's settings as a message (also merged into welcome
// and resumed).
func (rm *room) settings() signal.Message {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	locked, everyone := rm.locked, rm.everyoneCanModerate
	return signal.Message{Type: signal.TypeSettings, Locked: &locked, EveryoneCanModerate: &everyone}
}

func (rm *room) canModerate(p *participant) bool {
	rm.mu.Lock()
	everyone := rm.everyoneCanModerate
	rm.mu.Unlock()
	role := p.getRole()
	return everyone || role == signal.RoleHost || role == signal.RoleModerator
}

func (rm *room) find(id string) *participant {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.participants[id]
}

// isHost reports whether p is the room's host now.
func (rm *room) isHost(p *participant) bool {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.host == p
}

// setHost makes p the host; the previous host, if still here, becomes a
// moderator. "Trainer only" video follows the host, so every camera is
// re-targeted.
func (rm *room) setHost(p *participant) {
	rm.mu.Lock()
	old := rm.host
	rm.host = p
	rm.mu.Unlock()
	p.setRole(signal.RoleHost)
	rm.announce(p)
	if old != nil && old != p && rm.find(old.id) == old {
		old.setRole(signal.RoleModerator)
		rm.announce(old)
	}
	rm.retargetAll()
}

// successor picks the next host from the people left: the longest-present
// moderator, otherwise the longest-present participant. Called with rm.mu
// held.
func (rm *room) successor() *participant {
	people := make([]*participant, 0, len(rm.participants))
	for _, q := range rm.participants {
		people = append(people, q)
	}
	sort.Slice(people, func(i, j int) bool { return people[i].joinedAt.Before(people[j].joinedAt) })
	for _, q := range people {
		if q.getRole() == signal.RoleModerator {
			return q
		}
	}
	if len(people) > 0 {
		return people[0]
	}
	return nil
}

// announce tells everyone, q included, about q's role, state or visibility.
func (rm *room) announce(q *participant) {
	info := q.info()
	broadcast(rm.others(nil), signal.Message{Type: signal.TypeParticipantChanged, Participant: &info})
}

// retargetAll re-chooses every subscriber's layer of every track, after a
// change that affects who may see what.
func (rm *room) retargetAll() {
	rm.mu.Lock()
	tracks := make([]*upTrack, 0, len(rm.tracks))
	for t := range rm.tracks {
		tracks = append(tracks, t)
	}
	rm.mu.Unlock()
	for _, t := range tracks {
		t.retargetAll()
	}
}
