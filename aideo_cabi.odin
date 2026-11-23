package toom

import "core:c"

// AideoConfig mirrors aideo_config in aideo.h.
AideoConfig :: struct {
	fd:          c.int,
	src_w:       c.int,
	src_h:       c.int,
	out_w:       c.int,
	out_h:       c.int,
	colors:      c.int,
	origin_row:  c.int,
	origin_col:  c.int,
	border_px:   c.int,
	border_color: c.int,
}

// AideoEngine is the opaque terminal rendering engine from aideo.h.
AideoEngine :: struct {}
