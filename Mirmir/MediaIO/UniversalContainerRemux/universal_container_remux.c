#include "universal_container_remux.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

#include <stdio.h>
#include <string.h>

static void set_error(char *error, size_t error_cap, const char *message) {
    if (!error || error_cap == 0) return;
    if (!message) {
        error[0] = '\0';
        return;
    }
    snprintf(error, error_cap, "%s", message);
}

static void set_error_ff(char *error, size_t error_cap, const char *prefix, int err) {
    char buf[256];
    av_strerror(err, buf, sizeof(buf));
    if (!error || error_cap == 0) return;
    snprintf(error, error_cap, "%s: %s", prefix, buf);
}

static int copy_name(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return 0;
    if (!src) {
        dst[0] = '\0';
        return 0;
    }
    snprintf(dst, cap, "%s", src);
    return 0;
}

static int is_native_video(enum AVCodecID id) {
    switch (id) {
    case AV_CODEC_ID_H264:
    case AV_CODEC_ID_HEVC:
    case AV_CODEC_ID_MPEG4:
    case AV_CODEC_ID_MPEG2VIDEO:
    case AV_CODEC_ID_MJPEG:
        return 1;
    default:
        return 0;
    }
}

static int is_native_audio(enum AVCodecID id) {
    switch (id) {
    case AV_CODEC_ID_AAC:
    case AV_CODEC_ID_AAC_LATM:
    case AV_CODEC_ID_MP2:
    case AV_CODEC_ID_MP3:
    case AV_CODEC_ID_AC3:
    case AV_CODEC_ID_EAC3:
    case AV_CODEC_ID_PCM_S16LE:
    case AV_CODEC_ID_PCM_S16BE:
    case AV_CODEC_ID_PCM_S24LE:
    case AV_CODEC_ID_PCM_S24BE:
    case AV_CODEC_ID_PCM_S32LE:
    case AV_CODEC_ID_PCM_S32BE:
    case AV_CODEC_ID_PCM_F32LE:
    case AV_CODEC_ID_PCM_F32BE:
    case AV_CODEC_ID_ALAC:
        return 1;
    default:
        return 0;
    }
}

int ucr_probe(const char *input_path, UCRProbeInfo *out_info, char *error, size_t error_cap) {
    if (!input_path || !out_info) {
        set_error(error, error_cap, "missing probe arguments");
        return UCR_ERR_ARGS;
    }
    memset(out_info, 0, sizeof(*out_info));
    out_info->video_codec_id = AV_CODEC_ID_NONE;
    out_info->audio_codec_id = AV_CODEC_ID_NONE;

    AVFormatContext *fmt = NULL;
    int err = avformat_open_input(&fmt, input_path, NULL, NULL);
    if (err < 0) {
        set_error_ff(error, error_cap, "open input", err);
        return UCR_ERR_OPEN_INPUT;
    }
    err = avformat_find_stream_info(fmt, NULL);
    if (err < 0) {
        set_error_ff(error, error_cap, "find stream info", err);
        avformat_close_input(&fmt);
        return UCR_ERR_FIND_STREAM;
    }

    if (fmt->iformat && fmt->iformat->name) {
        copy_name(out_info->format_name, sizeof(out_info->format_name), fmt->iformat->name);
    }
    out_info->stream_count = (int)fmt->nb_streams;

    int video_index = -1;
    int audio_index = -1;
    for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        AVCodecParameters *par = fmt->streams[i]->codecpar;
        if (!par) continue;
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && video_index < 0) {
            video_index = (int)i;
            out_info->video_codec_id = (int)par->codec_id;
            const AVCodec *codec = avcodec_find_decoder(par->codec_id);
            copy_name(out_info->video_codec_name, sizeof(out_info->video_codec_name),
                      codec && codec->name ? codec->name : avcodec_get_name(par->codec_id));
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && audio_index < 0) {
            audio_index = (int)i;
            out_info->has_audio = 1;
            out_info->audio_codec_id = (int)par->codec_id;
            const AVCodec *codec = avcodec_find_decoder(par->codec_id);
            copy_name(out_info->audio_codec_name, sizeof(out_info->audio_codec_name),
                      codec && codec->name ? codec->name : avcodec_get_name(par->codec_id));
        }
    }

    avformat_close_input(&fmt);
    if (video_index < 0) {
        set_error(error, error_cap, "no video stream");
        return UCR_ERR_NO_VIDEO;
    }
    set_error(error, error_cap, NULL);
    return UCR_OK;
}

int ucr_is_remux_admissible(const UCRProbeInfo *info) {
    if (!info) return 0;
    if (!is_native_video((enum AVCodecID)info->video_codec_id)) return 0;
    if (info->has_audio && !is_native_audio((enum AVCodecID)info->audio_codec_id)) return 0;
    return 1;
}

int ucr_remux_to_mov(const char *input_path, const char *output_path,
                     char *error, size_t error_cap) {
    if (!input_path || !output_path) {
        set_error(error, error_cap, "missing remux arguments");
        return UCR_ERR_ARGS;
    }

    UCRProbeInfo probe;
    int probe_rc = ucr_probe(input_path, &probe, error, error_cap);
    if (probe_rc != UCR_OK) return probe_rc;
    if (!ucr_is_remux_admissible(&probe)) {
        set_error(error, error_cap, "codecs are not remux-admissible for native MOV decode");
        return UCR_ERR_UNSUPPORTED;
    }

    AVFormatContext *in = NULL;
    AVFormatContext *out = NULL;
    AVPacket *packet = NULL;
    int *stream_map = NULL;
    int rc = UCR_OK;

    int err = avformat_open_input(&in, input_path, NULL, NULL);
    if (err < 0) {
        set_error_ff(error, error_cap, "open input", err);
        return UCR_ERR_OPEN_INPUT;
    }
    err = avformat_find_stream_info(in, NULL);
    if (err < 0) {
        set_error_ff(error, error_cap, "find stream info", err);
        rc = UCR_ERR_FIND_STREAM;
        goto done;
    }

    err = avformat_alloc_output_context2(&out, NULL, "mov", output_path);
    if (err < 0 || !out) {
        set_error_ff(error, error_cap, "alloc output", err);
        rc = UCR_ERR_ALLOC;
        goto done;
    }

    stream_map = (int *)av_calloc(in->nb_streams, sizeof(int));
    if (!stream_map) {
        set_error(error, error_cap, "cannot allocate stream map");
        rc = UCR_ERR_ALLOC;
        goto done;
    }
    for (unsigned i = 0; i < in->nb_streams; ++i) stream_map[i] = -1;

    int out_index = 0;
    for (unsigned i = 0; i < in->nb_streams; ++i) {
        AVStream *in_stream = in->streams[i];
        AVCodecParameters *par = in_stream->codecpar;
        if (!par) continue;
        if (par->codec_type != AVMEDIA_TYPE_VIDEO && par->codec_type != AVMEDIA_TYPE_AUDIO) {
            continue;
        }
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && !is_native_video(par->codec_id)) continue;
        if (par->codec_type == AVMEDIA_TYPE_AUDIO && !is_native_audio(par->codec_id)) continue;

        AVStream *out_stream = avformat_new_stream(out, NULL);
        if (!out_stream) {
            set_error(error, error_cap, "cannot allocate output stream");
            rc = UCR_ERR_ALLOC;
            goto done;
        }
        err = avcodec_parameters_copy(out_stream->codecpar, par);
        if (err < 0) {
            set_error_ff(error, error_cap, "copy codec parameters", err);
            rc = UCR_ERR_COPY;
            goto done;
        }
        out_stream->codecpar->codec_tag = 0;
        out_stream->time_base = in_stream->time_base;
        stream_map[i] = out_index++;
    }

    if (out_index == 0) {
        set_error(error, error_cap, "no remuxable streams");
        rc = UCR_ERR_UNSUPPORTED;
        goto done;
    }

    if (!(out->oformat->flags & AVFMT_NOFILE)) {
        err = avio_open(&out->pb, output_path, AVIO_FLAG_WRITE);
        if (err < 0) {
            set_error_ff(error, error_cap, "open output", err);
            rc = UCR_ERR_OPEN_OUTPUT;
            goto done;
        }
    }

    err = avformat_write_header(out, NULL);
    if (err < 0) {
        set_error_ff(error, error_cap, "write header", err);
        rc = UCR_ERR_WRITE_HEADER;
        goto done;
    }

    packet = av_packet_alloc();
    if (!packet) {
        set_error(error, error_cap, "cannot allocate packet");
        rc = UCR_ERR_ALLOC;
        goto done;
    }

    int64_t *last_dts = (int64_t *)av_calloc((size_t)out_index, sizeof(int64_t));
    int64_t *packet_ordinal = (int64_t *)av_calloc((size_t)out_index, sizeof(int64_t));
    if (!last_dts || !packet_ordinal) {
        set_error(error, error_cap, "cannot allocate timestamp state");
        rc = UCR_ERR_ALLOC;
        av_free(last_dts);
        av_free(packet_ordinal);
        goto done;
    }
    for (int i = 0; i < out_index; ++i) last_dts[i] = AV_NOPTS_VALUE;

    while ((err = av_read_frame(in, packet)) >= 0) {
        int in_index = packet->stream_index;
        if (in_index < 0 || (unsigned)in_index >= in->nb_streams || stream_map[in_index] < 0) {
            av_packet_unref(packet);
            continue;
        }
        AVStream *in_stream = in->streams[in_index];
        int mapped = stream_map[in_index];
        AVStream *out_stream = out->streams[mapped];
        packet->stream_index = mapped;
        if (packet->pts == AV_NOPTS_VALUE && packet->dts != AV_NOPTS_VALUE) {
            packet->pts = packet->dts;
        }
        if (packet->dts == AV_NOPTS_VALUE && packet->pts != AV_NOPTS_VALUE) {
            packet->dts = packet->pts;
        }
        if (packet->pts == AV_NOPTS_VALUE && packet->dts == AV_NOPTS_VALUE) {
            int64_t synthetic = packet_ordinal[mapped];
            if (packet->duration > 0) synthetic *= packet->duration;
            packet->pts = synthetic;
            packet->dts = synthetic;
        }
        packet->pts = av_rescale_q_rnd(packet->pts, in_stream->time_base, out_stream->time_base,
                                       AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX);
        packet->dts = av_rescale_q_rnd(packet->dts, in_stream->time_base, out_stream->time_base,
                                       AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX);
        packet->duration = av_rescale_q(packet->duration, in_stream->time_base, out_stream->time_base);
        if (packet->dts != AV_NOPTS_VALUE && last_dts[mapped] != AV_NOPTS_VALUE
            && packet->dts <= last_dts[mapped]) {
            packet->dts = last_dts[mapped] + 1;
            if (packet->pts != AV_NOPTS_VALUE && packet->pts < packet->dts) {
                packet->pts = packet->dts;
            }
        }
        if (packet->dts != AV_NOPTS_VALUE) last_dts[mapped] = packet->dts;
        packet_ordinal[mapped] += 1;
        packet->pos = -1;
        err = av_interleaved_write_frame(out, packet);
        av_packet_unref(packet);
        if (err < 0) {
            set_error_ff(error, error_cap, "write frame", err);
            rc = UCR_ERR_COPY;
            av_free(last_dts);
            av_free(packet_ordinal);
            goto done;
        }
    }
    av_free(last_dts);
    av_free(packet_ordinal);
    if (err != AVERROR_EOF && err < 0) {
        set_error_ff(error, error_cap, "read frame", err);
        rc = UCR_ERR_COPY;
        goto done;
    }

    err = av_write_trailer(out);
    if (err < 0) {
        set_error_ff(error, error_cap, "write trailer", err);
        rc = UCR_ERR_TRAILER;
        goto done;
    }
    set_error(error, error_cap, NULL);
    rc = UCR_OK;

done:
    if (packet) av_packet_free(&packet);
    if (stream_map) av_free(stream_map);
    if (out) {
        if (out->pb && !(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
        avformat_free_context(out);
    }
    if (in) avformat_close_input(&in);
    return rc;
}
