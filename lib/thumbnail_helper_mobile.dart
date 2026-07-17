import 'dart:typed_data';
import 'package:image/image.dart' as img;

Future<Uint8List> createThumbnail(Uint8List originalBytes) async {
  try {
    final decodedImage = img.decodeImage(originalBytes);
    if (decodedImage != null) {
      final thumbnail = img.copyResizeCropSquare(decodedImage, size: 200);
      final compressedBytes = img.encodeJpg(thumbnail, quality: 50);
      return Uint8List.fromList(compressedBytes);
    }
  } catch (e) {
    // Không làm gì cả để tránh in log
  }
  return originalBytes;
}
