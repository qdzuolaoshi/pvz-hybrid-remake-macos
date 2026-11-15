# Reproducible patching of a Godot 4 pack (.pck, format 3 or newer, unencrypted) for the macOS build of
# 植物大战僵尸杂交重制版. Run with `python3 -I`.
#
#   pck_patch.py extract <pck> <res_path> <out_file>
#       Write one file of the pack to out_file.
#   pck_patch.py patch <in.pck> <out.pck> [--expect RES=MD5]... [--replace RES=FILE]... [--add RES=FILE]...
#       Copy in.pck to out.pck byte for byte, then append the new file data (32-byte aligned) and a new directory
#       after the old end of the pack, and point the header's directory offset at the new directory. The original
#       data and the old directory stay in place, unused, so in.pck is never modified and out.pck differs from it
#       only by the appended tail and the 8-byte directory offset in the header.
#       --replace  RES must already be in the pack; its entry is pointed at the appended copy of FILE.
#       --add      RES must not be in the pack yet; a new entry is added.
#       --expect   the md5 of RES's current bytes in in.pck must equal MD5 (checked before anything is written), so a
#                  newer game version is never patched blindly.
# RES is a pack path without "res://" (e.g. addons/AdobeAnimateEditor/Rendering/AdobeAnimateManagedMultiMesh.gdshader).
#
# Pack layout (Godot 4.4+): "GDPC", u32 format, u32 major, minor, patch, u32 flags (bit0 encrypted directory,
# bit1 file offsets relative to the files base), u64 files base, u64 directory offset. Directory: u32 count, then per
# entry u32 path length, path bytes (NUL padded to 4), u64 offset, u64 size, 16-byte md5, u32 flags (bit0 encrypted).
import hashlib
import shutil
import struct
import sys

HEADER_DIR_OFFSET_POS = 32
ALIGN = 32


def read_pack(f):
    f.seek(0)
    if f.read(4) != b'GDPC':
        sys.exit('pck_patch: not a Godot pack')
    fmt, major, minor, patch, flags = struct.unpack('<5I', f.read(20))
    if fmt < 3:
        sys.exit('pck_patch: pack format %d is not supported (needs 3 or newer)' % fmt)
    if flags & 1:
        sys.exit('pck_patch: encrypted directory is not supported')
    base, diroff = struct.unpack('<QQ', f.read(16))
    f.seek(diroff)
    n, = struct.unpack('<I', f.read(4))
    ents = []
    for _ in range(n):
        ln, = struct.unpack('<I', f.read(4))
        raw = f.read(ln)
        off, size = struct.unpack('<QQ', f.read(16))
        md5 = f.read(16)
        fl, = struct.unpack('<I', f.read(4))
        ents.append({'raw': raw, 'path': raw.rstrip(b'\0').decode('utf-8'), 'off': off, 'size': size,
                     'md5': md5, 'flags': fl})
    rel = bool(flags & 2)
    return {'version': (major, minor, patch), 'rel': rel, 'base': base, 'diroff': diroff, 'ents': ents}


def entry_bytes(f, pack, e):
    if e['flags'] & 1:
        sys.exit('pck_patch: %s is encrypted' % e['path'])
    f.seek(e['off'] + (pack['base'] if pack['rel'] else 0))
    return f.read(e['size'])


def parse_pairs(args, flag):
    out = []
    i = 0
    while i < len(args):
        if args[i] == flag:
            k, _, v = args[i + 1].partition('=')
            if not k or not v:
                sys.exit('pck_patch: %s needs RES=VALUE' % flag)
            out.append((k.replace('res://', ''), v))
            i += 2
        else:
            i += 1
    return out


def cmd_extract(pck, res, out):
    res = res.replace('res://', '')
    with open(pck, 'rb') as f:
        pack = read_pack(f)
        for e in pack['ents']:
            if e['path'] == res:
                data = entry_bytes(f, pack, e)
                with open(out, 'wb') as o:
                    o.write(data)
                print('pck_patch: extracted %s (%d bytes, md5 %s)' % (res, len(data), hashlib.md5(data).hexdigest()))
                return
    sys.exit('pck_patch: %s is not in the pack' % res)


def cmd_patch(src, dst, args):
    known = {'--expect', '--replace', '--add'}
    for i in range(0, len(args), 2):
        if args[i] not in known or i + 1 >= len(args):
            sys.exit('pck_patch: bad argument %r' % args[i])
    expects = parse_pairs(args, '--expect')
    replaces = parse_pairs(args, '--replace')
    adds = parse_pairs(args, '--add')

    with open(src, 'rb') as f:
        pack = read_pack(f)
        by_path = {e['path']: e for e in pack['ents']}
        for res, want in expects:
            if res not in by_path:
                sys.exit('pck_patch: expected file %s is not in the pack' % res)
            have = hashlib.md5(entry_bytes(f, pack, by_path[res])).hexdigest()
            if have != want.lower():
                sys.exit('pck_patch: %s has md5 %s, expected %s; refusing to patch a different game version'
                         % (res, have, want))
    for res, _ in replaces:
        if res not in by_path:
            sys.exit('pck_patch: --replace %s: not in the pack' % res)
    for res, _ in adds:
        if res in by_path:
            sys.exit('pck_patch: --add %s: already in the pack' % res)

    new_data = [(res, open(path, 'rb').read()) for res, path in replaces + adds]
    shutil.copyfile(src, dst)
    with open(dst, 'r+b') as f:
        f.seek(0, 2)
        placed = {}
        for res, data in new_data:
            f.write(b'\0' * ((-f.tell()) % ALIGN))
            pos = f.tell()
            f.write(data)
            placed[res] = (pos - pack['base'] if pack['rel'] else pos, len(data), hashlib.md5(data).digest())
        ents = pack['ents']
        for e in ents:
            if e['path'] in placed:
                e['off'], e['size'], e['md5'] = placed[e['path']]
        for res, _ in adds:
            raw = res.encode('utf-8')
            raw += b'\0' * ((-len(raw)) % 4)            # Godot pads paths to 4 bytes
            off, size, md5 = placed[res]
            ents.append({'raw': raw, 'path': res, 'off': off, 'size': size, 'md5': md5, 'flags': 0})
        f.write(b'\0' * ((-f.tell()) % ALIGN))
        diroff = f.tell()
        out = bytearray(struct.pack('<I', len(ents)))
        for e in ents:
            out += struct.pack('<I', len(e['raw'])) + e['raw'] + struct.pack('<QQ', e['off'], e['size'])
            out += e['md5'] + struct.pack('<I', e['flags'])
        f.write(out)
        f.seek(HEADER_DIR_OFFSET_POS)
        f.write(struct.pack('<Q', diroff))

    # Read back what was written.
    with open(dst, 'rb') as f:
        check = read_pack(f)
        by_path = {e['path']: e for e in check['ents']}
        for res, data in new_data:
            if entry_bytes(f, check, by_path[res]) != data:
                sys.exit('pck_patch: read-back of %s failed' % res)
    print('pck_patch: Godot %d.%d.%d pack, %d entries; replaced %s; added %s; directory at %d'
          % (check['version'] + (len(check['ents']), [r for r, _ in replaces], [r for r, _ in adds], diroff)))


def main(argv):
    if len(argv) == 5 and argv[1] == 'extract':
        cmd_extract(argv[2], argv[3], argv[4])
    elif len(argv) >= 4 and argv[1] == 'patch':
        cmd_patch(argv[2], argv[3], argv[4:])
    else:
        sys.exit(__doc__ or 'usage: see the header of pck_patch.py')


if __name__ == '__main__':
    main(sys.argv)
