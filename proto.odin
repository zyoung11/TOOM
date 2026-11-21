package toom

import "core:encoding/base64"
import "core:encoding/json"

PROTO_VERSION :: 1
HDR_LEN       :: 6

MSG_CREATE_ROOM    :: 0x01
MSG_CREATE_ROOM_RPY :: 0x02
MSG_JOIN_REQUEST   :: 0x03
MSG_JOIN_CHALLENGE :: 0x04
MSG_JOIN_PROOF     :: 0x05
MSG_JOIN_REPLY     :: 0x06
MSG_KEEPALIVE      :: 0x07
MSG_MEMBER_JOIN    :: 0x08
MSG_MEMBER_LEAVE   :: 0x09
MSG_MEMBER_UPDATE  :: 0x0a
MSG_SUBSCRIBE      :: 0x0b
MSG_PING           :: 0x0c
MSG_PONG           :: 0x0d
MSG_BYE            :: 0x0e
MSG_MEDIA          :: 0x40

RESULT_OK       :: "ok"
RESULT_REJECTED :: "rejected"

MEDIA_HDR_LEN   :: 18
MEDIA_STREAM_VIDEO  :: 0
MEDIA_STREAM_AUDIO  :: 1
MEDIA_STREAM_DESK   :: 2
MEDIA_STREAM_SCREEN :: 3
MEDIA_FLAG_KEY     :: 0x01

CreateRoomMsg :: struct {
	Name:    string `json:"name"`,
	JoinKey: string `json:"join_key"`,
}

CreateRoomRpyMsg :: struct {
	Result: string `json:"result"`,
	Error:  string `json:"error,omitempty"`,
}

JoinRequestMsg :: struct {
	Room: string `json:"room"`,
	Name: string `json:"name"`,
}

JoinChallengeMsg :: struct {
	Nonce: string `json:"nonce"`,
}

JoinProofMsg :: struct {
	Room:  string `json:"room"`,
	Name:  string `json:"name"`,
	Proof: string `json:"proof"`,
}

MemberInfo :: struct {
	ID:     u32 `json:"id"`,
	Name:   string `json:"name"`,
	Cam:    bool `json:"cam"`,
	Mic:    bool `json:"mic"`,
	Screen: bool `json:"screen"`,
}

JoinReplyMsg :: struct {
	Result:   string       `json:"result"`,
	Error:    string       `json:"error,omitempty"`,
	ClientID: u32          `json:"client_id,omitempty"`,
	Members:  []MemberInfo `json:"members,omitempty"`,
}

KeepAliveMsg :: struct {
	Seq: u64 `json:"seq"`
}

MemberJoinMsg :: struct {
	ID:     u32 `json:"id"`,
	Name:   string `json:"name"`,
	Cam:    bool `json:"cam"`,
	Mic:    bool `json:"mic"`,
	Screen: bool `json:"screen"`,
}

MemberLeaveMsg :: struct {
	ID: u32 `json:"id"`,
}

MemberUpdateMsg :: struct {
	ID:     u32 `json:"id"`,
	Cam:    bool `json:"cam"`,
	Mic:    bool `json:"mic"`,
	Screen: bool `json:"screen"`,
}

SubscribeMsg :: struct {
	IDs: []u32 `json:"ids"`,
}

PingMsg :: struct {
	TS: u64 `json:"ts"`,
}

PongMsg :: struct {
	TS: u64 `json:"ts"`,
}

b64e :: proc(data: []u8) -> string {
	return base64.encode(data)
}

b64d :: proc(s: string) -> []u8 {
	out, _ := base64.decode(s)
	return out
}

put_be32 :: proc(buf: []u8, v: u32) {
	buf[0] = u8(v >> 24)
	buf[1] = u8(v >> 16)
	buf[2] = u8(v >> 8)
	buf[3] = u8(v)
}

get_be32 :: proc(buf: []u8) -> u32 {
	return u32(buf[0]) << 24 | u32(buf[1]) << 16 | u32(buf[2]) << 8 | u32(buf[3])
}

// Envelope wraps one datagram body with version, type and length.
Envelope :: struct {
	typ:  u8,
	body: []u8,
}

env_marshal :: proc(env: Envelope) -> []u8 {
	out := make([]u8, HDR_LEN + len(env.body))
	out[0] = PROTO_VERSION
	out[1] = env.typ
	put_be32(out[2:], u32(len(env.body)))
	copy(out[HDR_LEN:], env.body)
	return out
}

env_unmarshal :: proc(data: []u8) -> (Envelope, bool) {
	if len(data) < HDR_LEN || data[0] != PROTO_VERSION {
		return {}, false
	}
	n := int(get_be32(data[2:]))
	if n != len(data) - HDR_LEN {
		return {}, false
	}
	return Envelope{typ = data[1], body = data[HDR_LEN:]}, true
}

json_marshal :: proc(v: $T) -> []u8 {
	data, _ := json.marshal(v)
	return data
}

json_unmarshal :: proc(data: []u8, out: ^$T) -> bool {
	return json.unmarshal(data, out) == nil
}

// MediaHead is the cleartext header of one media fragment.
MediaHead :: struct {
	src:    u32,
	seq:    u32,
	ts:     u32,
	stream: u8,
	flags:  u8,
	frag:   u16,
	cnt:    u16,
}

media_pack :: proc(buf: []u8, h: MediaHead, payload: []u8) -> int {
	buf[0] = u8(h.src)
	buf[1] = u8(h.src >> 8)
	buf[2] = u8(h.src >> 16)
	buf[3] = u8(h.src >> 24)
	buf[4] = u8(h.seq)
	buf[5] = u8(h.seq >> 8)
	buf[6] = u8(h.seq >> 16)
	buf[7] = u8(h.seq >> 24)
	buf[8] = u8(h.ts)
	buf[9] = u8(h.ts >> 8)
	buf[10] = u8(h.ts >> 16)
	buf[11] = u8(h.ts >> 24)
	buf[12] = h.stream
	buf[13] = h.flags
	buf[14] = u8(h.frag)
	buf[15] = u8(h.frag >> 8)
	buf[16] = u8(h.cnt)
	buf[17] = u8(h.cnt >> 8)
	return copy(buf[MEDIA_HDR_LEN:], payload) + MEDIA_HDR_LEN
}

media_unpack :: proc(buf: []u8) -> (MediaHead, []u8, bool) {
	if len(buf) < MEDIA_HDR_LEN {
		return {}, nil, false
	}
	h := MediaHead{
		src = u32(buf[0]) | u32(buf[1]) << 8 | u32(buf[2]) << 16 | u32(buf[3]) << 24,
		seq = u32(buf[4]) | u32(buf[5]) << 8 | u32(buf[6]) << 16 | u32(buf[7]) << 24,
		ts = u32(buf[8]) | u32(buf[9]) << 8 | u32(buf[10]) << 16 | u32(buf[11]) << 24,
		stream = buf[12],
		flags = buf[13],
		frag = u16(buf[14]) | u16(buf[15]) << 8,
		cnt = u16(buf[16]) | u16(buf[17]) << 8,
	}
	return h, buf[MEDIA_HDR_LEN:], true
}
