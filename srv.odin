package toom

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

SRV_MAX_MEMBERS    :: 10
SRV_MAX_ROOMS      :: 1024
SRV_MEMBER_TIMEOUT :: 10 * time.Second
SRV_CHALLENGE_TTL  :: 10 * time.Second
SRV_ROOM_EMPTY_TTL :: 30 * time.Minute

srv_stop: i32

// srv_json_unmarshal decodes one control body with temp memory so the
// event loop can reset it every round.
srv_json_unmarshal :: proc(data: []u8, out: ^$T) -> bool {
	old := context.allocator
	context.allocator = context.temp_allocator
	ok := json_unmarshal(data, out)
	context.allocator = old
	return ok
}

// srv_json_marshal encodes one control body with temp memory.
srv_json_marshal :: proc(v: $T) -> []u8 {
	old := context.allocator
	context.allocator = context.temp_allocator
	body := json_marshal(v)
	context.allocator = old
	return body
}

// srv_b64d decodes one base64 value with temp memory.
srv_b64d :: proc(s: string) -> []u8 {
	old := context.allocator
	context.allocator = context.temp_allocator
	out := b64d(s)
	context.allocator = old
	return out
}

// srv_b64e encodes one base64 value with temp memory.
srv_b64e :: proc(data: []u8) -> string {
	old := context.allocator
	context.allocator = context.temp_allocator
	out := b64e(data)
	context.allocator = old
	return out
}

// srv_now_plus returns the time one duration from now.
srv_now_plus :: proc(d: time.Duration) -> time.Time {
	return time.time_add(time.now(), d)
}

// srv_expired reports whether the deadline passed.
srv_expired :: proc(t: time.Time) -> bool {
	return time.since(t) > 0
}

// SrvChallenge is one pending join handshake step.
SrvChallenge :: struct {
	room:    string,
	name:    string,
	nonce:   []u8,
	expires: time.Time,
}

// SrvMember is one joined client inside a room.
SrvMember :: struct {
	id:        u32,
	name:      string,
	cam:       bool,
	mic:       bool,
	screen:    bool,
	addr:      SockAddr,
	last_seen: time.Time,
	has_subs:  bool,
	subs:      map[u32]bool,
	room:      ^SrvRoom,
}

// srv_member_wants reports whether the member subscribed to the
// sender stream.
srv_member_wants :: proc(m: ^SrvMember, sender_id: u32) -> bool {
	if !m.has_subs {
		return true
	}
	return m.subs[sender_id]
}

// SrvRoom is one conference room with its own membership table.
SrvRoom :: struct {
	name:        string,
	join_key:    [32]u8,
	members:     map[u32]^SrvMember,
	by_addr:     map[SockAddr]u32,
	next_id:     u32,
	empty_since: time.Time,
	has_empty:   bool,
}

// srv_room_new creates an empty room table with owned strings.
srv_room_new :: proc(name: string, join_key: [32]u8) -> ^SrvRoom {
	r := new(SrvRoom)
	r.name = strings.clone(name)
	r.join_key = join_key
	r.members = make(map[u32]^SrvMember)
	r.by_addr = make(map[SockAddr]u32)
	r.next_id = 1
	r.empty_since = time.now()
	r.has_empty = true
	return r
}

// srv_room_free releases one room table and its members.
srv_room_free :: proc(r: ^SrvRoom) {
	for _, m in r.members {
		delete(m.subs)
		delete(m.name)
		free(m)
	}
	delete(r.members)
	delete(r.by_addr)
	delete(r.name)
	free(r)
}

// srv_room_full reports whether the room reached the member cap.
srv_room_full :: proc(r: ^SrvRoom) -> bool {
	return len(r.members) >= SRV_MAX_MEMBERS
}

// srv_room_add registers a new member and returns it.
srv_room_add :: proc(r: ^SrvRoom, name: string, addr: SockAddr) -> ^SrvMember {
	id := r.next_id
	r.next_id += 1
	m := new(SrvMember)
	m.id = id
	m.name = strings.clone(name)
	m.addr = addr
	m.last_seen = time.now()
	m.room = r
	r.members[id] = m
	r.by_addr[addr] = id
	r.has_empty = false
	return m
}

// srv_room_find returns the member behind one client address.
srv_room_find :: proc(r: ^SrvRoom, addr: SockAddr) -> ^SrvMember {
	id, ok := r.by_addr[addr]
	if !ok {
		return nil
	}
	return r.members[id]
}

// srv_room_drop removes one member and reports whether it existed.
srv_room_drop :: proc(r: ^SrvRoom, addr: SockAddr) -> (^SrvMember, bool) {
	id, ok := r.by_addr[addr]
	if !ok {
		return nil, false
	}
	m := r.members[id]
	delete_key(&r.members, id)
	delete_key(&r.by_addr, addr)
	delete(m.subs)
	delete(m.name)
	if len(r.members) == 0 {
		r.empty_since = time.now()
		r.has_empty = true
	}
	return m, true
}

// srv_room_drop_id removes one member by identifier.
srv_room_drop_id :: proc(r: ^SrvRoom, id: u32) -> (^SrvMember, bool) {
	m := r.members[id]
	if m == nil {
		return nil, false
	}
	addr := m.addr
	_, dropped := srv_room_drop(r, addr)
	return m, dropped
}

// srv_room_list snapshots the room membership for join replies.
srv_room_list :: proc(r: ^SrvRoom) -> []MemberInfo {
	out := make([]MemberInfo, len(r.members))
	i := 0
	for _, m in r.members {
		out[i] = MemberInfo{ID = m.id, Name = m.name, Cam = m.cam, Mic = m.mic, Screen = m.screen}
		i += 1
	}
	return out
}

// SrvServer owns the UDP socket and all room state. One thread runs
// the whole event loop, so no locking is needed anywhere.
SrvServer :: struct {
	fd:         int,
	port:       int,
	rooms:      map[string]^SrvRoom,
	pending:    map[SockAddr]SrvChallenge,
	last_sweep: time.Time,
	forwarded:  u64,
	dropped:    u64,
}

// srv_new creates a server state for the given UDP port.
srv_new :: proc(port: int) -> ^SrvServer {
	s := new(SrvServer)
	s.port = port
	s.rooms = make(map[string]^SrvRoom)
	s.pending = make(map[SockAddr]SrvChallenge)
	return s
}

// srv_addr_norm zeroes the padding of one peer address so it compares
// and hashes correctly as a map key.
srv_addr_norm :: proc(a: SockAddr) -> SockAddr {
	out := a
	out.zero = {}
	return out
}

// srv_send_json seals one control message body to one client.
srv_send_json :: proc(s: ^SrvServer, to: SockAddr, typ: u8, body: []u8) {
	env := env_marshal(Envelope{typ = typ, body = body})
	addr := to
	net_send(s.fd, &addr, env)
	delete(env)
}

// srv_broadcast sends one control message body to every member
// except the one behind skip.
srv_broadcast :: proc(s: ^SrvServer, r: ^SrvRoom, typ: u8, body: []u8, skip: SockAddr) {
	for _, m in r.members {
		if m.addr == skip {
			continue
		}
		srv_send_json(s, m.addr, typ, body)
	}
}

// srv_member_at finds the room member behind one client address.
srv_member_at :: proc(s: ^SrvServer, addr: SockAddr) -> ^SrvMember {
	for _, r in s.rooms {
		if m := srv_room_find(r, addr); m != nil {
			return m
		}
	}
	return nil
}

// srv_valid_name checks a room or member name for length and control
// characters.
srv_valid_name :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > 32 {
		return false
	}
	for c in name {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}

// srv_drop_member removes one member and deletes the room the moment
// it turns empty, so an unused room never blocks a fresh create.
srv_drop_member :: proc(s: ^SrvServer, r: ^SrvRoom, addr: SockAddr) -> (^SrvMember, bool) {
	m, ok := srv_room_drop(r, addr)
	if ok && len(r.members) == 0 {
		delete_key(&s.rooms, r.name)
		srv_log_info(fmt.tprintf("room closed: %s", r.name))
		srv_room_free(r)
	}
	return m, ok
}

srv_handle_create_room :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	req: CreateRoomMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	key32: [32]u8
	has_key := false
	key := srv_b64d(req.JoinKey)
	if len(key) == 32 {
		copy(key32[:], key[:32])
		has_key = true
	}
	result := RESULT_OK
	err := ""
	existing := s.rooms[req.Name]
	if !srv_valid_name(req.Name) || !has_key {
		result = RESULT_REJECTED
		err = "bad room name or join key"
	} else if existing != nil && existing.join_key != key32 && len(existing.members) > 0 {
		result = RESULT_REJECTED
		err = "room exists with another key"
	} else if existing != nil && existing.join_key != key32 {
		delete_key(&s.rooms, req.Name)
		srv_room_free(existing)
		nr := srv_room_new(req.Name, key32)
		s.rooms[nr.name] = nr
		srv_log_info(fmt.tprintf("room recreated: %s", nr.name))
	} else if existing == nil && len(s.rooms) >= SRV_MAX_ROOMS {
		result = RESULT_REJECTED
		err = "too many rooms"
	} else if existing == nil {
		nr := srv_room_new(req.Name, key32)
		s.rooms[nr.name] = nr
		srv_log_info(fmt.tprintf("room created: %s", nr.name))
	}
	rbody := srv_json_marshal(CreateRoomRpyMsg{Result = result, Error = err})
	srv_send_json(s, from, MSG_CREATE_ROOM_RPY, rbody)
}

srv_handle_join_request :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	req: JoinRequestMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	r := s.rooms[req.Room]
	reject := ""
	switch {
	case r == nil:
		reject = "no such room"
	case !srv_valid_name(req.Name):
		reject = "bad name"
	case srv_room_full(r):
		reject = "room is full"
	}
	if reject != "" {
		rbody := srv_json_marshal(JoinReplyMsg{Result = RESULT_REJECTED, Error = reject})
		srv_send_json(s, from, MSG_JOIN_REPLY, rbody)
		return
	}
	nonce := make([]u8, 32)
	if !rand_bytes(nonce) {
		delete(nonce)
		rbody := srv_json_marshal(JoinReplyMsg{Result = RESULT_REJECTED, Error = "no entropy"})
		srv_send_json(s, from, MSG_JOIN_REPLY, rbody)
		return
	}
	old := s.pending[from]
	delete(old.nonce)
	delete(old.room)
	delete(old.name)
	s.pending[from] = SrvChallenge{
		room = strings.clone(req.Room), name = strings.clone(req.Name),
		nonce = nonce, expires = srv_now_plus(SRV_CHALLENGE_TTL),
	}
	ne := srv_b64e(nonce)
	cbody := srv_json_marshal(JoinChallengeMsg{Nonce = ne})
	srv_send_json(s, from, MSG_JOIN_CHALLENGE, cbody)
}

srv_handle_join_proof :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	req: JoinProofMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	pend := s.pending[from]
	bad := pend.nonce == nil || pend.room != req.Room || pend.name != req.Name || srv_expired(pend.expires)
	if bad {
		delete_key(&s.pending, from)
		delete(pend.nonce)
		delete(pend.room)
		delete(pend.name)
		rbody := srv_json_marshal(JoinReplyMsg{Result = RESULT_REJECTED, Error = "no pending challenge"})
		srv_send_json(s, from, MSG_JOIN_REPLY, rbody)
		return
	}
	delete_key(&s.pending, from)
	r := s.rooms[req.Room]
	proof := srv_b64d(req.Proof)
	proof_ok := r != nil && len(proof) == KEY_LEN && verify_proof(r.join_key[:], pend.nonce, proof)
	delete(pend.nonce)
	delete(pend.room)
	delete(pend.name)
	if !proof_ok {
		rbody := srv_json_marshal(JoinReplyMsg{Result = RESULT_REJECTED, Error = "bad proof"})
		srv_send_json(s, from, MSG_JOIN_REPLY, rbody)
		return
	}
	if srv_room_full(r) {
		rbody := srv_json_marshal(JoinReplyMsg{Result = RESULT_REJECTED, Error = "room is full"})
		srv_send_json(s, from, MSG_JOIN_REPLY, rbody)
		return
	}
	if old := srv_room_find(r, from); old != nil {
		old_id := old.id
		_, _ = srv_room_drop_id(r, old_id)
		lbody := srv_json_marshal(MemberLeaveMsg{ID = old_id})
		srv_broadcast(s, r, MSG_MEMBER_LEAVE, lbody, from)
	}
	m := srv_room_add(r, req.Name, from)
	srv_log_info(fmt.tprintf("join room %s: %s", r.name, req.Name))
	members := srv_room_list(r)
	rbody := srv_json_marshal(JoinReplyMsg{Result = RESULT_OK, ClientID = m.id, Members = members})
	srv_send_json(s, from, MSG_JOIN_REPLY, rbody)
	jbody := srv_json_marshal(MemberJoinMsg{ID = m.id, Name = m.name, Cam = m.cam, Mic = m.mic, Screen = m.screen})
	srv_broadcast(s, r, MSG_MEMBER_JOIN, jbody, from)
}

srv_handle_keepalive :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	req: KeepAliveMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	kbody := srv_json_marshal(req)
	srv_send_json(s, from, MSG_KEEPALIVE, kbody)
}

srv_handle_member_update :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	m := srv_member_at(s, from)
	if m == nil {
		return
	}
	req: MemberUpdateMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	m.cam = req.Cam
	m.mic = req.Mic
	m.screen = req.Screen
	ubody := srv_json_marshal(MemberUpdateMsg{ID = m.id, Cam = m.cam, Mic = m.mic, Screen = m.screen})
	srv_broadcast(s, m.room, MSG_MEMBER_UPDATE, ubody, from)
}

srv_handle_subscribe :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	m := srv_member_at(s, from)
	if m == nil {
		return
	}
	req: SubscribeMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	delete(m.subs)
	if len(req.IDs) == 0 {
		m.has_subs = false
		return
	}
	m.subs = make(map[u32]bool)
	for id in req.IDs {
		m.subs[id] = true
	}
	m.has_subs = true
}

srv_handle_ping :: proc(s: ^SrvServer, body: []u8, from: SockAddr) {
	req: PingMsg
	if !srv_json_unmarshal(body, &req) {
		return
	}
	pbody := srv_json_marshal(PongMsg{TS = req.TS})
	srv_send_json(s, from, MSG_PONG, pbody)
}

srv_handle_bye :: proc(s: ^SrvServer, from: SockAddr) {
	m := srv_member_at(s, from)
	if m == nil {
		return
	}
	r := m.room
	m_id := m.id
	srv_log_info(fmt.tprintf("bye room %s: %s", r.name, m.name))
	lbody := srv_json_marshal(MemberLeaveMsg{ID = m_id})
	srv_broadcast(s, r, MSG_MEMBER_LEAVE, lbody, from)
	_, _ = srv_drop_member(s, r, from)
}

srv_handle_stats :: proc(s: ^SrvServer, from: SockAddr) {
	rooms := len(s.rooms)
	members := 0
	for _, r in s.rooms {
		members += len(r.members)
	}
	rbody := srv_json_marshal(StatsRpyMsg{
		Result = RESULT_OK, Rooms = rooms, Members = members,
		Forwarded = s.forwarded, Dropped = s.dropped,
	})
	srv_send_json(s, from, MSG_STATS, rbody)
}

// srv_forward sends one media datagram to every subscriber of the
// sender.
srv_forward :: proc(s: ^SrvServer, data: []u8, sender: ^SrvMember) {
	r := sender.room
	for _, m in r.members {
		if m.id == sender.id || !srv_member_wants(m, sender.id) {
			continue
		}
		to := m.addr
		if net_send(s.fd, &to, data) {
			s.forwarded += 1
		} else {
			s.dropped += 1
		}
	}
}

srv_handle :: proc(s: ^SrvServer, data: []u8, from_raw: SockAddr) {
	from := srv_addr_norm(from_raw)
	env, ok := env_unmarshal(data)
	if !ok {
		s.dropped += 1
		return
	}
	if m := srv_member_at(s, from); m != nil {
		m.last_seen = time.now()
		if env.typ == MSG_MEDIA {
			srv_forward(s, data, m)
			return
		}
	}
	switch env.typ {
	case MSG_CREATE_ROOM:
		srv_handle_create_room(s, env.body, from)
	case MSG_JOIN_REQUEST:
		srv_handle_join_request(s, env.body, from)
	case MSG_JOIN_PROOF:
		srv_handle_join_proof(s, env.body, from)
	case MSG_KEEPALIVE:
		srv_handle_keepalive(s, env.body, from)
	case MSG_MEMBER_UPDATE:
		srv_handle_member_update(s, env.body, from)
	case MSG_SUBSCRIBE:
		srv_handle_subscribe(s, env.body, from)
	case MSG_PING:
		srv_handle_ping(s, env.body, from)
	case MSG_BYE:
		srv_handle_bye(s, from)
	case MSG_STATS:
		srv_handle_stats(s, from)
	case MSG_MEDIA:
		s.dropped += 1
	case:
		s.dropped += 1
	}
}

// srv_sweep drops expired challenges, idle members and empty rooms.
srv_sweep :: proc(s: ^SrvServer) {
	for addr, pend in s.pending {
		if srv_expired(pend.expires) {
			delete_key(&s.pending, addr)
			delete(pend.nonce)
			delete(pend.room)
			delete(pend.name)
		}
	}
	for name, r in s.rooms {
		for _, m in r.members {
			if time.since(m.last_seen) > SRV_MEMBER_TIMEOUT {
				m_id := m.id
				srv_log_info(fmt.tprintf("timeout room %s: %s", name, m.name))
				lbody := srv_json_marshal(MemberLeaveMsg{ID = m_id})
				srv_broadcast(s, r, MSG_MEMBER_LEAVE, lbody, m.addr)
				_, _ = srv_drop_member(s, r, m.addr)
			}
		}
		if len(r.members) == 0 && r.has_empty && time.since(r.empty_since) > SRV_ROOM_EMPTY_TTL {
			delete_key(&s.rooms, name)
			srv_log_info(fmt.tprintf("room expired: %s", name))
			srv_room_free(r)
		}
	}
}

// srv_run serves until srv_stop is set and returns the traffic
// counters.
srv_run :: proc(s: ^SrvServer) -> (u64, u64) {
	s.fd = net_open()
	if s.fd < 0 {
		srv_log_error("socket create failed")
		return 0, 0
	}
	defer sock_close(c.int(s.fd))
	if !net_bind(s.fd, u16(s.port)) {
		srv_log_error(fmt.tprintf("port %d is busy", s.port))
		return 0, 0
	}
	srv_log_info(fmt.tprintf("listening on udp port %d", s.port))
	buf := make([]u8, 2048)
	defer delete(buf)
	s.last_sweep = time.now()
	addr: SockAddr
	for sync.atomic_load(&srv_stop) == 0 {
		tmp := runtime.default_temp_allocator_temp_begin()
		n := net_recv(s.fd, buf[:], &addr)
		if n <= 0 {
			srv_sweep(s)
		} else {
			srv_handle(s, buf[:n], addr)
			if time.since(s.last_sweep) >= 5 * time.Second {
				srv_sweep(s)
				s.last_sweep = time.now()
			}
		}
		runtime.default_temp_allocator_temp_end(tmp)
	}
	return s.forwarded, s.dropped
}
