import argparse
import json
from pathlib import Path
import sys

import PyOpenColorIO as ocio

from .bake import BakingError, inspect_source, prepare
from .color import ColorSpaces
from .contract import Contract
from .native import compile_dcp


def main(argv=None):
    parser = argparse.ArgumentParser(description="Prepare explicitly color-managed LUTs for RawLab")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("spaces", help="List built-in input/output color spaces")
    inspect = commands.add_parser("inspect", help="Read format and declared metadata without modifying a file")
    inspect.add_argument("source", type=Path)
    bake = commands.add_parser("prepare", help="Compose a source LUT into the native photo CUBE contract")
    bake.add_argument("source", type=Path)
    bake.add_argument("destination", type=Path)
    bake.add_argument("--contract", type=Path, help="Version 1 JSON color contract")
    bake.add_argument("--size", type=int, default=65)
    bake.add_argument("--max-error", type=float, default=.02)
    bake.add_argument("--allow-approximation", action="store_true")
    bake.add_argument("--force", action="store_true")
    bake.add_argument("--ignore-dcp-exposure", action="store_true", help="Exclude DCP BaselineExposureOffset")
    native = commands.add_parser("compile-dcp", help="Preserve DCP stages for native CPU evaluation without RGB baking")
    native.add_argument("source", type=Path)
    native.add_argument("destination", type=Path)
    native.add_argument("--force", action="store_true")
    native.add_argument("--ignore-dcp-exposure", action="store_true")
    native.add_argument("--tone-curve", type=Path, help="Explicit JSON x/y pairs for a profile without ToneCurve")
    native.add_argument("--no-auto-black", action="store_true", help="Explicitly omit unsupported automatic black rendering")
    args = parser.parse_args(argv)
    try:
        if args.command == "spaces":
            result = {"spaces": ColorSpaces().names, "ocio_version": ocio.__version__}
        elif args.command == "inspect":
            result = inspect_source(args.source)
        elif args.command == "compile-dcp":
            result = compile_dcp(args.source, args.destination, force=args.force,
                                 dcp_exposure=not args.ignore_dcp_exposure,
                                 tone_curve=json.loads(args.tone_curve.read_text(encoding="utf-8")) if args.tone_curve else None,
                                 no_auto_black=args.no_auto_black)
        else:
            contract = None
            if args.contract:
                data = json.loads(args.contract.read_text(encoding="utf-8"))
                contract = Contract.from_dict(data)
                if contract.ocio:
                    config = Path(contract.ocio["config"])
                    contract.ocio["config"] = str((args.contract.parent / config).resolve())
            result = prepare(args.source, args.destination, contract, size=args.size,
                             max_error=args.max_error, allow_approximation=args.allow_approximation,
                             force=args.force, dcp_exposure=not args.ignore_dcp_exposure)
        print(json.dumps(result, indent=2, ensure_ascii=True))
        return 0
    except BakingError as error:
        print(json.dumps(error.report, indent=2, ensure_ascii=True))
        print(f"lutprep: {error}", file=sys.stderr)
        return 2
    except (OSError, ValueError, ocio.Exception) as error:
        print(f"lutprep: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
