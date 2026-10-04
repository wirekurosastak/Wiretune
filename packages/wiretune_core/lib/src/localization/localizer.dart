import '../util/event.dart';
import 'strings.dart';

/// A language the user interface is available in.
class LanguageInfo {
  const LanguageInfo(this.code, this.nativeName);

  /// Lower-case ISO 639-1 code; this is what is stored in the settings.
  final String code;

  /// The language's name in that language, shown in the language picker.
  final String nativeName;
}

/// All user-facing text of Wiretune, in every supported language. The single [instance] serves texts to code ([get],
/// [format]) and announces a language change through [languageChanged], so every view can redraw in place.
class Localizer {
  Localizer._();

  static const String hungarian = 'hu';
  static const String english = 'en';
  static const String german = 'de';

  static const List<LanguageInfo> languages = [
    LanguageInfo(hungarian, 'Magyar'),
    LanguageInfo(english, 'English'),
    LanguageInfo(german, 'Deutsch'),
  ];

  static final Localizer instance = Localizer._();

  String _language = english;

  /// Raised after [language] changed; texts formatted earlier have to be formatted again.
  final Event<String> languageChanged = Event<String>();

  /// The active language code (one of [languages]).
  String get language => _language;

  /// Switches the language. Returns false for an unsupported or unchanged language.
  bool setLanguage(String? code) {
    final normalized = normalize(code);
    if (normalized == null || normalized == _language) return false;
    _language = normalized;
    languageChanged.emit(normalized);
    return true;
  }

  /// Maps "de", "de-AT", "HU" ... to a supported code, or null when the language is not supported.
  static String? normalize(String? code) {
    if (code == null || code.trim().isEmpty) return null;
    final two = code.trim().split(RegExp('[-_]')).first.toLowerCase();
    return languages.any((l) => l.code == two) ? two : null;
  }

  /// The text for [key] in the active language. Unknown keys render as `[Key]`.
  static String get(String key) => lookup(key, instance._language);

  /// Formats the text for [key] with [args] (`{0}`, `{1}` ...). When the first argument is the integer 1 and the key
  /// has a `_One` variant, that variant is used ("1 track" instead of "1 tracks").
  static String format(String key, List<Object?> args) {
    final language = instance._language;
    final effectiveKey = args.isNotEmpty && args[0] == 1 && allStrings.containsKey('${key}_One') ? '${key}_One' : key;
    return formatTemplate(lookup(effectiveKey, language), args, language);
  }

  /// "1 h 5 min" for a duration of an hour or more, "4 min 30 s" below that.
  static String formatTotalDuration(Duration duration) => duration.inHours >= 1
      ? format('DurationHoursMinutes', [duration.inHours, duration.inMinutes % 60])
      : format('DurationMinutesSeconds', [duration.inMinutes % 60, duration.inSeconds % 60]);

  static String lookup(String key, String language) {
    final texts = allStrings[key];
    if (texts == null) return '[$key]';
    return switch (language) {
      hungarian => texts.$1,
      german => texts.$3,
      _ => texts.$2,
    };
  }

  static final RegExp _placeholder = RegExp(r'\{(\d+)(?::([^}]*))?\}');

  /// Fills `{n}` and `{n:format}` placeholders like .NET's string.Format: numbers with the language's decimal
  /// separator, dates with a `yyyy MM dd HH mm ss` pattern. A placeholder without an argument stays as it is.
  static String formatTemplate(String template, List<Object?> args, String language) {
    return template.replaceAllMapped(_placeholder, (m) {
      final index = int.parse(m.group(1)!);
      if (index >= args.length) return m.group(0)!;
      return _formatValue(args[index], m.group(2), language);
    });
  }

  static String _formatValue(Object? value, String? pattern, String language) {
    if (value == null) return '';
    if (value is DateTime) {
      final local = value.toLocal();
      final fmt = pattern ?? 'yyyy-MM-dd HH:mm';
      String two(int v) => v.toString().padLeft(2, '0');
      return fmt
          .replaceAll('yyyy', local.year.toString().padLeft(4, '0'))
          .replaceAll('MM', two(local.month))
          .replaceAll('dd', two(local.day))
          .replaceAll('HH', two(local.hour))
          .replaceAll('mm', two(local.minute))
          .replaceAll('ss', two(local.second));
    }
    if (value is double) {
      var text = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
      if (language != english) text = text.replaceAll('.', ',');
      return text;
    }
    return value.toString();
  }

  /// The decimal number [value] with [decimals] places at most (trailing zeros dropped), in the active language's
  /// notation: `44.1` in English, `44,1` in Hungarian and German.
  static String formatNumber(double value, {int decimals = 1}) {
    var text = value.toStringAsFixed(decimals);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    }
    return instance._language == english ? text : text.replaceAll('.', ',');
  }
}
