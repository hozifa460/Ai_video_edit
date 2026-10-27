import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/media_information.dart';
import 'package:ffmpeg_kit_flutter_new/stream_information.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/video_file.dart';
import '../../domain/repositories/video_import_repository.dart';

class VideoImportRepositoryImpl implements VideoImportRepository {
  @override
  Future<Result<VideoFile>> importVideo() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return AppError(const VideoImportFailure(message: 'No file selected'));
      }

      final path = result.files.single.path;
      if (path == null) {
        return AppError(
          const VideoImportFailure(message: 'Could not access file path'),
        );
      }

      return getVideoMetadata(path);
    } catch (e, stack) {
      AppLogger().e('Failed to import video', e, stack);
      return AppError(VideoImportFailure(message: e.toString()));
    }
  }

  @override
  Future<Result<VideoFile>> getVideoMetadata(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return AppError(
          const CorruptedFileFailure(message: 'File does not exist'),
        );
      }

      final fileSize = await file.length();
      final fileName = path.split(Platform.pathSeparator).last;
      final format = fileName.split('.').last.toLowerCase();

      // FFprobeKit can be null/throw in Release builds when R8 strips its JNI
      // bridge classes. A probe failure must never block importing a file that
      // exists: fall back to the video player, then to bare metadata.
      MediaInformation? mediaInfo;
      try {
        final info = await FFprobeKit.getMediaInformation(path);
        mediaInfo = info.getMediaInformation();
      } catch (e, stack) {
        AppLogger().e('FFprobeKit failed for $path', e, stack);
        mediaInfo = null;
      }

      if (mediaInfo == null) {
        return _fallbackMetadata(
          path: path,
          fileSize: fileSize,
          fileName: fileName,
          format: format,
        );
      }

      final streams = mediaInfo.getStreams();
      StreamInformation? videoStream;
      StreamInformation? audioStream;

      for (final stream in streams) {
        final type = stream.getType();
        if (type == 'video') {
          videoStream = stream;
        } else if (type == 'audio') {
          audioStream = stream;
        }
      }

      final duration = parseFfprobeDuration(mediaInfo.getDuration());
      final width = videoStream?.getWidth() ?? 0;
      final height = videoStream?.getHeight() ?? 0;
      final fpsStr = videoStream?.getRealFrameRate() ?? '30/1';
      final fpsParts = fpsStr.split('/');
      final fps = fpsParts.length == 2
          ? double.tryParse(fpsParts[0]) ?? 30
          : double.tryParse(fpsStr) ?? 30.0;

      return Success(
        VideoFile(
          path: path,
          fileName: fileName,
          fileSize: fileSize,
          duration: duration,
          width: width,
          height: height,
          fps: fps,
          format: format,
          hasAudio: audioStream != null,
        ),
      );
    } catch (e, stack) {
      AppLogger().e('Failed to get video metadata', e, stack);
      return AppError(VideoImportFailure(message: e.toString()));
    }
  }

  /// Release-mode fallback when FFprobe is unavailable (stripped JNI classes).
  ///
  /// Order: video player metadata → bare "file exists" metadata. An existing
  /// video must never be blocked from importing.
  Future<Result<VideoFile>> _fallbackMetadata({
    required String path,
    required int fileSize,
    required String fileName,
    required String format,
  }) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      final value = controller.value;
      return Success(
        VideoFile(
          path: path,
          fileName: fileName,
          fileSize: fileSize,
          duration: value.duration,
          width: value.size.width.toInt(),
          height: value.size.height.toInt(),
          fps: 30.0,
          format: format,
          hasAudio: true,
        ),
      );
    } catch (e, stack) {
      AppLogger().e('Metadata fallback failed for $path', e, stack);
      return Success(
        VideoFile(
          path: path,
          fileName: fileName,
          fileSize: fileSize,
          duration: Duration.zero,
          width: 0,
          height: 0,
          fps: 30.0,
          format: format,
          hasAudio: true,
        ),
      );
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {}
    }
  }

  static Duration parseFfprobeDuration(String? durationSeconds) {
    final seconds = double.tryParse(durationSeconds ?? '') ?? 0;
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
