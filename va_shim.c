/* va_shim.c - runtime loader trampolines for the VA-API entry points
 * referenced by the static FFmpeg libraries. The binary keeps no link
 * time dependency on libva, libva-drm or libdrm and loads them on the
 * first VAAPI call, so a machine without a driver stack still runs
 * the program and falls back to libx264.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_str.h>

static void *va_shim_lib;
static void *va_shim_drm_lib;
static int va_shim_state;

/* toom_va_sym resolves one entry point from the runtime loaded VA
 * libraries and returns nil when the stack is unavailable.
 */
static void *toom_va_sym(const char *name, int drm) {
	if (va_shim_state == 0) {
		va_shim_state = 1;
		va_shim_lib = dlopen("libva.so.2", RTLD_NOW | RTLD_LOCAL);
		va_shim_drm_lib = dlopen("libva-drm.so.2", RTLD_NOW | RTLD_LOCAL);
	}
	if (drm) {
		return va_shim_drm_lib ? dlsym(va_shim_drm_lib, name) : 0;
	}
	return va_shim_lib ? dlsym(va_shim_lib, name) : 0;
}

#define VA_FAIL_STATUS VA_STATUS_ERROR_UNKNOWN

#define VA_STUB(name, ret, params, args, drm, fail) \
	ret name params { \
		static ret (*fn) params; \
		if (!fn) { \
			fn = (ret (*) params)toom_va_sym(#name, drm); \
		} \
		if (!fn) { \
			return fail; \
		} \
		return fn args; \
	}

VA_STUB(vaBeginPicture, VAStatus,
	(VADisplay dpy, VAContextID context, VASurfaceID render_target),
	(dpy, context, render_target), 0, VA_FAIL_STATUS)
VA_STUB(vaCreateBuffer, VAStatus,
	(VADisplay dpy, VAContextID context, VABufferType type, unsigned int size, unsigned int num_elements, void *data, VABufferID *buf_id),
	(dpy, context, type, size, num_elements, data, buf_id), 0, VA_FAIL_STATUS)
VA_STUB(vaCreateConfig, VAStatus,
	(VADisplay dpy, VAProfile profile, VAEntrypoint entrypoint, VAConfigAttrib *attrib_list, int num_attribs, VAConfigID *config_id),
	(dpy, profile, entrypoint, attrib_list, num_attribs, config_id), 0, VA_FAIL_STATUS)
VA_STUB(vaCreateContext, VAStatus,
	(VADisplay dpy, VAConfigID config_id, int picture_width, int picture_height, int flag, VASurfaceID *render_targets, int num_render_targets, VAContextID *context),
	(dpy, config_id, picture_width, picture_height, flag, render_targets, num_render_targets, context), 0, VA_FAIL_STATUS)
VA_STUB(vaCreateImage, VAStatus,
	(VADisplay dpy, VAImageFormat *format, int width, int height, VAImage *image),
	(dpy, format, width, height, image), 0, VA_FAIL_STATUS)
VA_STUB(vaCreateSurfaces, VAStatus,
	(VADisplay dpy, unsigned int format, unsigned int width, unsigned int height, VASurfaceID *surfaces, unsigned int num_surfaces, VASurfaceAttrib *attrib_list, unsigned int num_attribs),
	(dpy, format, width, height, surfaces, num_surfaces, attrib_list, num_attribs), 0, VA_FAIL_STATUS)
VA_STUB(vaDeriveImage, VAStatus,
	(VADisplay dpy, VASurfaceID surface, VAImage *image),
	(dpy, surface, image), 0, VA_FAIL_STATUS)
VA_STUB(vaDestroyBuffer, VAStatus,
	(VADisplay dpy, VABufferID buffer_id),
	(dpy, buffer_id), 0, VA_FAIL_STATUS)
VA_STUB(vaDestroyConfig, VAStatus,
	(VADisplay dpy, VAConfigID config_id),
	(dpy, config_id), 0, VA_FAIL_STATUS)
VA_STUB(vaDestroyContext, VAStatus,
	(VADisplay dpy, VAContextID context),
	(dpy, context), 0, VA_FAIL_STATUS)
VA_STUB(vaDestroyImage, VAStatus,
	(VADisplay dpy, VAImageID image),
	(dpy, image), 0, VA_FAIL_STATUS)
VA_STUB(vaDestroySurfaces, VAStatus,
	(VADisplay dpy, VASurfaceID *surfaces, int num_surfaces),
	(dpy, surfaces, num_surfaces), 0, VA_FAIL_STATUS)
VA_STUB(vaEndPicture, VAStatus,
	(VADisplay dpy, VAContextID context),
	(dpy, context), 0, VA_FAIL_STATUS)
VA_STUB(vaEntrypointStr, const char *,
	(VAEntrypoint entrypoint), (entrypoint), 0, "")
VA_STUB(vaErrorStr, const char *,
	(VAStatus error_status), (error_status), 0, "")
VA_STUB(vaGetConfigAttributes, VAStatus,
	(VADisplay dpy, VAProfile profile, VAEntrypoint entrypoint, VAConfigAttrib *attrib_list, int num_attribs),
	(dpy, profile, entrypoint, attrib_list, num_attribs), 0, VA_FAIL_STATUS)
VA_STUB(vaGetDisplayDRM, VADisplay,
	(int fd), (fd), 1, 0)
VA_STUB(vaGetImage, VAStatus,
	(VADisplay dpy, VASurfaceID surface, int x, int y, unsigned int width, unsigned int height, VAImageID image),
	(dpy, surface, x, y, width, height, image), 0, VA_FAIL_STATUS)
VA_STUB(vaInitialize, VAStatus,
	(VADisplay dpy, int *major_version, int *minor_version),
	(dpy, major_version, minor_version), 0, VA_FAIL_STATUS)
VA_STUB(vaMapBuffer, VAStatus,
	(VADisplay dpy, VABufferID buf_id, void **pbuf),
	(dpy, buf_id, pbuf), 0, VA_FAIL_STATUS)
VA_STUB(vaMapBuffer2, VAStatus,
	(VADisplay dpy, VABufferID buf_id, void **pbuf, uint32_t flags),
	(dpy, buf_id, pbuf, flags), 0, VA_FAIL_STATUS)
VA_STUB(vaMaxNumEntrypoints, int,
	(VADisplay dpy), (dpy), 0, 0)
VA_STUB(vaMaxNumImageFormats, int,
	(VADisplay dpy), (dpy), 0, 0)
VA_STUB(vaMaxNumProfiles, int,
	(VADisplay dpy), (dpy), 0, 0)
VA_STUB(vaProfileStr, const char *,
	(VAProfile profile), (profile), 0, "")
VA_STUB(vaPutImage, VAStatus,
	(VADisplay dpy, VASurfaceID surface, VAImageID image, int src_x, int src_y, unsigned int src_width, unsigned int src_height, int dest_x, int dest_y, unsigned int dest_width, unsigned int dest_height),
	(dpy, surface, image, src_x, src_y, src_width, src_height, dest_x, dest_y, dest_width, dest_height), 0, VA_FAIL_STATUS)
VA_STUB(vaQueryConfigEntrypoints, VAStatus,
	(VADisplay dpy, VAProfile profile, VAEntrypoint *entrypoint_list, int *num_entrypoints),
	(dpy, profile, entrypoint_list, num_entrypoints), 0, VA_FAIL_STATUS)
VA_STUB(vaQueryConfigProfiles, VAStatus,
	(VADisplay dpy, VAProfile *profile_list, int *num_profiles),
	(dpy, profile_list, num_profiles), 0, VA_FAIL_STATUS)
VA_STUB(vaQueryImageFormats, VAStatus,
	(VADisplay dpy, VAImageFormat *format_list, int *num_formats),
	(dpy, format_list, num_formats), 0, VA_FAIL_STATUS)
VA_STUB(vaQuerySurfaceAttributes, VAStatus,
	(VADisplay dpy, VAConfigID config, VASurfaceAttrib *attrib_list, unsigned int *num_attribs),
	(dpy, config, attrib_list, num_attribs), 0, VA_FAIL_STATUS)
VA_STUB(vaQueryVendorString, const char *,
	(VADisplay dpy), (dpy), 0, "")
VA_STUB(vaRenderPicture, VAStatus,
	(VADisplay dpy, VAContextID context, VABufferID *buffers, int num_buffers),
	(dpy, context, buffers, num_buffers), 0, VA_FAIL_STATUS)
VA_STUB(vaSetDriverName, VAStatus,
	(VADisplay dpy, char *driver_name), (dpy, driver_name), 0, VA_FAIL_STATUS)
VA_STUB(vaSetErrorCallback, VAMessageCallback,
	(VADisplay dpy, VAMessageCallback callback, void *user_context),
	(dpy, callback, user_context), 0, 0)
VA_STUB(vaSetInfoCallback, VAMessageCallback,
	(VADisplay dpy, VAMessageCallback callback, void *user_context),
	(dpy, callback, user_context), 0, 0)
VA_STUB(vaSyncBuffer, VAStatus,
	(VADisplay dpy, VABufferID buf_id, uint64_t timeout_ns),
	(dpy, buf_id, timeout_ns), 0, VA_FAIL_STATUS)
VA_STUB(vaSyncSurface, VAStatus,
	(VADisplay dpy, VASurfaceID render_target),
	(dpy, render_target), 0, VA_FAIL_STATUS)
VA_STUB(vaTerminate, VAStatus,
	(VADisplay dpy), (dpy), 0, VA_FAIL_STATUS)
VA_STUB(vaUnmapBuffer, VAStatus,
	(VADisplay dpy, VABufferID buf_id), (dpy, buf_id), 0, VA_FAIL_STATUS)
