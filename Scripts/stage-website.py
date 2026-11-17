#!/usr/bin/env python3
"""Assemble a local Pages folder with the operator's existing legal pages."""
import argparse
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LEGAL_PAGES = ("impressum/index.html", "datenschutz/index.html", "en/legal/index.html", "en/privacy/index.html")


def stage(website: Path, legal: Path, destination: Path) -> None:
    for page in LEGAL_PAGES:
        source = legal / page
        if not source.is_file() or not source.read_bytes().strip():
            raise ValueError(f"Missing or empty operator page: {page}")
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"Staging directory already exists: {destination}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="website-", dir=destination.parent) as temporary:
        bundle = Path(temporary) / "site"
        shutil.copytree(website, bundle)
        for page in LEGAL_PAGES:
            output = bundle / page
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(legal / page, output)
        bundle.rename(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("legal_directory", type=Path, help="Local folder containing the four existing legal routes")
    args = parser.parse_args()
    destination = ROOT / "build" / "website"
    try:
        stage(ROOT / "Website", args.legal_directory, destination)
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")
    print(destination)


if __name__ == "__main__":
    main()
