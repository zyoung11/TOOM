package server

import (
	"net/netip"
	"time"

	"toom-server/internal/protocol"
)

const (
	maxMembersPerRoom = 10
	maxRooms          = 1024
	memberTimeout     = 20 * time.Second
	challengeTTL      = 10 * time.Second
	roomEmptyTTL      = 30 * time.Minute
)

// Member is one joined client inside a room. All fields are owned by
// the single server loop goroutine.
type Member struct {
	ID       uint32
	Name     string
	Cam      bool
	Mic      bool
	Screen   bool
	Addr     netip.AddrPort
	LastSeen time.Time
	Subs     map[uint32]bool
	room     *Room
}

// wants reports whether the member subscribed to the sender stream.
func (m *Member) wants(senderID uint32) bool {
	if m.Subs == nil {
		return true
	}
	return m.Subs[senderID]
}

// Room is one conference room with its own membership table.
type Room struct {
	Name       string
	JoinKey    []byte
	Members    map[uint32]*Member
	ByAddr     map[netip.AddrPort]uint32
	NextID     uint32
	EmptySince time.Time
}

func newRoom(name string, joinKey []byte, now time.Time) *Room {
	return &Room{
		Name:       name,
		JoinKey:    joinKey,
		Members:    make(map[uint32]*Member),
		ByAddr:     make(map[netip.AddrPort]uint32),
		NextID:     1,
		EmptySince: now,
	}
}

// full reports whether the room reached the member cap.
func (r *Room) full() bool {
	return len(r.Members) >= maxMembersPerRoom
}

// addMember registers a new member and returns it.
func (r *Room) addMember(name string, addr netip.AddrPort, now time.Time) *Member {
	id := r.NextID
	r.NextID++
	m := &Member{
		ID:       id,
		Name:     name,
		Addr:     addr,
		LastSeen: now,
		room:     r,
	}
	r.Members[id] = m
	r.ByAddr[addr] = id
	r.EmptySince = time.Time{}
	return m
}

// find returns the member behind one client address.
func (r *Room) find(addr netip.AddrPort) *Member {
	id, ok := r.ByAddr[addr]
	if !ok {
		return nil
	}
	return r.Members[id]
}

// drop removes one member and reports whether it existed.
func (r *Room) drop(addr netip.AddrPort) (*Member, bool) {
	id, ok := r.ByAddr[addr]
	if !ok {
		return nil, false
	}
	m := r.Members[id]
	delete(r.Members, id)
	delete(r.ByAddr, addr)
	if len(r.Members) == 0 {
		r.EmptySince = time.Now()
	}
	return m, true
}

// dropID removes one member by identifier.
func (r *Room) dropID(id uint32) (*Member, bool) {
	m, ok := r.Members[id]
	if !ok {
		return nil, false
	}
	_, dropped := r.drop(m.Addr)
	return m, dropped
}

// list snapshots the room membership for join replies.
func (r *Room) list() []protocol.Member {
	out := make([]protocol.Member, 0, len(r.Members))
	for _, m := range r.Members {
		out = append(out, protocol.Member{ID: m.ID, Name: m.Name, Cam: m.Cam, Mic: m.Mic, Screen: m.Screen})
	}
	return out
}
