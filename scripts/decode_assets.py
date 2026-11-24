#!/usr/bin/env python3
"""Decode base64-encoded binary assets back to their original paths.

The GitHub push route used for this repo only accepts UTF-8 text files, so
binary assets (PNG icons, emoji, .ico) are stored as `<path>.b64` text files.
Run this once after checkout (locally or in CI) before building:

    python3 scripts/decode_assets.py

It walks the repo for `*.b64` files and writes each decoded file to the same
path without the `.b64` suffix, skipping files that already exist with
identical content.
"""
import base64
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Android's resource merger (AAPT) rejects any file under res/ whose name
# does not end with .xml or .png. A leftover *.b64 transport copy there
# breaks :app:packageReleaseResources, so it must be removed after decode.
RES_DIR = ROOT / "android" / "app" / "src" / "main" / "res"

def main() -> int:
    decoded = 0
    skipped = 0
    removed = 0
    for b64_path in sorted(ROOT.rglob("*.b64")):
        if ".git" in b64_path.parts:
            continue
        target = b64_path.with_suffix("")
        data = base64.b64decode(b64_path.read_text(encoding="ascii"))
        if target.exists() and target.read_bytes() == data:
            skipped += 1
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            decoded += 1
        if RES_DIR in b64_path.parents:
            b64_path.unlink()
            removed += 1
    print(f"decode_assets: decoded {decoded}, skipped {skipped} (already present), removed {removed} .b64 under android res/")
    return 0

if __name__ == "__main__":
    sys.exit(main())
