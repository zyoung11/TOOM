package toom

// Tile is one picture region in terminal cells and pixels.
Tile :: struct {
	row, col: int,
	w, h:    int,
}

// layout_compute arranges n pictures on the terminal. It prefers a
// square grid and falls back to one column on narrow terminals. The
// last row of the screen is reserved for status text.
layout_compute :: proc(count_in: int, src_w, src_h: int) -> []Tile {
	n := max(count_in, 1)
	cols, rows := term_size()
	cw, ch := term_cell_pixels()
	full_w := cols * cw
	full_h := (rows - 1) * ch

	gcols := 1
	grows := n
	for gcols * grows < n {
		gcols += 1
	}
	best := gcols
	for c in 1..=n {
		r := (n + c - 1) / c
		if r * ch * 2 > full_w {
			continue
		}
		if c * r < n {
			continue
		}
		if abs(c - r) < abs(best - (n + best - 1) / best) {
			best = c
		}
	}
	gcols = best
	grows = (n + gcols - 1) / gcols

	cell_w := full_w / gcols
	cell_h := full_h / grows
	if src_w > 0 && src_h > 0 {
		max_w := cell_w
		max_h := cell_w * src_h / src_w
		if max_h > cell_h {
			max_h = cell_h
			max_w = cell_h * src_w / src_h
		}
		cell_w = max_w
		cell_h = max_h
	}
	cell_w -= cell_w % 2
	cell_h -= cell_h % 2
	if cell_w < 32 {
		cell_w = 32
	}
	if cell_h < 24 {
		cell_h = 24
	}

	tiles := make([]Tile, n)
	used_w := gcols * cell_w
	used_h := grows * cell_h
	off_x := (full_w - used_w) / 2
	off_y := (full_h - used_h) / 2
	for i in 0..<n {
		gy := i / gcols
		gx := i % gcols
		px := off_x + gx * cell_w
		py := off_y + gy * cell_h
		tiles[i] = Tile{
			row = py / ch + 1,
			col = px / cw + 1,
			w = cell_w,
			h = cell_h,
		}
	}
	return tiles
}

abs :: proc(v: int) -> int {
	if v < 0 {
		return -v
	}
	return v
}
