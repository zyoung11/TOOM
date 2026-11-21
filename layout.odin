package toom

// Tile is one member block: a picture rect centered inside a cell
// block with one caption row reserved below the picture.
Tile :: struct {
	row, col:  int,
	bw, bh:    int,
	w, h:      int,
	prow, pcol: int,
	cap:       int,
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
// for the given source size.
tile_fit :: proc(t: ^Tile, src_w, src_h: int) {
	cw, ch := term_cell_pixels()
	max_w := t.bw * cw
	max_h := (t.bh - 1) * ch
	w, h := fit_pic(src_w, src_h, max_w, max_h)
	ph := (h + ch - 1) / ch
	pw := (w + cw - 1) / cw
	t.w, t.h = w, h
	t.prow = t.row + max((t.bh - ph - 1) / 2, 0)
	t.pcol = t.col + max((t.bw - pw) / 2, 0)
	t.cap = t.prow + ph
}

// layout_grid arranges count members in the grid whose tiles carry
// the largest pictures. Empty blocks are allowed and the first one is
// returned as the info card slot. The tiles cover the area above the
// two footer rows.
layout_grid :: proc(count, src_w, src_h: int) -> ([]Tile, Tile, bool) {
	n := max(count, 1)
	cols, rows := term_size()
	cw, ch := term_cell_pixels()
	area_rows := rows - 2
	gap := 1
	best_gc, best_gr, best_score := 0, 0, -1
	for gc in 1..=n {
		gr := (n + gc - 1) / gc
		bw := (cols - (gc - 1) * gap) / gc
		bh := area_rows / gr
		if bw < 4 || bh < 2 {
			continue
		}
		w, h := fit_pic(src_w, src_h, bw * cw, (bh - 1) * ch)
		score := w * h
		if score > best_score || (score == best_score && gc * gr < best_gc * best_gr) {
			best_gc, best_gr, best_score = gc, gr, score
		}
	}
	if best_gc == 0 {
		return nil, Tile{}, false
	}
	bw := (cols - (best_gc - 1) * gap) / best_gc
	bh := area_rows / best_gr
	left := (cols - (best_gc * bw + (best_gc - 1) * gap)) / 2
	top := 1 + (area_rows - best_gr * bh) / 2
	tiles := make([]Tile, n)
	card: Tile
	has_card := false
	for i in 0..<best_gc * best_gr {
		gy := i / best_gc
		gx := i % best_gc
		b := Tile{row = top + gy * bh, col = left + gx * (bw + gap), bw = bw, bh = bh}
		if i < n {
			tiles[i] = b
		} else if !has_card {
			card = b
			has_card = true
		}
	}
	return tiles, card, has_card
}

// layout_focus arranges one big block for the focused member and a
// thumbnail strip for every other member. Wide terminals put the
// strip on the right, tall terminals put it at the bottom.
layout_focus :: proc(count, focus, src_w, src_h: int) -> []Tile {
	n := max(count, 1)
	f := min(max(focus, 0), n - 1)
	cols, rows := term_size()
	cw, ch := term_cell_pixels()
	area_rows := rows - 2
	if area_rows < 2 {
		return nil
	}
	tiles := make([]Tile, n)
	strip := n - 1
	if strip == 0 {
		tiles[0] = Tile{row = 1, col = 1, bw = cols, bh = area_rows}
		return tiles
	}
	horizontal := cols * cw * 10 >= area_rows * ch * 11
	if horizontal {
		big_bw := cols * 70 / 100
		strip_col := 1 + big_bw + 1
		strip_bw := cols - big_bw - 1
		tiles[f] = Tile{row = 1, col = 1, bw = big_bw, bh = area_rows}
		k := 0
		for i in 0..<n {
			if i == f {
				continue
			}
			top := 1 + k * area_rows / strip
			bot := 1 + (k + 1) * area_rows / strip
			tiles[i] = Tile{row = top, col = strip_col, bw = strip_bw, bh = bot - top}
			k += 1
		}
	} else {
		big_bh := area_rows * 70 / 100
		strip_row := 1 + big_bh + 1
		strip_bh := area_rows - big_bh - 1
		tiles[f] = Tile{row = 1, col = 1, bw = cols, bh = big_bh}
		k := 0
		for i in 0..<n {
			if i == f {
				continue
			}
			left := k * cols / strip
			right := (k + 1) * cols / strip
			tiles[i] = Tile{row = strip_row, col = left + 1, bw = right - left, bh = strip_bh}
			k += 1
		}
	}
	return tiles
}
