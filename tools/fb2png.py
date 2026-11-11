"""Convert a raw /dev/fb0 dump (first line = fb0 pan "x,y") from the handheld to PNG.
Usage: fb2png.py <dump> <out.png>  (640x480 visible area, 32bpp BGRX)"""
import sys, zlib, struct
raw = open(sys.argv[1], 'rb').read()
nl = raw.index(b'\n'); pan = raw[:nl].decode().strip(); data = raw[nl+1:]
w, h, stride = 640, 480, 2560
yoff = int(pan.split(',')[1]) if ',' in pan else 0
def png(path, y0):
    rows = b''.join(b'\x00' + bytes(b for px in range(w) for b in (data[(y0+y)*stride+px*4+2], data[(y0+y)*stride+px*4+1], data[(y0+y)*stride+px*4])) for y in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b''))
print('pan', pan, 'bytes', len(data))
png(sys.argv[2], yoff)
