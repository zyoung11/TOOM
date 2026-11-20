package server

import (
	"bytes"
	"net"
	"net/netip"
	"testing"
	"time"

	"toom-server/internal/protocol"
)

const testSecret = "s3cret"

type testClient struct {
	t    *testing.T
	conn *net.UDPConn
	to   netip.AddrPort
}

func startServer(t *testing.T) *Server {
	t.Helper()
	s := New(0)
	if err := s.Listen(); err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() {
		_ = s.Run()
	}()
	t.Cleanup(s.Stop)
	return s
}

func newClient(t *testing.T, s *Server) *testClient {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		t.Fatalf("client socket: %v", err)
	}
	t.Cleanup(func() {
		_ = conn.Close()
	})
	return &testClient{t: t, conn: conn, to: s.Addr()}
}

func (c *testClient) send(typ protocol.MsgType, v any) {
	c.t.Helper()
	pkt := protocol.Marshal(protocol.Envelope{Type: typ, Body: protocol.EncodeJSON(v)})
	if _, err := c.conn.WriteToUDPAddrPort(pkt, c.to); err != nil {
		c.t.Fatalf("send: %v", err)
	}
}

func (c *testClient) sendRaw(typ protocol.MsgType, body []byte) {
	c.t.Helper()
	pkt := protocol.Marshal(protocol.Envelope{Type: typ, Body: body})
	if _, err := c.conn.WriteToUDPAddrPort(pkt, c.to); err != nil {
		c.t.Fatalf("send raw: %v", err)
	}
}

// recvOne returns the next envelope regardless of its type.
func (c *testClient) recvOne(timeout time.Duration) (protocol.MsgType, []byte) {
	c.t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 2048)
	n, _, err := c.conn.ReadFromUDPAddrPort(buf)
	if err != nil {
		return 0, nil
	}
	env, err := protocol.Unmarshal(buf[:n])
	if err != nil {
		return 0, nil
	}
	return env.Type, env.Body
}

// recvUntil returns the body of the next envelope with the wanted type.
func (c *testClient) recvUntil(typ protocol.MsgType, timeout time.Duration) []byte {
	c.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		_ = c.conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		buf := make([]byte, 2048)
		n, _, err := c.conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			continue
		}
		env, err := protocol.Unmarshal(buf[:n])
		if err != nil || env.Type != typ {
			continue
		}
		return env.Body
	}
	return nil
}

func (c *testClient) createRoom(name string, joinKey []byte) bool {
	c.t.Helper()
	c.send(protocol.TypeCreateRoom, protocol.CreateRoom{Name: name, JoinKey: joinKey})
	body := c.recvUntil(protocol.TypeCreateRoomRpy, time.Second)
	if body == nil {
		c.t.Fatal("no room reply")
	}
	var rpy protocol.CreateRoomRpy
	if err := protocol.DecodeJSON(body, &rpy); err != nil {
		c.t.Fatalf("bad room reply: %v", err)
	}
	return rpy.Result == protocol.ResultOK
}

// join runs the challenge handshake and returns the assigned id.
func (c *testClient) join(room, name string, joinKey []byte) uint32 {
	c.t.Helper()
	c.send(protocol.TypeJoinRequest, protocol.JoinRequest{Room: room, Name: name})
	body := c.recvUntil(protocol.TypeJoinChallenge, time.Second)
	if body == nil {
		c.t.Fatal("no challenge")
	}
	var ch protocol.JoinChallenge
	if err := protocol.DecodeJSON(body, &ch); err != nil {
		c.t.Fatalf("bad challenge: %v", err)
	}
	c.send(protocol.TypeJoinProof, protocol.JoinProof{
		Room: room, Name: name, Proof: protocol.Proof(joinKey, ch.Nonce),
	})
	body = c.recvUntil(protocol.TypeJoinReply, time.Second)
	if body == nil {
		c.t.Fatal("no join reply")
	}
	var rpy protocol.JoinReply
	if err := protocol.DecodeJSON(body, &rpy); err != nil {
		c.t.Fatalf("bad join reply: %v", err)
	}
	if rpy.Result != protocol.ResultOK {
		c.t.Fatalf("join rejected: %s", rpy.Error)
	}
	return rpy.ClientID
}

func TestJoinForwardLeave(t *testing.T) {
	s := startServer(t)
	joinKey := protocol.DeriveJoinKey([]byte(testSecret))

	a := newClient(t, s)
	if !a.createRoom("demo", joinKey) {
		t.Fatal("create room failed")
	}
	idA := a.join("demo", "alice", joinKey)
	b := newClient(t, s)
	idB := b.join("demo", "bob", joinKey)
	if idA == 0 || idA == idB {
		t.Fatalf("bad ids: %d %d", idA, idB)
	}

	joinAnnounce := a.recvUntil(protocol.TypeMemberJoin, time.Second)
	if joinAnnounce == nil {
		t.Fatal("alice got no MemberJoin")
	}
	var mj protocol.MemberJoin
	if err := protocol.DecodeJSON(joinAnnounce, &mj); err != nil || mj.ID != idB {
		t.Fatalf("bad MemberJoin: %+v err=%v", mj, err)
	}

	payload := []byte("video-chunk-1")
	a.sendRaw(protocol.TypeMedia, payload)
	got := b.recvUntil(protocol.TypeMedia, time.Second)
	if !bytes.Equal(got, payload) {
		t.Fatalf("bob got %q, want %q", got, payload)
	}
	if a.recvUntil(protocol.TypeMedia, 200*time.Millisecond) != nil {
		t.Fatal("sender received its own media")
	}

	payload2 := []byte("audio-chunk-1")
	b.sendRaw(protocol.TypeMedia, payload2)
	got = a.recvUntil(protocol.TypeMedia, time.Second)
	if !bytes.Equal(got, payload2) {
		t.Fatalf("alice got %q, want %q", got, payload2)
	}

	b.send(protocol.TypeBye, struct{}{})
	leave := a.recvUntil(protocol.TypeMemberLeave, time.Second)
	if leave == nil {
		t.Fatal("alice got no MemberLeave")
	}
	var ml protocol.MemberLeave
	if err := protocol.DecodeJSON(leave, &ml); err != nil || ml.ID != idB {
		t.Fatalf("bad MemberLeave: %+v err=%v", ml, err)
	}
}

func TestJoinRejectsBadProof(t *testing.T) {
	s := startServer(t)
	joinKey := protocol.DeriveJoinKey([]byte(testSecret))

	a := newClient(t, s)
	if !a.createRoom("demo", joinKey) {
		t.Fatal("create room failed")
	}

	evil := newClient(t, s)
	evil.send(protocol.TypeJoinRequest, protocol.JoinRequest{Room: "demo", Name: "mallory"})
	body := evil.recvUntil(protocol.TypeJoinChallenge, time.Second)
	if body == nil {
		t.Fatal("no challenge")
	}
	var ch protocol.JoinChallenge
	if err := protocol.DecodeJSON(body, &ch); err != nil {
		t.Fatalf("bad challenge: %v", err)
	}
	wrongKey := protocol.DeriveJoinKey([]byte("wrong"))
	evil.send(protocol.TypeJoinProof, protocol.JoinProof{
		Room: "demo", Name: "mallory", Proof: protocol.Proof(wrongKey, ch.Nonce),
	})
	body = evil.recvUntil(protocol.TypeJoinReply, time.Second)
	if body == nil {
		t.Fatal("no join reply")
	}
	var rpy protocol.JoinReply
	if err := protocol.DecodeJSON(body, &rpy); err != nil {
		t.Fatalf("bad reply: %v", err)
	}
	if rpy.Result != protocol.ResultRejected {
		t.Fatal("bad proof accepted")
	}
}

func TestRoomCapacity(t *testing.T) {
	s := startServer(t)
	joinKey := protocol.DeriveJoinKey([]byte(testSecret))

	first := newClient(t, s)
	if !first.createRoom("full", joinKey) {
		t.Fatal("create room failed")
	}
	first.join("full", "m0", joinKey)
	for i := 1; i < maxMembersPerRoom; i++ {
		c := newClient(t, s)
		c.join("full", "m"+string(rune('0'+i)), joinKey)
	}
	over := newClient(t, s)
	over.send(protocol.TypeJoinRequest, protocol.JoinRequest{Room: "full", Name: "extra"})
	typ, body := over.recvOne(time.Second)
	if typ != protocol.TypeJoinReply {
		t.Fatalf("overfull room answered type %02x, want join reply", typ)
	}
	var rpy protocol.JoinReply
	if err := protocol.DecodeJSON(body, &rpy); err != nil {
		t.Fatalf("bad reply: %v", err)
	}
	if rpy.Result != protocol.ResultRejected {
		t.Fatal("overfull room accepted a join")
	}
}
