# Custom LUT Names and EKTAR Artwork

## Scope

Removed the display-look name allowlist in the shared CUBE parser. Valid arbitrary names now pass with the existing F-Log2 input and F-Gamut to ITU-R BT.709 declaration. Empty declarations, incompatible input/gamut and the known F-Log2-to-F-Log2 technical transform remain rejected. This checks metadata, not whether arbitrary table data really implements a display transfer function.

Created `RawLabMac/Resources/FilmIcons/ektar-100-phuket.png` with the built-in image-generation tool. The 1254 x 1254 full-bleed label matches the existing film-package artwork style, with RAWLAB branding, red/yellow panels and an explicit FILM SIMULATION LUT caption. Prompt and provenance are recorded alongside the asset. No built-in LUT or artwork mapping was added; that is a separate user choice.

## Verification

- Red: the new contract tests failed on the three custom display-name cases before the parser change; existing rejection cases passed.
- Green: `bash lutools/test.sh` passed all 11 CTest cases, including color contracts, GPU photo, Sony/DJI RAW, white balance and highlight checks. Total CTest time: 140.20 seconds.
- `bash RawLabMac/build.sh` passed, including bundled dependency and signature verification. Output: `build/RawLab Mac.app`.
- The EKTAR transform rendered `lutools/test-assets/DSC00316.ARW` successfully through the normal PHOTO API/CLI, not the generic LUT-only helper.
- The previously delivered CUBE was no longer at its original experiment path. The smoke check used an independently regenerated temporary CUBE from the unchanged `color_lut.py` under the experiment's ignored `.cache/`; the missing original was not restored or overwritten.
- `git diff --check` passed. Existing unrelated iOS changes were preserved; no iOS rebuild or UI acceptance test was performed.
