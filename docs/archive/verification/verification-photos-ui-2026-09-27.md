# Photos-Style Mac Editor

## Delivered Scope

- A single bottom tool row contains film selection, film strength, exposure, highlights, shadows, contrast, S-curve, saturation, relative temperature, tint and sharpening. There is no separate adjustment/film mode switch.
- Selecting the film tool reveals a horizontal cartridge-icon chooser in the same bottom area. Icons identify the simulations; they are not representations of official physical film packaging. Long built-in names wrap, and custom LUT import remains available.
- Signed yellow rings start at the default: positive changes fill clockwise and negative changes counterclockwise. Each side is normalized to its own range, including asymmetric temperature limits. The selected tool retains its ring.
- A collapsible floating output histogram occupies the upper-right corner. Its collapse state survives photo switches and file-tree visibility changes.
- A collapsible left file tree stores user-added directory references, lazily lists child folders and shows embedded RAW thumbnails. Removing a directory reference never deletes files. ImageIO thumbnails apply orientation and do not fall back to full RAW decoding; missing embedded previews use a placeholder.
- Each photo retains its own settings and film choice for this application session. Directory references persist across launches; edits do not yet persist as sidecars or a catalog.
- Fit-relative zoom is continuous; 100% accounts for Retina display scale. Native-resolution state travels with the rendered frame rather than transient busy state.

The shared C++ rendering algorithms, LUT color contract and numeric parameter ranges were not changed for this UI work.

## Verification

- `bash RawLabMac/tests/presentation.sh`: all checks passed. Covers nine tonal/color tools plus strength, native symbols, signed progress, asymmetric ranges, fit/zoom/Retina math, photo edit isolation and directory filtering for ARW/ARQ/DNG.
- New presentation tests initially failed because the APIs did not exist. The ARQ regression separately failed on the directory count before adding the missing extension and passed afterward.
- `bash RawLabMac/tests/adjustments.sh`: all 8 real RAW fixtures passed with the updated frame metadata, including control mappings, reset, exposure-baseline stability, original-size 16-bit PNG and preview/export pixel parity. Artifacts: `/tmp/rawlab-adjustments.HppnG4/`.
- `bash RawLabMac/build.sh`: final native bundle built successfully, with no compiler warnings in the final build.
- The final application passed ad-hoc signature verification and `git diff --check`.

Native interaction verification ran against an isolated copy with a separate bundle identifier, not by resetting the user's active original editor:

1. Added `lutools/examples` through the native directory picker. Seven RAW thumbnail buttons appeared; the saved root returned after restarting the verification copy.
2. Selected DSC06251 from its thumbnail, changed exposure to -2 EV, highlights to +50 and film to ASTIA. Selected DSC06271 and observed default 0 EV / PROVIA. Selected DSC06251 again and observed its prior values and ASTIA restored.
3. Reset all adjustments and observed zero exposure/highlights without replacing ASTIA.
4. Verified negative exposure filled the left half of its ring while positive highlights filled the right half, including on the selected tool.
5. Verified film selection via cartridge icons, inline long-name wrapping, file-tree collapse and histogram collapse. Repeated RAW loading on the final build retained the collapsed histogram.
6. Exported through the GUI to `/tmp/rawlab-ui-final/ui-verification.jpg`; the application reported completion and ImageIO/sips confirmed original portrait dimensions, 4672x7008.

The automation tool temporarily could not read the verification window after the directory picker closed. A process sample showed an idle event loop, not a decoding deadlock. After the user displayed the window again, the same session resumed and the directory tree was present. This was not treated as evidence of an application crash.

## Visual Evidence

Actual macOS screenshots, not HTML mockups:

- `.impeccable/review/mac-final-empty.jpg`: minimum window, empty/disabled states.
- `.impeccable/review/mac-final-compact.jpg`: minimum window with directory thumbnails, real portrait RAW, collapsed histogram and unified film chooser.
- `.impeccable/review/mac-final-wide.jpg`: wide desktop layout with the same workflow.
- `.impeccable/review/mac-compact-adjustments.jpg`: signed progress-ring comparison at -2 EV and +50 highlights. Captured before the final histogram-state and label-wrap fixes; the ring implementation is unchanged.

Compact captures are approximately 1900x1344 physical pixels at 2x scale, corresponding to the 950x620 minimum content area plus the native title bar. Wide capture is 3726x2100 pixels. A general-purpose independent reviewer was used because this session exposes no dedicated Impeccable reviewer role. It returned `ship` for the captured surface and code, identifying the subsequently fixed ARQ filter omission. Native code was not run through the web-only HTML/CSS detector.

## Boundaries

This is a macOS delivery. iOS was not redesigned or rebuilt. Visual validation was on this host's macOS 27, not every supported macOS release. All original RAWs were left intact; no commit or push was made. Existing user changes were preserved.
