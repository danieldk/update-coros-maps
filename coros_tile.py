#!/usr/bin/env python3
"""Add the COROS custom tile trailer (top-level protobuf fields 4-11) to an MVT tile.

Observed semantics (derived from the original files from original .t files):
  f4 (varint)  = number of layers
  f5 (bytes)   = per-layer class code, varint-concatenated: A=2 B=2 F=2 H=4 I=2 J=4 K=7 L=18 N=3 O=2 P=4 (Q=2 in VCM)
  f6 (bytes)   = per-layer count of entries in the layer's values array
  f7 (bytes)   = per-layer feature count
  f8 (bytes)   = per-layer total tag varints (2 per key-value pair)
  f9 (bytes)   = per-layer total geometry payload bytes
  f10 (bytes)  = concatenated layer names
  f11 (bytes)  = per-layer sum of name(X) string lengths for point layers, else 0
"""
import gzip

F5 = {'A': 2, 'B': 2, 'F': 2, 'H': 4, 'I': 2, 'J': 4, 'K': 7, 'L': 18, 'N': 3, 'O': 2, 'P': 4, 'Q': 2}

def _varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def _read_varint(buf, pos):
    r = 0; s = 0
    while True:
        b = buf[pos]; pos += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80):
            return r, pos
        s += 7

def _field_varint(f, v):
    return bytes([(f << 3) | 0]) + _varint(v)

def _field_bytes(f, b):
    return bytes([(f << 3) | 2]) + _varint(len(b)) + b

def _count_varints(buf):
    n = 0; pos = 0
    while pos < len(buf):
        _, pos = _read_varint(buf, pos)
        n += 1
    return n

def parse_layers(raw):
    """return list of layer dicts from raw MVT"""
    pos = 0; layers = []
    while pos < len(raw):
        tag = raw[pos]; pos += 1
        f, w = tag >> 3, tag & 7
        if w == 2:
            ln, pos = _read_varint(raw, pos)
            seg = raw[pos:pos+ln]; pos += ln
            if f != 3:
                continue
            lp = 0; name = ''; nfeat = 0; nvals = 0; tagvarints = 0; geobytes = 0; namelen = 0; all_point = True
            keys = []; values = []; feats = []
            while lp < len(seg):
                lt = seg[lp]; lp += 1
                lf, lw = lt >> 3, lt & 7
                if lw == 2:
                    l2, lp = _read_varint(seg, lp)
                    payload = seg[lp:lp+l2]; lp += l2
                    if lf == 1:
                        name = payload.decode('utf8', 'replace')
                    elif lf == 2:
                        nfeat += 1
                        fp = 0; ftype = None; ftags = None
                        while fp < len(payload):
                            ft = payload[fp]; fp += 1
                            ff, fw = ft >> 3, ft & 7
                            if fw == 2:
                                fl, fp = _read_varint(payload, fp)
                                if ff == 2:
                                    tagvarints += _count_varints(payload[fp:fp+fl])
                                    ftags = payload[fp:fp+fl]
                                elif ff == 4:
                                    geobytes += fl
                                fp += fl
                            elif fw == 0:
                                v, fp = _read_varint(payload, fp)
                                if ff == 3:
                                    ftype = v
                        if ftype == 1:
                            pass
                        elif ftype is not None:
                            all_point = False
                        feats.append((ftype, ftags))
                    elif lf == 3:
                        keys.append(payload.decode('utf8', 'replace'))
                    elif lf == 4:
                        nvals += 1
                        values.append(payload)
                elif lw == 0:
                    _, lp = _read_varint(seg, lp)
            # f11: for point layers, sum of byte lengths of X (name) values actually referenced
            if 'X' in keys:
                xi = keys.index('X')
                for ftype, ftags in feats:
                    if ftags is None:
                        continue
                    tv = []
                    p = 0
                    while p < len(ftags):
                        v, p = _read_varint(ftags, p)
                        tv.append(v)
                    for j in range(0, len(tv) - 1, 2):
                        if tv[j] == xi and tv[j+1] < len(values):
                            # TileValue: field 1 = string_value
                            vp = 0; val = values[tv[j+1]]
                            while vp < len(val):
                                vt = val[vp]; vp += 1
                                vf, vw = vt >> 3, vt & 7
                                if vw == 2:
                                    vl, vp = _read_varint(val, vp)
                                    if vf == 1:
                                        namelen += vl
                                    vp += vl
                                elif vw == 0:
                                    _, vp = _read_varint(val, vp)
                                else:
                                    break
            layers.append(dict(name=name, nfeat=nfeat, nvals=nvals, tagvarints=tagvarints,
                               geobytes=geobytes, all_point=all_point, namelen=namelen))
        elif w == 0:
            _, pos = _read_varint(raw, pos)
        else:
            break
    return layers

def add_trailer(raw):
    layers = parse_layers(raw)
    out = bytearray(raw)
    out += _field_varint(4, len(layers))
    out += _field_bytes(5, b''.join(_varint(F5.get(l['name'], 2)) for l in layers))
    out += _field_bytes(6, b''.join(_varint(l['nvals']) for l in layers))
    out += _field_bytes(7, b''.join(_varint(l['nfeat']) for l in layers))
    out += _field_bytes(8, b''.join(_varint(l['tagvarints']) for l in layers))
    out += _field_bytes(9, b''.join(_varint(l['geobytes']) for l in layers))
    out += _field_bytes(10, ''.join(l['name'] for l in layers).encode())
    out += _field_bytes(11, b''.join(_varint(l['namelen'] if l['name'] not in ('N','B','F') else 0) for l in layers))
    return bytes(out)

def wrap_tile(blob):
    """blob: gzip-compressed MVT -> gzip-compressed MVT+trailer"""
    raw = gzip.decompress(blob) if blob[:2] == b'\x1f\x8b' else blob
    return gzip.compress(add_trailer(raw), mtime=0)
