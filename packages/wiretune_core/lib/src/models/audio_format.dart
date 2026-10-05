import 'package:path/path.dart' as p;

import '../localization/localizer.dart';

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

  /// The text of the tag: just [spec] (`FLAC 24bit/96kHz`); the tier itself is told by the colour of the tag. With
  /// [compact] the file format is left off and the resolution kept (`24bit/96kHz`, `320kbps`). Without a spec the tier
  /// word stands alone rather than leaving an empty pill.
  String tagText(String? spec, {bool compact = false}) {
    if (spec == null || spec.trim().isEmpty) return word;
    final text = spec.trim();
    final space = text.indexOf(' ');
    return compact && space > 0 ? text.substring(space + 1).trim() : text;
  }
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
      : '${codec.toUpperCase()} ${bitsPerSample}bit/${khz(sampleRate)}kHz';

  String get qualityLabel {
    if (!isLossless) return '${codec.toUpperCase()} • $bitrateKbps kbps';
    if (sampleRate >= 192000 && bitsPerSample >= 24) return 'Ultra Hi-Res Studio Master (192kHz/24b)';
    if (sampleRate >= 96000 && bitsPerSample >= 24) return 'Hi-Res Studio Master (96kHz/24b)';
    if (sampleRate >= 88200 && bitsPerSample >= 24) return 'Hi-Res Audio (88.2kHz/24b)';
    if (sampleRate == 48000 && bitsPerSample >= 24) return 'Enhanced Studio (48kHz/24b)';
    if (sampleRate == 44100 && bitsPerSample >= 24) return 'Hi-Res 24-bit Lossless (44.1kHz/24b)';
    if (sampleRate == 44100 && bitsPerSample == 16) return 'CD Quality Lossless (16-bit / 44.1 kHz)';
    return '$bitsPerSample-bit / ${khz(sampleRate)} kHz';
  }

  /// A sample rate in kHz with at most one decimal: `44.1`, `96`, `2822.4`.
  static String khz(int sampleRate) {
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
      codec: json['codec'] as String? ?? 'FLAC',
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 44100,
      bitsPerSample: (json['bitsPerSample'] as num?)?.toInt() ?? 16,
      channels: (json['channels'] as num?)?.toInt() ?? 2,
      bitrateKbps: (json['bitrateKbps'] as num?)?.toInt() ?? 1411,
      isLossless: json['isLossless'] as bool? ?? true,
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

/// The quality tag of a group of tracks (an album or a playlist): the tier the group is shown in and the short text
/// that follows the tier word, for example `FLAC 24bit/96kHz` or `MIXED`.
class QualitySummary {
  const QualitySummary(this.tier, this.spec);

  /// What the tag says when the tracks are in different formats.
  static const String mixedSpec = 'MIXED';

  /// The lowest tier among the tracks: "every track here is at least this good".
  final QualityTier tier;

  /// The format of the tracks when they all share one, [mixedSpec] otherwise.
  final String spec;

  /// Summarises [formats], or returns null when there are none (an empty playlist has no tag). Two lossy files count
  /// as the same format only when their bitrate matches too.
  static QualitySummary? of(Iterable<AudioFormat> formats) {
    AudioFormat? first;
    var lowest = QualityTier.gold;
    var mixed = false;
    for (final format in formats) {
      if (format.tier.index < lowest.index) lowest = format.tier;
      if (first == null) {
        first = format;
      } else if (!_sameSpec(first, format)) {
        mixed = true;
      }
    }
    if (first == null) return null;
    return QualitySummary(lowest, mixed ? mixedSpec : first.tagSpec);
  }

  static bool _sameSpec(AudioFormat a, AudioFormat b) =>
      a.isLossless == b.isLossless &&
      a.codec.toLowerCase() == b.codec.toLowerCase() &&
      a.sampleRate == b.sampleRate &&
      (a.isLossless ? a.bitsPerSample == b.bitsPerSample : a.bitrateKbps == b.bitrateKbps);
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
