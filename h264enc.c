/* h264enc.c - H.264 encode shim with backend probing.
 *
 * Tries hardware encoders first and falls back to libx264, so the Odin
 * side never touches AVCodecContext or hardware frame plumbing.
 */
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <stdlib.h>
#include <string.h>

struct h264enc {
	AVCodecContext *ctx;
	AVFrame *sw;
	AVFrame *hwframe;
	AVPacket *pkt;
	AVBufferRef *hwdev;
	int use_hw;
	int w, h;
	int64_t pts;
};

void h264enc_close(struct h264enc *e);

static int open_x264(struct h264enc *e, int kbps, int fps) {
	const AVCodec *codec = avcodec_find_encoder_by_name("libx264");
	if (!codec)
		return -1;
	e->ctx = avcodec_alloc_context3(codec);
	if (!e->ctx)
		return -1;
	e->ctx->width = e->w;
	e->ctx->height = e->h;
	e->ctx->pix_fmt = AV_PIX_FMT_YUV420P;
	e->ctx->time_base = (AVRational){1, fps};
	e->ctx->framerate = (AVRational){fps, 1};
	e->ctx->bit_rate = (int64_t)kbps * 1000;
	e->ctx->gop_size = fps * 2;
	e->ctx->max_b_frames = 0;
	av_opt_set(e->ctx->priv_data, "preset", "ultrafast", 0);
	av_opt_set(e->ctx->priv_data, "tune", "zerolatency", 0);
	if (avcodec_open2(e->ctx, codec, NULL) < 0)
		return -1;
	e->use_hw = 0;
	return 0;
}

static int open_hw(struct h264enc *e, const char *name, enum AVHWDeviceType devtype,
	enum AVPixelFormat hwfmt, int kbps, int fps) {
	const AVCodec *codec = avcodec_find_encoder_by_name(name);
	AVHWFramesContext *frames;
	AVBufferRef *frames_ref;

	if (!codec)
		return -1;
	if (av_hwdevice_ctx_create(&e->hwdev, devtype, NULL, NULL, 0) < 0)
		return -1;
	e->ctx = avcodec_alloc_context3(codec);
	if (!e->ctx)
		return -1;
	frames_ref = av_hwframe_ctx_alloc(e->hwdev);
	if (!frames_ref)
		return -1;
	frames = (AVHWFramesContext *)frames_ref->data;
	frames->format = hwfmt;
	frames->sw_format = AV_PIX_FMT_NV12;
	frames->width = e->w;
	frames->height = e->h;
	frames->initial_pool_size = 8;
	if (av_hwframe_ctx_init(frames_ref) < 0) {
		av_buffer_unref(&frames_ref);
		return -1;
	}
	e->ctx->hw_frames_ctx = frames_ref;
	e->ctx->width = e->w;
	e->ctx->height = e->h;
	e->ctx->time_base = (AVRational){1, fps};
	e->ctx->framerate = (AVRational){fps, 1};
	e->ctx->bit_rate = (int64_t)kbps * 1000;
	e->ctx->gop_size = fps * 2;
	e->ctx->max_b_frames = 0;
	if (avcodec_open2(e->ctx, codec, NULL) < 0)
		return -1;
	e->use_hw = 1;
	return 0;
}

struct h264enc *h264enc_open(int w, int h, int fps, int kbps, int prefer) {
	struct h264enc *e = calloc(1, sizeof *e);
	int order[3];
	int i;

	if (!e)
		return NULL;
	e->w = w & ~1;
	e->h = h & ~1;
	e->pkt = av_packet_alloc();
	e->sw = av_frame_alloc();
	if (!e->pkt || !e->sw)
		goto fail;

	switch (prefer) {
	case 1:
		order[0] = 1;
		break;
	case 2:
		order[0] = 2;
		break;
	case 3:
		order[0] = 3;
		break;
	default:
		order[0] = 3;
		break;
	}
	order[1] = (order[0] == 2) ? 3 : 2;
	order[2] = 1;

	for (i = 0; i < 3; i++) {
		int backend = order[i];
		if (backend == 3 && open_hw(e, "h264_nvenc", AV_HWDEVICE_TYPE_CUDA,
				AV_PIX_FMT_CUDA, kbps, fps) == 0) {
			goto ready;
		}
		if (backend == 2 && open_hw(e, "h264_vaapi", AV_HWDEVICE_TYPE_VAAPI,
				AV_PIX_FMT_VAAPI, kbps, fps) == 0) {
			goto ready;
		}
		if (backend == 1 && open_x264(e, kbps, fps) == 0) {
			goto ready;
		}
		if (e->ctx) {
			avcodec_free_context(&e->ctx);
		}
		av_buffer_unref(&e->hwdev);
	}
	goto fail;

ready:
	e->sw->width = e->w;
	e->sw->height = e->h;
	e->sw->format = e->use_hw ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P;
	if (av_frame_get_buffer(e->sw, 32) < 0)
		goto fail;
	if (e->use_hw) {
		e->hwframe = av_frame_alloc();
		if (!e->hwframe)
			goto fail;
	}
	return e;

fail:
	h264enc_close(e);
	return NULL;
}

const char *h264enc_backend(struct h264enc *e) {
	if (!e || !e->ctx)
		return "none";
	return e->ctx->codec->name;
}

static void fill_nv12(struct h264enc *e, const uint8_t *y, const uint8_t *u,
	const uint8_t *v, int sy, int sc) {
	int w = e->w, h = e->h, row;
	if (av_frame_make_writable(e->sw) < 0)
		return;
	for (row = 0; row < h; row++)
		memcpy(e->sw->data[0] + row * e->sw->linesize[0], y + row * sy, w);
	for (row = 0; row < h / 2; row++) {
		uint8_t *dst = e->sw->data[1] + row * e->sw->linesize[1];
		const uint8_t *su = u + row * sc;
		const uint8_t *sv = v + row * sc;
		int col;
		for (col = 0; col < w / 2; col++) {
			dst[col * 2] = su[col];
			dst[col * 2 + 1] = sv[col];
		}
	}
}

int h264enc_encode(struct h264enc *e, const uint8_t *y, const uint8_t *u,
	const uint8_t *v, int sy, int sc, uint8_t *out, int cap, int *keyframe) {
	AVFrame *send;
	int ret;

	if (!e || !e->ctx)
		return -1;
	if (keyframe)
		*keyframe = 0;
	if (av_frame_make_writable(e->sw) < 0)
		return -1;

	if (e->use_hw) {
		fill_nv12(e, y, u, v, sy, sc);
		if (av_hwframe_get_buffer(e->ctx->hw_frames_ctx, e->hwframe, 0) < 0)
			return -1;
		if (av_hwframe_transfer_data(e->hwframe, e->sw, 0) < 0) {
			av_frame_unref(e->hwframe);
			return -1;
		}
		e->hwframe->pts = e->pts++;
		send = e->hwframe;
	} else {
		int row;
		for (row = 0; row < e->h; row++)
			memcpy(e->sw->data[0] + row * e->sw->linesize[0], y + row * sy, e->w);
		for (row = 0; row < e->h / 2; row++)
			memcpy(e->sw->data[1] + row * e->sw->linesize[1], u + row * sc, e->w / 2);
		for (row = 0; row < e->h / 2; row++)
			memcpy(e->sw->data[2] + row * e->sw->linesize[2], v + row * sc, e->w / 2);
		e->sw->pts = e->pts++;
		send = e->sw;
	}

	if (avcodec_send_frame(e->ctx, send) < 0)
		return -1;
	if (e->use_hw)
		av_frame_unref(e->hwframe);
	ret = avcodec_receive_packet(e->ctx, e->pkt);
	if (ret == AVERROR(EAGAIN))
		return 0;
	if (ret < 0)
		return -1;
	if (e->pkt->size > cap) {
		av_packet_unref(e->pkt);
		return -2;
	}
	memcpy(out, e->pkt->data, e->pkt->size);
	ret = e->pkt->size;
	if (keyframe && (e->pkt->flags & AV_PKT_FLAG_KEY))
		*keyframe = 1;
	av_packet_unref(e->pkt);
	return ret;
}

void h264enc_close(struct h264enc *e) {
	if (!e)
		return;
	av_frame_free(&e->sw);
	av_frame_free(&e->hwframe);
	av_packet_free(&e->pkt);
	avcodec_free_context(&e->ctx);
	av_buffer_unref(&e->hwdev);
	free(e);
}
