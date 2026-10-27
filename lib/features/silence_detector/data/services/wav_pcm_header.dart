import 'dart:typed_data';

import '../../../../core/constants/app_constants.dart';

/// The PCM layout declared by a RIFF/WAVE header.
///
/// The silence-detection WAV is produced by FFmpeg as canonical 44-byte
/// PCM16/mono, but parsing the declared values keeps the analysis honest when a
/// different `-ar`/`-ac` combination reaches it (SR sample-rate mismatch).
class WavPcmHeader {
  /// Declared sample rate in Hz.
  final int sampleRate;

  /// Declared channel count.
  final int channels;

  /// Declared bits per sample.
  final int bitsPerSample;

  /// Offset of the first PCM byte in the file.
  final int dataOffset;

  /// Declared length of the PCM payload in bytes.
  final int dataLength;

  /// RIFF format tag. `1` is integer PCM and `0xFFFE` is WAVE_FORMAT_EXTENSIBLE.
  final int audioFormat;

  const WavPcmHeader({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
    required this.audioFormat,
  });

  int get _bytesPerSample => bitsPerSample ~/ 8;

  /// Bytes occupied by one sample frame across all channels.
  int get blockAlign => channels <= 0 ? 0 : channels * _bytesPerSample;

  /// True when the payload can be read as 16-bit integer PCM.
  bool get isPcm16 =>
      bitsPerSample == 16 &&
      blockAlign > 0 &&
      (audioFormat == 1 || audioFormat == 0xFFFE);

  /// A canonical 44-byte header when the chunk walk found no usable `data`.
  factory WavPcmHeader.canonical(int fileLength) {
    const headerLength = 44;
    final offset = fileLength < headerLength ? fileLength : headerLength;
    return WavPcmHeader(
      sampleRate: AppConstants.audioSampleRate,
      channels: AppConstants.audioChannels,
      bitsPerSample: 16,
      dataOffset: offset,
      dataLength: fileLength > offset ? fileLength - offset : 0,
      audioFormat: 1,
    );
  }
}

/// Reads the sample rate and PCM offset from RIFF/WAVE [bytes].
///
/// The canonical header stores the sample rate at bytes 24..27, little-endian.
/// A chunk walk is used first so a `LIST`/`JUNK` chunk before `data` does not
/// shift the payload; the canonical offset and
/// [AppConstants.audioSampleRate] are the fallback when the header is truncated
/// or malformed. Never throws: analysis must degrade to the documented default
/// rather than fail detection.
WavPcmHeader parseWavPcmHeader(Uint8List bytes) {
  if (bytes.length < 12 ||
      _ascii(bytes, 0, 4) != 'RIFF' ||
      _ascii(bytes, 8, 4) != 'WAVE') {
    return WavPcmHeader.canonical(bytes.length);
  }

  var sampleRate = _readUint32(bytes, 24) ?? AppConstants.audioSampleRate;
  var channels = _readUint16(bytes, 22) ?? AppConstants.audioChannels;
  var bitsPerSample = _readUint16(bytes, 34) ?? 16;
  var audioFormat = _readUint16(bytes, 20) ?? 1;

  int? dataOffset;
  int? dataLength;
  var position = 12;

  while (position + 8 <= bytes.length) {
    final id = _ascii(bytes, position, 4);
    final chunkSize = _readUint32(bytes, position + 4);
    if (chunkSize == null) break;

    final chunkData = position + 8;
    if (id == 'fmt ' && chunkData + 16 <= bytes.length) {
      audioFormat = _readUint16(bytes, chunkData) ?? audioFormat;
      channels = _readUint16(bytes, chunkData + 2) ?? channels;
      sampleRate = _readUint32(bytes, chunkData + 4) ?? sampleRate;
      bitsPerSample = _readUint16(bytes, chunkData + 14) ?? bitsPerSample;
    } else if (id == 'data') {
      dataOffset = chunkData;
      final available = bytes.length - chunkData;
      dataLength = chunkSize <= available ? chunkSize : available;
      break;
    }

    // Chunks are word aligned; a malformed length must stop the walk rather
    // than making the parser read arbitrary bytes as a chunk id.
    final next = chunkData + chunkSize + (chunkSize.isOdd ? 1 : 0);
    if (next <= position || next > bytes.length) break;
    position = next;
  }

  if (dataOffset == null) {
    final fallback = WavPcmHeader.canonical(bytes.length);
    return WavPcmHeader(
      sampleRate: _positiveOr(sampleRate, fallback.sampleRate),
      channels: _positiveOr(channels, fallback.channels),
      bitsPerSample: _positiveOr(bitsPerSample, fallback.bitsPerSample),
      dataOffset: fallback.dataOffset,
      dataLength: fallback.dataLength,
      audioFormat: audioFormat,
    );
  }

  return WavPcmHeader(
    sampleRate: _positiveOr(sampleRate, AppConstants.audioSampleRate),
    channels: _positiveOr(channels, AppConstants.audioChannels),
    bitsPerSample: _positiveOr(bitsPerSample, 16),
    dataOffset: dataOffset,
    dataLength: dataLength ?? 0,
    audioFormat: audioFormat,
  );
}

int _positiveOr(int value, int fallback) => value > 0 ? value : fallback;

int? _readUint16(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return null;
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int? _readUint32(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return null;
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

String _ascii(Uint8List bytes, int offset, int length) {
  if (offset < 0 || offset + length > bytes.length) return '';
  return String.fromCharCodes(bytes, offset, offset + length);
}
