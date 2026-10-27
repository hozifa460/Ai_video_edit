class VideoSegment {
  double startSeconds;
  double endSeconds;

  VideoSegment({required this.startSeconds, required this.endSeconds});

  double get durationSeconds => endSeconds - startSeconds;

  VideoSegment copyWith({double? startSeconds, double? endSeconds}) {
    return VideoSegment(
      startSeconds: startSeconds ?? this.startSeconds,
      endSeconds: endSeconds ?? this.endSeconds,
    );
  }
}
