import asyncio
from dataclasses import asdict, dataclass
import json
import logging
import os
from pathlib import Path
import shutil
import signal
import tempfile

import anyio

from .config import ServerConfig


COMMANDS = {"capabilities", "validate_recipe", "info", "preview", "export"}
RECIPE_VERSIONS = {1, 2, 3, 4}
MAX_JSON_BYTES = 4 * 1024 * 1024
logger = logging.getLogger(__name__)


class AdapterError(Exception):
    def __init__(self, message, code="invalid_argument", status=None):
        super().__init__(message)
        self.code, self.status = code, status


@dataclass(frozen=True)
class Error:
    code: str
    message: str
    status: int | None = None


@dataclass(frozen=True)
class Envelope:
    command: str
    ok: bool
    result: dict | None = None
    error: Error | None = None
    protocol_version: int = 1

    def as_dict(self):
        return asdict(self)


@dataclass(frozen=True)
class Capabilities:
    recipe_versions: tuple[int, ...]
    result: dict


def failure(command, error):
    return Envelope(command, False, error=Error(error.code, str(error), error.status))


class CliAdapter:
    def __init__(self, config: ServerConfig, *, environment=None):
        self.config = config
        self.environment = {**os.environ, **(environment or {})}
        self.capabilities = None
        self._processes = set()
        self._closed = False

    async def start(self):
        envelope = await self._run("capabilities", ["--capabilities", "--json"])
        if not envelope.ok:
            raise AdapterError(envelope.error.message, envelope.error.code)
        result = envelope.result
        versions = result.get("recipe_versions")
        commands = result.get("commands")
        if (not isinstance(versions, list) or any(type(v) is not int for v in versions)
                or 4 not in versions):
            raise AdapterError("CLI must support recipe schema version 4")
        if (not isinstance(commands, list) or any(not isinstance(c, str) for c in commands)
                or not COMMANDS.issubset(commands)):
            raise AdapterError("CLI is missing a required command")
        supported = tuple(sorted(RECIPE_VERSIONS.intersection(versions)))
        result = {**result, "recipe_versions": list(supported),
                  "commands": [c for c in commands if c in COMMANDS]}
        self.capabilities = Capabilities(supported, result)
        return self.capabilities

    async def close(self):
        self._closed = True
        for process in tuple(self._processes):
            await self._stop(process)

    @staticmethod
    async def _stop(process):
        with anyio.CancelScope(shield=True):
            if process.returncode is None:
                try:
                    if os.name == "posix":
                        os.killpg(process.pid, signal.SIGTERM)
                    else:
                        process.terminate()
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.wait_for(process.wait(), 2)
                except asyncio.TimeoutError:
                    try:
                        if os.name == "posix":
                            os.killpg(process.pid, signal.SIGKILL)
                        else:
                            process.kill()
                    except ProcessLookupError:
                        pass
                    await process.wait()

    async def _run(self, command, args):
        if self._closed:
            raise AdapterError("Server is shutting down", "processing_error")
        process = None
        launch = asyncio.create_task(asyncio.create_subprocess_exec(
            str(self.config.cli), *map(str, args),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=self.environment, start_new_session=os.name == "posix",
        ))
        try:
            try:
                process = await asyncio.shield(launch)
            except asyncio.CancelledError:
                # 取消发生在 spawn 完成之前时，也要回收刚创建的子进程。
                with anyio.CancelScope(shield=True):
                    process = await launch
                    await self._stop(process)
                raise
            self._processes.add(process)
            if self._closed:
                raise AdapterError("Server is shutting down", "processing_error")

            async def collect(stream):
                data = bytearray()
                while chunk := await stream.read(65536):
                    data.extend(chunk)
                    if len(data) > MAX_JSON_BYTES:
                        raise AdapterError("CLI output exceeds the size limit", "processing_error")
                return bytes(data)

            async with asyncio.timeout(self.config.timeout):
                async with asyncio.TaskGroup() as group:
                    stdout = group.create_task(collect(process.stdout))
                    stderr = group.create_task(collect(process.stderr))
                    group.create_task(process.wait())
            if stderr.result():
                logger.info("CLI diagnostics: %s", stderr.result().decode("utf-8", errors="replace"))
            try:
                value = json.loads(stdout.result())
            except (ValueError, UnicodeError) as e:
                raise AdapterError("CLI returned invalid JSON", "processing_error") from e
            if (not isinstance(value, dict) or set(value) != {"protocol_version", "command", "ok", "result", "error"}
                    or type(value.get("protocol_version")) is not int
                    or value["protocol_version"] != 1 or value.get("command") != command
                    or type(value.get("ok")) is not bool):
                raise AdapterError("CLI protocol or command mismatch", "processing_error")
            if value["ok"]:
                if process.returncode != 0 or not isinstance(value.get("result"), dict) or value.get("error") is not None:
                    raise AdapterError("CLI success envelope contradicts its exit status", "processing_error")
                return Envelope(command, True, value["result"])
            error = value.get("error")
            if (process.returncode == 0 or value.get("result") is not None or not isinstance(error, dict)
                    or set(error) != {"code", "message", "status"}
                    or not isinstance(error.get("code"), str)
                    or error.get("code") not in {"invalid_argument", "unsupported", "io_error", "processing_error",
                                                  "out_of_memory", "output_io_error", "invalid_recipe"}
                    or not isinstance(error.get("message"), str)
                    or (error.get("status") is not None and (type(error["status"]) is not int or not 1 <= error["status"] <= 6))):
                raise AdapterError("CLI returned an invalid error envelope", "processing_error")
            return Envelope(command, False, error=Error(error["code"], error["message"], error.get("status")))
        except TimeoutError as e:
            raise AdapterError("CLI task timed out", "processing_error") from e
        except ExceptionGroup as e:
            raise AdapterError("CLI output collection failed", "processing_error") from e
        except OSError as e:
            raise AdapterError(f"Could not execute CLI: {e}", "processing_error") from e
        finally:
            if process is not None:
                await self._stop(process)
                self._processes.discard(process)

    @staticmethod
    def _inside(path, roots):
        return any(path == root or root in path.parents for root in roots)

    def _read_path(self, value, base=None, *, require_file=True):
        if not isinstance(value, (str, Path)) or not str(value):
            raise AdapterError("Expected a nonempty file path")
        path = Path(value)
        if not path.is_absolute():
            if base is None:
                raise AdapterError("Tool paths must be absolute")
            path = base / path
        try:
            path = path.resolve(strict=require_file)
        except (OSError, RuntimeError) as e:
            raise AdapterError(f"Cannot resolve input file: {value}", "io_error") from e
        if not self._inside(path, self.config.read_roots) or (require_file and not path.is_file()):
            raise AdapterError("Input is not a file within an allowed read root")
        return path

    def _output_path(self, value, base=None, *, require_parent=True):
        if not isinstance(value, (str, Path)) or not str(value):
            raise AdapterError("Expected a nonempty output path")
        path = Path(value)
        if not path.is_absolute():
            if base is None:
                raise AdapterError("Tool paths must be absolute")
            path = base / path
        if require_parent and path.is_symlink():
            raise AdapterError("Output cannot be a symbolic link")
        try:
            path = path.resolve()
        except (OSError, RuntimeError) as e:
            raise AdapterError("Cannot resolve output path") from e
        if not self._inside(path, self.config.write_roots) or (require_parent and not path.parent.is_dir()):
            raise AdapterError("Output parent must exist within an allowed write root")
        return path

    async def _recipe(self, recipe_path, preview_output=None, *, validating=False):
        if self.capabilities is None:
            raise AdapterError("CLI negotiation has not completed", "processing_error")
        source = self._read_path(recipe_path)
        # CLI 自己解析原文件，保留重复键、整数 token、深度等严格格式校验。
        validated = await self._run("validate_recipe", ["--recipe", recipe_path, "--print-recipe", "--json"])
        if not validated.ok:
            raise AdapterError(validated.error.message, validated.error.code, validated.error.status)
        recipe = validated.result
        # 符号链接 recipe 的相对路径仍以调用方传入目录为准，和 CLI 一致。
        base = Path(recipe_path).parent
        try:
            version = recipe["schema_version"]
            if type(version) is not int or version not in self.capabilities.recipe_versions:
                raise AdapterError("Unsupported recipe schema version")
            def reference(value):
                if not isinstance(value, str) or not value:
                    raise AdapterError("Expected a nonempty recipe path", "invalid_recipe")
                # CLI 先 lexically_normal，再交给文件系统解析符号链接。
                return Path(os.path.normpath(base / value))

            image = self._read_path(reference(recipe["input"]["path"]), require_file=not validating)
            if not validating:
                recipe["input"]["path"] = str(image)
            protected = {source, image}
            look = recipe.get("edits", {}).get("look")
            if look and look.get("path"):
                look_path = self._read_path(reference(look["path"]), require_file=not validating)
                protected.add(look_path)
                if not validating:
                    look["path"] = str(look_path)
            output = self._output_path(preview_output if preview_output is not None else reference(recipe["output"]["path"]),
                                       require_parent=not validating)
            if not validating and output in protected:
                raise AdapterError("Output cannot overwrite the recipe, input or look")
            if not validating:
                recipe["output"]["path"] = str(output)
            return source, recipe, output
        except (KeyError, TypeError, AttributeError, ValueError) as e:
            raise AdapterError(f"Malformed recipe: {e}") from e

    async def image_info(self, image_path):
        try:
            path = self._read_path(image_path)
            return await self._run("info", ["--info", path, "--json"])
        except AdapterError as e:
            return failure("info", e)

    async def validate_recipe(self, recipe_path):
        return await self._render("validate_recipe", recipe_path)

    async def render_preview(self, recipe_path, output_path, long_edge=1280):
        if type(long_edge) is not int or not 1 <= long_edge <= 4294967295:
            return failure("preview", AdapterError("long_edge must be a positive uint32"))
        return await self._render("preview", recipe_path, output_path, long_edge)

    async def export_photo(self, recipe_path):
        return await self._render("export", recipe_path)

    async def _render(self, command, recipe_path, preview_output=None, long_edge=1280):
        try:
            async with asyncio.timeout(self.config.timeout):
                return await self._render_task(command, recipe_path, preview_output, long_edge)
        except TimeoutError:
            return failure(command, AdapterError("CLI task timed out", "processing_error"))

    async def _render_task(self, command, recipe_path, preview_output, long_edge):
        folder = None
        try:
            _, recipe, output = await self._recipe(recipe_path, preview_output, validating=command == "validate_recipe")
            if command == "validate_recipe":
                return Envelope(command, True, recipe)
            if output.exists() or output.is_symlink():
                raise AdapterError("Output already exists; overwriting is not allowed")
            folder = Path(tempfile.mkdtemp(prefix=".rawlab-mcp-", dir=output.parent))
            staged = folder / ("result" + output.suffix)
            recipe["output"]["path"] = str(staged)
            private_recipe = folder / "recipe.json"
            private_recipe.write_text(json.dumps(recipe, ensure_ascii=False, allow_nan=False), encoding="utf-8")
            args = ["--recipe", private_recipe]
            if command == "preview":
                args += ["--preview", staged, "--long-edge", str(long_edge)]
            result = await self._run(command, [*args, "--json"])
            if not result.ok:
                return result
            if not staged.is_file() or staged.is_symlink() or result.result.get("output_path") != str(staged):
                raise AdapterError("CLI did not produce the expected output", "output_io_error")
            if self._output_path(output) != output:
                raise AdapterError("Output directory changed during rendering", "output_io_error")
            # 同卷 hard link 是无覆盖的原子发布；目标已存在时不会替换任何文件。
            os.link(staged, output)
            return Envelope(command, True, {**result.result, "output_path": str(output)})
        except AdapterError as e:
            return failure(command, e)
        except (OSError, ValueError) as e:
            return failure(command, AdapterError(str(e), "output_io_error"))
        finally:
            if folder is not None:
                shutil.rmtree(folder)
