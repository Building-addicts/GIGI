#!/usr/bin/env python3
"""Build the tiny hardware-trigger Shortcut for GIGI.

`GIGI Listen` is the only Shortcut the user binds to Back Tap / Action Button.
It performs no dictation and no routing: it simply opens `gigi://listen`, letting
GIGI foreground into the Dynamic Island listening flow and capture speech in-app.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Iterable

from shortcuts import FMT_SHORTCUT, FMT_TOML
from shortcuts import actions as a

from build_talk_to_gigi import DynamicURLAction, ShortcutBuilder, sha256

SHORTCUT_NAME = "GIGI-Listen"
DEFAULT_OUT = Path("artifacts/shortcuts/GIGI-Listen.shortcut")
DEFAULT_TOML_OUT = Path("artifacts/shortcuts/GIGI-Listen.toml")


def build():
    b = ShortcutBuilder(name=SHORTCUT_NAME)
    b.add(DynamicURLAction, url="gigi://listen")
    b.add(a.web.OpenURLAction)
    return b.shortcut


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the GIGI Listen hardware-trigger Shortcut")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=".shortcut output path")
    parser.add_argument("--toml", type=Path, default=DEFAULT_TOML_OUT, help="debug TOML output path")
    parser.add_argument("--no-toml", action="store_true", help="skip debug TOML output")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    shortcut = build()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("wb") as handle:
        shortcut.dump(handle, file_format=FMT_SHORTCUT)

    if not args.no_toml:
        args.toml.parent.mkdir(parents=True, exist_ok=True)
        with args.toml.open("wb") as handle:
            shortcut.dump(handle, file_format=FMT_TOML)

    print(f"Wrote {args.out}")
    print(f"Actions: {len(shortcut.actions)}")
    print(f"SHA256: {sha256(args.out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
