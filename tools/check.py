"""Type-check with TpF3's bundled Teal compiler and run the mod's Lua tests."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
from zipfile import ZipFile

from localization import check_localization, lua_catalog


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--game-dir",
        type=Path,
        default=Path(
            os.environ.get("TF3_GAME_DIR")
            or os.environ.get("TPF3_INSTALL_DIR")
            or "/home/apasz/.local/share/Steam/steamapps/common/Transport Fever 3"
        ),
    )
    args = parser.parse_args()
    mod_root = Path(__file__).resolve().parents[1]
    catalog = check_localization(mod_root, args.game_dir)
    with tempfile.TemporaryDirectory(prefix="noter-check-") as directory:
        compiler = Path(directory) / "tl.lua"
        react = Path(directory) / "react.lua"
        translations = Path(directory) / "translations.lua"
        translations.write_text(lua_catalog(catalog), encoding="utf-8")
        with ZipFile(args.game_dir / "base/content/base.zip") as archive:
            compiler.write_bytes(archive.read("base/tl.lua"))
        with ZipFile(args.game_dir / "base/content/gui.zip") as archive:
            react.write_bytes(archive.read("gui/main/react.lua"))
        subprocess.run(
            ["lua5.3", str(mod_root / "tools/check.lua"), str(compiler),
             str(args.game_dir.resolve()), str(mod_root), str(translations), str(react)],
            check=True,
        )


if __name__ == "__main__":
    main()
