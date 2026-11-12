// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:path/path.dart' as p;

import '../localization/localizer.dart';
import 'protocol.dart';

/// How good a recording is, as a three-step medal the whole interface uses for its quality tags: [gold] is hi-res
/// (24 bit, or a sample rate above 48 kHz), [silver] is lossless at CD resolution (16 bit), [bronze] is everything that
/// is not lossless (MP3, AAC, Ogg Vorbis, ...). The index order is the quality order, so the lowest tier of a set of
/// tracks is simply the minimum.
enum QualityTier {
  bronze,
  silver,
  gold;

  /// The tier's name as the tag shows it: GOLD, SILVER, BRONZE (ARANY, EZÜST, BRONZ / GOLD, SILBER, BRONZE).
  String get word => Localizer.get(switch (this) {
    QualityTier.gold => 'QualityGold',
    QualityTier.silver => 'QualitySilver',
    QualityTier.bronze => 'QualityBronze',
  });

  /// One sentence saying what the tier stands for.
  String get hint => Localizer.get(switch (this) {
    QualityTier.gold => 'QualityGoldHint',
    QualityTier.silver => 'QualitySilverHint',
    QualityTier.bronze => 'QualityBronzeHint',
  });

  /// The text of the tag: just [spec] (`FLAC 24bit/96kHz`); the tier itself is told by the colour of the tag. Without a
  /// spec the tier word stands alone rather than leaving an empty pill.
  String tagText(String? spec) => spec == null || spec.trim().isEmpty ? word : spec.trim();
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

  /// The tag of a small cover: the format alone (`FLAC`, `MP3`), in every tier; the tag's colour says the
  /// tier, so a hi-res FLAC reads `FLAC` in gold.
  static String compactSpec(QualityTier tier, String spec) {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) return tier == QualityTier.bronze ? 'MP3' : 'FLAC';
    final space = trimmed.indexOf(' ');
    return space > 0 ? trimmed.substring(0, space) : trimmed;
  }

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

/// Orders formats from the weakest to the best: by tier, then by bit depth and sample rate (lossless) or bitrate and
/// sample rate (lossy).
int compareFormatQuality(AudioFormat a, AudioFormat b) {
  final byTier = a.tier.index.compareTo(b.tier.index);
  if (byTier != 0) return byTier;
  final byDepth = a.isLossless && b.isLossless
      ? a.bitsPerSample.compareTo(b.bitsPerSample)
      : a.bitrateKbps.compareTo(b.bitrateKbps);
  return byDepth != 0 ? byDepth : a.sampleRate.compareTo(b.sampleRate);
}

/// The quality tag of an album: what most of its tracks are. The tier most tracks
/// have, and within it the format most tracks have; a tie goes to the weaker one, so the tag never claims more than
/// half the tracks have.
class QualitySummary {
  const QualitySummary(this.format);

  /// The format the tag stands for: one of the tracks'.
  final AudioFormat format;

  QualityTier get tier => format.tier;

  /// The format as the tag says it, for example `FLAC 24bit/96kHz`.
  String get spec => format.tagSpec;

  /// What the tag of a small cover says: the format alone ([AudioFormat.compactSpec]).
  String get compactSpec => AudioFormat.compactSpec(tier, spec);

  /// Summarises [formats], or returns null when there are none (an album always has one).
  static QualitySummary? of(Iterable<AudioFormat> formats) {
    // Weakest first, so that on a tie the weaker one, counted first, wins.
    final sorted = formats.toList()..sort(compareFormatQuality);
    if (sorted.isEmpty) return null;
    final tiers = <QualityTier, int>{};
    for (final format in sorted) {
      tiers[format.tier] = (tiers[format.tier] ?? 0) + 1;
    }
    final tier = _mostCommon(tiers);
    final specs = <String, int>{};
    final formatOf = <String, AudioFormat>{};
    for (final format in sorted.where((f) => f.tier == tier)) {
      specs[format.tagSpec] = (specs[format.tagSpec] ?? 0) + 1;
      formatOf.putIfAbsent(format.tagSpec, () => format);
    }
    return QualitySummary(formatOf[_mostCommon(specs)]!);
  }

  /// The key counted most often; on a tie the first one.
  static K _mostCommon<K>(Map<K, int> counts) {
    MapEntry<K, int>? best;
    for (final entry in counts.entries) {
      if (best == null || entry.value > best.value) best = entry;
    }
    return best!.key;
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
