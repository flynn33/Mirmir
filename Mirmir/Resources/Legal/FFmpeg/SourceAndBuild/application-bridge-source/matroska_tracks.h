#ifndef MIRMIR_MATROSKA_TRACKS_PROTOTYPE_H
#define MIRMIR_MATROSKA_TRACKS_PROTOTYPE_H
#include <stddef.h>
#include <stdint.h>
typedef struct MTECatalog MTECatalog;
typedef struct { int (*is_cancelled)(void *context); void *context; } MTECancellation;
typedef struct { int code; uint64_t offset; char reason[192]; } MTEError;
typedef struct {
 uint64_t number, uid, type;
 int enabled, default_track, forced, lacing;
 /* Bits: enabled1/default2/forced4/lacing8 distinguish absent normative defaults. */
 unsigned flags_present;
 int has_video; uint64_t pixel_width,pixel_height,crop_left,crop_right,crop_top,crop_bottom,display_width,display_height,display_unit,alpha_mode; unsigned video_fields_present;
 const char *codec_id;
 const uint8_t *codec_private; size_t codec_private_size;
 const uint8_t *raw_entry; size_t raw_entry_size;
 uint64_t entry_offset;
 uint8_t entry_sha256[32];
} MTETrack;
typedef struct {
 uint8_t source_sha256[32]; int64_t source_bytes;
 const char *doc_type; int count;
 uint64_t metadata_read_bytes, skipped_payload_bytes, source_hash_read_bytes;
} MTEFacts;
/* Borrowed results live until catalog close. fd is neither closed nor moved.
 * Authenticates the supplied fd against expected identity, then reads original
 * TrackEntry metadata with pread. Bounded to 32 tracks/4MiB TrackEntry payloads,
 * 100000 element headers and 16MiB metadata I/O. Known media payload sizes are
 * skipped by offsets. Unknown-sized Segment is accepted; other unknown-sized
 * elements are rejected explicitly rather than searched by byte signature.
 */
int mte_read_fd_with_cancel(int fd,const uint8_t expected_sha256[32],int64_t expected_bytes,MTECancellation cancellation,MTECatalog **out,MTEError *error);
int mte_read_fd(int fd,const uint8_t expected_sha256[32],int64_t expected_bytes,MTECatalog **out,MTEError *error);
int mte_facts(const MTECatalog *,MTEFacts *out);
int mte_track(const MTECatalog *,int index,MTETrack *out);
void mte_close(MTECatalog **);
#endif
