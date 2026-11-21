// Package protocol defines the TOOM wire format: a versioned envelope
// with JSON control bodies and opaque media bodies.
package protocol

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
)

// Version is the envelope version byte.
const Version byte = 0x01

// MsgType identifies the payload kind of one envelope.
type MsgType byte

// Control message types. Bodies are JSON except TypeMedia.
const (
	TypeCreateRoom    MsgType = 0x01
	TypeCreateRoomRpy MsgType = 0x02
	TypeJoinRequest   MsgType = 0x03
	TypeJoinChallenge MsgType = 0x04
	TypeJoinProof     MsgType = 0x05
	TypeJoinReply     MsgType = 0x06
	TypeKeepAlive     MsgType = 0x07
	TypeMemberJoin    MsgType = 0x08
	TypeMemberLeave   MsgType = 0x09
	TypeMemberUpdate  MsgType = 0x0a
	TypeSubscribe     MsgType = 0x0b
	TypePing          MsgType = 0x0c
	TypePong          MsgType = 0x0d
	TypeBye           MsgType = 0x0e

	TypeMedia MsgType = 0x40
)

const headerLen = 6

// Envelope is one datagram: version, type, big endian body length, body.
type Envelope struct {
	Type MsgType
	Body []byte
}

// Marshal encodes an envelope.
func Marshal(env Envelope) []byte {
	out := make([]byte, headerLen+len(env.Body))
	out[0] = Version
	out[1] = byte(env.Type)
	binary.BigEndian.PutUint32(out[2:6], uint32(len(env.Body)))
	copy(out[6:], env.Body)
	return out
}

// Unmarshal decodes one envelope and rejects malformed datagrams.
func Unmarshal(data []byte) (Envelope, error) {
	if len(data) < headerLen {
		return Envelope{}, fmt.Errorf("datagram too short: %d bytes", len(data))
	}
	if data[0] != Version {
		return Envelope{}, fmt.Errorf("protocol version %02x, want %02x", data[0], Version)
	}
	bodyLen := binary.BigEndian.Uint32(data[2:6])
	if uint32(len(data)-headerLen) != bodyLen {
		return Envelope{}, fmt.Errorf("body length %d, want %d", bodyLen, len(data)-headerLen)
	}
	body := make([]byte, bodyLen)
	copy(body, data[6:])
	return Envelope{Type: MsgType(data[1]), Body: body}, nil
}

// Result values carried by reply messages.
const (
	ResultOK       = "ok"
	ResultRejected = "rejected"
)

// CreateRoom registers a room with its join key.
type CreateRoom struct {
	Name    string `json:"name"`
	JoinKey []byte `json:"join_key"`
}

// CreateRoomRpy reports the CreateRoom outcome.
type CreateRoomRpy struct {
	Result string `json:"result"`
	Error  string `json:"error,omitempty"`
}

// JoinRequest starts the join handshake for a room.
type JoinRequest struct {
	Room string `json:"room"`
	Name string `json:"name"`
}

// JoinChallenge carries the nonce the client must sign.
type JoinChallenge struct {
	Nonce []byte `json:"nonce"`
}

// JoinProof proves knowledge of the room join key.
type JoinProof struct {
	Room  string `json:"room"`
	Name  string `json:"name"`
	Proof []byte `json:"proof"`
}

// Member describes one participant.
type Member struct {
	ID     uint32 `json:"id"`
	Name   string `json:"name"`
	Cam    bool   `json:"cam"`
	Mic    bool   `json:"mic"`
	Screen bool   `json:"screen"`
}

// JoinReply completes the join handshake.
type JoinReply struct {
	Result   string   `json:"result"`
	Error    string   `json:"error,omitempty"`
	ClientID uint32   `json:"client_id,omitempty"`
	Members  []Member `json:"members,omitempty"`
}

// KeepAlive reports client liveness.
type KeepAlive struct {
	Seq uint64 `json:"seq"`
}

// MemberJoin announces a new participant to the room.
type MemberJoin struct {
	ID     uint32 `json:"id"`
	Name   string `json:"name"`
	Cam    bool   `json:"cam"`
	Mic    bool   `json:"mic"`
	Screen bool   `json:"screen"`
}

// MemberLeave announces a participant exit.
type MemberLeave struct {
	ID uint32 `json:"id"`
}

// MemberUpdate announces device state changes.
type MemberUpdate struct {
	ID     uint32 `json:"id"`
	Cam    bool   `json:"cam"`
	Mic    bool   `json:"mic"`
	Screen bool   `json:"screen"`
}

// Subscribe replaces the media subscription list of the sender. An
// empty list means every member.
type Subscribe struct {
	IDs []uint32 `json:"ids"`
}

// Ping carries a client timestamp for round trip measurement.
type Ping struct {
	TS uint64 `json:"ts"`
}

// Pong echoes the Ping timestamp.
type Pong struct {
	TS uint64 `json:"ts"`
}

// EncodeJSON encodes a control message body.
func EncodeJSON(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return data
}

// DecodeJSON decodes a control message body.
func DecodeJSON(body []byte, v any) error {
	if err := json.Unmarshal(body, v); err != nil {
		return fmt.Errorf("decode message body: %w", err)
	}
	return nil
}
