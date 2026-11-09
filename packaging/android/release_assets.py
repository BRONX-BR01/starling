#!/usr/bin/env python3
"""Require every architecture APK before creating the release's shared assets."""
import argparse
from pathlib import Path

from build_apk import ROOT, TARGETS, zip_folder


def prepare(folder, version, visuals):
    version = version.removeprefix("v")
    missing = [abi for abi in TARGETS if not (folder / f"starling-{version}-{abi}.apk").is_file()]
    if missing:
        raise ValueError("Missing release APKs: " + ", ".join(missing))
    zip_folder(visuals, folder / "StarlingVisuals.zip")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "target/android")
    args = parser.parse_args()
    try:
        prepare(args.output, args.version, ROOT / "packaging/shaderpacks/starling-visuals")
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
