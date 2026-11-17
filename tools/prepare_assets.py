#!/usr/bin/env python3
"""Prepares the generated hardware assets for the app.

For every color folder (carriage.png, rail.png) it:
- removes stray alpha specks outside the main contour,
- bleeds the opaque edge color into semi-transparent edge pixels (removes colored halos),
- crops to the visible contour,
- measures registration data (normalized to the cropped image):
  carriage: print point = center and top of the ceramic insert, bottom of the body
  rail: top of the band and center of the dark guide groove.

Usage: prepare_assets.py <source dir> <output dir>
Needs numpy and Pillow.
"""
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image


def shift(m, dy, dx):
    out = np.zeros_like(m)
    h, w = m.shape
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    out[yd, xd] = m[ys, xs]
    return out


def dilate(m, r):
    out = m.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= shift(m, dy, dx)
    return out


def largest_component(mask, factor=4):
    """Largest 4-connected component, computed on a downsampled grid."""
    h, w = mask.shape
    small = mask[: h - h % factor, : w - w % factor].reshape(h // factor, factor, w // factor, factor).any(axis=(1, 3))
    sh, sw = small.shape
    labels = np.zeros(small.shape, dtype=np.int32)
    best, best_size, label = 0, 0, 0
    for y in range(sh):
        for x in range(sw):
            if small[y, x] and not labels[y, x]:
                label += 1
                size = 0
                q = deque([(y, x)])
                labels[y, x] = label
                while q:
                    cy, cx = q.popleft()
                    size += 1
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < sh and 0 <= nx < sw and small[ny, nx] and not labels[ny, nx]:
                            labels[ny, nx] = label
                            q.append((ny, nx))
                if size > best_size:
                    best, best_size = label, size
    keep_small = labels == best
    keep = np.zeros_like(mask)
    keep[: sh * factor, : sw * factor] = np.repeat(np.repeat(keep_small, factor, 0), factor, 1)
    return keep


def clean(img):
    a = img[..., 3].astype(np.float32)
    solid = a > 128
    main = dilate(largest_component(solid), 3)
    a = np.where(main, a, 0)
    a[a < 6] = 0
    # Color bleed: give semi-transparent pixels the color of their opaque neighbors.
    rgb = img[..., :3].astype(np.float32)
    known = a >= 250
    for _ in range(12):
        acc = np.zeros_like(rgb)
        cnt = np.zeros(a.shape, dtype=np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            k = shift(known, dy, dx)
            acc += np.where(k[..., None], np.stack([shift(rgb[..., c], dy, dx) for c in range(3)], -1), 0)
            cnt += k
        grow = (~known) & (cnt > 0)
        rgb[grow] = acc[grow] / cnt[grow][:, None]
        known |= grow
    out = np.concatenate([rgb, a[..., None]], -1)
    return np.clip(out, 0, 255).astype(np.uint8)


def crop(img, pad=4):
    a = img[..., 3]
    ys, xs = np.where(a > 0)
    y0, y1 = max(0, ys.min() - pad), min(a.shape[0], ys.max() + 1 + pad)
    x0, x1 = max(0, xs.min() - pad), min(a.shape[1], xs.max() + 1 + pad)
    return img[y0:y1, x0:x1]


def register_carriage(img):
    a = img[..., 3] > 128
    h, w = a.shape
    cols = np.where(a.any(0))[0]
    rows = np.where(a.any(1))[0]
    left, right, top, bottom = cols.min(), cols.max(), rows.min(), rows.max()
    body_h = bottom - top
    profile = np.array([np.argmax(a[:, x]) if a[:, x].any() else h for x in range(w)])
    # The notch is the dip in the left half of the top contour.
    half = left + (right - left) // 2
    region = np.arange(left, half)
    deep = region[profile[region] > top + 0.12 * body_h]
    # Ignore the rounded outer corner at the far left.
    deep = deep[deep > left + 0.04 * (right - left)]
    notch_l, notch_r = deep.min(), deep.max()
    floor = profile[notch_l:notch_r + 1].max()
    floor_cols = np.arange(notch_l, notch_r + 1)[profile[notch_l:notch_r + 1] >= floor - 0.025 * body_h]
    # The ceramic is the raised part between the left and the right notch floor.
    gaps = np.diff(floor_cols)
    if len(gaps) and gaps.max() > 3:
        i = int(np.argmax(gaps))
        c_l, c_r = floor_cols[i], floor_cols[i + 1]
    else:
        c_l, c_r = notch_l, notch_r
    ceramic_top = profile[c_l:c_r + 1].min()
    cx = (c_l + c_r) / 2
    return {
        "printX": cx / w, "printY": ceramic_top / h,
        "ceramicLeft": c_l / w, "ceramicRight": c_r / w,
        "notchLeft": notch_l / w, "notchRight": notch_r / w,
        "left": left / w, "right": right / w, "top": top / h, "bottom": bottom / h,
        "width": w, "height": h,
    }


def register_rail(img):
    a = img[..., 3]
    h, w = a.shape
    coverage = (a > 200).mean(1)
    band = np.where(coverage > 0.9)[0]
    top, bottom = band.min(), band.max()
    lum = img[..., :3].astype(np.float32).mean(2)
    row_lum = np.array([lum[y, a[y] > 200].mean() if coverage[y] > 0.5 else 999 for y in range(h)])
    upper = np.arange(top, top + max(4, (bottom - top) // 3))
    groove = int(upper[np.argmin(row_lum[upper])])
    dark = upper[row_lum[upper] < row_lum[groove] + 0.5 * (np.median(row_lum[band]) - row_lum[groove])]
    return {
        "top": top / h, "bottom": bottom / h,
        "grooveTop": dark.min() / h, "grooveBottom": dark.max() / h, "groove": groove / h,
        "width": w, "height": h,
    }


def main():
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    registry = {}
    for folder in sorted(p for p in src.iterdir() if (p / "carriage.png").exists()):
        out = dst / folder.name
        out.mkdir(exist_ok=True)
        entry = {}
        for part, register in (("carriage", register_carriage), ("rail", register_rail)):
            img = np.array(Image.open(folder / f"{part}.png").convert("RGBA"))
            img = crop(clean(img))
            entry[part] = register(img)
            Image.fromarray(img).save(out / f"{part}.png", optimize=True)
        registry[folder.name] = entry
        c = entry["carriage"]
        print(f"{folder.name:12} print=({c['printX']:.3f},{c['printY']:.3f}) "
              f"ceramic=[{c['ceramicLeft']:.3f},{c['ceramicRight']:.3f}] groove={entry['rail']['groove']:.3f}")
    Image.open(src / "paper.png").convert("RGB").save(dst / "paper.png", optimize=True)
    (dst / "registration.json").write_text(json.dumps(registry, indent=2))


if __name__ == "__main__":
    main()
