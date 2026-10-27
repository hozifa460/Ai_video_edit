import 'package:equatable/equatable.dart';

abstract class Failure extends Equatable {
  final String message;
  final String? code;

  const Failure({required this.message, this.code});

  @override
  List<Object?> get props => [message, code];
}

class VideoImportFailure extends Failure {
  const VideoImportFailure({super.message = 'Failed to import video', super.code});
}

class AudioExtractionFailure extends Failure {
  const AudioExtractionFailure({super.message = 'Failed to extract audio', super.code});
}

class SilenceDetectionFailure extends Failure {
  const SilenceDetectionFailure({super.message = 'Failed to detect silence', super.code});
}

class VideoProcessingFailure extends Failure {
  const VideoProcessingFailure({super.message = 'Failed to process video', super.code});
}

class ExportFailure extends Failure {
  const ExportFailure({super.message = 'Failed to export video', super.code});
}

class PermissionFailure extends Failure {
  const PermissionFailure({super.message = 'Permission denied', super.code});
}

class StorageFailure extends Failure {
  const StorageFailure({super.message = 'Storage is full or unavailable', super.code});
}

class CorruptedFileFailure extends Failure {
  const CorruptedFileFailure({super.message = 'File is corrupted or unsupported', super.code});
}

class NoAudioTrackFailure extends Failure {
  const NoAudioTrackFailure({super.message = 'Video has no audio track', super.code});
}

class EnhancementFailure extends Failure {
  const EnhancementFailure({super.message = 'Failed to enhance video', super.code});
}

