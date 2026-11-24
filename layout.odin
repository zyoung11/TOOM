package toom

// Tile is one member block: a picture rect centered inside a cell
// block with one caption row reserved below the picture. The rect is
// a fixed aspect box so the border never moves when a camera toggles.
// lim_w and lim_h cap the picture box in pixels so a whole thumbnail
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

// fit_pic scales a source into the max box keeping the source aspect
// and rounds both sides down to even pixel counts.
fit_pic :: proc(src_w, src_h, max_w, max_h: int) -> (int, int) {
	if src_w <= 0 || src_h <= 0 || max_w < 4 || max_h < 4 {
		return max(max_w, 4), max(max_h, 4)
	}
	w := max_w
	h := w * src_h / src_w
	if h > max_h {
		h = max_h
		w = h * src_w / src_h
	}
	w -= w % 2
	h -= h % 2
	return max(w, 4), max(h, 4)
}

// tile_fit computes the picture rect and the caption row of one block
// for the given box aspect.
tile_fit :: proc(t: ^Tile, src_w, src_h: int) {
	cw, ch := term_cell_pixels()
	max_w := t.bw * cw
	max_h := (t.bh - 1) * ch
	if t.lim_w > 0 {
		max_w = min(max_w, t.lim_w)
	}
	if t.lim_h > 0 {
		max_h = min(max_h, t.lim_h)
	}
	w, h := fit_pic(src_w, src_h, max_w, max_h)
	ph := (h + ch - 1) / ch
	pw := (w + cw - 1) / cw
	t.w, t.h = w, h
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
		w, h := fit_pic(4, 3, bw * cw, (bh - 1) * ch)
		score := w * h
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
// box size taken from the smallest strip block so their borders and
// captions line up.
layout_focus :: proc(count, focus, big_w, big_h: int) -> []Tile {
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
		strip_col := 1 + off_c + big_bw + 1
		strip_bw := vw - big_bw - 1
		tiles[f] = Tile {
			row = 1 + off_r,
			col = 1 + off_c,
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
		big_px := vw * cw
		_, ph_big := fit_pic(big_w, big_h, big_px, vh * ch)
		ph_big_c := (ph_big + ch - 1) / ch
		small_bw := vw / strip
		_, ph_small := fit_pic(4, 3, small_bw * cw, vh * ch * 30 / 100)
		ph_small_c := (ph_small + ch - 1) / ch
		total := ph_big_c + ph_small_c + 4
		if total > vh {
			ph_big_c = max(ph_big_c - (total - vh), 3)
			total = ph_big_c + ph_small_c + 4
		}
		top := 1 + off_r + max((vh - total) / 2, 0)
		tiles[f] = Tile {
			row  = top,
			col  = 1 + off_c,
			bw   = vw,
			bh   = ph_big_c + 1,
			snap = 2,
		}
		strip_row := top + ph_big_c + 1 + 2
		k := 0
		for i in 0 ..< n {
			if i == f {
				continue
			}
			left := 1 + off_c + k * vw / strip
			right := 1 + off_c + (k + 1) * vw / strip
			tiles[i] = Tile {
				row  = strip_row,
				col  = left,
				bw   = right - left - 1,
				bh   = ph_small_c + 1,
				snap = 2,
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
			tiles[i].lim_w = lbw * cw
			tiles[i].lim_h = lbh * ch
		}
	}
	return tiles
}
