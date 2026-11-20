package toom

import "core:crypto/chacha20poly1305"
import "core:crypto/hmac"
import "core:crypto/sha2"
import "core:unicode/utf8"

KEY_LEN  :: 32

// bytes_of views a string as a byte slice.
bytes_of :: proc(s: string) -> []u8 {
	return (([^]u8)(raw_data(s)))[:len(s)]
}
NONCE_LEN :: 24
TAG_LEN  :: 16

foreign import randlib {
	"system:libc.so.6",
}

foreign randlib {
	@(link_name="getrandom")
	sys_getrandom :: proc(buf: rawptr, n: u64, flags: u32) -> i64 ---
}

// rand_bytes fills buf with kernel random bytes.
rand_bytes :: proc(buf: []u8) -> bool {
	return sys_getrandom(raw_data(buf), u64(len(buf)), 0) == i64(len(buf))
}

// derive_key expands a room secret with a purpose label.
derive_key :: proc(secret: []u8, label: string) -> [KEY_LEN]u8 {
	ctx: sha2.Context_256
	out: [KEY_LEN]u8
	sha2.init_256(&ctx)
	sha2.update(&ctx, secret)
	for r in label {
		b, n := utf8.encode_rune(r)
		for i in 0..<n {
			sha2.update(&ctx, b[i:i + 1])
		}
	}
	sha2.final(&ctx, out[:])
	return out
}

derive_join_key :: proc(secret: []u8) -> [KEY_LEN]u8 {
	return derive_key(secret, "join")
}

derive_media_key :: proc(secret: []u8) -> [KEY_LEN]u8 {
	return derive_key(secret, "media")
}

// proof signs a join challenge nonce with the room join key.
proof :: proc(join_key: []u8, nonce: []u8) -> [KEY_LEN]u8 {
	out: [KEY_LEN]u8
	hmac.sum(.SHA256, out[:], nonce, join_key)
	return out
}

verify_proof :: proc(join_key: []u8, nonce: []u8, mac: []u8) -> bool {
	return hmac.verify(.SHA256, mac, nonce, join_key)
}

// seal encrypts plaintext into nonce, ciphertext, tag.
seal :: proc(key: []u8, plaintext: []u8) -> []u8 {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key)
	nonce := make([]u8, NONCE_LEN)
	rand_bytes(nonce)
	ct := make([]u8, len(plaintext))
	tag := make([]u8, TAG_LEN)
	chacha20poly1305.seal(&ctx, ct, tag, nonce, nil, plaintext)
	out := make([]u8, NONCE_LEN + len(ct) + TAG_LEN)
	copy(out[:NONCE_LEN], nonce)
	copy(out[NONCE_LEN:NONCE_LEN + len(ct)], ct)
	copy(out[NONCE_LEN + len(ct):], tag)
	delete(nonce)
	delete(ct)
	delete(tag)
	return out
}

// open decrypts a seal blob. It returns nil on tag mismatch.
open :: proc(key: []u8, blob: []u8) -> []u8 {
	if len(blob) < NONCE_LEN + TAG_LEN {
		return nil
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key)
	nonce := blob[:NONCE_LEN]
	tag := blob[len(blob) - TAG_LEN:]
	ct := blob[NONCE_LEN:len(blob) - TAG_LEN]
	pt := make([]u8, len(ct))
	if !chacha20poly1305.open(&ctx, pt, nonce, nil, ct, tag) {
		delete(pt)
		return nil
	}
	return pt
}

// crypto_self_test runs known answer checks for the crypto chain.
crypto_self_test :: proc() -> bool {
	secret := bytes_of("s3cret")
	jk := derive_join_key(secret)
	mk := derive_media_key(secret)
	if jk == mk {
		return false
	}
	nonce := bytes_of("nonce-1234")
	mac := proof(jk[:], nonce)
	if !verify_proof(jk[:], nonce, mac[:]) {
		return false
	}
	if verify_proof(mk[:], nonce, mac[:]) {
		return false
	}
	plain := bytes_of("hello toom media")
	blob := seal(mk[:], plain)
	back := open(mk[:], blob)
	defer delete(back)
	if len(back) != len(plain) {
		return false
	}
	for i in 0..<len(plain) {
		if back[i] != plain[i] {
			return false
		}
	}
	blob[0] = blob[0] ~ 0xff
	if open(mk[:], blob) != nil {
		return false
	}
	return true
}
