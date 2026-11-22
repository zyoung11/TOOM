package toom

import "core:c"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// niri_win_provider tracks windows through the niri message IPC. The
// poll loop can later be swapped for the niri event stream without
// touching any caller.
niri_win_provider := WinProvider{
	name = "niri",
	probe = niri_probe,
	start = niri_start,
	stop = niri_stop,
	refresh = niri_refresh,
	track = niri_track,
}

// NiriLayout mirrors the layout object of one niri window.
NiriLayout :: struct {
	TilePos: []f64 `json:"tile_pos_in_workspace_view"`,
	Offset:  [2]f64 `json:"window_offset_in_tile"`,
	Size:    [2]i32 `json:"window_size"`,
}

// NiriWin mirrors one window of the niri IPC.
NiriWin :: struct {
	ID:      u64        `json:"id"`,
	Title:   string     `json:"title"`,
	AppID:   string     `json:"app_id"`,
	WSID:    u64        `json:"workspace_id"`,
	Floating: bool       `json:"is_floating"`,
	Layout:  NiriLayout `json:"layout"`,
}

// NiriWs mirrors one workspace of the niri IPC.
NiriWs :: struct {
	ID:     u64    `json:"id"`,
	Output: string `json:"output"`,
	Active: bool   `json:"is_active"`,
}

// NiriOut mirrors one output of the niri IPC. The outputs message is
// a JSON object keyed by output name, so it unmarshals into a map.
NiriOut :: struct {
	Name:    string `json:"name"`,
	Logical: struct {
		X: int `json:"x"`,
		Y: int `json:"y"`,
	} `json:"logical"`,
}

niri_run:   i32
niri_slow:  int
niri_mu:    sync.Mutex
niri_wins:  map[u64]WinInfo
niri_ws:    map[u64]NiriWs
niri_outs:  map[string]WinRect

// niri_probe reports whether the niri IPC socket is present.
niri_probe :: proc() -> bool {
	return os.get_env_alloc("NIRI_SOCKET", context.allocator) != ""
}

// niri_start spawns the polling thread.
niri_start :: proc() -> bool {
	sync.atomic_store(&niri_run, 1)
	niri_poll_tables()
	niri_poll()
	_ = thread.create_and_start(niri_thread)
	return true
}

// niri_stop asks the polling thread to exit.
niri_stop :: proc() {
	sync.atomic_store(&niri_run, 0)
}

// niri_refresh returns a snapshot of the cached windows.
niri_refresh :: proc() -> [dynamic]WinInfo {
	out: [dynamic]WinInfo
	sync.mutex_lock(&niri_mu)
	defer sync.mutex_unlock(&niri_mu)
	for _, w in niri_wins {
		info := w
		info.title = strings.clone(w.title)
		info.app = strings.clone(w.app)
		info.output = strings.clone(w.output)
		append(&out, info)
	}
	return out
}

// niri_track returns the cached state of one window.
niri_track :: proc(id: u64) -> (WinInfo, bool, bool) {
	sync.mutex_lock(&niri_mu)
	defer sync.mutex_unlock(&niri_mu)
	w, ok := niri_wins[id]
	if !ok {
		return {}, false, false
	}
	return w, w.shown, true
}

// niri_exec runs one niri command and returns its standard output.
niri_exec :: proc(cmd: string) -> string {
	mode: [2]u8
	mode[0] = 'r'
	cbuf: [48]u8
	f := clip_popen(to_cstr(cmd, cbuf[:]), cast(cstring)&mode[0])
	if f == nil {
		return ""
	}
	out: [dynamic]u8
	chunk: [4096]u8
	for clip_fgets(raw_data(chunk[:]), c.int(len(chunk)), f) != nil {
		for i in 0..<len(chunk) {
			if chunk[i] == 0 {
				break
			}
			append(&out, chunk[i])
		}
	}
	_ = clip_pclose(f)
	s := strings.clone(string(out[:]))
	delete(out)
	return s
}

// niri_poll_tables reloads the workspace and output tables.
niri_poll_tables :: proc() {
	ws_raw := niri_exec("niri msg --json workspaces")
	ws_list: []NiriWs
	if json.unmarshal(transmute([]u8)ws_raw, &ws_list) == nil {
		sync.mutex_lock(&niri_mu)
		niri_ws = make(map[u64]NiriWs)
		for w in ws_list {
			niri_ws[w.ID] = w
		}
		sync.mutex_unlock(&niri_mu)
	}
	out_raw := niri_exec("niri msg --json outputs")
	out_map: map[string]NiriOut
	if json.unmarshal(transmute([]u8)out_raw, &out_map) == nil {
		sync.mutex_lock(&niri_mu)
		niri_outs = make(map[string]WinRect)
		for _, o in out_map {
			niri_outs[o.Name] = WinRect{x = o.Logical.X, y = o.Logical.Y, w = 0, h = 0}
		}
		sync.mutex_unlock(&niri_mu)
		clear(&out_map)
	}
}

// niri_win_rect computes one window rectangle from its layout and the
// workspace and output tables.
niri_win_rect :: proc(w: NiriWin, ws: map[u64]NiriWs, outs: map[string]WinRect) -> (WinRect, bool) {
	if len(w.Layout.TilePos) < 2 {
		return {}, false
	}
	info, ok := ws[w.WSID]
	if !ok || !info.Active {
		return {}, false
	}
	o, ok2 := outs[info.Output]
	if !ok2 {
		return {}, false
	}
	return WinRect{
		x = o.x + int(w.Layout.TilePos[0] + w.Layout.Offset[0]),
		y = o.y + int(w.Layout.TilePos[1] + w.Layout.Offset[1]),
		w = int(w.Layout.Size[0]),
		h = int(w.Layout.Size[1]),
	}, true
}

// niri_poll reloads the window table into the cache.
niri_poll :: proc() {
	if niri_slow % 8 == 0 {
		niri_poll_tables()
	}
	niri_slow += 1
	raw := niri_exec("niri msg --json windows")
	wins: []NiriWin
	if json.unmarshal(transmute([]u8)raw, &wins) != nil {
		return
	}
	sync.mutex_lock(&niri_mu)
	defer sync.mutex_unlock(&niri_mu)
	next := make(map[u64]WinInfo)
	for w in wins {
		rect, shown := niri_win_rect(w, niri_ws, niri_outs)
		if !shown {
			if old, ok := niri_wins[w.ID]; ok {
				rect = old.rect
			}
		}
		title := w.Title
		if title == "" {
			title = w.AppID
		}
		outn := ""
		if info, ok := niri_ws[w.WSID]; ok {
			outn = info.Output
		}
		next[w.ID] = WinInfo{id = w.ID, title = title, app = w.AppID, output = outn, rect = rect, shown = shown, floating = w.Floating}
	}
	niri_wins = next
}

// niri_thread keeps the window cache fresh behind the provider
// interface.
niri_thread :: proc() {
	for sync.atomic_load(&niri_run) != 0 {
		niri_poll()
		time.sleep(250 * time.Millisecond)
	}
}
