# tools/mcp (`rawlab_mcp`)

These instructions apply to `tools/mcp/`, the MCP server package bridging RawLab CLI and desktop stores.

## Thin Process & Protocol Adapter Rules

1. **CLI as Single Source of Truth**: Image decoding, BSH diagnostics, and recipe validation must invoke the `sony2fuji` CLI and recognize the full status range `0..8` (including `7 = cancelled`, `8 = ai_not_ready`).
2. **No Re-implemented Parsers or Grading Rules**: Do not hand-write JSON lexers/scanners or duplicate client grading, curve, or color-math rules in Python; keep protocol constraints synchronized with `Shared/specs/adjustment-fields-v1.json`.
3. **Read-Modify-Merge Persistence**: Any write to `Edits/edits.json` or `Presets/presets.json` must follow incremental read-modify-merge semantics—preserving existing unknown and orthogonal fields (`hdr`, `hdrCameraAI`, `proRAWDecodeVersion`, `aiDenoiseEnabled`, `aiDenoiseBlend`, `asShotWhiteBalance`) and raw byte slices of unrelated records, using the platform's shared OS locking primitive.
4. **Unshadowed Snapshot Verification**: Bundled JSON snapshots (`transfer_spec.json`, `catalog_data.json`) must be tested in isolation with `RAWLAB_REPO` and repo-root discovery disabled so tests actually validate the packaged files rather than being shadowed by `Shared/`.
5. **Verification**: Run `uv run --project tools/mcp --frozen python -m unittest discover -s tools/mcp/tests -v` and `python3 -m unittest discover -s scripts/ci -p 'test_mcp_snapshots.py' -v` after changes.
