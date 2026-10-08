// Package signal carries WebRTC signalling messages (offers, answers and ICE
// candidates) as JSON over a WebSocket.
//
// WebRTC itself doesn't define how two peers exchange these; every app picks
// its own channel. Ours is one WebSocket per participant.
package signal

import (
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

// Message types.
const (
	TypeOffer     = "offer"
	TypeAnswer    = "answer"
	TypeCandidate = "candidate"
	TypeError     = "error"
)

// Message is one signalling message in either direction.
type Message struct {
	Type      string                   `json:"type"`
	SDP       string                   `json:"sdp,omitempty"`
	Candidate *webrtc.ICECandidateInit `json:"candidate,omitempty"`
	Error     string                   `json:"error,omitempty"`
}

const (
	writeTimeout = 10 * time.Second
	pongTimeout  = 60 * time.Second
	pingInterval = 25 * time.Second
	maxMessage   = 64 << 10 // SDP for a few tracks is a few KB
)

// Conn wraps a WebSocket for signalling. Send is safe to call from several
// goroutines (ICE candidates arrive on Pion's goroutines); Receive must only
// be called from one.
type Conn struct {
	ws        *websocket.Conn
	writeMu   sync.Mutex
	closeOnce sync.Once
	done      chan struct{}
}

// NewConn takes ownership of ws and starts keep-alive pings, so dead
// connections (a phone that lost signal) are noticed within a minute.
func NewConn(ws *websocket.Conn) *Conn {
	c := &Conn{ws: ws, done: make(chan struct{})}
	ws.SetReadLimit(maxMessage)
	_ = ws.SetReadDeadline(time.Now().Add(pongTimeout))
	ws.SetPongHandler(func(string) error {
		return ws.SetReadDeadline(time.Now().Add(pongTimeout))
	})
	go c.ping()
	return c
}

func (c *Conn) ping() {
	t := time.NewTicker(pingInterval)
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
			c.writeMu.Lock()
			err := c.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(writeTimeout))
			c.writeMu.Unlock()
			if err != nil {
				c.Close()
				return
			}
		}
	}
}

// Send writes one message.
func (c *Conn) Send(m Message) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(writeTimeout))
	return c.ws.WriteJSON(m)
}

// Receive blocks until the next message arrives or the connection closes.
func (c *Conn) Receive() (Message, error) {
	var m Message
	_, data, err := c.ws.ReadMessage()
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return m, ErrBadMessage
	}
	return m, nil
}

// Close closes the connection; it is safe to call more than once.
func (c *Conn) Close() {
	c.closeOnce.Do(func() {
		close(c.done)
		_ = c.ws.Close()
	})
}

// ErrBadMessage is returned for messages that aren't valid JSON.
var ErrBadMessage = errors.New("signal: malformed message")
