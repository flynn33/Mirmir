#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    UCR_OK = 0,
    UCR_ERR_ARGS = 1,
    UCR_ERR_OPEN_INPUT = 2,
    UCR_ERR_FIND_STREAM = 3,
    UCR_ERR_NO_VIDEO = 4,
    UCR_ERR_UNSUPPORTED = 5,
    UCR_ERR_OPEN_OUTPUT = 6,
    UCR_ERR_WRITE_HEADER = 7,
    UCR_ERR_COPY = 8,
    UCR_ERR_TRAILER = 9,
    UCR_ERR_ALLOC = 10
};

typedef struct {
    int video_codec_id;
    int audio_codec_id;
    int has_audio;
    int stream_count;
    char format_name[64];
    char video_codec_name[32];
    char audio_codec_name[32];
} UCRProbeInfo;

/// Probe container/codec identity. Returns UCR_OK on success.
int ucr_probe(const char *input_path, UCRProbeInfo *out_info, char *error, size_t error_cap);

/// True when video (+ optional audio) can be bitstream-copied into a MOV that
/// AVFoundation is expected to open with hardware/software native decoders.
int ucr_is_remux_admissible(const UCRProbeInfo *info);

/// Bitstream-copy remux to QuickTime/MOV. Deterministic copy; no re-encode.
int ucr_remux_to_mov(const char *input_path, const char *output_path,
                     char *error, size_t error_cap);

#ifdef __cplusplus
}
#endif
