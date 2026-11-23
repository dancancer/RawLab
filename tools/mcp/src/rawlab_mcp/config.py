from dataclasses import dataclass
from pathlib import Path
import math
import os
import sys


def default_data_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "RawLab"
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA")
        base = Path(local_app_data) if local_app_data else (Path.home() / "AppData" / "Local")
        return base / "RawLab"
    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg_data_home) if xdg_data_home else (Path.home() / ".local" / "share")
    return base / "RawLab"


def _validate_data_dir(raw: Path) -> Path:
    text = str(raw)
    try:
        text.encode("utf-8")
        encoded = os.fsencode(text)
    except (TypeError, UnicodeError, ValueError) as e:
        raise ValueError("data_dir contains an invalid path") from e
    if not text or b"\x00" in encoded:
        raise ValueError("data_dir contains an invalid path")
    path = Path(text)
    if not path.is_absolute():
        raise ValueError("data_dir must be an absolute path")
    if ".." in path.parts:
        raise ValueError("data_dir must not contain '..' segments")
    resolved = Path(os.path.realpath(path))
    if os.path.lexists(path) and path.is_symlink() and not resolved.is_dir():
        raise ValueError("data_dir symlink target must be an existing directory")
    if resolved.exists() and not resolved.is_dir():
        raise ValueError("data_dir must be a directory path")
    return resolved


@dataclass(frozen=True)
class ServerConfig:
    cli: Path
    read_roots: tuple[Path, ...]
    write_roots: tuple[Path, ...]
    timeout: float = 120.0
    lens_database: Path | None = None
    enable_gui_sync: bool = False
    data_dir: Path | None = None

    def __post_init__(self):
        if not Path(self.cli).is_absolute() or any(
            not Path(path).is_absolute() for path in (*self.read_roots, *self.write_roots)
        ):
            raise ValueError("CLI and allowed roots must be absolute paths")
        cli = Path(self.cli).resolve(strict=True)
        if not cli.is_file() or not os.access(cli, os.X_OK):
            raise ValueError("CLI must be an executable file")
        if not math.isfinite(self.timeout) or self.timeout <= 0:
            raise ValueError("Timeout must be finite and positive")
        object.__setattr__(self, "cli", cli)
        for name in ("read_roots", "write_roots"):
            roots = tuple(Path(p).resolve(strict=True) for p in getattr(self, name))
            if not roots or any(not p.is_dir() for p in roots):
                raise ValueError(f"{name} must contain existing directories")
            object.__setattr__(self, name, roots)
        if self.lens_database is not None:
            path = Path(self.lens_database)
            if not path.is_absolute():
                raise ValueError("Lens database must be an absolute path")
            path = path.resolve(strict=True)
            if (not any(path == root or root in path.parents for root in self.read_roots)
                    or not (path.is_file() or path.is_dir())):
                raise ValueError("Lens database must be a file or directory within an allowed read root")
            object.__setattr__(self, "lens_database", path)
        if type(self.enable_gui_sync) is not bool:
            raise ValueError("enable_gui_sync must be a boolean")
        if self.data_dir is not None:
            object.__setattr__(self, "data_dir", _validate_data_dir(Path(self.data_dir)))
        elif self.enable_gui_sync:
            object.__setattr__(self, "data_dir", _validate_data_dir(default_data_dir()))
