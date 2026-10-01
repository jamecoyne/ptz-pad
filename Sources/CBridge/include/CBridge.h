// C-side glue for the Swift target.
//
// Syphon: its umbrella header leaves out SyphonSubclassing.h, which is where
// -[SyphonServerBase copySurfaceForWidth:height:options:] and -publish live — the CPU
// path to publishing a frame. The framework is copied out of TouchDesigner or OBS at
// build time (see Package.swift), the same way segcam does it.
//
// NDI: libndi is loaded at run time with dlopen (NDI Tools / the NDI runtime install
// it), so the SDK headers are not needed to build. Only the handful of types this app
// passes across the boundary are declared here, laid out exactly as in the NDI 5/6 SDK's
// Processing.NDI.*.h. Anonymous unions in the SDK are flattened to their first member,
// which has the same size and offset.
#pragma once

#import <Syphon/Syphon.h>
#import <Syphon/SyphonSubclassing.h>

#include <stdbool.h>
#include <stdint.h>

typedef void *NDIlib_find_instance_t;
typedef void *NDIlib_recv_instance_t;

typedef struct NDIlib_source_t {
    const char *p_ndi_name;
    const char *p_url_address;          // union { p_url_address; p_ip_address; }
} NDIlib_source_t;

typedef struct NDIlib_find_create_t {
    bool show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} NDIlib_find_create_t;

typedef enum NDIlib_recv_bandwidth_e {
    NDIlib_recv_bandwidth_metadata_only = -10,
    NDIlib_recv_bandwidth_audio_only = 10,
    NDIlib_recv_bandwidth_lowest = 0,
    NDIlib_recv_bandwidth_highest = 100,
    NDIlib_recv_bandwidth_max = 0x7fffffff
} NDIlib_recv_bandwidth_e;

typedef enum NDIlib_recv_color_format_e {
    NDIlib_recv_color_format_BGRX_BGRA = 0,
    NDIlib_recv_color_format_UYVY_BGRA = 1,
    NDIlib_recv_color_format_RGBX_RGBA = 2,
    NDIlib_recv_color_format_UYVY_RGBA = 3,
    NDIlib_recv_color_format_fastest = 100,
    NDIlib_recv_color_format_best = 101,
    NDIlib_recv_color_format_max = 0x7fffffff
} NDIlib_recv_color_format_e;

typedef struct NDIlib_recv_create_v3_t {
    NDIlib_source_t source_to_connect_to;
    NDIlib_recv_color_format_e color_format;
    NDIlib_recv_bandwidth_e bandwidth;
    bool allow_video_fields;
    const char *p_ndi_recv_name;
} NDIlib_recv_create_v3_t;

typedef enum NDIlib_frame_type_e {
    NDIlib_frame_type_none = 0,
    NDIlib_frame_type_video = 1,
    NDIlib_frame_type_audio = 2,
    NDIlib_frame_type_metadata = 3,
    NDIlib_frame_type_error = 4,
    NDIlib_frame_type_status_change = 100,
    NDIlib_frame_type_max = 0x7fffffff
} NDIlib_frame_type_e;

typedef struct NDIlib_video_frame_v2_t {
    int xres;
    int yres;
    uint32_t FourCC;                    // NDIlib_FourCC_video_type_e
    int frame_rate_N;
    int frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;              // NDIlib_frame_format_type_e
    int64_t timecode;
    uint8_t *p_data;
    int line_stride_in_bytes;           // union { line_stride_in_bytes; data_size_in_bytes; }
    const char *p_metadata;
    int64_t timestamp;
} NDIlib_video_frame_v2_t;

// NDI_LIB_FOURCC('B','G','R','A') and friends.
#define PTZ_NDI_FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
static const uint32_t NDIlib_FourCC_type_BGRA = PTZ_NDI_FOURCC('B', 'G', 'R', 'A');
static const uint32_t NDIlib_FourCC_type_BGRX = PTZ_NDI_FOURCC('B', 'G', 'R', 'X');

typedef bool (*NDIlib_initialize_f)(void);
typedef NDIlib_find_instance_t (*NDIlib_find_create_v2_f)(const NDIlib_find_create_t *);
typedef void (*NDIlib_find_destroy_f)(NDIlib_find_instance_t);
typedef const NDIlib_source_t *(*NDIlib_find_get_current_sources_f)(NDIlib_find_instance_t, uint32_t *);
typedef NDIlib_recv_instance_t (*NDIlib_recv_create_v3_f)(const NDIlib_recv_create_v3_t *);
typedef void (*NDIlib_recv_destroy_f)(NDIlib_recv_instance_t);
// Audio and metadata frame pointers are always passed NULL, so they are typed void *.
typedef NDIlib_frame_type_e (*NDIlib_recv_capture_v2_f)(NDIlib_recv_instance_t, NDIlib_video_frame_v2_t *,
                                                        void *, void *, uint32_t);
typedef void (*NDIlib_recv_free_video_v2_f)(NDIlib_recv_instance_t, const NDIlib_video_frame_v2_t *);
