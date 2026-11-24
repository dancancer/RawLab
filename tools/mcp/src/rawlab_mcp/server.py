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
    recipe_path: str = Field(min_length=1, description="Absolute path to an existing recipe JSON file in a version advertised by the capabilities tool")


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


class SavePresetArguments(Arguments):
    name: str = Field(min_length=1, description="User-visible preset name (trimmed and normalized to NFC)")
    values: dict[str, Any] = Field(min_length=1, description="RawLab adjustment transfer field map")
    is_raw: bool | None = Field(default=None, description="Whether source adjustments came from a RAW image (defaults to false for HDR presets, true for SDR)")
    processing_version: int = Field(default=3, ge=1, le=3, description="RawLab SDR processing version (1..3)")
    overwrite: bool = Field(default=False, description="Allow overwriting an existing preset with the same normalized name")
    recipe_context: dict[str, Any] | None = Field(default=None, description="Optional recipe context {id, strength, settings_version}")
    hdr_processing_version: int | None = Field(default=None, ge=1, le=9, description="Optional HDR processing version when saving an HDR preset (1..9)")


class SyncPhotoEditArguments(Arguments):
    photo_path: str = Field(min_length=1, description="Absolute path to the photo inside an allowed read root")
    adjustments: dict[str, Any] = Field(description="Adjustment parameter map to persist to Edits/edits.json")
    film_id: str = Field(default="", description="Optional film LUT identifier (empty, builtin:<name>, or managed UUID)")
    master_recipe_id: str | None = Field(default=None, description="Optional MasterRecipe ID (e.g. hamada_daylight_v2)")


READ_ONLY_TOOL_SPECS = {
    "capabilities": (Arguments, "capabilities", "Read negotiated capabilities of the configured RawLab CLI."),
    "validate_recipe": (RecipeArguments, "validate_recipe", "Validate a recipe and return its normalized CLI representation."),
    "image_info": (InfoArguments, "info", "Read image metadata without rendering or modifying the image."),
    "render_preview": (PreviewArguments, "preview", "Render a recipe preview into a new file without overwriting an existing output."),
    "export_photo": (RecipeArguments, "export", "Export a recipe into its output path without overwriting an existing output."),
    "diagnose_image": (DiagnoseArguments, "analyze", "Compute native B->S->H telemetry and optional region samples on an image or recipe without writing output files."),
    "list_catalog_looks": (CatalogLooksArguments, "list_catalog_looks", "List bundled Master Recipes, Fuji F-Log2, SDR, and HDR looks from the RawLab catalog."),
}

GUI_SYNC_TOOL_SPECS = {
    "save_preset": (SavePresetArguments, "save_preset", "Save or overwrite a user preset in Presets/presets.json inside the configured --data-dir (requires --enable-gui-sync)."),
    "sync_photo_edit": (SyncPhotoEditArguments, "sync_photo_edit", "Persist non-destructive edits for a photo to desktop Edits/edits.json inside --data-dir (requires --enable-gui-sync)."),
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
