// wlshim.c - dlopen trampolines for the libwayland-client entry points
// used by the screen capture glue. The binary keeps no link time
// Wayland dependency and loads the library only for screen sharing.

#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

struct wl_proxy;
struct wl_display;
struct wl_message;

// wl_interface mirrors the public layout of the Wayland interface
// table so core interface symbols can be copied in at load time.
struct wl_message {
	const char* name;
	const char* signature;
	const struct wl_interface** types;
};

struct wl_interface {
	const char* name;
	int version;
	int method_count;
	const struct wl_message* methods;
	int event_count;
	const struct wl_message* events;
};

// wl_argument mirrors the public argument union of the Wayland
// marshalling API.
union wl_argument {
	int32_t i;
	uint32_t u;
	int32_t f;
	const char* s;
	struct wl_proxy* o;
};

static void* wl_lib;

static struct wl_proxy* (*p_marshal_array_flags)(struct wl_proxy*, uint32_t, const struct wl_interface*, uint32_t, uint32_t, union wl_argument*);
static int (*p_add_listener)(struct wl_proxy*, void (**)(void), void*);
static void (*p_set_user_data)(struct wl_proxy*, void*);
static void* (*p_get_user_data)(struct wl_proxy*);
static void (*p_proxy_destroy)(struct wl_proxy*);
static struct wl_display* (*p_display_connect)(const char*);
static void (*p_display_disconnect)(struct wl_display*);
static int (*p_display_get_fd)(struct wl_display*);
static int (*p_display_dispatch_pending)(struct wl_display*);
static int (*p_display_flush)(struct wl_display*);
static int (*p_display_prepare_read)(struct wl_display*);
static int (*p_display_read_events)(struct wl_display*);
static void (*p_display_cancel_read)(struct wl_display*);
static int (*p_display_roundtrip)(struct wl_display*);
static int (*p_display_get_error)(struct wl_display*);
static uint32_t (*p_proxy_get_version)(struct wl_proxy*);
static const char* (*p_proxy_get_class)(struct wl_proxy*);

struct wl_interface wl_display_interface;

extern const struct wl_interface zwlr_screencopy_manager_v1_interface;
extern const struct wl_interface zwlr_screencopy_frame_v1_interface;

const char* wl_proxy_get_class(struct wl_proxy* proxy);
uint32_t wl_proxy_get_version(struct wl_proxy* proxy);

struct wl_interface wl_registry_interface;
struct wl_interface wl_shm_interface;
struct wl_interface wl_shm_pool_interface;
struct wl_interface wl_buffer_interface;
struct wl_interface wl_output_interface;

#define WL_LOAD(field, name) \
	do { \
		*(void**)&(field) = dlsym(wl_lib, (name)); \
		if ((field) == 0) { \
			dlclose(wl_lib); \
			wl_lib = 0; \
			return -1; \
		} \
	} while (0)

// wl_shim_init loads the Wayland client library and copies the core
// interface tables. It returns 0 on success.
int wl_shim_init(void) {
	if (wl_lib) {
		return 0;
	}
	wl_lib = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
	if (!wl_lib) {
		return -1;
	}
	WL_LOAD(p_marshal_array_flags, "wl_proxy_marshal_array_flags");
	WL_LOAD(p_add_listener, "wl_proxy_add_listener");
	WL_LOAD(p_set_user_data, "wl_proxy_set_user_data");
	WL_LOAD(p_get_user_data, "wl_proxy_get_user_data");
	WL_LOAD(p_proxy_destroy, "wl_proxy_destroy");
	WL_LOAD(p_display_connect, "wl_display_connect");
	WL_LOAD(p_display_disconnect, "wl_display_disconnect");
	WL_LOAD(p_display_get_fd, "wl_display_get_fd");
	WL_LOAD(p_display_dispatch_pending, "wl_display_dispatch_pending");
	WL_LOAD(p_display_flush, "wl_display_flush");
	WL_LOAD(p_display_prepare_read, "wl_display_prepare_read");
	WL_LOAD(p_display_read_events, "wl_display_read_events");
	WL_LOAD(p_display_cancel_read, "wl_display_cancel_read");
	WL_LOAD(p_display_roundtrip, "wl_display_roundtrip");
	WL_LOAD(p_display_get_error, "wl_display_get_error");
	WL_LOAD(p_proxy_get_version, "wl_proxy_get_version");
	WL_LOAD(p_proxy_get_class, "wl_proxy_get_class");
	memcpy(&wl_display_interface, dlsym(wl_lib, "wl_display_interface"), sizeof(struct wl_interface));
	memcpy(&wl_registry_interface, dlsym(wl_lib, "wl_registry_interface"), sizeof(struct wl_interface));
	memcpy(&wl_shm_interface, dlsym(wl_lib, "wl_shm_interface"), sizeof(struct wl_interface));
	memcpy(&wl_shm_pool_interface, dlsym(wl_lib, "wl_shm_pool_interface"), sizeof(struct wl_interface));
	memcpy(&wl_buffer_interface, dlsym(wl_lib, "wl_buffer_interface"), sizeof(struct wl_interface));
	memcpy(&wl_output_interface, dlsym(wl_lib, "wl_output_interface"), sizeof(struct wl_interface));
	return 0;
}


// wl_proxy_marshal_flags walks the message signature of the proxy
// class, collects the variadic arguments and forwards them through the
// array marshaller so the generated protocol inlines work unchanged.
struct wl_proxy* wl_proxy_marshal_flags(struct wl_proxy* proxy, uint32_t opcode, const struct wl_interface* interface, uint32_t version, uint32_t flags, ...) {
	static const struct wl_interface* (*p_get_class_iface)(struct wl_proxy*);
	const char* cls = wl_proxy_get_class(proxy);
	const struct wl_interface* meta = NULL;
	static const char* names[] = {"wl_display", "wl_registry", "wl_shm", "wl_shm_pool", "wl_buffer", "wl_output", "zwlr_screencopy_manager_v1", "zwlr_screencopy_frame_v1", NULL};
	const struct wl_interface* tables[] = {&wl_display_interface, &wl_registry_interface, &wl_shm_interface, &wl_shm_pool_interface, &wl_buffer_interface, &wl_output_interface, &zwlr_screencopy_manager_v1_interface, &zwlr_screencopy_frame_v1_interface};
	(void)p_get_class_iface;
	for (int i = 0; names[i]; i++) {
		if (cls && strcmp(cls, names[i]) == 0) {
			meta = tables[i];
			break;
		}
	}
	if (!meta || opcode >= (uint32_t)meta->method_count) {
		return NULL;
	}
	const char* sig = meta->methods[opcode].signature;
	union wl_argument args[16];
	memset(args, 0, sizeof(args));
	va_list ap;
	va_start(ap, flags);
	int slot = 0;
	for (const char* c = sig; *c && slot < 16; c++) {
		if (*c == '?') {
			continue;
		}
		switch (*c) {
		case 'i':
		case 'f':
		case 'h':
			args[slot++].i = va_arg(ap, int32_t);
			break;
		case 'u':
			args[slot++].u = va_arg(ap, uint32_t);
			break;
		case 's':
			args[slot++].s = va_arg(ap, const char*);
			break;
		case 'o':
			args[slot++].o = va_arg(ap, struct wl_proxy*);
			break;
		case 'n':
			(void)va_arg(ap, struct wl_proxy*);
			args[slot++].o = NULL;
			break;
		default:
			break;
		}
	}
	va_end(ap);
	return p_marshal_array_flags(proxy, opcode, interface, version, flags, args);
}

struct wl_proxy* wl_proxy_marshal_array_flags(struct wl_proxy* proxy, uint32_t opcode, const struct wl_interface* interface, uint32_t version, uint32_t flags, union wl_argument* args) {
	return p_marshal_array_flags(proxy, opcode, interface, version, flags, args);
}

int wl_proxy_add_listener(struct wl_proxy* proxy, void (**implementation)(void), void* data) {
	return p_add_listener(proxy, implementation, data);
}

void wl_proxy_set_user_data(struct wl_proxy* proxy, void* data) {
	p_set_user_data(proxy, data);
}

void* wl_proxy_get_user_data(struct wl_proxy* proxy) {
	return p_get_user_data(proxy);
}

void wl_proxy_destroy(struct wl_proxy* proxy) {
	p_proxy_destroy(proxy);
}

struct wl_display* wl_display_connect(const char* name) {
	return p_display_connect(name);
}

void wl_display_disconnect(struct wl_display* display) {
	p_display_disconnect(display);
}

int wl_display_get_fd(struct wl_display* display) {
	return p_display_get_fd(display);
}

int wl_display_dispatch_pending(struct wl_display* display) {
	return p_display_dispatch_pending(display);
}

int wl_display_flush(struct wl_display* display) {
	return p_display_flush(display);
}

int wl_display_prepare_read(struct wl_display* display) {
	return p_display_prepare_read(display);
}

int wl_display_read_events(struct wl_display* display) {
	return p_display_read_events(display);
}

void wl_display_cancel_read(struct wl_display* display) {
	p_display_cancel_read(display);
}

int wl_display_roundtrip(struct wl_display* display) {
	return p_display_roundtrip(display);
}

int wl_display_get_error(struct wl_display* display) {
	return p_display_get_error(display);
}

uint32_t wl_proxy_get_version(struct wl_proxy* proxy) {
	return p_proxy_get_version(proxy);
}

const char* wl_proxy_get_class(struct wl_proxy* proxy) {
	return p_proxy_get_class(proxy);
}
