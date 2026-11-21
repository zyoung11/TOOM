// Package server runs the TOOM SFU: room management, join handshakes
// and raw media forwarding over one UDP socket.
package server

import (
	"bytes"
	"crypto/rand"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"sync/atomic"
	"time"

	"toom-server/internal/logx"
	"toom-server/internal/protocol"
)

// challenge is one pending join handshake step.
type challenge struct {
	room    string
	name    string
	nonce   []byte
	expires time.Time
}

// Server owns the UDP socket and all room state. One goroutine runs
// the whole event loop, so no locking is needed anywhere.
type Server struct {
	conn      *net.UDPConn
	port      int
	rooms     map[string]*Room
	pending   map[netip.AddrPort]challenge
	stopping  atomic.Bool
	lastSweep time.Time
	forwarded atomic.Uint64
	dropped   atomic.Uint64
}

// New creates a server that listens on the given UDP port.
func New(port int) *Server {
	return &Server{
		port:    port,
		rooms:   make(map[string]*Room),
		pending: make(map[netip.AddrPort]challenge),
	}
}

// Listen binds the UDP socket. Call it before Run.
func (s *Server) Listen() error {
	addr := net.UDPAddrFromAddrPort(netip.AddrPortFrom(netip.IPv4Unspecified(), uint16(s.port)))
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		return err
	}
	s.conn = conn
	return nil
}

// Addr returns the bound socket address.
func (s *Server) Addr() netip.AddrPort {
	if s.conn == nil {
		return netip.AddrPort{}
	}
	ua, ok := s.conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.AddrPort{}
	}
	return ua.AddrPort()
}

// Run serves until Stop is called.
func (s *Server) Run() error {
	if s.conn == nil {
		if err := s.Listen(); err != nil {
			return err
		}
	}
	logx.Info("listening on udp port " + strconv.Itoa(s.port))

	buf := make([]byte, 2048)
	s.lastSweep = time.Now()
	for {
		if s.stopping.Load() {
			return nil
		}
		_ = s.conn.SetReadDeadline(time.Now().Add(time.Second))
		n, from, err := s.conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				s.sweep()
				continue
			}
			if s.stopping.Load() {
				return nil
			}
			return err
		}
		s.handle(buf[:n], from)
		if time.Since(s.lastSweep) >= 5*time.Second {
			s.sweep()
			s.lastSweep = time.Now()
		}
	}
}

// Stop requests the event loop to exit and closes the socket.
func (s *Server) Stop() {
	s.stopping.Store(true)
	if s.conn != nil {
		_ = s.conn.Close()
	}
}

// Stats returns forwarded and dropped datagram counters.
func (s *Server) Stats() (forwarded, dropped uint64) {
	return s.forwarded.Load(), s.dropped.Load()
}

func (s *Server) handle(data []byte, from netip.AddrPort) {
	env, err := protocol.Unmarshal(data)
	if err != nil {
		s.dropped.Add(1)
		return
	}
	if m, ok := s.memberAt(from); ok {
		m.LastSeen = time.Now()
		if env.Type == protocol.TypeMedia {
			s.forward(data, m)
			return
		}
	}
	switch env.Type {
	case protocol.TypeCreateRoom:
		s.handleCreateRoom(env.Body, from)
	case protocol.TypeJoinRequest:
		s.handleJoinRequest(env.Body, from)
	case protocol.TypeJoinProof:
		s.handleJoinProof(env.Body, from)
	case protocol.TypeKeepAlive:
		s.handleKeepAlive(env.Body, from)
	case protocol.TypeMemberUpdate:
		s.handleMemberUpdate(env.Body, from)
	case protocol.TypeSubscribe:
		s.handleSubscribe(env.Body, from)
	case protocol.TypePing:
		s.handlePing(env.Body, from)
	case protocol.TypeBye:
		s.handleBye(from)
	case protocol.TypeMedia:
		s.dropped.Add(1)
	default:
		s.dropped.Add(1)
	}
}

func (s *Server) handleCreateRoom(body []byte, from netip.AddrPort) {
	var req protocol.CreateRoom
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	rpy := protocol.CreateRoomRpy{Result: protocol.ResultOK}
	existing, ok := s.rooms[req.Name]
	switch {
	case !validName(req.Name) || len(req.JoinKey) != 32:
		rpy.Result = protocol.ResultRejected
		rpy.Error = "bad room name or join key"
	case ok && !bytes.Equal(existing.JoinKey, req.JoinKey) && len(existing.Members) > 0:
		rpy.Result = protocol.ResultRejected
		rpy.Error = "room exists with another key"
	case ok && !bytes.Equal(existing.JoinKey, req.JoinKey):
		s.rooms[req.Name] = newRoom(req.Name, req.JoinKey, time.Now())
		logx.Info("room recreated: " + req.Name)
	case !ok && len(s.rooms) >= maxRooms:
		rpy.Result = protocol.ResultRejected
		rpy.Error = "too many rooms"
	case !ok:
		s.rooms[req.Name] = newRoom(req.Name, req.JoinKey, time.Now())
		logx.Info("room created: " + req.Name)
	}
	s.sendJSON(from, protocol.TypeCreateRoomRpy, rpy)
}

func (s *Server) handleJoinRequest(body []byte, from netip.AddrPort) {
	var req protocol.JoinRequest
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	r, ok := s.rooms[req.Room]
	switch {
	case !ok:
		s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "no such room"})
	case !validName(req.Name):
		s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "bad name"})
	case r.full():
		s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "room is full"})
	default:
		nonce := make([]byte, 32)
		if _, err := rand.Read(nonce); err != nil {
			s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "no entropy"})
			return
		}
		s.pending[from] = challenge{room: req.Room, name: req.Name, nonce: nonce, expires: time.Now().Add(challengeTTL)}
		s.sendJSON(from, protocol.TypeJoinChallenge, protocol.JoinChallenge{Nonce: nonce})
	}
}

func (s *Server) handleJoinProof(body []byte, from netip.AddrPort) {
	var req protocol.JoinProof
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	pend, ok := s.pending[from]
	if !ok || pend.room != req.Room || pend.name != req.Name || time.Now().After(pend.expires) {
		delete(s.pending, from)
		s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "no pending challenge"})
		return
	}
	delete(s.pending, from)
	r := s.rooms[req.Room]
	if r == nil || !protocol.VerifyProof(r.JoinKey, pend.nonce, req.Proof) {
		s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "bad proof"})
		return
	}
	if r.full() {
		s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{Result: protocol.ResultRejected, Error: "room is full"})
		return
	}
	if old := r.find(from); old != nil {
		_, _ = r.dropID(old.ID)
		s.broadcast(r, protocol.TypeMemberLeave, protocol.MemberLeave{ID: old.ID}, from)
	}
	m := r.addMember(req.Name, from, time.Now())
	logx.Info("join room " + r.Name + ": " + req.Name)
	s.sendJSON(from, protocol.TypeJoinReply, protocol.JoinReply{
		Result:   protocol.ResultOK,
		ClientID: m.ID,
		Members:  r.list(),
	})
	s.broadcast(r, protocol.TypeMemberJoin, protocol.MemberJoin{ID: m.ID, Name: m.Name, Cam: m.Cam, Mic: m.Mic, Screen: m.Screen}, from)
}

func (s *Server) handleKeepAlive(body []byte, from netip.AddrPort) {
	var req protocol.KeepAlive
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	s.sendJSON(from, protocol.TypeKeepAlive, req)
}

func (s *Server) handleMemberUpdate(body []byte, from netip.AddrPort) {
	m, ok := s.memberAt(from)
	if !ok {
		return
	}
	var req protocol.MemberUpdate
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	m.Cam = req.Cam
	m.Mic = req.Mic
	m.Screen = req.Screen
	s.broadcast(m.room, protocol.TypeMemberUpdate, protocol.MemberUpdate{ID: m.ID, Cam: m.Cam, Mic: m.Mic, Screen: m.Screen}, from)
}

func (s *Server) handleSubscribe(body []byte, from netip.AddrPort) {
	m, ok := s.memberAt(from)
	if !ok {
		return
	}
	var req protocol.Subscribe
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	if len(req.IDs) == 0 {
		m.Subs = nil
		return
	}
	subs := make(map[uint32]bool, len(req.IDs))
	for _, id := range req.IDs {
		subs[id] = true
	}
	m.Subs = subs
}

func (s *Server) handlePing(body []byte, from netip.AddrPort) {
	var req protocol.Ping
	if err := protocol.DecodeJSON(body, &req); err != nil {
		return
	}
	s.sendJSON(from, protocol.TypePong, protocol.Pong{TS: req.TS})
}

func (s *Server) handleBye(from netip.AddrPort) {
	m, ok := s.memberAt(from)
	if !ok {
		return
	}
	r := m.room
	_, _ = s.dropMember(r, from)
	logx.Info("bye room " + r.Name + ": " + m.Name)
	s.broadcast(r, protocol.TypeMemberLeave, protocol.MemberLeave{ID: m.ID}, from)
}

// dropMember removes one member and deletes the room the moment it
// turns empty, so an unused room never blocks a fresh create.
func (s *Server) dropMember(r *Room, addr netip.AddrPort) (*Member, bool) {
	m, ok := r.drop(addr)
	if ok && len(r.Members) == 0 {
		delete(s.rooms, r.Name)
		logx.Info("room closed: " + r.Name)
	}
	return m, ok
}

// forward sends one media datagram to every subscriber of the sender.
func (s *Server) forward(data []byte, sender *Member) {
	r := sender.room
	for _, m := range r.Members {
		if m.ID == sender.ID || !m.wants(sender.ID) {
			continue
		}
		if _, err := s.conn.WriteToUDPAddrPort(data, m.Addr); err == nil {
			s.forwarded.Add(1)
		} else {
			s.dropped.Add(1)
		}
	}
}

// sweep drops expired challenges, idle members and empty rooms.
func (s *Server) sweep() {
	now := time.Now()
	for addr, pend := range s.pending {
		if now.After(pend.expires) {
			delete(s.pending, addr)
		}
	}
	for _, r := range s.rooms {
		for _, m := range r.Members {
			if now.Sub(m.LastSeen) > memberTimeout {
				_, _ = s.dropMember(r, m.Addr)
				logx.Info("timeout room " + r.Name + ": " + m.Name)
				s.broadcast(r, protocol.TypeMemberLeave, protocol.MemberLeave{ID: m.ID}, m.Addr)
			}
		}
		if len(r.Members) == 0 && !r.EmptySince.IsZero() && now.Sub(r.EmptySince) > roomEmptyTTL {
			delete(s.rooms, r.Name)
			logx.Info("room expired: " + r.Name)
		}
	}
}

// broadcast sends one control message to every member except skip.
func (s *Server) broadcast(r *Room, typ protocol.MsgType, v any, skip netip.AddrPort) {
	for _, m := range r.Members {
		if m.Addr == skip {
			continue
		}
		s.sendJSON(m.Addr, typ, v)
	}
}

func (s *Server) sendJSON(to netip.AddrPort, typ protocol.MsgType, v any) {
	body := protocol.EncodeJSON(v)
	if body == nil {
		return
	}
	pkt := protocol.Marshal(protocol.Envelope{Type: typ, Body: body})
	_, _ = s.conn.WriteToUDPAddrPort(pkt, to)
}

func (s *Server) memberAt(addr netip.AddrPort) (*Member, bool) {
	for _, r := range s.rooms {
		if m := r.find(addr); m != nil {
			return m, true
		}
	}
	return nil, false
}

func validName(s string) bool {
	if len(s) < 1 || len(s) > 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return false
		}
	}
	return true
}
