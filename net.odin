package toom

import "core:c"
import "core:sync"

AF_INET      :: 2
SOCK_DGRAM   :: 2
SOL_SOCKET   :: 1
SO_REUSEADDR :: 2
SO_RCVBUF    :: 8
SO_SNDBUF    :: 7
SO_RCVTIMEO  :: 20

MEDIA_CHUNK  :: 1340
FRAG_MAX     :: 512

SockAddr :: struct {
	family: u16,
	port:   u16,
	addr:   u32,
	zero:   [8]u8,
}

Timeval :: struct {
	sec:  i64,
	usec: i64,
}

foreign import netlib {
	"system:libc.so.6",
}

foreign netlib {
	@(link_name="socket")
	sock_socket :: proc(domain, typ, proto: c.int) -> c.int ---
	@(link_name="bind")
	sock_bind :: proc(fd: c.int, addr: ^SockAddr, alen: u32) -> c.int ---
	@(link_name="sendto")
	sock_sendto :: proc(fd: c.int, buf: rawptr, n: u64, flags: c.int, addr: ^SockAddr, alen: u32) -> c.long ---
	@(link_name="recvfrom")
	sock_recvfrom :: proc(fd: c.int, buf: rawptr, n: u64, flags: c.int, addr: ^SockAddr, alen: ^u32) -> c.long ---
	@(link_name="setsockopt")
	sock_setsockopt :: proc(fd: c.int, level, name: c.int, val: rawptr, optlen: u32) -> c.int ---
	@(link_name="close")
	sock_close :: proc(fd: c.int) -> c.int ---
	@(link_name="htons")
	sock_htons :: proc(v: u16) -> u16 ---
	@(link_name="inet_addr")
	sock_inet_addr :: proc(s: cstring) -> u32 ---
}

net_open :: proc() -> int {
	fd := int(sock_socket(AF_INET, SOCK_DGRAM, 0))
	if fd < 0 {
		return -1
	}
	one: i32 = 1
	sock_setsockopt(c.int(fd), SOL_SOCKET, SO_REUSEADDR, &one, 4)
	sz: i32 = 1 << 20
	sock_setsockopt(c.int(fd), SOL_SOCKET, SO_RCVBUF, &sz, 4)
	sock_setsockopt(c.int(fd), SOL_SOCKET, SO_SNDBUF, &sz, 4)
	tv := Timeval{sec = 0, usec = 200_000}
	sock_setsockopt(c.int(fd), SOL_SOCKET, SO_RCVTIMEO, &tv, u32(size_of(Timeval)))
	return fd
}

net_bind :: proc(fd: int, port: u16) -> bool {
	addr: SockAddr
	addr.family = AF_INET
	addr.port = sock_htons(port)
	return sock_bind(c.int(fd), &addr, u32(size_of(SockAddr))) == 0
}

net_addr :: proc(ip: string, port: u16) -> SockAddr {
	buf: [256]u8
	addr: SockAddr
	n := min(len(ip), len(buf) - 1)
	copy(buf[:], ip[:n])
	buf[n] = 0
	addr.family = AF_INET
	addr.port = sock_htons(port)
	addr.addr = sock_inet_addr(cast(cstring)&buf[0])
	return addr
}

net_send :: proc(fd: int, addr: ^SockAddr, data: []u8) -> bool {
	n := sock_sendto(c.int(fd), raw_data(data), u64(len(data)), 0, addr, u32(size_of(SockAddr)))
	return n == c.long(len(data))
}

net_recv :: proc(fd: int, buf: []u8, addr: ^SockAddr) -> int {
	alen: u32 = u32(size_of(SockAddr))
	n := sock_recvfrom(c.int(fd), raw_data(buf), u64(len(buf)), 0, addr, &alen)
	return int(n)
}

PeerInfo :: struct {
	id:   u32,
	name: string,
	cam:  bool,
	mic:  bool,
}

// Session is the client side protocol state for one room.
Session :: struct {
	fd:       int,
	srv:      SockAddr,
	room:     string,
	name:     string,
	join_key: [32]u8,
	media_key: [32]u8,
	self_id:  u32,
	peers:    map[u32]PeerInfo,
	peer_mu:  sync.Mutex,
	tx_video: u32,
	tx_audio: u32,
	keep_seq: u64,
}

sess_init :: proc(s: ^Session, fd: int, srv: SockAddr, room, name: string, secret: []u8) {
	s.fd = fd
	s.srv = srv
	s.room = room
	s.name = name
	s.join_key = derive_join_key(secret)
	s.media_key = derive_media_key(secret)
	s.peers = make(map[u32]PeerInfo)
}

sess_send_env :: proc(s: ^Session, typ: u8, body: []u8) {
	env := env_marshal(Envelope{typ = typ, body = body})
	defer delete(env)
	net_send(s.fd, &s.srv, env)
}

sess_create_room :: proc(s: ^Session) -> bool {
	body := json_marshal(CreateRoomMsg{Name = s.room, JoinKey = b64e(s.join_key[:])})
	defer delete(body)
	sess_send_env(s, MSG_CREATE_ROOM, body)
	return true
}

// sess_join runs the challenge handshake and stores the peer table.
sess_join :: proc(s: ^Session) -> (bool, string) {
	body := json_marshal(JoinRequestMsg{Room = s.room, Name = s.name})
	defer delete(body)
	sess_send_env(s, MSG_JOIN_REQUEST, body)

	buf: [2048]u8
	addr: SockAddr
	deadline := 30
	nonce_b64 := ""
	for i in 0..<deadline {
		n := net_recv(s.fd, buf[:], &addr)
		if n <= 0 {
			continue
		}
		env, ok := env_unmarshal(buf[:n])
		if !ok {
			continue
		}
		switch env.typ {
		case MSG_JOIN_CHALLENGE:
			ch: JoinChallengeMsg
			if json_unmarshal(env.body, &ch) {
				nonce_b64 = ch.Nonce
			}
		case MSG_JOIN_REPLY:
			rpy: JoinReplyMsg
			if json_unmarshal(env.body, &rpy) && rpy.Result == RESULT_REJECTED {
				return false, rpy.Error
			}
		}
		if nonce_b64 != "" {
			break
		}
	}
	if nonce_b64 == "" {
		return false, "no challenge"
	}

	nonce := b64d(nonce_b64)
	mac := proof(s.join_key[:], nonce)
	pbody := json_marshal(JoinProofMsg{Room = s.room, Name = s.name, Proof = b64e(mac[:])})
	defer delete(pbody)
	sess_send_env(s, MSG_JOIN_PROOF, pbody)

	for i in 0..<deadline {
		n := net_recv(s.fd, buf[:], &addr)
		if n <= 0 {
			continue
		}
		env, ok := env_unmarshal(buf[:n])
		if !ok || env.typ != MSG_JOIN_REPLY {
			continue
		}
		rpy: JoinReplyMsg
		if !json_unmarshal(env.body, &rpy) {
			continue
		}
		if rpy.Result != RESULT_OK {
			return false, rpy.Error
		}
		s.self_id = rpy.ClientID
		sync.mutex_lock(&s.peer_mu)
		for m in rpy.Members {
			if m.ID != s.self_id {
				s.peers[m.ID] = PeerInfo{id = m.ID, name = m.Name, cam = m.Cam, mic = m.Mic}
			}
		}
		sync.mutex_unlock(&s.peer_mu)
		return true, ""
	}
	return false, "no join reply"
}

sess_keepalive :: proc(s: ^Session) {
	s.keep_seq += 1
	body := json_marshal(KeepAliveMsg{Seq = s.keep_seq})
	defer delete(body)
	sess_send_env(s, MSG_KEEPALIVE, body)
}

sess_update :: proc(s: ^Session, cam, mic: bool) {
	body := json_marshal(MemberUpdateMsg{ID = s.self_id, Cam = cam, Mic = mic})
	defer delete(body)
	sess_send_env(s, MSG_MEMBER_UPDATE, body)
}

sess_bye :: proc(s: ^Session) {
	body := json_marshal(struct{}{})
	defer delete(body)
	sess_send_env(s, MSG_BYE, body)
}

// sess_send_media seals one media fragment and sends it.
sess_send_media :: proc(s: ^Session, plain: []u8) {
	blob := seal(s.media_key[:], plain)
	defer delete(blob)
	env := env_marshal(Envelope{typ = MSG_MEDIA, body = blob})
	defer delete(env)
	net_send(s.fd, &s.srv, env)
}

// sess_send_frame fragments one media frame and ships every fragment.
sess_send_frame :: proc(s: ^Session, stream, flags: u8, seq, ts: u32, payload: []u8) {
	cnt := u8((len(payload) + MEDIA_CHUNK - 1) / MEDIA_CHUNK)
	buf := make([]u8, MEDIA_HDR_LEN + MEDIA_CHUNK)
	defer delete(buf)
	for frag in 0..<int(cnt) {
		off := frag * MEDIA_CHUNK
		n := min(MEDIA_CHUNK, len(payload) - off)
		h := MediaHead{src = s.self_id, seq = seq, ts = ts, stream = stream, flags = flags, frag = u8(frag), cnt = cnt}
		total := media_pack(buf, h, payload[off:off + n])
		sess_send_media(s, buf[:total])
	}
}

// FragAsm reassembles one fragmented media message at a time.
FragAsm :: struct {
	seq:   u32,
	cnt:   u8,
	total: int,
	nrecv: int,
	valid: bool,
	got:   [FRAG_MAX]bool,
	buf:   [FRAG_MAX * MEDIA_CHUNK]u8,
}

frag_reset :: proc(a: ^FragAsm) {
	for i in 0..<FRAG_MAX {
		a.got[i] = false
	}
	a.total = 0
	a.nrecv = 0
}

// frag_feed returns a complete reassembled message when ready.
frag_feed :: proc(a: ^FragAsm, h: MediaHead, payload: []u8) -> ([]u8, bool) {
	if h.cnt == 0 || int(h.cnt) > FRAG_MAX || int(h.frag) >= int(h.cnt) {
		return nil, false
	}
	if !a.valid || h.seq != a.seq {
		a.seq = h.seq
		a.cnt = h.cnt
		a.valid = true
		frag_reset(a)
	}
	if h.cnt != a.cnt {
		return nil, false
	}
	off := int(h.frag) * MEDIA_CHUNK
	if off + len(payload) > len(a.buf) {
		return nil, false
	}
	copy(a.buf[off:], payload)
	if h.frag == a.cnt - 1 {
		a.total = off + len(payload)
	}
	if !a.got[h.frag] {
		a.got[h.frag] = true
		a.nrecv += 1
	}
	if a.nrecv == int(a.cnt) && a.total > 0 {
		a.valid = false
		return a.buf[:a.total], true
	}
	return nil, false
}
