#!/usr/bin/env python3
"""Build a macOS icon from the square project artwork using macOS tools."""
from pathlib import Path
import subprocess
import sys
import tempfile

source, destination = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory() as scratch:
    iconset = Path(scratch) / 'Wombat.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ''), (2, '@2x')):
            pixels = str(size * scale)
            output = iconset / f'icon_{size}x{size}{suffix}.png'
            subprocess.run(['/usr/bin/sips', '-z', pixels, pixels, str(source), '--out', str(output)],
                           check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)
