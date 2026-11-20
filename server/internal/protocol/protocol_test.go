package protocol

import (
	"bytes"
	"testing"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	body := []byte(`{"room":"demo"}`)
	out := Marshal(Envelope{Type: TypeJoinRequest, Body: body})
	env, err := Unmarshal(out)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if env.Type != TypeJoinRequest {
		t.Fatalf("type %02x, want %02x", env.Type, TypeJoinRequest)
	}
	if !bytes.Equal(env.Body, body) {
		t.Fatalf("body %q, want %q", env.Body, body)
	}
}

func TestUnmarshalRejectsBadPackets(t *testing.T) {
	cases := map[string][]byte{
		"short":       {0x01, 0x03},
		"bad version": {0x99, 0x03, 0, 0, 0, 0},
		"bad length":  {0x01, 0x03, 0, 0, 0, 2, 'x'},
	}
	for name, pkt := range cases {
		if _, err := Unmarshal(pkt); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestProofVerify(t *testing.T) {
	secret := []byte("s3cret")
	joinKey := DeriveJoinKey(secret)
	nonce := []byte("nonce-1234")
	proof := Proof(joinKey, nonce)
	if !VerifyProof(joinKey, nonce, proof) {
		t.Fatal("valid proof rejected")
	}
	other := DeriveJoinKey([]byte("wrong"))
	if VerifyProof(other, nonce, proof) {
		t.Fatal("wrong key accepted")
	}
	if VerifyProof(joinKey, []byte("other-nonce"), proof) {
		t.Fatal("wrong nonce accepted")
	}
}

func TestKeyDerivationSeparatesKeys(t *testing.T) {
	secret := []byte("s3cret")
	if bytes.Equal(DeriveJoinKey(secret), DeriveMediaKey(secret)) {
		t.Fatal("join key equals media key")
	}
}
