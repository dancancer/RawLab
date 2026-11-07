#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include <stddef.h>

_Static_assert(SONY2FUJI_REQUEST_VERSION==2,"legacy request version changed");
_Static_assert(SONY2FUJI_INPUT_DISPLAY_BUFFER==2,"legacy input enum changed");
_Static_assert(sizeof(sony2fuji_hdr_diagnostic_v1)==16,"HDR diagnostic layout changed");
_Static_assert(sizeof(sony2fuji_hdr_source_info_v1)==72,"HDR source layout changed");
_Static_assert(sizeof(sony2fuji_hdr_request_v1)==88,"HDR request layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v1,exposure_ev)==16,"HDR request prefix changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v1,long_edge)==84,"HDR request tail changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v2,base)==0,"HDR request v2 must start with v1");
_Static_assert(offsetof(sony2fuji_hdr_request_v2,black_point)==88,"HDR tone tail moved");
_Static_assert(offsetof(sony2fuji_hdr_request_v2,curve)==104,"HDR curve layout changed");
_Static_assert(sizeof(sony2fuji_hdr_request_v2)==648,"HDR request v2 layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v3,base)==0,"HDR request v3 must start with v2");
_Static_assert(offsetof(sony2fuji_hdr_request_v3,hsl)==656,"HDR HSL tail moved");
_Static_assert(offsetof(sony2fuji_hdr_request_v3,grading)==760,"HDR grading tail moved");
_Static_assert(sizeof(sony2fuji_hdr_request_v3)==792,"HDR request v3 layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v4,base)==0,"HDR request v4 must start with v3");
_Static_assert(offsetof(sony2fuji_hdr_request_v4,peak_limit_ev)==792,"HDR rendition tail moved");
_Static_assert(sizeof(sony2fuji_hdr_request_v4)==808,"HDR request v4 layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v5,base)==0,"HDR request v5 must start with v4");
_Static_assert(offsetof(sony2fuji_hdr_request_v5,effects)==808,"HDR photo effects tail moved");
_Static_assert(sizeof(sony2fuji_hdr_request_v5)==848,"HDR request v5 layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v6,base)==0,"HDR request v6 must start with v5");
_Static_assert(offsetof(sony2fuji_hdr_request_v6,sharpening)==848,"HDR detail tail moved");
_Static_assert(sizeof(sony2fuji_hdr_request_v6)==864,"HDR request v6 layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v7,base)==0,"HDR request v7 must start with v6");
_Static_assert(offsetof(sony2fuji_hdr_request_v7,look_path)==864,"HDR look tail moved");
_Static_assert(sizeof(sony2fuji_hdr_look_info_v1)==108,"HDR look info layout changed");
_Static_assert(offsetof(sony2fuji_hdr_camera_development_v2,base)==0,"HDR camera development v2 must start with v1");
_Static_assert(offsetof(sony2fuji_hdr_camera_development_v2,profile_path)==sizeof(sony2fuji_hdr_camera_development_v1),
               "HDR camera profile tail moved");
_Static_assert(sizeof(sony2fuji_hdr_camera_profile_info_v1)==140,"HDR camera profile info layout changed");
#if UINTPTR_MAX==UINT64_MAX
_Static_assert(sizeof(sony2fuji_hdr_request_v7)==952,"HDR request v7 layout changed");
_Static_assert(sizeof(sony2fuji_hdr_camera_development_v1)==40,"HDR camera development v1 layout changed");
_Static_assert(sizeof(sony2fuji_hdr_camera_development_v2)==120,"HDR camera development v2 layout changed");
_Static_assert(sizeof(sony2fuji_hdr_buffer_v1)==56,"HDR buffer layout changed");
_Static_assert(offsetof(sony2fuji_hdr_buffer_v1,stride_bytes)==32,"HDR buffer stride changed");
_Static_assert(sizeof(sony2fuji_hdr_image_pair_v1)==208,"HDR pair layout changed");
_Static_assert(offsetof(sony2fuji_hdr_image_pair_v1,source_sha256)==160,"HDR source identity changed");
_Static_assert(offsetof(sony2fuji_hdr_image_pair_v1,owner_token)==192,"HDR owner layout changed");
_Static_assert(offsetof(sony2fuji_hdr_image_pair_v1,output_native_width)==200,"HDR output canvas layout changed");
_Static_assert(sizeof(sony2fuji_hdr_export_config_v1)==64,"HDR JPEG config layout changed");
_Static_assert(sizeof(sony2fuji_hdr_sdr_export_config_v1)==56,"HDR SDR config layout changed");
#endif

int rawlab_hdr_c_header_check(void) { return SONY2FUJI_HDR_PROCESSING_VERSION; }
