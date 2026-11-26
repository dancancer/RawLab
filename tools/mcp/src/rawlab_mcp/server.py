from contextlib import asynccontextmanager
import json
from typing import Any, Literal

from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
from mcp.types import CallToolResult, ListToolsResult, TextContent, Tool
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from .adapter import AdapterError, CliAdapter, Envelope, failure
from .config import ServerConfig


class Arguments(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class RecipeArguments(Arguments):
    recipe_path: str = Field(
        min_length=1,
        description=(
            "Absolute path to an existing recipe JSON file in a version advertised by the capabilities tool "
            "(up to SDR v20 including calibration, point_color, selective_color, bw, texture, grain presets, halation, bloom, sharpen_v2, defringe)"
        ),
    )


class InfoArguments(Arguments):
    image_path: str = Field(min_length=1, description="Absolute path to an existing input image")


class PreviewArguments(RecipeArguments):
    output_path: str = Field(min_length=1, description="New absolute preview path within an allowed write root")
    long_edge: int = Field(default=1280, ge=1, le=4294967295, description="Maximum preview edge in pixels")


class DiagnoseArguments(Arguments):
    image_path: str | None = Field(default=None, min_length=1, description="Absolute path to an existing input image inside an allowed read root")
    recipe_path: str | None = Field(default=None, min_length=1, description="Absolute path to an existing recipe JSON file inside an allowed read root")
    samples: list[str] = Field(default_factory=list, max_length=16, description="Optional repeatable normalized region probes formatted as 'x,y[,label]'")
    long_edge: int = Field(default=1024, ge=1, le=4294967295, description="Analysis long edge in pixels")

    @model_validator(mode="after")
    def _validate_target(self):
        if bool(self.image_path) == bool(self.recipe_path):
            raise ValueError("Specify exactly one of image_path or recipe_path")
        return self


class CatalogLooksArguments(Arguments):
    category: Literal["all", "master_recipe", "fuji_flog2", "bundled", "hdr"] = Field(
        default="all",
        description="Filter catalog entries by look category",
    )
    query: str | None = Field(default=None, description="Optional case-insensitive substring filter")


_V014_TRANSFER_FIELDS = (
    "color.calibration.shadow_tint",
    "color.calibration.red_hue",
    "color.calibration.red_saturation",
    "color.calibration.green_hue",
    "color.calibration.green_saturation",
    "color.calibration.blue_hue",
    "color.calibration.blue_saturation",
    "color.point_color",
    "color.selective_color",
    "color.bw.enabled",
    "color.bw.mixer",
    "effects.texture",
    "effects.grain.tone_curve",
    "effects.grain.format_preset",
    "effects.halation.amount",
    "effects.halation.threshold",
    "effects.halation.radius",
    "effects.halation.hue",
    "effects.bloom.amount",
    "effects.bloom.threshold",
    "effects.bloom.radius",
    "detail.sharpening.luminance_v2",
    "detail.sharpening.radius",
    "detail.sharpening.detail",
    "detail.sharpening.masking",
    "geometry.lens.defringe_purple_amount",
    "geometry.lens.defringe_purple_hue",
    "geometry.lens.defringe_green_amount",
    "geometry.lens.defringe_green_hue",
)

_V014_ADJUSTMENT_KEYS = (
    "texture",
    "calibration",
    "point_color",
    "selective_color",
    "bw",
    "sharpen_v2",
    "film_optics",
    "photo_effects",
    "lens_correction",
)


class SavePresetArguments(Arguments):
    name: str = Field(min_length=1, description="User-visible preset name (trimmed and normalized to NFC)")
    values: dict[str, Any] = Field(
        min_length=1,
        description=(
            "RawLab adjustment transfer field map (validated by CLI against the v0.14.0 adjustment spec). "
            "Includes SDR v0.14.0 fields: color.calibration.* (-100..100), "
            "color.point_color ({swatches: [<=8 dicts with src_hue [0,360), src_saturation/src_luminance [0,1], "
            "hue_shift/saturation_shift/luminance_shift/variance [-100,100], range/hue_range/sat_range/lum_range [0,100], enabled]}), "
            "color.selective_color ({method: 'relative'|'absolute', bands: {reds..blacks: {cyan, magenta, yellow, black}}}), "
            "color.bw.enabled, color.bw.mixer ({red..magenta: [-100,100]}), effects.texture (-100..100), "
            "effects.grain.tone_curve ('legacy'|'negative_asymmetric'), effects.grain.format_preset ('custom'|'135'|'120'), "
            "effects.halation.{amount,threshold,radius,hue}, effects.bloom.{amount,threshold,radius}, "
            "detail.sharpening.{luminance_v2,radius,detail,masking}, and "
            "geometry.lens.{defringe_purple_amount,defringe_purple_hue,defringe_green_amount,defringe_green_hue}."
        ),
        json_schema_extra={"x_v014_transfer_fields": list(_V014_TRANSFER_FIELDS)},
    )
    is_raw: bool | None = Field(default=None, description="Whether source adjustments came from a RAW image (defaults to false for HDR presets, true for SDR)")
    processing_version: int = Field(default=3, ge=1, le=3, description="RawLab SDR processing version (1..3)")
    overwrite: bool = Field(default=False, description="Allow overwriting an existing preset with the same normalized name")
    recipe_context: dict[str, Any] | None = Field(default=None, description="Optional recipe context {id, strength, settings_version}")
    hdr_processing_version: int | None = Field(default=None, ge=1, le=10, description="Optional HDR processing version when saving an HDR preset (1..10)")


class SyncPhotoEditArguments(Arguments):
    photo_path: str = Field(min_length=1, description="Absolute path to the photo inside an allowed read root")
    adjustments: dict[str, Any] = Field(
        description=(
            "Adjustment parameter map to persist to Edits/edits.json (preserves untouched orthogonal fields such as "
            "hdr, aiDenoiseEnabled, aiDenoiseBlend, lutID, and unknown future fields; pass null or default values to reset/omit optional blocks). "
            "Supports v0.14.0 keys: texture (-100..100), "
            "calibration ({shadow_tint, red_hue, red_saturation, green_hue, green_saturation, blue_hue, blue_saturation}), "
            "point_color ({swatches: [...] }), selective_color ({method, bands}), bw ({enabled, mixer}), "
            "sharpen_v2 ({luminance_v2, radius, detail, masking}), "
            "film_optics ({halation_amount, halation_threshold, halation_radius, halation_hue, bloom_amount, bloom_threshold, bloom_radius}), "
            "photo_effects (including grain_tone_curve, grain_format_preset), and "
            "lens_correction (including defringe_purple_amount/hue, defringe_green_amount/hue)."
        ),
        json_schema_extra={"x_v014_adjustment_keys": list(_V014_ADJUSTMENT_KEYS)},
    )
    film_id: str = Field(default="", description="Optional film LUT identifier (empty, builtin:<name>, or managed UUID)")
    master_recipe_id: str | None = Field(default=None, description="Optional MasterRecipe ID (e.g. hamada_daylight_v2)")


READ_ONLY_TOOL_SPECS = {
    "capabilities": (Arguments, "capabilities", "Read negotiated capabilities of the configured RawLab CLI."),
    "validate_recipe": (RecipeArguments, "validate_recipe", "Validate a recipe (including SDR v20) and return its normalized CLI representation."),
    "image_info": (InfoArguments, "info", "Read image metadata without rendering or modifying the image."),
    "render_preview": (PreviewArguments, "preview", "Render a recipe preview into a new file without overwriting an existing output."),
    "export_photo": (RecipeArguments, "export", "Export a recipe into its output path without overwriting an existing output."),
    "diagnose_image": (
        DiagnoseArguments,
        "analyze",
        "Compute native B->S->H telemetry, portrait skin & variance checks, and v0.14.0 guidance "
        "(point_color, calibration, texture, sharpening luminance_v2/masking, halation/bloom, negative_asymmetric grain, "
        "selective_color, bw.mixer, and lens defringe) on an image or recipe without writing output files.",
    ),
    "list_catalog_looks": (CatalogLooksArguments, "list_catalog_looks", "List bundled Master Recipes, Fuji F-Log2, SDR, and HDR looks from the RawLab catalog."),
}

GUI_SYNC_TOOL_SPECS = {
    "save_preset": (
        SavePresetArguments,
        "save_preset",
        "Save or overwrite a user preset (including all 29 SDR v0.14.0 transfer fields) in Presets/presets.json inside --data-dir (requires --enable-gui-sync).",
    ),
    "sync_photo_edit": (
        SyncPhotoEditArguments,
        "sync_photo_edit",
        "Persist non-destructive SDR edits (including v0.14.0 blocks and explicit null/default resets while preserving hdr/aiDenoise/lutID and unknown fields) "
        "to desktop Edits/edits.json inside --data-dir (requires --enable-gui-sync).",
    ),
}

TOOL_SPECS = READ_ONLY_TOOL_SPECS


def create_server(adapter: CliAdapter) -> Server:
    active_tools = (
        {**READ_ONLY_TOOL_SPECS, **GUI_SYNC_TOOL_SPECS}
        if adapter.config.enable_gui_sync
        else dict(READ_ONLY_TOOL_SPECS)
    )

    @asynccontextmanager
    async def lifespan(server):
        try:
            await adapter.start()
            yield None
        finally:
            await adapter.close()

    async def list_tools(context, params):
        return ListToolsResult(tools=[
            Tool(name=name, description=description, input_schema=model.model_json_schema())
            for name, (model, _, description) in active_tools.items()
        ])

    async def call_tool(context, params):
        spec = active_tools.get(params.name)
        if spec is None:
            envelope = failure(params.name, AdapterError("Unknown tool"))
        else:
            model, command, _ = spec
            try:
                arguments = model.model_validate(params.arguments or {}).model_dump()
                if params.name == "capabilities":
                    envelope = Envelope(command, True, adapter.capabilities.result)
                else:
                    envelope = await getattr(adapter, params.name)(**arguments)
            except ValidationError as error:
                envelope = failure(command, AdapterError(str(error)))
        value = envelope.as_dict()
        return CallToolResult(
            content=[TextContent(type="text", text=json.dumps(value, ensure_ascii=False))],
            structured_content=value,
            is_error=not envelope.ok,
        )

    return Server("rawlab-mcp", version="0.1.0", lifespan=lifespan,
                  on_list_tools=list_tools, on_call_tool=call_tool)


async def serve(config: ServerConfig):
    server = create_server(CliAdapter(config))
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())
