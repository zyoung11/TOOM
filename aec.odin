package toom

import "core:c"

// Aec wraps one WebRTC audio processing instance for echo
// cancellation and noise suppression.
Aec :: struct {
	handle: rawptr,
}

// aec_open creates the processor for the given sample rate and the
// capture and playback channel counts.
aec_open :: proc(a: ^Aec, rate, cap_ch, play_ch: int) -> bool {
	a.handle = toom_aec_open(c.int(rate), c.int(cap_ch), c.int(play_ch))
	return a.handle != nil
}

// aec_play feeds one played block as the echo reference.
aec_play :: proc(a: ^Aec, data: []i16, frames: int) {
	if a.handle != nil {
		toom_aec_play(a.handle, raw_data(data), c.int(frames))
	}
}

// aec_cap cleans one captured block in place.
aec_cap :: proc(a: ^Aec, data: []i16, frames: int) {
	if a.handle != nil {
		toom_aec_cap(a.handle, raw_data(data), c.int(frames))
	}
}

// aec_close destroys the processor.
aec_close :: proc(a: ^Aec) {
	if a.handle != nil {
		toom_aec_close(a.handle)
		a.handle = nil
	}
}
