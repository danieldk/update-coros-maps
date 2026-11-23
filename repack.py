#!/usr/bin/env python3
"""Repack a tilemaker PMTiles into a COROS-compatible .t file:
- header copied from the original cell file (bounds, center, clustered=1, zooms),
  with section offsets/lengths/counts updated
- metadata block reused verbatim from the original
- directory: full z8..13 pyramid over the cell bbox, empty tiles as zero-length
  entries (grouped in runs), data tiles in Hilbert order
- tile data: our gzip MVT blobs concatenated in tile-id order
"""
import sys, gzip, struct, math
from pmtiles.reader import MmapSource, Reader, all_tiles, zxy_to_tileid, tileid_to_zxy
from coros_tile import wrap_tile

def parse_entries(get_bytes, header):
    """return {tile_id: (offset, length)} from root (+leaf) directory"""
    from pmtiles.reader import deserialize_directory
    out = {}
    def walk(off, ln):
        for e in deserialize_directory(get_bytes(off, ln)):
            if e.run_length == 0:
                walk(header['leaf_directory_offset'] + e.offset, e.length)
            else:
                for i in range(e.run_length):
                    out[e.tile_id + i] = (e.offset, e.length)
    walk(header['root_offset'], header['root_length'])
    return out

def bbox_tiles(bbox, zmin, zmax):
    """all tile ids zmin..zmax intersecting bbox (minlon,minlat,maxlon,maxlat)"""
    ids = []
    for z in range(zmin, zmax + 1):
        n = 2 ** z
        x0 = int((bbox[0] + 180) / 360 * n)
        x1 = int((bbox[2] + 180) / 360 * n)
        # y from lat
        def yof(lat):
            return int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n)
        y0 = yof(bbox[3])  # maxlat -> smaller y
        y1 = yof(bbox[1])
        for x in range(max(0, x0), min(n - 1, x1) + 1):
            for y in range(max(0, y0), min(n - 1, y1) + 1):
                ids.append(zxy_to_tileid(z, x, y))
    return sorted(ids)

def write_varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def build_directory(tile_ids, data):  # data: {tile_id: blob}
    """entries: group consecutive empty ids into runs; data tiles run_length=1"""
    # one entry per tile id, run_length always 1 (matches the identity-repack control)
    entries = [(tid, 1, len(data[tid]) if tid in data else 0) for tid in tile_ids]
    # serialize in the 4-pass PMTiles layout: num_entries, tid deltas,
    # run_lengths, lengths, offsets (0 = contiguous with previous)
    buf = bytearray()
    buf += write_varint(len(entries))
    prev_tid = 0
    for tid, rl, ln in entries:
        buf += write_varint(tid - prev_tid); prev_tid = tid
    for tid, rl, ln in entries:
        buf += write_varint(rl)
    for tid, rl, ln in entries:
        buf += write_varint(ln)
    off = 0
    for i, (tid, rl, ln) in enumerate(entries):
        if i == 0:
            buf += write_varint(off + 1)
        else:
            buf += write_varint(0)  # contiguous
        off += ln
    return bytes(buf), len(entries), sum(rl for _, rl, _ in entries)

def repack(src_pmtiles, orig_t, out_t):
    # original header + metadata
    with open(orig_t, 'rb') as f:
        ohdr = f.read(127)
    o_root_off, o_root_len, o_meta_off, o_meta_len, o_leaf_off, o_leaf_len, o_tile_off, o_tile_len = struct.unpack('<8Q', ohdr[8:72])
    with open(orig_t, 'rb') as f:
        f.seek(o_meta_off)
        meta_block = f.read(o_meta_len)
    min_zoom, max_zoom = ohdr[100], ohdr[101]
    min_lon, min_lat, max_lon, max_lat = struct.unpack('<4i', ohdr[102:118])
    center_zoom = ohdr[118]
    center_lon, center_lat = struct.unpack('<2i', ohdr[119:127])
    bbox = (min_lon / 1e7, min_lat / 1e7, max_lon / 1e7, max_lat / 1e7)

    # our tiles -- only load blobs for tiles inside the target cell bbox
    gb = MmapSource(open(src_pmtiles, 'rb'))
    r = Reader(gb)
    h = r.header()
    entries = parse_entries(gb, h)
    tile_off = h['tile_data_offset']
    tile_ids = bbox_tiles(bbox, min_zoom, max_zoom)
    wanted = set(tile_ids)
    data = {}
    for tid, (off, ln) in entries.items():
        if ln > 0 and tid in wanted:
            data[tid] = wrap_tile(gb(tile_off + off, ln))
    dir_raw, n_entries, n_addressed = build_directory(tile_ids, data)
    dir_gz = gzip.compress(dir_raw, mtime=0)
    contents = len(data)

    tile_blob = bytearray()
    for tid in tile_ids:
        if tid in data:
            tile_blob += data[tid]

    root_off = 127
    root_len = len(dir_gz)
    meta_off = root_off + root_len
    meta_len = len(meta_block)
    leaf_off = meta_off + meta_len
    leaf_len = 0
    t_off = leaf_off
    t_len = len(tile_blob)

    hdr = bytearray(127)
    hdr[0:7] = b'PMTiles'
    hdr[7] = 3
    struct.pack_into('<8Q', hdr, 8, root_off, root_len, meta_off, meta_len, leaf_off, leaf_len, t_off, t_len)
    struct.pack_into('<Q', hdr, 72, n_addressed)
    struct.pack_into('<Q', hdr, 80, n_entries)
    struct.pack_into('<Q', hdr, 88, contents)
    hdr[96] = 1   # clustered
    hdr[97] = 2   # internal compression gzip
    hdr[98] = 2   # tile compression gzip
    hdr[99] = 1   # tile type MVT
    hdr[100] = min_zoom
    hdr[101] = max_zoom
    struct.pack_into('<4i', hdr, 102, min_lon, min_lat, max_lon, max_lat)
    hdr[118] = center_zoom
    struct.pack_into('<2i', hdr, 119, center_lon, center_lat)

    with open(out_t, 'wb') as f:
        f.write(hdr)
        f.write(dir_gz)
        f.write(meta_block)
        f.write(tile_blob)
    return dict(addressed=n_addressed, entries=n_entries, contents=contents, size=len(hdr) + len(dir_gz) + len(meta_block) + len(tile_blob))

if __name__ == '__main__':
    src, orig, out = sys.argv[1:4]
    info = repack(src, orig, out)
    print(out, info)
