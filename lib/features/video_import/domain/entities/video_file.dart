import 'package:equatable/equatable.dart';

class VideoFile extends Equatable {
  final String path;
  final String fileName;
  final int fileSize;
  final Duration duration;
  final int width;
  final int height;
  final double fps;
  final String format;
  final bool hasAudio;
  final String? audioPath;

  const VideoFile({
    required this.path,
    required this.fileName,
    required this.fileSize,
    required this.duration,
    required this.width,
    required this.height,
    required this.fps,
    required this.format,
    this.hasAudio = true,
    this.audioPath,
  });

  String get resolution => '${width}x$height';

  @override
  List<Object?> get props => [
        path,
        fileName,
        fileSize,
        duration,
        width,
        height,
        fps,
        format,
        hasAudio,
        audioPath,
      ];
}
