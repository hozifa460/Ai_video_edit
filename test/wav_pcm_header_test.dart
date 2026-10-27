import 'dart:typed_data';

import 'package:ai_video_editing/core/constants/app_constants.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/wav_pcm_header.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _canonicalWav({
  required int sampleRate,
  required int dataBytes,
  int channels = 1,
}) {
  final bytes = Uint8List(44 + dataBytes);
  final data = ByteData.sublistView(bytes);

  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);
  return bytes;
}

void main() {
  group('parseWavPcmHeader reads the declared sample rate', () {
    test('canonical 44-byte header exposes bytes 24..27', () {
      final header = parseWavPcmHeader(
        _canonicalWav(sampleRate: 44100, dataBytes: 4410),
      );

      expect(header.sampleRate, 44100);
      expect(header.channels, 1);
      expect(header.bitsPerSample, 16);
      expect(header.dataOffset, 44);
      expect(header.dataLength, 4410);
      expect(header.isPcm16, isTrue);
    });

    test('a JUNK chunk before fmt/data does not shift the payload', () {
      final base = _canonicalWav(sampleRate: 48000, dataBytes: 960);
      final junkSize = 7;
      final bytes = Uint8List(base.length + 8 + junkSize + 1);
      final data = ByteData.sublistView(bytes);

      bytes.setRange(0, 12, base);
      var offset = 12;
      void tag(int at, String value) {
        for (var i = 0; i < value.length; i++) {
          bytes[at + i] = value.codeUnitAt(i);
        }
      }

      tag(offset, 'JUNK');
      data.setUint32(offset + 4, junkSize, Endian.little);
      offset += 8 + junkSize + 1; // odd chunk + pad byte

      bytes.setRange(offset, offset + base.length - 12, base, 12);

      final header = parseWavPcmHeader(bytes);
      expect(header.sampleRate, 48000);
      // The data payload now starts after RIFF + JUNK + fmt.
      expect(header.dataOffset, 60);
      expect(header.dataLength, 960);
    });

    test('a malformed header falls back to the application sample rate', () {
      final header = parseWavPcmHeader(Uint8List.fromList([1, 2, 3, 4]));

      expect(header.sampleRate, AppConstants.audioSampleRate);
      expect(header.channels, AppConstants.audioChannels);
      expect(header.bitsPerSample, 16);
    });

    test('a truncated canonical header still reports the declared rate', () {
      final bytes = _canonicalWav(sampleRate: 22050, dataBytes: 0);
      final truncated = Uint8List.sublistView(bytes, 0, 30);

      final header = parseWavPcmHeader(truncated);
      expect(header.sampleRate, 22050);
      expect(header.dataOffset, 30);
      expect(header.dataLength, 0);
    });
  });
}
