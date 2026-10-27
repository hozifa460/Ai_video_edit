import 'dart:io';
import 'package:flutter/services.dart';
import 'logger.dart';

class MediaScanner {
  MediaScanner._();

  static const _channel = MethodChannel('com.example.ai_video_editing/media_scanner');

  static Future<void> scanFile(String filePath) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('scanFile', {'path': filePath});
    } catch (e) {
      AppLogger().e('MediaScanner error', e);
    }
  }
}
