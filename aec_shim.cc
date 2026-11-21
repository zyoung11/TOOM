// aec_shim.cc - C wrapper around WebRTC audio processing for toom.

#include <modules/audio_processing/include/audio_processing.h>
#include <api/scoped_refptr.h>

namespace {

struct Aec {
	rtc::scoped_refptr<webrtc::AudioProcessing> apm;
	webrtc::StreamConfig cap_cfg;
	webrtc::StreamConfig play_cfg;
};

}

extern "C" {

void* toom_aec_open(int rate, int cap_ch, int play_ch) {
	Aec* a = new Aec();
	a->apm = webrtc::AudioProcessingBuilder().Create();
	if (a->apm.get() == nullptr) {
		delete a;
		return nullptr;
	}
	webrtc::AudioProcessing::Config config;
	config.echo_canceller.enabled = true;
	config.echo_canceller.mobile_mode = false;
	config.noise_suppression.enabled = true;
	config.noise_suppression.level =
		webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
	config.high_pass_filter.enabled = true;
	a->apm->ApplyConfig(config);
	a->cap_cfg = webrtc::StreamConfig(rate, cap_ch, false);
	a->play_cfg = webrtc::StreamConfig(rate, play_ch, false);
	return a;
}

void toom_aec_close(void* p) {
	delete static_cast<Aec*>(p);
}

void toom_aec_play(void* p, const short* data, int frames) {
	Aec* a = static_cast<Aec*>(p);
	if (a == nullptr || data == nullptr) {
		return;
	}
	int chunk = a->play_cfg.sample_rate_hz() / 100;
	int ch = a->play_cfg.num_channels();
	short* buf = const_cast<short*>(data);
	for (int off = 0; off + chunk <= frames; off += chunk) {
		a->apm->ProcessReverseStream(
			buf + off * ch, a->play_cfg, a->play_cfg, buf + off * ch);
	}
}

void toom_aec_cap(void* p, short* data, int frames) {
	Aec* a = static_cast<Aec*>(p);
	if (a == nullptr || data == nullptr) {
		return;
	}
	int chunk = a->cap_cfg.sample_rate_hz() / 100;
	int ch = a->cap_cfg.num_channels();
	short* buf = data;
	for (int off = 0; off + chunk <= frames; off += chunk) {
		a->apm->ProcessStream(
			buf + off * ch, a->cap_cfg, a->cap_cfg, buf + off * ch);
	}
}

}
