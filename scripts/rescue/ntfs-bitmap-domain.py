#!/usr/bin/env python3
# Build a GNU ddrescue domain mapfile (used clusters only) from an NTFS
# partition's boot sector and $Bitmap, read separately with dd.
# Fallback for when ddru_ntfsbitmap returns an empty bitmap (docs/runbooks/disk-rescue.md).
# usage: ntfs-bitmap-domain.py <bootsector> <bitmap> <partition_bytes> <out_domain>
import sys, struct
boot = open(sys.argv[1], 'rb').read(512)
bps = struct.unpack_from('<H', boot, 0x0B)[0]
spc = boot[0x0D]
cl = bps * spc
bm = open(sys.argv[2], 'rb').read()
total = int(sys.argv[3])
nclus = total // cl
runs, start, used = [], None, 0
for c in range(nclus):
    bit = (bm[c >> 3] >> (c & 7)) & 1
    if bit and start is None:
        start = c
    elif not bit and start is not None:
        runs.append((start, c)); start = None
    used += bit
if start is not None:
    runs.append((start, nclus))
with open(sys.argv[4], 'w') as f:
    f.write('# domain from $Bitmap\n0x00000000     +\n#      pos        size  status\n')
    pos = 0
    for s, e in runs:
        if s * cl > pos:
            f.write('0x%X  0x%X  ?\n' % (pos, s * cl - pos))
        f.write('0x%X  0x%X  +\n' % (s * cl, (e - s) * cl))
        pos = e * cl
    if pos < total:
        f.write('0x%X  0x%X  ?\n' % (pos, total - pos))
print('cluster=%d clusters=%d used=%.1f GB runs=%d' % (cl, nclus, used * cl / 1e9, len(runs)))
