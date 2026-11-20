package toom

import "core:sync"
import ma "../Aideo/miniaudio"

AUDIO_RATE    :: 48000
AUDIO_BLOCK   :: 960
AUDIO_MIX_MAX :: 32767

cap_ring: RingBuf
pb_ring:  RingBuf
cap_mu:   sync.Mutex
pb_mu:    sync.Mutex
cap_dev:  ma.device
pb_dev:   ma.device
audio_ok: bool
spk_mute: i32
mic_mute: i32
spk_vol_bits: u32
pb_primed:    i32

// RingBuf is a single producer single consumer PCM ring.
RingBuf :: struct {
	data: []i16,
	cap:  int,
	head: i64,
	tail: i64,
}

ring_init :: proc(rb: ^RingBuf, frames: int) {
	rb.cap = frames
	rb.data = make([]i16, frames)
	rb.head = 0
	rb.tail = 0
}

ring_write :: proc "contextless" (rb: ^RingBuf, samples: []i16) {
	head := rb.head
	tail := rb.tail
	space := rb.cap - int(head - tail)
	n := min(len(samples), space)
	if n <= 0 {
		return
	}
	pos := int(head % i64(rb.cap))
	first := min(n, rb.cap - pos)
	copy(rb.data[pos:pos + first], samples[:first])
	copy(rb.data[0:n - first], samples[first:n])
	rb.head = head + i64(n)
}

ring_read :: proc "contextless" (rb: ^RingBuf, dst: []i16) -> int {
	head := rb.head
	tail := rb.tail
	avail := int(head - tail)
	n := min(len(dst), avail)
	if n <= 0 {
		return 0
	}
	pos := int(tail % i64(rb.cap))
	first := min(n, rb.cap - pos)
	copy(dst[:first], rb.data[pos:pos + first])
	copy(dst[first:n], rb.data[0:n - first])
	rb.tail = tail + i64(n)
	return n
}

ring_fill :: proc "contextless" (rb: ^RingBuf) -> int {
	return int(rb.head - rb.tail)
}

cap_cb :: proc "c" (_: ^ma.device, _out: rawptr, input: rawptr, frames: u32) {
	if input == nil {
		return
	}
	src := ([^]i16)(input)
	n := int(frames)
	sync.mutex_lock(&cap_mu)
	ring_write(&cap_ring, src[:n])
	sync.mutex_unlock(&cap_mu)
}

pb_cb :: proc "c" (_: ^ma.device, output: rawptr, _in: rawptr, frames: u32) {
	dst := (([^]i16)(output))[:int(frames)]
	n := len(dst)
	if sync.atomic_load(&spk_mute) != 0 {
		for i in 0..<n {
			dst[i] = 0
		}
		return
	}
	if sync.atomic_load(&pb_primed) == 0 {
		sync.mutex_lock(&pb_mu)
		fill := ring_fill(&pb_ring)
		sync.mutex_unlock(&pb_mu)
		if fill < AUDIO_RATE / 5 {
			for i in 0..<n {
				dst[i] = 0
			}
			return
		}
		sync.atomic_store(&pb_primed, 1)
	}
	sync.mutex_lock(&pb_mu)
	read := ring_read(&pb_ring, dst)
	sync.mutex_unlock(&pb_mu)
	for i in read..<n {
		dst[i] = 0
	}
	vol := transmute(f32)u32(sync.atomic_load(&spk_vol_bits))
	if vol != 1.0 {
		for i in 0..<read {
			s := f32(dst[i]) * vol
			if s > AUDIO_MIX_MAX {
				s = AUDIO_MIX_MAX
			} else if s < -32768 {
				s = -32768
			}
			dst[i] = i16(s)
		}
	}
}

audio_start :: proc() -> bool {
	ring_init(&cap_ring, AUDIO_RATE * 2)
	ring_init(&pb_ring, AUDIO_RATE * 2)
	sync.atomic_store(&spk_vol_bits, transmute(u32)f32(1.0))

	ccfg := ma.device_config_init(.capture)
	ccfg.capture.format = .s16
	ccfg.capture.channels = 1
	ccfg.sampleRate = AUDIO_RATE
	ccfg.periodSizeInMilliseconds = 20
	ccfg.dataCallback = cap_cb
	if ma.device_init(nil, &ccfg, &cap_dev) != .SUCCESS {
		return false
	}
	if ma.device_start(&cap_dev) != .SUCCESS {
		ma.device_uninit(&cap_dev)
		return false
	}

	pcfg := ma.device_config_init(.playback)
	pcfg.playback.format = .s16
	pcfg.playback.channels = 1
	pcfg.sampleRate = AUDIO_RATE
	pcfg.periodSizeInMilliseconds = 20
	pcfg.dataCallback = pb_cb
	if ma.device_init(nil, &pcfg, &pb_dev) != .SUCCESS {
		ma.device_uninit(&cap_dev)
		return false
	}
	if ma.device_start(&pb_dev) != .SUCCESS {
		ma.device_uninit(&pb_dev)
		ma.device_uninit(&cap_dev)
		return false
	}
	audio_ok = true
	return true
}

audio_stop :: proc() {
	if !audio_ok {
		return
	}
	ma.device_uninit(&pb_dev)
	ma.device_uninit(&cap_dev)
	audio_ok = false
}

audio_capture_fill :: proc() -> int {
	sync.mutex_lock(&cap_mu)
	n := ring_fill(&cap_ring)
	sync.mutex_unlock(&cap_mu)
	return n
}

audio_capture_pop :: proc(dst: []i16) -> int {
	sync.mutex_lock(&cap_mu)
	n := ring_read(&cap_ring, dst)
	sync.mutex_unlock(&cap_mu)
	return n
}

// audio_play_push mixes one decoded mono block into the playback ring.
audio_play_push :: proc(samples: []i16) {
	sync.mutex_lock(&pb_mu)
	ring_write(&pb_ring, samples)
	sync.mutex_unlock(&pb_mu)
}

audio_toggle_spk :: proc() {
	if sync.atomic_load(&spk_mute) != 0 {
		sync.atomic_store(&spk_mute, 0)
	} else {
		sync.atomic_store(&spk_mute, 1)
	}
}

audio_toggle_mic :: proc() {
	if sync.atomic_load(&mic_mute) != 0 {
		sync.atomic_store(&mic_mute, 0)
	} else {
		sync.atomic_store(&mic_mute, 1)
	}
}

audio_vol_add :: proc(delta: f32) {
	v := transmute(f32)u32(sync.atomic_load(&spk_vol_bits)) + delta
	if v < 0 {
		v = 0
	} else if v > 2 {
		v = 2
	}
	sync.atomic_store(&spk_vol_bits, transmute(u32)f32(v))
}
