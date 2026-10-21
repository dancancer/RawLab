from contextlib import asynccontextmanager
import json

from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
from mcp.types import CallToolResult, ListToolsResult, TextContent, Tool
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .adapter import AdapterError, CliAdapter, Envelope, failure
from .config import ServerConfig


class Arguments(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class RecipeArguments(Arguments):
    recipe_path: str = Field(min_length=1, description="Absolute path to an existing v1-v4 recipe JSON file")


class InfoArguments(Arguments):
    image_path: str = Field(min_length=1, description="Absolute path to an existing input image")


class PreviewArguments(RecipeArguments):
    output_path: str = Field(min_length=1, description="New absolute preview path within an allowed write root")
    long_edge: int = Field(default=1280, ge=1, le=4294967295, description="Maximum preview edge in pixels")


TOOL_SPECS = {
    "capabilities": (Arguments, "capabilities", "Read negotiated capabilities of the configured RawLab CLI."),
    "validate_recipe": (RecipeArguments, "validate_recipe", "Validate a recipe and return its normalized CLI representation."),
    "image_info": (InfoArguments, "info", "Read image metadata without rendering or modifying the image."),
    "render_preview": (PreviewArguments, "preview", "Render a recipe preview into a new file without overwriting an existing output."),
    "export_photo": (RecipeArguments, "export", "Export a recipe into its output path without overwriting an existing output."),
}


def create_server(adapter: CliAdapter) -> Server:
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
            for name, (model, _, description) in TOOL_SPECS.items()
        ])

    async def call_tool(context, params):
        spec = TOOL_SPECS.get(params.name)
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
