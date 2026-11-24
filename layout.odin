package toom

// Tile is one member block: a picture rect centered inside a cell
// block with one caption row reserved below the picture. The rect is
// a fixed aspect box so the border never moves when a camera toggles.
// lim_w and lim_h cap the picture box in cells so a whole thumbnail
// strip shares one box size, zero keeps the block limit.
Tile :: struct {
	row, col:     int,
	bw, bh:       int,
	lim_w, lim_h: int,
	w, h:         int,
	prow, pcol:   int,
	cap:          int,
	snap:         i8,
}

// LayoutMode is the picture arrangement cycled with f.
LayoutMode :: enum {
	Grid,
	Focus,
}

// box_cells picks the whole cell box nearest to the aspect ratio
// that fits the limits. Width comes first so a box fills its limit
// width and the height follows, then a height cap pulls both sides
// in.
box_cells :: proc(in_w, in_h, max_bw, max_bh, cw, ch: int) -> (int, int) {
	aw := in_w
	ah := in_h
	if aw <= 0 || ah <= 0 {
		aw, ah = 4, 3
	}
	if max_bw < 1 || max_bh < 1 {
		return max(max_bw, 1), max(max_bh, 1)
	}
	pw := max_bw
	ph := (pw * cw * ah * 2 + aw * ch) / (aw * ch * 2)
	if ph > max_bh {
		ph = max_bh
		pw = min((ph * ch * aw * 2 + ah * cw) / (ah * cw * 2), max_bw)
	}
	return pw, ph
}

// tile_fit computes the picture rect and the caption row of one block
// for the given box aspect. The box is whole cells so text drawn at
// the box corners lines up with the picture edges.
tile_fit :: proc(t: ^Tile, src_w, src_h: int) {
	cw, ch := term_cell_pixels()
	mbw := t.bw
	mbh := t.bh - 1
	if t.lim_w > 0 {
		mbw = min(mbw, t.lim_w)
	}
	if t.lim_h > 0 {
		mbh = min(mbh, t.lim_h)
	}
	pw, ph := box_cells(src_w, src_h, mbw, mbh, cw, ch)
	t.w, t.h = pw * cw, ph * ch
	switch t.snap {
	case 1:
		t.prow = t.row + max(t.bh - 1 - ph, 0)
	case 2:
		t.prow = t.row
	case:
		t.prow = t.row + max((t.bh - ph - 1) / 2, 0)
	}
	t.pcol = t.col + max((t.bw - pw) / 2, 0)
	t.cap = t.prow + ph
}

// share_box_aspect picks the share box ratio nearest to the content
// ratio: 16:10 below the midpoint of 16:9 and 16:10, 16:9 above.
share_box_aspect :: proc(w, h: int) -> (int, int) {
	if w > 0 && h > 0 && w * 45 < h * 76 {
		return 16, 10
	}
	return 16, 9
}

// canvas_width is the shared picture area width in columns like the
// BM progress bar width. Narrow terminals shrink it and the height is
// derived from the 16:9 video aspect.
canvas_width: int = 200

// canvas_box clamps the drawable area to the canvas width and returns
// the centered box as row, col, width and height in cells.
canvas_box :: proc(cols, rows: int) -> (int, int, int, int) {
	cw, ch := term_cell_pixels()
	vw := min(cols, canvas_width)
	vh := min(rows, canvas_width * max(cw, 1) * 9 / (max(ch, 1) * 16))
	vw = max(vw, 8)
	vh = max(vh, 4)
	return (rows - vh) / 2, (cols - vw) / 2, vw, vh
}

// layout_grid arranges count members in the grid whose tiles carry
// the largest pictures. Empty blocks stay empty. The tiles cover the
// centered canvas above the two footer rows.
layout_grid :: proc(count: int) -> []Tile {
	n := max(count, 1)
	cols, rows := term_size()
	crows := rows - 2
	cw, ch := term_cell_pixels()
	off_r, off_c, vw, vh := canvas_box(cols, crows)
	gap := 1
	best_gc, best_gr, best_score := 0, 0, -1
	for gc in 1 ..= n {
		gr := (n + gc - 1) / gc
		bw := (vw - (gc - 1) * gap) / gc
		bh := vh / gr
		if bw < 4 || bh < 2 {
			continue
		}
		pw, ph := box_cells(4, 3, bw, bh - 1, cw, ch)
		score := pw * ph
		if score > best_score || (score == best_score && gc * gr < best_gc * best_gr) {
			best_gc, best_gr, best_score = gc, gr, score
		}
	}
	if best_gc == 0 {
		return nil
	}
	bw := (vw - (best_gc - 1) * gap) / best_gc
	bh := vh / best_gr
	left := 1 + off_c + (vw - (best_gc * bw + (best_gc - 1) * gap)) / 2
	top := 1 + off_r + (vh - best_gr * bh) / 2
	tiles := make([]Tile, n)
	for i in 0 ..< min(n, best_gc * best_gr) {
		gy := i / best_gc
		gx := i % best_gc
		tiles[i] = Tile {
			row = top + gy * bh,
			col = left + gx * (bw + gap),
			bw  = bw,
			bh  = bh,
		}
	}
	return tiles
}

// layout_focus arranges one big block for the focused member and a
// thumbnail strip for every other member on the centered canvas. Wide
// terminals put the strip on the right, tall terminals put it at the
// bottom. The big block takes the given box aspect and every
// thumbnail takes the camera box aspect. All thumbnails share one
// box size so their borders and captions line up, and the bottom
// strip spans the big box width so both side edges align with it.
// The swap flag mirrors the big block and the strip along the layout
// axis so a share can sit on either side.
layout_focus :: proc(count, focus, big_w, big_h: int, swap: bool) -> []Tile {
	n := max(count, 1)
	f := min(max(focus, 0), n - 1)
	cols, rows := term_size()
	cw, ch := term_cell_pixels()
	crows := rows - 2
	if crows < 2 {
		return nil
	}
	off_r, off_c, vw, vh := canvas_box(cols, crows)
	tiles := make([]Tile, n)
	strip := n - 1
	if strip == 0 {
		tiles[0] = Tile {
			row = 1 + off_r,
			col = 1 + off_c,
			bw  = vw,
			bh  = vh,
		}
		return tiles
	}
	horizontal := vw * cw * 10 >= vh * ch * 11
	if horizontal {
		big_bw := vw * 70 / 100
		strip_bw := vw - big_bw - 1
		big_col := 1 + off_c
		strip_col := 1 + off_c + big_bw + 1
		if swap {
			big_col = 1 + off_c + strip_bw + 1
			strip_col = 1 + off_c
		}
		tiles[f] = Tile {
			row = 1 + off_r,
			col = big_col,
			bw  = big_bw,
			bh  = vh,
		}
		k := 0
		for i in 0 ..< n {
			if i == f {
				continue
			}
			if strip == 2 {
				if k == 0 {
					tiles[i] = Tile {
						row  = 1 + off_r,
						col  = strip_col,
						bw   = strip_bw,
						bh   = vh / 2 - 1,
						snap = 1,
					}
				} else {
					tiles[i] = Tile {
						row  = 1 + off_r + vh / 2,
						col  = strip_col,
						bw   = strip_bw,
						bh   = vh - vh / 2,
						snap = 2,
					}
				}
				k += 1
				continue
			}
			top := 1 + off_r + k * vh / strip
			bot := 1 + off_r + (k + 1) * vh / strip
			tiles[i] = Tile {
				row = top,
				col = strip_col,
				bw  = strip_bw,
				bh  = bot - top,
			}
			k += 1
		}
	} else {
		small_bw := max(vw / strip - 1, 1)
		ph_cap := max(vh * 30 / 100, 1)
		pw_s, ph_s := box_cells(4, 3, small_bw, ph_cap, cw, ch)
		_, ph_big := box_cells(big_w, big_h, vw, vh, cw, ch)
		total := ph_big + ph_s + 4
		if total > vh {
			ph_big = max(ph_big - (total - vh), 3)
			total = ph_big + ph_s + 4
		}
		pw_big, _ := box_cells(big_w, big_h, vw, ph_big, cw, ch)
		top := 1 + off_r + max((vh - total) / 2, 0)
		big_row := top
		strip_row := top + ph_big + 1 + 2
		if swap {
			strip_row = top
			big_row = top + ph_s + 1 + 2
		}
		tiles[f] = Tile {
			row  = big_row,
			col  = 1 + off_c,
			bw   = vw,
			bh   = ph_big + 1,
			snap = 2,
		}
		bl := 1 + off_c + (vw - pw_big) / 2
		span := max(pw_big - pw_s, 0)
		k := 0
		for i in 0 ..< n {
			if i == f {
				continue
			}
			x := bl + span / 2
			if strip > 1 {
				x = bl + k * span / (strip - 1)
			}
			tiles[i] = Tile {
				row   = strip_row,
				col   = x,
				bw    = pw_s,
				bh    = ph_s + 1,
				lim_w = pw_s,
				lim_h = ph_s,
				snap  = 2,
			}
			k += 1
		}
	}
	lbw := 0
	lbh := 0
	for i in 0 ..< n {
		if i == f {
			continue
		}
		if lbw == 0 || tiles[i].bw < lbw {
			lbw = tiles[i].bw
		}
		if lbh == 0 || tiles[i].bh - 1 < lbh {
			lbh = tiles[i].bh - 1
		}
	}
	if lbw > 0 && lbh > 0 {
		for i in 0 ..< n {
			if i == f {
				continue
			}
			if tiles[i].lim_w != 0 {
				continue
			}
			tiles[i].lim_w = lbw
			tiles[i].lim_h = lbh
		}
	}
	return tiles
}
