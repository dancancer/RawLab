# Sony2Fuji iOS API (C FFI)

This document describes the C API exposed by `include/sony2fuji/ffi/sony2fuji_c.h`,
which is the recommended surface for Swift/ObjC integration.

## Build Outputs

- `sony2fuji.framework` (device/simulator builds)
- `sony2fuji.xcframework` (recommended for Xcode, generated under `build-ios/`)

Headers live under `include/sony2fuji/ffi/` and `include/sony2fuji/`.

## API Overview

The API is stateful. Create a session, fill out a request, run processing,
and release any output buffers.

```c
sony2fuji_session* session = NULL;
sony2fuji_status status = sony2fuji_session_create(&session);
if (status != SONY2FUJI_STATUS_OK) { /* handle error */ }

sony2fuji_request request = {0};
request.version = SONY2FUJI_REQUEST_VERSION;
request.struct_size = sizeof(sony2fuji_request);
request.input_type = SONY2FUJI_INPUT_RAW;
request.input_path = "/path/to/input.ARW";
request.lut_path = "/path/to/lut.cube";
request.lut_strength = 1.0f;
request.output_target = SONY2FUJI_TARGET_FILE;
request.output_path = "/path/to/output.jpg";
request.output_format = SONY2FUJI_OUTPUT_JPEG;
request.jpeg_quality = 95;
request.wb_mode = SONY2FUJI_WB_CAMERA;
request.exposure_ev = 0.0f;
request.brightness = 1.0f;
request.size_mode = SONY2FUJI_SIZE_EXACT;
request.target_width = 0;
request.target_height = 0;
request.intent = SONY2FUJI_INTENT_FINAL;

status = sony2fuji_process(session, &request, NULL);
sony2fuji_session_destroy(session);
```

## GPU Acceleration

Enable GPU LUT application when available (Metal on iOS):

```c
sony2fuji_gpu_config gpu_config = {0};
gpu_config.version = SONY2FUJI_GPU_CONFIG_VERSION;
gpu_config.struct_size = sizeof(sony2fuji_gpu_config);
gpu_config.mode = SONY2FUJI_GPU_AUTO;
sony2fuji_session_set_gpu_config(session, &gpu_config);
```

## Request Fields

### Input

- `input_type`: `SONY2FUJI_INPUT_RAW`, scene `SONY2FUJI_INPUT_BUFFER`, or
  `SONY2FUJI_INPUT_DISPLAY_BUFFER` for decoded display-sRGB pixels.
- `input_path`: required for RAW input.
- `input_pixels`, `input_width`, `input_height`, `input_pixel_format`:
  required for buffer input.
- `input_color_space`: applies only to buffer input.
- `input_is_linear`: non-zero if buffer data is already linear.

### Display-input lens metadata

`sony2fuji_session_set_display_lens_metadata(session, metadata)` supplies
camera/lens identity, focal length, aperture, crop factor and original EXIF
orientation for a display input. Set `version = SONY2FUJI_LENS_METADATA_VERSION`
and `struct_size = sizeof(sony2fuji_lens_metadata)`. The setter copies string data;
pass NULL when clearing/reusing the session for a different source. RAW rendering
uses its own metadata and does not consume display metadata.

Use `sony2fuji_session_inspect_lens_metadata` to obtain the match report and catalog
candidates before enabling corrections. Load the lens database and set the existing
lens correction config, then supply the same metadata for preview and final render.
Display pixels must already be oriented once; `source_orientation` describes the
original EXIF orientation so calibration coordinates can be mapped correctly.
Missing focal/crop metadata remains an unavailable calibration, not a success.
The request-v2 memory layout is unchanged.

### LUT

- `lut_path`: `.cube` LUT path.
- `lut_strength`: blend amount, clamped to `[0.0, 2.0]`.

### White Balance / Exposure

- `wb_mode`: `CAMERA`, `AUTO`, or `CUSTOM`.
- `wb_mul`: RGB multipliers for custom WB.
- `exposure_ev`: exposure offset in EV.
- `brightness`: post multiplier (default `1.0`).

### Sizing

- `size_mode`: `EXACT`, `FIT_LONG_EDGE`, or `FIT_SHORT_EDGE`.
- `target_width`, `target_height`: used when `EXACT`.
- `long_edge`, `short_edge`: used when fitting.
- `intent`: `PREVIEW` or `FINAL`.
- `preview_long_edge`: overrides size for preview.

### Output

- `output_target`: `FILE` or `BUFFER`.
- `output_path`: required when `FILE`.
- `output_format`: `JPEG`, `PNG`, `RGB8`, or `RGBA8`.
- `jpeg_quality`: 1-100 (used for JPEG only).

## Output Buffer

If `output_target` is `SONY2FUJI_TARGET_BUFFER`, pass a `sony2fuji_buffer`
to `sony2fuji_process`. You must release it with:

```c
sony2fuji_release_buffer(&buffer);
```

## Status Codes

- `SONY2FUJI_STATUS_OK`
- `SONY2FUJI_STATUS_INVALID_ARGUMENT`
- `SONY2FUJI_STATUS_UNSUPPORTED`
- `SONY2FUJI_STATUS_IO_ERROR`
- `SONY2FUJI_STATUS_PROCESSING_ERROR`
- `SONY2FUJI_STATUS_OUT_OF_MEMORY`

Use `sony2fuji_status_message(status)` for a short string.

## Notes

- The library requires an iOS-compatible `libraw`.
- For Swift, wrap the C API in a thin Objective-C layer.
- The LUT order is auto-detected at load time.
