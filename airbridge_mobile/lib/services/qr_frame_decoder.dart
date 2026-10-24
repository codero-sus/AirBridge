import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Decodes one packed RGB888 camera frame, returning null when no QR is found.
String? decodeRgb888QrFrame(
  Uint8List rgb,
  int width,
  int height, {
  int rotationDegrees = 0,
}) {
  if (width <= 0 || height <= 0 || rgb.length < width * height * 3) return null;
  final rotation = (rotationDegrees % 360 + 360) % 360;
  if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) {
    return null;
  }
  try {
    final rotated = rotation == 90 || rotation == 270;
    final outputWidth = rotated ? height : width;
    final outputHeight = rotated ? width : height;
    final pixels = Int32List(outputWidth * outputHeight);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final sourceOffset = (y * width + x) * 3;
        final targetX = switch (rotation) {
          90 => height - 1 - y,
          180 => width - 1 - x,
          270 => y,
          _ => x,
        };
        final targetY = switch (rotation) {
          90 => x,
          180 => height - 1 - y,
          270 => width - 1 - x,
          _ => y,
        };
        pixels[targetY * outputWidth + targetX] =
            (rgb[sourceOffset] << 16) |
                (rgb[sourceOffset + 1] << 8) |
                rgb[sourceOffset + 2];
      }
    }
    final luminance = RGBLuminanceSource(outputWidth, outputHeight, pixels);
    final bitmap = BinaryBitmap(HybridBinarizer(luminance));
    return QRCodeReader().decode(bitmap).text;
  } on Object {
    return null;
  }
}
