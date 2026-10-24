"""Give upstream CI DMGs their public, upstream-style notarized names."""

import argparse
from collections import defaultdict
from pathlib import Path
import re
import shutil


ARTIFACT_NAME = re.compile(
    r"qBittorrent-CI_macOS_GUI=(ON|OFF)_libtorrent-(\d+\.\d+\.\d+)_Qt-(\d+\.\d+\.\d+)"
)


def prepare_assets(source: Path, destination: Path, version: str) -> list[Path]:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"Unexpected qBittorrent version: {version}")

    variants = []
    for dmg in sorted(source.rglob("*.dmg")):
        match = ARTIFACT_NAME.fullmatch(dmg.parent.name)
        if not match:
            raise ValueError(f"Unrecognized upstream artifact directory: {dmg.parent.name}")
        gui, libtorrent, qt = match.groups()
        product = "qbittorrent" if gui == "ON" else "qbittorrent-nox"
        if dmg.name != f"{product}.dmg":
            raise ValueError(f"Unexpected DMG for {gui}: {dmg.name}")
        variants.append((dmg, product, libtorrent, qt))
    if not variants:
        raise ValueError("No DMG files were downloaded")

    # Preserve short upstream names for the usual single-Qt matrix, while
    # distinguishing additional Qt versions or libtorrent patches automatically.
    qt_versions = {qt for _, _, _, qt in variants}
    series_versions = defaultdict(set)
    for _, _, libtorrent, _ in variants:
        series_versions[tuple(libtorrent.split(".")[:2])].add(libtorrent)

    planned = []
    names = set()
    for dmg, product, libtorrent, qt in variants:
        series = tuple(libtorrent.split(".")[:2])
        suffix = ""
        if len(series_versions[series]) > 1:
            suffix += f"_lt{libtorrent}"
        elif series != ("1", "2"):
            suffix += "_lt" + "".join(series)
        if len(qt_versions) > 1:
            suffix += f"_qt{qt}"
        name = f"{product}-{version}{suffix}_notarized.dmg"
        target = destination / name
        if name in names or target.exists():
            raise ValueError(f"Refusing to overwrite release asset: {name}")
        names.add(name)
        planned.append((dmg, target))

    destination.mkdir(parents=True, exist_ok=True)
    for dmg, target in planned:
        shutil.copy2(dmg, target)
    return [target for _, target in planned]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    try:
        assets = prepare_assets(args.source, args.destination, args.version)
    except ValueError as error:
        parser.exit(1, f"Cannot prepare release assets: {error}\n")
    print(f"Prepared {len(assets)} notarized release assets:")
    for asset in assets:
        print(asset)
