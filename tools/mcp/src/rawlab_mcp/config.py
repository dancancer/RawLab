from dataclasses import dataclass
from pathlib import Path
import math
import os


@dataclass(frozen=True)
class ServerConfig:
    cli: Path
    read_roots: tuple[Path, ...]
    write_roots: tuple[Path, ...]
    timeout: float = 120.0

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
