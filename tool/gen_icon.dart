// Generates assets/icon/icon.ico (32×32 BMP-in-ICO) without any external
// dependencies. Run: dart run tool/gen_icon.dart
import 'dart:io';
import 'dart:typed_data';

void main() {
  const size = 32;
  final b = BytesBuilder();

  // ── Icon pixels (BGRA, bottom-up) ──────────────────────────────────────────
  final pixels = BytesBuilder();
  for (var y = size - 1; y >= 0; y--) {
    for (var x = 0; x < size; x++) {
      const r = 7.0;
      final dx = x < r
          ? r - x
          : (x > size - 1 - r ? x - (size - 1 - r) : 0.0);
      final dy = y < r
          ? r - y
          : (y > size - 1 - r ? y - (size - 1 - r) : 0.0);
      final inside = dx * dx + dy * dy <= r * r;

      if (!inside) {
        pixels.addByte(0);
        pixels.addByte(0);
        pixels.addByte(0);
        pixels.addByte(0); // transparent
        continue;
      }

      // Vertical gradient: teal → dark navy.
      final t = y / (size - 1);
      int col(int a, int b) => (a + (b - a) * t).round().clamp(0, 255);
      int red = col(20, 15); // R
      int green = col(184, 23); // G
      int blue = col(166, 42); // B

      // White "relay" bars.
      final isBar = x >= 7 && x <= 24 && ((y >= 8 && y <= 10) || (y >= 14 && y <= 16) || (y >= 20 && y <= 22));
      if (isBar) {
        red = 255;
        green = 255;
        blue = 255;
      }
      pixels.addByte(blue);
      pixels.addByte(green);
      pixels.addByte(red);
      pixels.addByte(255);
    }
  }
  final xorData = pixels.toBytes();

  // AND mask: 32 rows × 4 bytes (32bpp uses alpha; mask stays 0).
  final andMask = Uint8List(size * 4);

  // ── BITMAPINFOHEADER (height doubled: XOR + AND) ───────────────────────────
  final header = ByteData(40);
  header.setUint32(0, 40, Endian.little); // biSize
  header.setInt32(4, size, Endian.little); // biWidth
  header.setInt32(8, size * 2, Endian.little); // biHeight
  header.setUint16(12, 1, Endian.little); // biPlanes
  header.setUint16(14, 32, Endian.little); // biBitCount
  // rest = 0

  final imageData = <int>[
    ...header.buffer.asUint8List(),
    ...xorData,
    ...andMask,
  ];

  // ── ICONDIR ────────────────────────────────────────────────────────────────
  final dir = ByteData(6);
  dir.setUint16(0, 0, Endian.little); // reserved
  dir.setUint16(2, 1, Endian.little); // type: icon
  dir.setUint16(4, 1, Endian.little); // count

  // ── ICONDIRENTRY ───────────────────────────────────────────────────────────
  final entry = ByteData(16);
  entry.setUint8(0, size); // width
  entry.setUint8(1, size); // height
  entry.setUint8(2, 0); // palette
  entry.setUint8(3, 0); // reserved
  entry.setUint16(4, 1, Endian.little); // planes
  entry.setUint16(6, 32, Endian.little); // bpp
  entry.setUint32(8, imageData.length, Endian.little);
  entry.setUint32(12, 22, Endian.little); // offset = 6 + 16

  b.add(dir.buffer.asUint8List());
  b.add(entry.buffer.asUint8List());
  b.add(imageData);

  final out = File('assets/icon/icon.ico');
  out.createSync(recursive: true);
  out.writeAsBytesSync(b.toBytes());
  stdout.writeln('Wrote ${out.path} (${b.toBytes().length} bytes)');
}
