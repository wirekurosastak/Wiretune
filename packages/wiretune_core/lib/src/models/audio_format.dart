// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:path/path.dart' as p;

import '../localization/localizer.dart';
import 'protocol.dart';

/// How good a recording is, as a three-step medal the whole interface colours its quality tags with: [gold] is hi-res
/// (24 bit, or a sample rate above 48 kHz), [silver] is lossless at CD resolution (16 bit), [bronze] is everything that
/// is not lossless (MP3, AAC, Ogg Vorbis, ...). The index order is the quality order, so the lowest tier of a set of
/// tracks is simply the minimum.
enum QualityTier {
  bronze,
  silver,
  gold;

  /// One sentence saying what the tier stands for.
  String get hint => Localizer.get(switch (this) {
    QualityTier.gold => 'QualityGoldHint',
    QualityTier.silver => 'QualitySilverHint',
    QualityTier.bronze => 'QualityBronzeHint',
  });
}

/// The technical description of one recording.
class AudioFormat {
  const AudioFormat({
    this.codec = 'FLAC',
    this.sampleRate = 44100,
    this.bitsPerSample = 16,
    this.channels = 2,
    this.bitrateKbps = 1411,
    this.isLossless = true,
  });

  final String codec;
  final int sampleRate;
  final int bitsPerSample;
  final int channels;
  final int bitrateKbps;
  final bool isLossless;

  bool get isHiRes => isLossless && (sampleRate > 48000 || bitsPerSample > 16);

  /// Gold for hi-res, silver for lossless at CD resolution, bronze for anything that is not lossless.
  QualityTier get tier => isHiRes ? QualityTier.gold : (isLossless ? QualityTier.silver : QualityTier.bronze);

  /// The text that follows the tier word in a quality tag: `FLAC 24bit/96kHz` for lossless files, `MP3 320kbps` for
  /// lossy ones.
  String get tagSpec => !isLossless
      ? '${codec.toUpperCase()} ${bitrateKbps}kbps'
      : '${codec.toUpperCase()} ${bitsPerSample}bit/${_khz(sampleRate)}kHz';

  /// The short tag of lists and covers: `HI-RES`, `CD`, or a lossy file's codec (`MP3`).
  String get badge => switch (tier) {
    QualityTier.gold => 'HI-RES',
    QualityTier.silver => 'CD',
    QualityTier.bronze => codec.toUpperCase(),
  };

  /// The player's tag: the short tag and the format (`HI-RES · FLAC 24bit/96kHz`), or a lossy file's format alone
  /// (`MP3 320kbps`), which starts with its short tag already.
  String get playerTag => isLossless ? '$badge · $tagSpec' : tagSpec;

  /// A sample rate in kHz with at most one decimal: `44.1`, `96`, `2822.4`.
  static String _khz(int sampleRate) {
    final text = (sampleRate / 1000.0).toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  Map<String, Object?> toJson() => {
    'codec': codec,
    'sampleRate': sampleRate,
    'bitsPerSample': bitsPerSample,
    'channels': channels,
    'bitrateKbps': bitrateKbps,
    'isLossless': isLossless,
  };

  static AudioFormat fromJson(Object? json) {
    if (json is! Map) return const AudioFormat();
    return AudioFormat(
      codec: jsonField<String>(json, 'codec') ?? 'FLAC',
      sampleRate: jsonField<num>(json, 'sampleRate')?.toInt() ?? 44100,
      bitsPerSample: jsonField<num>(json, 'bitsPerSample')?.toInt() ?? 16,
      channels: jsonField<num>(json, 'channels')?.toInt() ?? 2,
      bitrateKbps: jsonField<num>(json, 'bitrateKbps')?.toInt() ?? 1411,
      isLossless: jsonField<bool>(json, 'isLossless') ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.codec == codec &&
      other.sampleRate == sampleRate &&
      other.bitsPerSample == bitsPerSample &&
      other.channels == channels &&
      other.bitrateKbps == bitrateKbps &&
      other.isLossless == isLossless;

  @override
  int get hashCode => Object.hash(codec, sampleRate, bitsPerSample, channels, bitrateKbps, isLossless);
}

/// The quality tag of a group of tracks (an album or a playlist): the weakest track's tier.
class QualitySummary {
  const QualitySummary(this.tier, this._lossyCodec);

  /// The lowest tier among the tracks: "every track here is at least this good".
  final QualityTier tier;

  /// The codec of the lossy tracks when they share one, null otherwise.
  final String? _lossyCodec;

  /// The tag: `HI-RES` or `CD`; with a lossy track, the lossy tracks' codec (`MP3`), or the word for lossy when their
  /// codecs differ.
  String get badge => switch (tier) {
    QualityTier.gold => 'HI-RES',
    QualityTier.silver => 'CD',
    QualityTier.bronze => _lossyCodec ?? Localizer.get('QualityLossy'),
  };

  /// Summarises [formats], or returns null when there are none (an empty playlist has no tag).
  static QualitySummary? of(Iterable<AudioFormat> formats) {
    var any = false;
    var lowest = QualityTier.gold;
    String? lossyCodec;
    var lossyMixed = false;
    for (final format in formats) {
      any = true;
      if (format.tier.index < lowest.index) lowest = format.tier;
      if (!format.isLossless) {
        final codec = format.codec.toUpperCase();
        if (lossyCodec == null) {
          lossyCodec = codec;
        } else if (lossyCodec != codec) {
          lossyMixed = true;
        }
      }
    }
    if (!any) return null;
    return QualitySummary(lowest, lossyMixed ? null : lossyCodec);
  }
}

/// Single source of truth for which audio files Wiretune indexes, how they are labelled and which MIME type the server
/// streams them with.
abstract final class AudioFileTypes {
  static const Map<String, (String codec, bool isLossless, String mimeType)> _types = {
    '.flac': ('FLAC', true, 'audio/flac'),
    '.wav': ('WAV', true, 'audio/wav'),
    '.aiff': ('AIFF', true, 'audio/aiff'),
    '.aif': ('AIFF', true, 'audio/aiff'),
    '.wv': ('WAVPACK', true, 'audio/x-wavpack'),
    '.ape': ('APE', true, 'audio/x-ape'),
    '.dsf': ('DSD', true, 'audio/x-dsf'),
    '.m4a': ('AAC', false, 'audio/mp4'),
    '.aac': ('AAC', false, 'audio/aac'),
    '.mp3': ('MP3', false, 'audio/mpeg'),
    '.ogg': ('VORBIS', false, 'audio/ogg'),
    '.opus': ('OPUS', false, 'audio/ogg'),
  };

  static String _extension(String path) => p.extension(path).toLowerCase();

  static bool isSupported(String path) => _types.containsKey(_extension(path));

  static String mimeType(String path) => _types[_extension(path)]?.$3 ?? 'application/octet-stream';

  /// The MIME type a file of [codec] (as [describe] labels it) is streamed with; ALAC is in MP4, as AAC.
  static String mimeTypeOfCodec(String codec) {
    final label = codec.toUpperCase() == 'ALAC' ? 'AAC' : codec.toUpperCase();
    return _types.values.where((type) => type.$1 == label).firstOrNull?.$3 ?? 'application/octet-stream';
  }

  /// Codec label and losslessness for a file. MP4 containers are only known to hold ALAC (lossless) once the stream
  /// description has been read.
  static (String codec, bool isLossless) describe(String path, [String? streamDescription]) {
    final ext = _extension(path);
    if (ext == '.m4a' && (streamDescription?.toLowerCase().contains('alac') ?? false)) return ('ALAC', true);
    final type = _types[ext];
    if (type != null) return (type.$1, type.$2);
    return (ext.startsWith('.') ? ext.substring(1).toUpperCase() : ext.toUpperCase(), false);
  }
}
