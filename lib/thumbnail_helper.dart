import 'dart:typed_data';

import 'thumbnail_helper_stub.dart'
    if (dart.library.html) 'thumbnail_helper_web.dart'
    if (dart.library.io) 'thumbnail_helper_mobile.dart';

Future<Uint8List> generateThumbnail(Uint8List originalBytes) async {
  return createThumbnail(originalBytes);
}
