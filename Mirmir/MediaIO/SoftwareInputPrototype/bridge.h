#ifndef MIRMIR_INPUT_BRIDGE_PROTOTYPE_H
#define MIRMIR_INPUT_BRIDGE_PROTOTYPE_H
#include <stddef.h>
#include <stdint.h>

/* Prototype ABI. All spans are borrowed until the owning source closes, or
 * until the cursor advances/seeks/closes. No libav object crosses this ABI.
 * One serial caller per cursor. Cancellation alone is safe from another thread.
 * Original facts are probed from original bytes; decoded facts never replace them.
 */
typedef struct MIBSource MIBSource;
typedef struct MIBCursor MIBCursor;
typedef struct { const uint8_t *data; size_t size; } MIBSpan;
typedef struct { int num, den; } MIBRational;
typedef struct { int valid; int64_t value; MIBRational base; } MIBTime;
typedef struct { int code; char stage[48], message[256]; } MIBError;
typedef struct {
    size_t packet_bytes, frame_bytes, metadata_bytes;
    int streams, cursors, max_width, max_height, max_channels, max_audio_samples;
} MIBLimits;
typedef struct {
    uint8_t sha256[32]; int64_t bytes, device, inode;
    const char *demuxer;
    MIBTime start, duration;
    int streams, chapters, programs, groups;
    uint64_t denied_secondary_opens;
} MIBAssetFacts;
typedef struct {
    int ordinal, container_id, media_type, codec_id; uint32_t codec_tag;
    const char *codec_name;
    int profile, level, disposition, width, height, pixel_format;
    int raw_depth, coded_depth, color_range, primaries, transfer, matrix, chroma_location, field_order;
    int video_delay, sample_rate, sample_format, channels, frame_size;
    int initial_padding, trailing_padding, seek_preroll, side_data_count;
    int channel_order, channel_id[32]; uint64_t channel_mask;
    MIBRational time_base, average_frame_rate, real_frame_rate, sample_aspect_ratio;
    MIBTime start, duration; int64_t declared_frames;
    const char *channel_layout;
    MIBSpan extradata;
} MIBStreamFacts;
typedef struct { int type; const char *name; MIBSpan bytes; } MIBSideData;
typedef struct {
    int id, flags, discard, program_number, pmt_pid, pcr_pid, pmt_version;
    int stream_count; const unsigned int *stream_ordinals;
} MIBProgramFacts;
typedef struct {
    int64_t ordinal, position; int ordinal_valid;
    uint8_t payload_sha256[32];
    MIBTime pts, dts, duration, vop_time;
    int flags, vop_type, vop_count;
} MIBPacketIdentity;
typedef struct {
    int stream; MIBPacketIdentity identity; MIBSpan bytes;
    int side_data_count;
} MIBPacket;
typedef struct { MIBSpan bytes; int row_bytes, width, height; } MIBPlane;
typedef struct {
    int stream; int64_t ordinal;
    MIBTime pts, best_effort_pts, duration, packet_dts;
    int has_packet_identity; MIBPacketIdentity packet_identity;
    int flags, decode_error_flags, side_data_count;
    int pixel_format, width, height, planes, components, depth, chroma_log2_width, chroma_log2_height;
    uint64_t pixel_format_flags; int pixel_is_rgb, pixel_has_alpha;
    const char *pixel_format_name;
    int color_range, primaries, transfer, matrix, chroma_location;
    MIBRational sample_aspect_ratio;
    size_t crop_left, crop_right, crop_top, crop_bottom;
    MIBPlane plane[4]; MIBSpan image_bytes;
    int sample_rate, channels, native_sample_format, decoded_samples, normalized_samples;
    const char *channel_layout;
    int channel_order, channel_id[32]; uint64_t channel_mask;
    uint32_t skip_start, skip_end; uint8_t skip_start_reason, skip_end_reason;
    /* Raw skip facts above may span frames. Derived audible range is separate. */
    int audible_offset, audible_samples;
    MIBSpan s32_interleaved;
} MIBDecodedFrame;
enum { MIB_PACKET_CURSOR=0, MIB_VIDEO_CURSOR=1, MIB_AUDIO_CURSOR=2 };
/* Callback/context remain alive until source and all retained cursors close.
 * Return nonzero to cancel; callback must be thread-safe and nonblocking. */
typedef struct { int (*is_cancelled)(void *context); void *context; } MIBCancellation;

MIBLimits mib_default_limits(void);
/* fd is not closed or repositioned. Requires an authenticated expected identity.
 * Bridge duplicates it CLOEXEC and exclusively uses pread on that same inode.
 */
int mib_source_open_fd(int fd, const uint8_t expected_sha256[32], int64_t expected_bytes,
                       const MIBLimits *limits, MIBSource **out, MIBError *error);
int mib_source_open_fd_with_cancel(int fd, const uint8_t expected_sha256[32], int64_t expected_bytes,
                       const MIBLimits *limits, MIBCancellation cancellation, MIBSource **out, MIBError *error);
void mib_source_close(MIBSource **source);
void mib_source_cancel(MIBSource *source);
int mib_source_authenticate(MIBSource *source, MIBError *error);
int mib_asset_facts(MIBSource *source, MIBAssetFacts *out, MIBError *error);
int mib_stream_facts(MIBSource *source, int stream, MIBStreamFacts *out, MIBError *error);
int mib_program_facts(MIBSource *source, int index, MIBProgramFacts *out, MIBError *error);
int mib_program_metadata_count(MIBSource *source, int index, MIBError *error);
int mib_program_metadata_at(MIBSource *source, int index, int entry, const char **key, const char **value, MIBError *error);
/* Metadata scope: -1 asset, otherwise original stream ordinal. */
int mib_metadata_count(MIBSource *source, int stream, MIBError *error);
int mib_metadata_at(MIBSource *source, int stream, int index, const char **key, const char **value, MIBError *error);
int mib_stream_side_data(MIBSource *source, int stream, int index, MIBSideData *out, MIBError *error);
int mib_cursor_open(MIBSource *source, int stream, int kind, MIBCursor **out, MIBError *error);
void mib_cursor_close(MIBCursor **cursor);
/* Returns 1 sample, 0 fully drained EOF, or a negative error. */
int mib_next_packet(MIBCursor *cursor, MIBPacket *out, MIBError *error);
int mib_packet_side_data(MIBCursor *cursor, int index, MIBSideData *out, MIBError *error);
int mib_next_frame(MIBCursor *cursor, MIBDecodedFrame *out, MIBError *error);
int mib_frame_side_data(MIBCursor *cursor, int index, MIBSideData *out, MIBError *error);
/* Exact replay seek: reopen original demuxer and flush decoder/resampler, then
 * discard decoded video preceding target. Work is linear; memory stays bounded.
 * Audio seeks expose overlapping frames unchanged: caller applies exact sample
 * clock trimming using returned pts/skip fields. Unknown timing returns ENODATA.
 */
enum { MIB_RAW_FRAME_CLOCK=0, MIB_MPEG4_VOP_CLOCK=1 };
/* VOP clock is bitstream-local. Caller must first qualify its mapping to the
 * original container timeline; this API never silently replaces raw PTS. */
int mib_cursor_seek_with_clock(MIBCursor *cursor, MIBTime target, int clock, MIBError *error);
int mib_cursor_seek(MIBCursor *cursor, MIBTime target, MIBError *error);
int mib_cursor_rewind(MIBCursor *cursor, MIBError *error);
size_t mib_cursor_scratch_capacity(const MIBCursor *cursor);
/* Versioned observed implementation/ABI query; no libav objects cross it. */
int mib_copy_abi_contract_v1(char *output, size_t capacity);
const char *mib_implementation_image_path_v1(int role);
const char *mib_library_image_path_v1(int library);
unsigned int mib_library_runtime_version_v1(int library);
unsigned int mib_library_compiled_version_v1(int library);
#endif
