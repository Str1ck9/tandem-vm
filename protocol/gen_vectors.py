#!/usr/bin/env python3
"""Reference encoder for GuestLink frames. Writes vectors.json, which the Swift and Rust codec tests consume.
Kept independent of both implementations on purpose."""
import json, struct, sys, os, zlib

MAGIC = 0x4B4E4C42
IN, OUT = 1, 2

def encode(f):
    reply = f["kind"] == 2
    inline = bytes.fromhex(f["inline"])
    pad = (-len(inline)) % 8
    desc, payload = b"", b""
    for b in f["buffers"]:
        data = bytes.fromhex(b.get("data", ""))
        present = bool(b["flags"] & (OUT if reply else IN))
        length = len(data) if present else b["length"]
        desc += struct.pack("<II", length, b["flags"])
        if present:
            payload += data
    total = 32 + len(inline) + pad + len(desc) + len(payload) + 4
    head = struct.pack("<IIQHHIIHH", MAGIC, total, f["requestId"], f["kind"], f["opcode"], f["status"],
                       len(inline), len(f["buffers"]), 0)
    body = head + inline + b"\0" * pad + desc + payload
    return body + struct.pack("<I", zlib.crc32(body) & 0xFFFFFFFF)

def buf(flags, data=b"", length=None):
    b = {"flags": flags, "length": len(data) if length is None else length}
    if data: b["data"] = data.hex()
    return b

PENDING = 0xFFFFFFFF
cases = [
    ("empty request", dict(requestId=1, kind=1, opcode=0x0100, status=PENDING, inline="", buffers=[])),
    ("hello request", dict(requestId=2, kind=1, opcode=0x0001, status=PENDING,
                           inline=struct.pack("<III", 1, 1, 0b111).hex(), buffers=[buf(IN, b"0.1.0")])),
    ("hello reply", dict(requestId=2, kind=2, opcode=0x0001, status=0,
                         inline=struct.pack("<II", 1, 0).hex(), buffers=[buf(IN, length=5)])),
    ("inline needing padding", dict(requestId=3, kind=1, opcode=0x0004, status=PENDING,
                                    inline=struct.pack("<I", 2).hex(), buffers=[buf(IN, "wärn ⚠".encode())])),
    ("wait_event request offers capacity", dict(requestId=4, kind=1, opcode=0x0002, status=PENDING, inline="",
                                               buffers=[buf(OUT, length=65536)])),
    ("wait_event reply with data", dict(requestId=4, kind=2, opcode=0x0002, status=0,
                                        inline=struct.pack("<III", 1, 0, 0).hex(), buffers=[buf(OUT, b"copied text")])),
    ("echo request in+out", dict(requestId=0x1122334455667788, kind=1, opcode=0x0005, status=PENDING, inline="",
                                 buffers=[buf(IN, bytes(range(256))), buf(OUT, length=256)])),
    ("echo reply in+out", dict(requestId=0x1122334455667788, kind=2, opcode=0x0005, status=0, inline="",
                               buffers=[buf(IN, length=256), buf(OUT, bytes(range(256)))])),
    ("error reply", dict(requestId=9, kind=2, opcode=0x0999, status=0xE0000001, inline="", buffers=[])),
    ("host time reply", dict(requestId=10, kind=2, opcode=0x0100, status=0,
                             inline=struct.pack("<qIi", 1794623447, 217429000, -18000).hex(), buffers=[])),
    ("in/out buffer in request", dict(requestId=11, kind=1, opcode=0x0401, status=PENDING, inline="0102030405060708",
                                      buffers=[buf(IN | OUT, b"both ways")])),
    ("max buffers", dict(requestId=12, kind=1, opcode=0x0005, status=PENDING, inline="",
                         buffers=[buf(IN, bytes([i])) for i in range(16)])),
]
out = [dict(name=n, frame=f, hex=encode(f).hex()) for n, f in cases]
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors.json")
json.dump(out, open(path, "w"), indent=1)
print("wrote %d vectors to %s" % (len(out), path))
