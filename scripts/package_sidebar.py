"""Package a completed Windows x64 build for the Sidebar updater."""

import argparse
from pathlib import Path

from . import HELIUM_REPO, OUT_DIR, ROOT_DIR
from .installer import portable_files
import filescfg
import helium_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    release = ".".join(helium_version.get_version_parts(HELIUM_REPO, ROOT_DIR).values())
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output / f"Helium-Sidebar-Compact-{release}-Windows-x64.zip"
    included = [ROOT_DIR / name for name in (
        "LICENSE", "LICENSE.ungoogled_chromium", "portable/Sidebar Defaults.json",
        "portable/Open Helium PR 2367.cmd",
    )]
    filescfg.create_archive(dict.fromkeys(portable_files(OUT_DIR)), included, OUT_DIR, output)


if __name__ == "__main__":
    main()
