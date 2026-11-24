#!/usr/bin/env python3
"""从 1024px 主图生成各平台图标与电视横幅；需要 Pillow。

主图：scripts/brand_icon.png（1024x1024，红果图标造型、绿色渲染）。
iOS 图标为方形（系统自行切圆角）；圆角版只用于 Windows ICO、Android
legacy 图标、macOS 徽章与电视横幅。Android monochrome 为主图白色播放
造型抽出的单色剪影。
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='从 1024px 主图生成各平台图标与电视横幅；需要 Pillow。')
parser.add_argument('--output', type=Path, default=root)
options = parser.parse_args()
output = options.output

master = Image.open(root / 'scripts/brand_icon.png').convert('RGB')
assert master.size == (1024, 1024), master.size
foreground = master.convert('RGBA')

# 白色播放造型 -> 单色剪影（白度 = V*(1-S)，纯白为 1、饱和绿约 0.1）
hsv = np.array(master.convert('HSV')).astype(np.float64)
whiteness = (hsv[..., 2] / 255.0) * (1.0 - hsv[..., 1] / 255.0)
# 纯白环白度为 1.0，最浅的薄荷绿约 0.62，阈值取 0.80 只留白环
alpha = np.clip((whiteness - 0.80) * 5.0, 0.0, 1.0)
mono = np.zeros((1024, 1024, 4), dtype=np.uint8)
mono[..., 0], mono[..., 1], mono[..., 2] = 0x3A, 0x53, 0x44
mono[..., 3] = np.uint8(np.round(alpha * 255))
silhouette = Image.fromarray(mono, 'RGBA')

icon = master  # iOS：方形，系统切圆角
rounded = foreground.copy()
corners = Image.new('L', (1024, 1024), 0)
ImageDraw.Draw(corners).rounded_rectangle((0, 0, 1023, 1023), radius=236, fill=255)
rounded.putalpha(corners)
adaptive = Image.new('RGBA', (1536, 1536))
adaptive.paste(foreground, (256, 256))
monochrome = Image.new('RGBA', (1536, 1536))
monochrome.paste(silhouette, (256, 256), silhouette)


def save(image, name):
    destination = output / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)


contents = json.loads((root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())
for entry in contents['images']:
    if 'filename' in entry:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        save(icon.resize((size, size), Image.Resampling.LANCZOS),
             'ios/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename'])
save(rounded.resize((256, 256), Image.Resampling.LANCZOS), 'windows/runner/resources/app_icon.ico')
macos_canvas = Image.new('RGBA', (1024, 1024))
macos_badge = rounded.resize((824, 824), Image.Resampling.LANCZOS)
macos_canvas.paste(macos_badge, (100, 100), macos_badge)
macos_contents = json.loads((root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())
for entry in macos_contents['images']:
    if 'filename' in entry:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        save(macos_canvas.resize((size, size), Image.Resampling.LANCZOS),
             'macos/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename'])
for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
    legacy = round(48 * scale)
    layer = round(108 * scale)
    save(rounded.resize((legacy, legacy), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
    save(adaptive.resize((layer, layer), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher_foreground.png')
    save(monochrome.resize((layer, layer), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher_monochrome.png')
banner = Image.new('RGB', (640, 360), '#F0FAF3')
badge = rounded.resize((220, 220), Image.Resampling.LANCZOS)
banner.paste(badge, (210, 70), badge)
save(banner, 'android/app/src/main/res/drawable-xhdpi/tv_banner.png')
