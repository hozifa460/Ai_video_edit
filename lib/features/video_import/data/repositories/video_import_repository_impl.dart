import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/stream_information.dart';
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

      final info = await FFprobeKit.getMediaInformation(path);
      final mediaInfo = info.getMediaInformation();
      if (mediaInfo == null) {
        return AppError(
          const CorruptedFileFailure(
            message: 'Could not read media information',
          ),
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

  static Duration parseFfprobeDuration(String? durationSeconds) {
    final seconds = double.tryParse(durationSeconds ?? '') ?? 0;
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
