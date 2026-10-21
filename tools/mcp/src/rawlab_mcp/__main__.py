import argparse
import asyncio
import logging
from pathlib import Path
import sys

from .config import ServerConfig
from .server import serve


def main():
    parser = argparse.ArgumentParser(description="Local stdio MCP adapter for the RawLab v4 agent CLI")
    parser.add_argument("--cli", required=True, type=Path, help="Path to the trusted sony2fuji executable")
    parser.add_argument("--read-root", required=True, action="append", type=Path, help="Allowed input directory (repeatable)")
    parser.add_argument("--write-root", required=True, action="append", type=Path, help="Allowed output directory (repeatable)")
    parser.add_argument("--timeout", default=120.0, type=float, help="Per-command timeout in seconds")
    args = parser.parse_args()
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    try:
        config = ServerConfig(args.cli, tuple(args.read_root), tuple(args.write_root), args.timeout)
        asyncio.run(serve(config))
    except KeyboardInterrupt:
        pass
    except Exception as error:
        logging.error("RawLab MCP stopped: %s", error)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
