package toom

import "core:c"

// ScreenCap wraps one wlr-screencopy capture session.
ScreenCap :: struct {
	handle: rawptr,
}

// screen_open starts capturing the picked output.
screen_open :: proc(s: ^ScreenCap, output_index: int) -> bool {
	s.handle = toom_screen_open(c.int(output_index))
	return s.handle != nil
}

// screen_poll pumps the capture until a frame is ready. It returns 1
// for a frame, 0 on timeout and -1 on failure.
screen_poll :: proc(s: ^ScreenCap, timeout_ms: int) -> int {
	return int(toom_screen_poll(s.handle, c.int(timeout_ms)))
}

// screen_frame returns the newest frame and its geometry.
screen_frame :: proc(s: ^ScreenCap, w, h, stride, y_invert: ^int) -> []u8 {
	fw: c.int
	fh: c.int
	fs: c.int
	fy: c.int
	p := toom_screen_frame(s.handle, &fw, &fh, &fs, &fy)
	if p == nil {
		return nil
	}
	w^ = int(fw)
	h^ = int(fh)
	stride^ = int(fs)
	y_invert^ = int(fy)
	return p[:int(fs) * int(fh)]
}

// screen_close stops the capture and releases every resource.
screen_close :: proc(s: ^ScreenCap) {
	if s.handle != nil {
		toom_screen_close(s.handle)
		s.handle = nil
	}
}
