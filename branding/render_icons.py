#!/usr/bin/env python3
"""Render the shared SVG artwork to platform assets; requires cairosvg and Pillow."""
from pathlib import Path
import shutil
import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / 'branding'
OUT = ART / 'generated'
OUT.mkdir(exist_ok=True)

def contents(name):
    source = (ART / name).read_text()
    return source.split('>', 1)[1].rsplit('</svg>', 1)[0]

def svg(body):
    return '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">' + body + '</svg>'

def render(source, path, size):
    cairosvg.svg2png(bytestring=source.encode(), write_to=str(path), output_width=size, output_height=size)

background, foreground = contents('background.svg'), contents('foreground.svg')
mac = svg('''<defs><clipPath id="mask"><rect x="64" y="64" width="896" height="896" rx="200"/></clipPath></defs>
<rect x="64" y="77" width="896" height="896" rx="200" fill="#081B49" opacity="0.10"/>
<rect x="68" y="83" width="888" height="888" rx="198" fill="#081B49" opacity="0.05"/>
<g clip-path="url(#mask)"><g transform="translate(64 64) scale(.875)">''' + background + foreground + '''</g></g>
<rect x="65" y="65" width="894" height="894" rx="199" fill="none" stroke="#FFFFFF" stroke-opacity="0.18" stroke-width="2"/>''')
harmony = svg('<defs><clipPath id="mask"><rect width="1024" height="1024" rx="224"/></clipPath></defs><g clip-path="url(#mask)">' + background + foreground + '</g>')
(OUT / 'macos.svg').write_text(mac)
(OUT / 'harmony-preview.svg').write_text(harmony)
render(mac, OUT / 'macos-1024.png', 1024)
render(harmony, OUT / 'harmony-1024.png', 1024)
render(svg(background), OUT / 'background.png', 1024)
render(svg(foreground), OUT / 'foreground.png', 1024)
render(harmony, OUT / 'startIcon.png', 512)

for media in [ROOT / 'cast-sender/AppScope/resources/base/media', ROOT / 'cast-sender/entry/src/main/resources/base/media']:
    for name in ['background.png', 'foreground.png']:
        shutil.copyfile(OUT / name, media / name)
shutil.copyfile(OUT / 'startIcon.png', ROOT / 'cast-sender/entry/src/main/resources/base/media/startIcon.png')
iconset = ROOT / 'macos-cast/Resources/HarmonyCast.iconset'
iconset.mkdir(exist_ok=True)
for points in [16, 32, 128, 256, 512]:
    render(mac, iconset / f'icon_{points}x{points}.png', points)
    render(mac, iconset / f'icon_{points}x{points}@2x.png', points * 2)

# Contact sheet for visual QA at actual desktop and launcher sizes.
preview = Image.new('RGB', (1000, 590), '#F4F7FC')
draw = ImageDraw.Draw(preview)
font_path = next((path for path in [Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
    Path('/System/Library/Fonts/Supplemental/Arial.ttf')] if path.exists()), None)
font = ImageFont.truetype(str(font_path), 24) if font_path else ImageFont.load_default(size=24)
small = ImageFont.truetype(str(font_path), 16) if font_path else ImageFont.load_default(size=16)
for title, path, x in [('Mac', OUT / 'macos-1024.png', 70), ('HarmonyOS', OUT / 'harmony-1024.png', 570)]:
    draw.text((x, 32), title, fill='#26354B', font=font)
    icon = Image.open(path).convert('RGBA')
    preview.paste(icon.resize((310, 310), Image.Resampling.LANCZOS), (x, 85), icon.resize((310, 310), Image.Resampling.LANCZOS))
    sx = x
    for size in [16, 32, 64, 128]:
        sample = icon.resize((size, size), Image.Resampling.LANCZOS)
        preview.paste(sample, (sx, 425 + (128-size)//2), sample)
        draw.text((sx, 560), str(size), fill='#5F6B7B', font=small)
        sx += size + 26
preview.save(OUT / 'icon-preview.png')
print(OUT / 'icon-preview.png')
