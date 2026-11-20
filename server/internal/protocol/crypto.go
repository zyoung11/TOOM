package protocol

import (
	"crypto/hmac"
	"crypto/sha256"
)

// DeriveJoinKey derives the join proof key from the room secret.
func DeriveJoinKey(secret []byte) []byte {
	h := sha256.New()
	h.Write(secret)
	h.Write([]byte("join"))
	return h.Sum(nil)
}

// DeriveMediaKey derives the media sealing key from the room secret.
func DeriveMediaKey(secret []byte) []byte {
	h := sha256.New()
	h.Write(secret)
	h.Write([]byte("media"))
	return h.Sum(nil)
}

// Proof computes the join proof bound to a challenge nonce.
func Proof(joinKey, nonce []byte) []byte {
	mac := hmac.New(sha256.New, joinKey)
	mac.Write(nonce)
	return mac.Sum(nil)
}

// VerifyProof checks a join proof against the stored join key.
func VerifyProof(joinKey, nonce, proof []byte) bool {
	mac := hmac.New(sha256.New, joinKey)
	mac.Write(nonce)
	return hmac.Equal(mac.Sum(nil), proof)
}
