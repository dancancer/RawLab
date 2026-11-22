import argparse
import asyncio
import logging
from pathlib import Path
import sys

from .config import ServerConfig
from .server import serve


def main():
    parser = argparse.ArgumentParser(description="Local stdio MCP adapter for the RawLab agent CLI (capability-negotiated recipes)")
    parser.add_argument("--cli", required=True, type=Path, help="Path to the trusted sony2fuji executable")
    parser.add_argument("--read-root", required=True, action="append", type=Path, help="Allowed input directory (repeatable)")
    parser.add_argument("--write-root", required=True, action="append", type=Path, help="Allowed output directory (repeatable)")
    parser.add_argument("--lens-database", type=Path, help="Lensfun file or directory within an allowed read root")
    parser.add_argument("--timeout", default=120.0, type=float, help="Per-tool timeout in seconds, including validation")
    parser.add_argument(
        "--enable-gui-sync",
        action="store_true",
        default=False,
        help="Enable opt-in GUI persistence tools (save_preset, sync_photo_edit) scoped to --data-dir",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=None,
        help="Absolute RawLab application data directory for opt-in GUI sync (defaults to platform AppData/RawLab)",
    )
    args = parser.parse_args()
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    try:
        config = ServerConfig(
            args.cli,
            tuple(args.read_root),
            tuple(args.write_root),
            args.timeout,
            lens_database=args.lens_database,
            enable_gui_sync=args.enable_gui_sync,
            data_dir=args.data_dir,
        )
        asyncio.run(serve(config))
    except KeyboardInterrupt:
        pass
    except Exception as error:
        logging.error("RawLab MCP stopped: %s", error)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
