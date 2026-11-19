"""将标准 PNG 图标尺寸封装为 macOS ICNS。"""
from pathlib import Path
import json
import shutil
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
resources = root / 'Resources'

def find_actool() -> str | None:
    actool = shutil.which('actool')
    if actool:
        return actool
    result = subprocess.run(['/usr/bin/xcrun', '--find', 'actool'], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def build_with_actool(actool: str) -> bool:
    """Build a real Assets.car and ICNS so Finder and TCC can read the icon."""
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            images.append({
                'filename': f'icon_{size}x{size}{suffix}.png',
                'idiom': 'mac',
                'scale': f'{scale}x',
                'size': f'{size}x{size}',
            })
    with tempfile.TemporaryDirectory(prefix='macclean-assets-') as directory:
        catalog = Path(directory) / 'Assets.xcassets/AppIcon.appiconset'
        output = Path(directory) / 'compiled'
        catalog.mkdir(parents=True)
        output.mkdir()
        for image in images:
            shutil.copy2(iconset / image['filename'], catalog / image['filename'])
        (catalog / 'Contents.json').write_text(
            json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2),
            encoding='utf-8',
        )
        partial = output / 'partial.plist'
        subprocess.run([
            actool, '--platform', 'macosx', '--minimum-deployment-target', '13.0',
            '--app-icon', 'AppIcon', '--output-partial-info-plist', str(partial),
            '--compile', str(output), str(Path(directory) / 'Assets.xcassets'),
        ], check=True)
        shutil.copy2(output / 'AppIcon.icns', resources / 'AppIcon.icns')
        shutil.copy2(output / 'Assets.car', resources / 'Assets.car')
    return True


with tempfile.TemporaryDirectory(prefix='macclean-iconset-') as directory:
    iconset = Path(directory)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            output = iconset / f'icon_{size}x{size}{suffix}.png'
            pixels = str(size * scale)
            subprocess.run(['sips', '-z', pixels, pixels, str(resources / 'AppIcon.png'), '--out', str(output)], check=True, stdout=subprocess.DEVNULL)

    actool = find_actool()
    if actool is None or not build_with_actool(actool):
        # Fallback for environments without Xcode. PNG chunks are used instead of
        # legacy icp4/icp5/icp6 chunks, which Finder may decode as colored noise.
        entries = [
            ('ic11', 'icon_16x16@2x.png'), ('ic12', 'icon_32x32@2x.png'),
            ('ic07', 'icon_128x128.png'), ('ic13', 'icon_128x128@2x.png'),
            ('ic08', 'icon_256x256.png'), ('ic14', 'icon_256x256@2x.png'),
            ('ic09', 'icon_512x512.png'), ('ic10', 'icon_512x512@2x.png'),
        ]
        chunks = []
        for kind, name in entries:
            payload = (iconset / name).read_bytes()
            assert payload.startswith(b'\x89PNG\r\n\x1a\n')
            chunks.append(kind.encode('ascii') + struct.pack('>I', len(payload) + 8) + payload)
        body = b''.join(chunks)
        (resources / 'AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
print(resources / 'AppIcon.icns')
