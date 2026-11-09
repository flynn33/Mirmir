#ifndef MIRMIR_CARRIER_PIXELS_H
#define MIRMIR_CARRIER_PIXELS_H
#include "bridge.h"
/* Explicit working 4:2:0 conversion followed by lossless vertical duplication
 * into the qualified native yuvs/yuvf 4:2:2 delivery format. No RGB conversion.
 * 4:2:2 uses (a+b+1)/2, 4:4:4 uses (a+b+c+d+2)/4, ties upward.
 * Even opaque 8-bit planar YUV only. Unsupported inputs fail before writes. */
int mib_carrier_pixel_format_supported(int pixel_format);
int mib_carrier_pack_yuyv420(const MIBDecodedFrame *frame, uint8_t *output, size_t bytes);
/* Separately qualified opaque full-range RGB8 -> declared YCbCr working path. */
int mirmir_rgb8_layout_supported(int pixel_format);
int mirmir_rgb8_to_yuyv420(const MIBDecodedFrame *frame, int matrix,
                         int source_full_range, uint8_t *output, size_t bytes);
/* Exact same RGB conversion codes in authenticated raw NV12 delivery. */
int mirmir_rgb8_working(const MIBDecodedFrame *frame, int matrix,
                       int source_full_range, uint8_t *output, size_t bytes);
int mib_biplanar_layout_supported(int pixel_format);
enum { MIB_RANGE_DECLARED = 0, MIB_RANGE_QUALIFIED_UNSPECIFIED_8BIT = 1 };
int mib_biplanar_working(const MIBDecodedFrame *frame, int destination_depth,
                         int full_range, int range_policy, uint8_t *output, size_t bytes);
int mib_presentation_bgra(const MIBDecodedFrame *frame, int matrix, int full_range,
                          int range_policy, int source_chroma_location, uint8_t *output, size_t bytes);
#endif
