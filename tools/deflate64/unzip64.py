import zipfile, os, struct, subprocess, sys, zlib
zp, out, tool = sys.argv[1], sys.argv[2], sys.argv[3]
z = zipfile.ZipFile(zp, metadata_encoding='gbk')
f = open(zp, 'rb')
ok = bad = 0
for i in z.infolist():
    name = i.filename
    name = name.replace('\\', '/')
    assert not name.startswith('/') and '..' not in name.split('/'), name
    dest = os.path.join(out, name)
    if name.endswith('/'):
        os.makedirs(dest, exist_ok=True); continue
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    f.seek(i.header_offset)
    h = f.read(30)
    assert h[:4] == b'PK\x03\x04'
    nlen, elen = struct.unpack('<HH', h[26:30])
    data_off = i.header_offset + 30 + nlen + elen
    r = subprocess.run([tool, zp, str(data_off), str(i.compress_size), str(i.file_size), dest, str(i.compress_type)], capture_output=True, text=True)
    crc = 0
    with open(dest, 'rb') as g:
        while True:
            b = g.read(1 << 20)
            if not b: break
            crc = zlib.crc32(b, crc)
    if r.returncode == 0 and crc == i.CRC:
        ok += 1
    else:
        bad += 1; print('FAIL', name, r.returncode, r.stderr.strip(), hex(crc), hex(i.CRC))
print('ok', ok, 'bad', bad)
