import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/logger.dart';

class _FaceTrack {
  final List<Rect> boxes = [];
  final List<Point<double>> mouthCenters = [];

  double get avgMouthMovement {
    if (mouthCenters.length < 2) return 0;
    double total = 0;
    for (var i = 1; i < mouthCenters.length; i++) {
      final dx = mouthCenters[i].x - mouthCenters[i - 1].x;
      final dy = mouthCenters[i].y - mouthCenters[i - 1].y;
      total += sqrt(dx * dx + dy * dy);
    }
    return total / (mouthCenters.length - 1);
  }

  double get avgCenterPixelX {
    if (boxes.isEmpty) return double.nan;
    return boxes.map((b) => b.center.dx).reduce((a, b) => a + b) / boxes.length;
  }
}

class FaceDetectionService {
  /// Returns the raw pixel X of the speaker's face center for the entire clip.
  static Future<double?> detectFaceCenterX(
    String videoPath,
    double startSec,
    double endSec, {
    int sampleCount = 6,
  }) async {
    if (endSec - startSec < 1) sampleCount = 3;

    final tempDir = await getApplicationDocumentsDirectory();

    final allFrameFaces = <List<({Rect box, Point<double> mouth})>>[];

    for (var i = 0; i < sampleCount; i++) {
      final t = startSec + (endSec - startSec) * (i / max(sampleCount - 1, 1));
      final baseName = 'spk_${t.toStringAsFixed(1).replaceAll('.', '_')}.jpg';
      final framePath = '${tempDir.path}/$baseName';

      final cmd = '-ss ${t.toStringAsFixed(3)} -i "$videoPath" -vframes 1 -q:v 2 -y "$framePath"';
      final session = await FFmpegKit.execute(cmd);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) continue;

      final file = File(framePath);
      if (!await file.exists()) continue;

      final inputImage = InputImage.fromFilePath(framePath);
      final detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: false,
          enableLandmarks: true,
          enableContours: false,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
      final faces = await detector.processImage(inputImage);
      detector.close();

      if (faces.isNotEmpty) {
        final frameFaces = <({Rect box, Point<double> mouth})>[];
        for (final f in faces) {
          final mouth = _mouthCenter(f);
          frameFaces.add((box: f.boundingBox, mouth: mouth));
        }
        allFrameFaces.add(frameFaces);
      }

      await file.delete();
    }

    if (allFrameFaces.every((f) => f.isEmpty)) {
      AppLogger().i('FaceDetection: no faces in $sampleCount frames');
      return null;
    }

    final tracks = _buildTracks(allFrameFaces);
    if (tracks.isEmpty) return null;

    tracks.sort((a, b) => b.avgMouthMovement.compareTo(a.avgMouthMovement));
    final speaker = tracks.first;
    final mostPersistent = tracks
        .reduce((a, b) => (a.boxes.length > b.boxes.length) ? a : b);

    final selected =
        (speaker.avgMouthMovement > 3 && speaker.boxes.length >= 2)
            ? speaker
            : mostPersistent;

    final pixelX = selected.avgCenterPixelX;
    AppLogger().i(
        'FaceDetection: ${tracks.length} track(s), '
        'mouthMove=${speaker.avgMouthMovement.toStringAsFixed(1)} '
        'fallback=${identical(selected, mostPersistent)} centerX=$pixelX');
    return pixelX;
  }

  /// Samples frames every ~1 second across the clip, detects ALL faces,
  /// tracks them, and for each sample picks the speaker (highest recent
  /// mouth movement). Returns a list of raw pixel X positions — one per
  /// second of clip duration — for smooth per-frame camera animation.
  static Future<List<double>?> detectFacePath(
    String videoPath,
    double startSec,
    double endSec,
  ) async {
    final clipDur = endSec - startSec;
    if (clipDur < 1) return null;

    final sampleCount = clipDur.round().clamp(3, 120);

    final tempDir = await getApplicationDocumentsDirectory();

    final allFrameFaces = <List<({Rect box, Point<double> mouth})>>[];

    for (var i = 0; i < sampleCount; i++) {
      final t = startSec + clipDur * (i / max(sampleCount - 1, 1));
      final baseName = 'path_${t.toStringAsFixed(1).replaceAll('.', '_')}.jpg';
      final framePath = '${tempDir.path}/$baseName';

      final cmd = '-ss ${t.toStringAsFixed(3)} -i "$videoPath" -vframes 1 -q:v 2 -y "$framePath"';
      final session = await FFmpegKit.execute(cmd);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) continue;

      final file = File(framePath);
      if (!await file.exists()) continue;

      final inputImage = InputImage.fromFilePath(framePath);
      final detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: false,
          enableLandmarks: true,
          enableContours: false,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
      final faces = await detector.processImage(inputImage);
      detector.close();

      if (faces.isNotEmpty) {
        final frameFaces = <({Rect box, Point<double> mouth})>[];
        for (final f in faces) {
          final mouth = _mouthCenter(f);
          frameFaces.add((box: f.boundingBox, mouth: mouth));
        }
        allFrameFaces.add(frameFaces);
      }

      await file.delete();
    }

    if (allFrameFaces.every((f) => f.isEmpty)) {
      AppLogger().i('FacePath: no faces in $sampleCount frames');
      return null;
    }

    final tracks = _buildTracks(allFrameFaces);
    if (tracks.isEmpty) return null;

    AppLogger().i('FacePath: ${tracks.length} tracks, $sampleCount samples');

    final path = <double>[];
    for (var i = 0; i < allFrameFaces.length; i++) {
      final frameFaces = allFrameFaces[i];
      if (frameFaces.isEmpty) {
        path.add(path.isNotEmpty ? path.last : 0.5);
        continue;
      }

      final startWin = max(0, i - 1);
      final endWin = min(allFrameFaces.length - 1, i + 1);

      _FaceTrack? bestTrack;
      double bestMovement = -1;

      for (final track in tracks) {
        if (track.boxes.length <= i) continue;
        final winStart = max(0, i - startWin);
        final winEnd = min(track.mouthCenters.length - 1, i + endWin - startWin);
        if (winEnd <= winStart) continue;

        double localMovement = 0;
        int count = 0;
        for (var j = winStart; j < winEnd; j++) {
          final dx = track.mouthCenters[j + 1].x - track.mouthCenters[j].x;
          final dy = track.mouthCenters[j + 1].y - track.mouthCenters[j].y;
          localMovement += sqrt(dx * dx + dy * dy);
          count++;
        }
        localMovement = count > 0 ? localMovement / count : 0;

        if (localMovement > bestMovement) {
          bestMovement = localMovement;
          bestTrack = track;
        }
      }

      double pixelX;
      if (bestTrack != null && bestMovement > 3 && bestTrack.boxes.length > i) {
        pixelX = bestTrack.boxes[i].center.dx;
      } else {
        final persistent = tracks
            .reduce((a, b) => (a.boxes.length > b.boxes.length) ? a : b);
        pixelX = persistent.boxes.length > i
            ? persistent.boxes[i].center.dx
            : persistent.boxes.last.center.dx;
      }
      path.add(pixelX.clamp(0.0, 5000.0));
    }

    AppLogger().i('FacePath: path has ${path.length} points');
    return path;
  }

  static List<_FaceTrack> _buildTracks(
      List<List<({Rect box, Point<double> mouth})>> allFrameFaces) {
    final tracks = <_FaceTrack>[];

    for (final frameFaces in allFrameFaces) {
      for (final ff in frameFaces) {
        _FaceTrack? bestTrack;
        double bestDist = double.infinity;

        for (final track in tracks) {
          if (track.boxes.isEmpty) continue;
          final last = track.boxes.last.center;
          final refW = ff.box.width > 0 ? ff.box.width : 100;
          final dx = (ff.box.center.dx - last.dx).abs() / refW;
          if (dx < 0.25 && dx < bestDist) {
            bestDist = dx;
            bestTrack = track;
          }
        }

        if (bestTrack != null) {
          bestTrack.boxes.add(ff.box);
          bestTrack.mouthCenters.add(ff.mouth);
        } else {
          final t = _FaceTrack();
          t.boxes.add(ff.box);
          t.mouthCenters.add(ff.mouth);
          tracks.add(t);
        }
      }
    }

    return tracks;
  }

  static Point<double> _mouthCenter(Face face) {
    double mx = 0, my = 0;
    int count = 0;

    void add(FaceLandmark? lm) {
      if (lm != null) {
        mx += lm.position.x;
        my += lm.position.y;
        count++;
      }
    }

    add(face.landmarks[FaceLandmarkType.bottomMouth]);
    add(face.landmarks[FaceLandmarkType.leftMouth]);
    add(face.landmarks[FaceLandmarkType.rightMouth]);

    if (count == 0) {
      mx = face.boundingBox.center.dx;
      my = face.boundingBox.center.dy + face.boundingBox.height * 0.15;
      count = 1;
    }

    return Point<double>(mx / count, my / count);
  }
}
