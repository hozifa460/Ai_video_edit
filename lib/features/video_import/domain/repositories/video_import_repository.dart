import '../../../../core/utils/result.dart';
import '../entities/video_file.dart';

abstract class VideoImportRepository {
  Future<Result<VideoFile>> importVideo();
  Future<Result<VideoFile>> getVideoMetadata(String path);
}
