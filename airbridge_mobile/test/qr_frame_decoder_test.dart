import 'dart:typed_data';

import 'package:airbridge_mobile/services/qr_frame_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zxing2/qrcode.dart';

void main() {
  test('decodes a QR from a packed RGB888 camera frame', () {
    const payload = 'airbridge://pair?version=1&key=example';
    final matrix = Encoder.encode(payload, ErrorCorrectionLevel.h).matrix!;
    const scale = 5;
    const quietZone = 4;
    final width = (matrix.width + quietZone * 2) * scale;
    final height = (matrix.height + quietZone * 2) * scale;
    final rgb = Uint8List(width * height * 3)..fillRange(0, width * height * 3, 255);

    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) != 1) continue;
        for (var subY = 0; subY < scale; subY++) {
          for (var subX = 0; subX < scale; subX++) {
            final pixelX = (x + quietZone) * scale + subX;
            final pixelY = (y + quietZone) * scale + subY;
            final offset = (pixelY * width + pixelX) * 3;
            rgb[offset] = 0;
            rgb[offset + 1] = 0;
            rgb[offset + 2] = 0;
          }
        }
      }
    }

    expect(decodeRgb888QrFrame(rgb, width, height), payload);

    final cameraRotated = Uint8List(rgb.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final sourceOffset = (y * width + x) * 3;
        final targetX = y;
        final targetY = width - 1 - x;
        final targetOffset = (targetY * height + targetX) * 3;
        cameraRotated.setRange(
          targetOffset,
          targetOffset + 3,
          rgb,
          sourceOffset,
        );
      }
    }
    expect(
      decodeRgb888QrFrame(
        cameraRotated,
        width,
        height,
        rotationDegrees: 90,
      ),
      payload,
    );
  });

  test('returns null for invalid or undersized frames', () {
    expect(decodeRgb888QrFrame(Uint8List(3), 0, 1), isNull);
    expect(decodeRgb888QrFrame(Uint8List(3), 2, 2), isNull);
    expect(decodeRgb888QrFrame(Uint8List(3), 1, 1), isNull);
    expect(
      decodeRgb888QrFrame(Uint8List(3), 1, 1, rotationDegrees: 45),
      isNull,
    );
  });
}
