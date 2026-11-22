from pathlib import Path
from struct import pack
import sys
src, out = map(Path, sys.argv[1:])
types = [
    (b'icp4','16x16'), (b'icp5','32x32'), (b'icp6','32x32@2x'),
    (b'ic07','128x128'), (b'ic08','256x256'), (b'ic09','512x512'),
    (b'ic10','512x512@2x'), (b'ic11','16x16@2x'), (b'ic12','32x32@2x'),
    (b'ic13','128x128@2x'), (b'ic14','256x256@2x')
]
chunks = []
for typ, name in types:
    img = (src / ('icon_' + name + '.png')).read_bytes()
    assert img.startswith(b'\x89PNG\r\n\x1a\n')
    chunks.append(pack('>4sI', typ, len(img) + 8) + img)
body = b''.join(chunks)
out.write_bytes(pack('>4sI', b'icns', len(body) + 8) + body)
