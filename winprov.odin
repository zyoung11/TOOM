package toom

// WinRect is one window rectangle in global logical coordinates.
WinRect :: struct {
	x, y, w, h: int,
}

// WinInfo is one application window known to a window provider.
WinInfo :: struct {
	id:     u64,
	title:  string,
	app:    string,
	output: string,
	rect:   WinRect,
	shown:  bool,
}

// win_entries holds the last window snapshot for menu building.
win_entries: [dynamic]WinInfo

// WinProvider hides compositor specific window tracking behind one
// interface so new backends plug in without touching the app.
WinProvider :: struct {
	name:    string,
	probe:   proc() -> bool,
	start:   proc() -> bool,
	stop:    proc(),
	refresh: proc() -> [dynamic]WinInfo,
	track:   proc(id: u64) -> (WinInfo, bool, bool),
}

// win_providers lists the window providers in probe order.
win_providers := [1]WinProvider{niri_win_provider}

win_active: ^WinProvider

// win_use starts the first window provider that reports availability.
win_use :: proc() -> bool {
	if win_active != nil {
		return true
	}
	for i in 0..<len(win_providers) {
		p := &win_providers[i]
		if p.probe() && p.start() {
			win_active = p
			return true
		}
	}
	return false
}

// win_list returns the current windows from the active provider. The
// caller owns the returned titles.
win_list :: proc() -> [dynamic]WinInfo {
	if win_active == nil {
		return nil
	}
	return win_active.refresh()
}

// win_track returns the cached state of one window. shown tells
// whether the window is on screen and alive tells whether it still
// exists.
win_track :: proc(id: u64) -> (WinInfo, bool, bool) {
	if win_active == nil {
		return {}, false, false
	}
	return win_active.track(id)
}

// win_stop releases the active window provider.
win_stop :: proc() {
	if win_active != nil {
		win_active.stop()
		win_active = nil
	}
}
