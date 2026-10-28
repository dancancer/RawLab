#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include <stddef.h>

_Static_assert(SONY2FUJI_REQUEST_VERSION==2,"legacy request version changed");
_Static_assert(SONY2FUJI_INPUT_DISPLAY_BUFFER==2,"legacy input enum changed");
_Static_assert(sizeof(sony2fuji_hdr_diagnostic_v1)==16,"HDR diagnostic layout changed");
_Static_assert(sizeof(sony2fuji_hdr_source_info_v1)==72,"HDR source layout changed");
_Static_assert(sizeof(sony2fuji_hdr_request_v1)==88,"HDR request layout changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v1,exposure_ev)==16,"HDR request prefix changed");
_Static_assert(offsetof(sony2fuji_hdr_request_v1,long_edge)==84,"HDR request tail changed");
#if UINTPTR_MAX==UINT64_MAX
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
