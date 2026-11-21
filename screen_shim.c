// screen_shim.c - wlr-screencopy capture client for toom screen
// sharing. It speaks the Wayland wire protocol through the wlshim
// trampolines and hands out BGRA frames from shared memory.

#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <wayland-client.h>

#include "screencopy-client-protocol.h"
#include <stdio.h>

int wl_shim_init(void);
void toom_screen_close(void* handle);

#define MAX_OUTPUTS 8

struct toom_screen;

struct toom_screen_output {
	struct toom_screen* owner;
	int idx;
	struct wl_output* obj;
	uint32_t gname;
	int x;
	int y;
	char desc[80];
};

struct toom_screen {
	struct wl_display* disp;
	struct wl_registry* registry;
	struct zwlr_screencopy_manager_v1* mgr;
	struct wl_shm* shm;
	struct wl_output* output;
	struct zwlr_screencopy_frame_v1* frame;
	uint32_t mgr_name;
	uint32_t mgr_version;
	uint32_t shm_name;
	struct toom_screen_output outs[MAX_OUTPUTS];
	uint32_t out_names[MAX_OUTPUTS];
	int out_count;
	int out_pick;
	int cursor;
	int rx, ry, rw, rh;
	int fmt;
	int w;
	int h;
	int stride;
	int y_invert;
	int ready_idx;
	int cur;
	int dead;
	size_t buf_size;
	int fds[2];
	size_t map_size;
	void* maps[2];
	struct wl_shm_pool* pools[2];
	struct wl_buffer* bufs[2];
};

static void registry_global(void* data, struct wl_registry* reg, uint32_t name, const char* interface, uint32_t version) {
	struct toom_screen* s = data;
	if (strcmp(interface, zwlr_screencopy_manager_v1_interface.name) == 0) {
		s->mgr_name = name;
		s->mgr_version = version < 3 ? version : 3;
	} else if (strcmp(interface, "wl_shm") == 0) {
		s->shm_name = name;
	} else if (strcmp(interface, "wl_output") == 0 && s->out_count < MAX_OUTPUTS) {
		s->outs[s->out_count].gname = name;
		s->out_count += 1;
	}
	(void)data;
}

static void registry_global_remove(void* data, struct wl_registry* reg, uint32_t name) {
	struct toom_screen* s = data;
	if (s->out_count > 0 && name == s->outs[s->out_pick].gname) {
		s->dead = 1;
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static void shm_format(void* data, struct wl_shm* shm, uint32_t format) {
}

static const struct wl_shm_listener shm_listener = {
	.format = shm_format,
};

static void output_geometry(void* data, struct wl_output* output, int32_t x, int32_t y, int32_t phys_w, int32_t phys_h, int32_t subpixel, const char* make, const char* model, int32_t transform) {
	struct toom_screen_output* o = data;
	o->x = x;
	o->y = y;
}

static void output_mode(void* data, struct wl_output* output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
}

static void output_done(void* data, struct wl_output* output) {
}

static void output_scale(void* data, struct wl_output* output, int32_t factor) {
}

static void output_name(void* data, struct wl_output* output, const char* name) {
	struct toom_screen_output* o = data;
	if (name) {
		snprintf(o->desc, sizeof(o->desc), "%s", name);
	}
}

static void output_description(void* data, struct wl_output* output, const char* description) {
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

static void buffer_release(void* data, struct wl_buffer* buffer) {
}

static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static void frame_request(struct toom_screen* s);

static void buffer_free(struct toom_screen* s, int i) {
	if (s->bufs[i]) {
		wl_buffer_destroy(s->bufs[i]);
		s->bufs[i] = NULL;
	}
	if (s->pools[i]) {
		wl_shm_pool_destroy(s->pools[i]);
		s->pools[i] = NULL;
	}
	if (s->maps[i]) {
		munmap(s->maps[i], s->map_size);
		s->maps[i] = NULL;
	}
	if (s->fds[i] >= 0) {
		close(s->fds[i]);
		s->fds[i] = -1;
	}
}

static int pool_ensure(struct toom_screen* s) {
	size_t need = (size_t)s->stride * (size_t)s->h;
	if (s->bufs[0] && s->buf_size == need) {
		return 0;
	}
	buffer_free(s, 0);
	buffer_free(s, 1);
	s->buf_size = need;
	s->map_size = need;
	for (int i = 0; i < 2; i++) {
		s->fds[i] = memfd_create("toom-screen", 0);
		if (s->fds[i] < 0) {
			return -1;
		}
		if (ftruncate(s->fds[i], (off_t)need) != 0) {
			return -1;
		}
		s->maps[i] = mmap(NULL, need, PROT_READ | PROT_WRITE, MAP_SHARED, s->fds[i], 0);
		if (s->maps[i] == MAP_FAILED) {
			s->maps[i] = NULL;
			return -1;
		}
		s->pools[i] = wl_shm_create_pool(s->shm, s->fds[i], (int32_t)need);
		s->bufs[i] = wl_shm_pool_create_buffer(s->pools[i], 0, s->w, s->h, s->stride, (uint32_t)s->fmt);
		wl_proxy_add_listener((struct wl_proxy*)s->bufs[i], (void (**)(void))&buffer_listener, s);
	}
	return 0;
}

static void frame_buffer(void* data, struct zwlr_screencopy_frame_v1* frame, uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
	struct toom_screen* s = data;
	s->fmt = (int)format;
	s->w = (int)width;
	s->h = (int)height;
	s->stride = (int)stride;
	if (pool_ensure(s) != 0 || s->bufs[s->cur] == NULL) {
		s->dead = 1;
	}
}

static void frame_flags(void* data, struct zwlr_screencopy_frame_v1* frame, uint32_t flags) {
	struct toom_screen* s = data;
	s->y_invert = (flags & 1) != 0;
}

static void frame_ready(void* data, struct zwlr_screencopy_frame_v1* frame, uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
	struct toom_screen* s = data;
	zwlr_screencopy_frame_v1_destroy(s->frame);
	s->frame = NULL;
	s->ready_idx = s->cur;
	s->cur = 1 - s->cur;
	frame_request(s);
}

static void frame_failed(void* data, struct zwlr_screencopy_frame_v1* frame) {
	struct toom_screen* s = data;
	zwlr_screencopy_frame_v1_destroy(s->frame);
	s->frame = NULL;
	s->dead = 1;
}

static void frame_damage(void* data, struct zwlr_screencopy_frame_v1* frame, uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
}

static void frame_linux_dmabuf(void* data, struct zwlr_screencopy_frame_v1* frame, uint32_t format, uint32_t width, uint32_t height) {
}

static void frame_buffer_done(void* data, struct zwlr_screencopy_frame_v1* frame) {
	struct toom_screen* s = data;
	if (s->dead || s->bufs[s->cur] == NULL) {
		return;
	}
	zwlr_screencopy_frame_v1_copy(s->frame, s->bufs[s->cur]);
}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
	.buffer = frame_buffer,
	.flags = frame_flags,
	.ready = frame_ready,
	.failed = frame_failed,
	.damage = frame_damage,
	.linux_dmabuf = frame_linux_dmabuf,
	.buffer_done = frame_buffer_done,
};

static void frame_request(struct toom_screen* s) {
	if (s->rw > 0 && s->rh > 0) {
		s->frame = zwlr_screencopy_manager_v1_capture_output_region(s->mgr, s->cursor, s->output, s->rx, s->ry, s->rw, s->rh);
	} else {
		s->frame = zwlr_screencopy_manager_v1_capture_output(s->mgr, s->cursor, s->output);
	}
	wl_proxy_add_listener((struct wl_proxy*)s->frame, (void (**)(void))&frame_listener, s);
}

static void output_bind_all(struct toom_screen* s) {
	for (int i = 0; i < s->out_count; i++) {
		s->outs[i].owner = s;
		s->outs[i].idx = i;
		s->outs[i].obj = (struct wl_output*)wl_registry_bind(s->registry, s->outs[i].gname, &wl_output_interface, 4);
		wl_proxy_add_listener((struct wl_proxy*)s->outs[i].obj, (void (**)(void))&output_listener, &s->outs[i]);
	}
}

// toom_screen_list fills buf with one output per line in the form
// name<TAB>description<NUL> and returns the output count.
int toom_screen_list(char* buf, int cap) {
	if (wl_shim_init() != 0 || !buf || cap < 1) {
		return 0;
	}
	buf[0] = 0;
	struct toom_screen s;
	memset(&s, 0, sizeof(s));
	s.disp = wl_display_connect(NULL);
	if (!s.disp) {
		return 0;
	}
	union wl_argument none[1];
	memset(none, 0, sizeof(none));
	s.registry = (struct wl_registry*)wl_proxy_marshal_array_flags((struct wl_proxy*)s.disp, WL_DISPLAY_GET_REGISTRY, &wl_registry_interface, 1, 0, none);
	wl_proxy_add_listener((struct wl_proxy*)s.registry, (void (**)(void))&registry_listener, &s);
	wl_display_roundtrip(s.disp);
	output_bind_all(&s);
	wl_display_roundtrip(s.disp);
	int pos = 0;
	for (int i = 0; i < s.out_count; i++) {
		const char* nm = s.outs[i].desc[0] ? s.outs[i].desc : "?";
		int n = snprintf(buf + pos, (size_t)(cap - pos), "%s", nm);
		if (n < 0 || pos + n + 1 >= cap) {
			break;
		}
		pos += n + 1;
	}
	for (int i = 0; i < s.out_count; i++) {
		if (s.outs[i].obj) {
			wl_proxy_destroy((struct wl_proxy*)s.outs[i].obj);
		}
	}
	wl_proxy_destroy((struct wl_proxy*)s.registry);
	wl_display_flush(s.disp);
	wl_display_disconnect(s.disp);
	return s.out_count;
}

// toom_screen_open_ex starts capturing one output. The region is a
// slurp style rectangle or null for the full output. The name picks
// the output and may be empty for the first one.
void* toom_screen_open_ex(const char* name, const char* region, int cursor) {
	if (wl_shim_init() != 0) {
		return NULL;
	}
	struct toom_screen* s = calloc(1, sizeof(struct toom_screen));
	if (!s) {
		return NULL;
	}
	s->fds[0] = -1;
	s->fds[1] = -1;
	s->cursor = cursor != 0;
	s->disp = wl_display_connect(NULL);
	if (!s->disp) {
		free(s);
		return NULL;
	}
	union wl_argument none[1];
	memset(none, 0, sizeof(none));
	s->registry = (struct wl_registry*)wl_proxy_marshal_array_flags((struct wl_proxy*)s->disp, WL_DISPLAY_GET_REGISTRY, &wl_registry_interface, 1, 0, none);
	wl_proxy_add_listener((struct wl_proxy*)s->registry, (void (**)(void))&registry_listener, s);
	wl_display_roundtrip(s->disp);
	if (s->mgr_name == 0 || s->shm_name == 0 || s->out_count == 0) {
		toom_screen_close(s);
		return NULL;
	}
	output_bind_all(s);
	wl_display_roundtrip(s->disp);
	s->out_pick = 0;
	if (name && name[0]) {
		for (int i = 0; i < s->out_count; i++) {
			if (strcmp(s->outs[i].desc, name) == 0) {
				s->out_pick = i;
				break;
			}
		}
	}
	s->mgr = (struct zwlr_screencopy_manager_v1*)wl_registry_bind(s->registry, s->mgr_name, &zwlr_screencopy_manager_v1_interface, s->mgr_version);
	s->shm = (struct wl_shm*)wl_registry_bind(s->registry, s->shm_name, &wl_shm_interface, 1);
	wl_proxy_add_listener((struct wl_proxy*)s->shm, (void (**)(void))&shm_listener, s);
	s->output = s->outs[s->out_pick].obj;
	if (region && region[0]) {
		int rw = 0, rh = 0;
		char out_name[80];
		out_name[0] = 0;
		int nx = 0, ny = 0;
		if (sscanf(region, "%d,%d %dx%d %79s", &nx, &ny, &rw, &rh, out_name) >= 4) {
			int ox = 0, oy = 0;
			if (out_name[0]) {
				for (int i = 0; i < s->out_count; i++) {
					if (strcmp(s->outs[i].desc, out_name) == 0) {
						s->out_pick = i;
						s->output = s->outs[i].obj;
						ox = s->outs[i].x;
						oy = s->outs[i].y;
						break;
					}
				}
			} else {
				ox = s->outs[s->out_pick].x;
				oy = s->outs[s->out_pick].y;
			}
			s->rx = nx - ox;
			s->ry = ny - oy;
			s->rw = rw;
			s->rh = rh;
		}
	}
	frame_request(s);
	return s;
}

// toom_screen_open starts capturing the first output in full.
void* toom_screen_open(int output_index) {
	(void)output_index;
	return toom_screen_open_ex(NULL, NULL, 1);
}

// toom_screen_poll pumps the Wayland connection until a frame is
// ready. It returns 1 for a frame, 0 on timeout and -1 on failure.
int toom_screen_poll(void* handle, int timeout_ms) {
	struct toom_screen* s = handle;
	if (!s || s->dead) {
		return -1;
	}
	if (s->ready_idx >= 0) {
		return 1;
	}
	wl_display_flush(s->disp);
	if (wl_display_prepare_read(s->disp) == 0) {
		struct pollfd pfd;
		pfd.fd = wl_display_get_fd(s->disp);
		pfd.events = POLLIN;
		if (poll(&pfd, 1, timeout_ms) > 0) {
			wl_display_read_events(s->disp);
		} else {
			wl_display_cancel_read(s->disp);
		}
	}
	wl_display_dispatch_pending(s->disp);
	if (s->dead) {
		return -1;
	}
	return s->ready_idx >= 0 ? 1 : 0;
}

// toom_screen_frame returns the newest frame and its geometry. The
// pointer stays valid until the second following frame.
void* toom_screen_frame(void* handle, int* w, int* h, int* stride, int* y_invert) {
	struct toom_screen* s = handle;
	if (!s || s->ready_idx < 0) {
		return NULL;
	}
	*w = s->w;
	*h = s->h;
	*stride = s->stride;
	*y_invert = s->y_invert;
	void* base = s->maps[s->ready_idx];
	s->ready_idx = -1;
	return base;
}

// toom_screen_close stops the capture and releases every resource.
void toom_screen_close(void* handle) {
	struct toom_screen* s = handle;
	if (!s) {
		return;
	}
	if (s->frame) {
		zwlr_screencopy_frame_v1_destroy(s->frame);
	}
	buffer_free(s, 0);
	buffer_free(s, 1);
	if (s->mgr) {
		zwlr_screencopy_manager_v1_destroy(s->mgr);
	}
	if (s->output) {
		wl_proxy_destroy((struct wl_proxy*)s->output);
	}
	if (s->shm) {
		wl_proxy_destroy((struct wl_proxy*)s->shm);
	}
	if (s->registry) {
		wl_proxy_destroy((struct wl_proxy*)s->registry);
	}
	wl_display_flush(s->disp);
	wl_display_disconnect(s->disp);
	free(s);
}
