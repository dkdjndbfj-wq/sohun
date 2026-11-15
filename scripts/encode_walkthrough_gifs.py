"""Encode real Flutter capture frames as compact, looping presentation GIFs.

No UI text or controls are painted here. The pointer and click indicators are
already part of the Flutter captures. Requires Pillow; never reads user data.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

from PIL import Image


def read_frames(folder: Path):
    manifest = json.loads((folder / 'frames.json').read_text(encoding='utf-8'))
    records = manifest['frames'] if isinstance(manifest, dict) else manifest
    if not records:
        raise ValueError(f'No captured frames in {folder}')
    result = []
    for item in records:
        path = (folder / item['file']).resolve()
        if folder.resolve() not in path.parents or path.suffix.lower() != '.png':
            raise ValueError('Frame must be a PNG within its capture folder')
        duration = item['durationMs']
        if type(duration) is not int or duration < 10:
            raise ValueError('GIF frame duration must be at least 10ms')
        result.append((path, max(10, round(duration / 10) * 10)))
    return result


def make_palette(records):
    indices = sorted({round(i * (len(records) - 1) / 23) for i in range(24)})
    atlas = Image.new('RGB', (320 * 4, 200 * ((len(indices) + 3) // 4)))
    accents = Counter()
    for position, index in enumerate(indices):
        with Image.open(records[index][0]) as source:
            thumb = source.convert('RGB')
            # Sample original colors without blending narrow icon/progress
            # strokes into their pale backgrounds. Reserve palette entries
            # for saturated UI accents, which occupy very little screen area.
            thumb.thumbnail((320, 200), Image.Resampling.NEAREST)
            pixels = getattr(thumb, 'get_flattened_data', thumb.getdata)()
            accents.update(color for color in pixels
                           if max(color) - min(color) >= 48)
            atlas.paste(thumb, ((position % 4) * 320, (position // 4) * 200))
    base = atlas.quantize(colors=224, method=Image.Quantize.MEDIANCUT)
    accent_colors = [color for color, _ in accents.most_common(32)]
    accent_colors += [(0, 0, 0)] * (32 - len(accent_colors))
    palette = Image.new('P', (1, 1))
    palette.putpalette(base.getpalette()[:224 * 3]
                       + [channel for color in accent_colors for channel in color])
    base.close()
    atlas.close()
    return palette


def encode(folder: Path, destination: Path):
    records = read_frames(folder)
    target = destination / f'{folder.name}.gif'
    if target.exists():
        raise FileExistsError(f'Existing GIF preserved: {target}')
    palette = make_palette(records)
    frames, durations = [], []
    size = None
    for path, duration in records:
        with Image.open(path) as image:
            rgb = image.convert('RGB')
            if size is not None and rgb.size != size:
                raise ValueError('Capture size changed during a clip')
            size = rgb.size
            frames.append(rgb.quantize(palette=palette, dither=Image.Dither.NONE))
            durations.append(duration)
    frames[0].save(target, format='GIF', save_all=True, append_images=frames[1:],
                   duration=durations, loop=0, disposal=1, optimize=False)
    for frame in frames:
        frame.close()
    palette.close()
    # Reopen every encoded frame: detects truncated output and verifies timing.
    with Image.open(target) as decoded:
        duration_ms = 0
        for index in range(decoded.n_frames):
            decoded.seek(index)
            decoded.load()
            duration_ms += decoded.info.get('duration', 0)
        if decoded.size != size or abs(duration_ms - sum(durations)) > 10:
            raise ValueError('Encoded GIF size or timing does not match capture')
        actual_frames = decoded.n_frames
    return {'file': target.name, 'width': size[0], 'height': size[1],
            'durationMs': duration_ms, 'capturedFrames': len(records),
            'encodedFrames': actual_frames, 'bytes': target.stat().st_size,
            'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
            'loop': 'continuous', 'source': 'real_flutter_widgets_with_example_records',
            'realPrinterActions': False, 'actualModelInference': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    destination = args.root / 'GIF'
    destination.mkdir(exist_ok=True)
    folders = sorted(path.parent for path in (args.root / 'frames').glob('*/frames.json'))
    if not folders:
        raise ValueError('No frame manifests found')
    report = [encode(folder, destination) for folder in folders]
    with (args.root / 'gif-manifest.json').open('x', encoding='utf-8') as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
