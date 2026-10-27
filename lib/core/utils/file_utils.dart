import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class FileUtils {
  FileUtils._();

  static const String appDirName = 'Ai_video_editing';

  static Future<Directory> getExportDirectory() async {
    Directory? baseDir;

    if (Platform.isAndroid) {
      // Shared /Download requires WRITE_EXTERNAL_STORAGE granted at runtime
      // on Android 6-9. On newer versions the request may be silently denied
      // (scoped storage) — every failure below then falls back gracefully
      // to app documents instead of crashing the export.
      try {
        await Permission.storage.request();
      } catch (_) {}
      baseDir = Directory('/storage/emulated/0/Download');
    } else {
      baseDir = await getDownloadsDirectory();
    }

    if (baseDir != null && await baseDir.exists()) {
      final dir = Directory('${baseDir.path}/$appDirName');
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        // Verify the directory is actually writable before trusting it.
        final probe = File('${dir.path}/.write_probe');
        await probe.writeAsString('ok');
        await probe.delete();
        return dir;
      } catch (_) {
        // Fall through to app documents.
      }
    }

    try {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String formatDurationMs(int milliseconds) {
    return formatDuration(Duration(milliseconds: milliseconds));
  }

  static String getFileExtension(String path) {
    return path.split('.').last.toLowerCase();
  }

  static bool isVideoFile(String path) {
    const extensions = ['mp4', 'mov', 'mkv', 'avi', 'webm'];
    return extensions.contains(getFileExtension(path));
  }

  static Future<void> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static String getFileName(String path) {
    return path.split(Platform.pathSeparator).last;
  }
}
