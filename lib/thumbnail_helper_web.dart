import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

Future<Uint8List> createThumbnail(Uint8List originalBytes) async {
  final completer = Completer<Uint8List>();
  
  try {
    final blob = html.Blob([originalBytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    
    final image = html.ImageElement();
    image.src = url;
    
    image.onLoad.listen((_) {
      try {
        final canvas = html.CanvasElement();
        final w = image.naturalWidth;
        final h = image.naturalHeight;
        const size = 200;
        canvas.width = size;
        canvas.height = size;
        
        final ctx = canvas.context2D;
        
        int sx = 0, sy = 0, sw = w, sh = h;
        if (w > h) {
          sw = h;
          sx = ((w - h) / 2).toInt();
        } else {
          sh = w;
          sy = ((h - w) / 2).toInt();
        }
        
        ctx.drawImageToRect(
          image,
          destRect: const html.Rectangle(0, 0, size, size),
          sourceRect: html.Rectangle(sx, sy, sw, sh),
        );
        
        final dataUrl = canvas.toDataUrl('image/jpeg', 0.6);
        const header = 'data:image/jpeg;base64,';
        if (dataUrl.startsWith(header)) {
          final base64Str = dataUrl.substring(header.length);
          completer.complete(base64.decode(base64Str));
        } else {
          completer.complete(originalBytes);
        }
      } catch (e) {
        completer.complete(originalBytes);
      } finally {
        html.Url.revokeObjectUrl(url);
      }
    });
    
    image.onError.listen((err) {
      html.Url.revokeObjectUrl(url);
      completer.complete(originalBytes);
    });
  } catch (e) {
    completer.complete(originalBytes);
  }
  
  return completer.future;
}
