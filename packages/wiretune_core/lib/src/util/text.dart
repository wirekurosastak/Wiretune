// Text helpers: sorting the way people expect names to sort, folding accents, and small checks.

const Map<String, String> _foldMap = {
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ä': 'a',
  'ã': 'a',
  'å': 'a',
  'ā': 'a',
  'ą': 'a',
  'æ': 'ae',
  'ç': 'c',
  'č': 'c',
  'ć': 'c',
  'ď': 'd',
  'đ': 'd',
  'ð': 'd',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ę': 'e',
  'ě': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ĺ': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ő': 'o',
  'ø': 'o',
  'ō': 'o',
  'œ': 'oe',
  'ř': 'r',
  'ŕ': 'r',
  'š': 's',
  'ś': 's',
  'ş': 's',
  'ß': 'ss',
  'ť': 't',
  'ţ': 't',
  'þ': 'th',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ű': 'u',
  'ū': 'u',
  'ů': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
};

/// The primary sort key of [text], modelled on ICU's root collation: whitespace sorts first, then punctuation and
/// symbols (in ICU's order, with typographic variants such as `…`, `–` or `’` treated as their ASCII counterparts),
/// then digits, then letters, case-insensitively and without accents (`Ábel` sorts with `abel`, not after `zebra`;
/// `…I Care` before `0`). Each character becomes one code unit of the key, so keys compare with [String.compareTo].
String collationKey(String text) {
  final cached = _keyCache[text];
  if (cached != null) return cached;
  if (_keyCache.length >= _keyCacheLimit) _keyCache.clear();

  final key = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    if (rune < 0x80) {
      key.writeCharCode(_asciiWeights[rune]);
      continue;
    }
    final char = String.fromCharCode(rune);
    final folded = _foldMap[char];
    if (folded != null) {
      for (final unit in folded.codeUnits) {
        key.writeCharCode(_asciiWeights[unit]);
      }
      continue;
    }
    final ascii = _punctuationVariants[char];
    if (ascii != null) {
      key.writeCharCode(_asciiWeights[ascii.codeUnitAt(0)]);
    } else if (_whitespace.hasMatch(char)) {
      key.writeCharCode(_weightWhitespace);
    } else if (_letter.hasMatch(char)) {
      // Letters of other scripts after the Latin ones, in code point order (kept below the surrogate range).
      key.writeCharCode(_weightOtherLetters + (rune < 0xC000 ? rune : 0xBFFF));
    } else if (_digit.hasMatch(char)) {
      key.writeCharCode(_weightDigits + 10);
    } else {
      key.writeCharCode(_weightOtherSymbols);
    }
  }
  return _keyCache[text] = key.toString();
}

const int _keyCacheLimit = 50000;
final Map<String, String> _keyCache = {};

const int _weightWhitespace = 0x10;
const int _weightPunctuation = 0x20; // + the position in _punctuationOrder
const int _weightOtherSymbols = 0x70;
const int _weightDigits = 0x100; // + the digit
const int _weightLatin = 0x200; // + the letter
const int _weightOtherLetters = 0x400;

/// ICU's root order of the ASCII punctuation and symbols.
const String _punctuationOrder = r"""_-,;:!?.'"()[]{}@*/\&#%`^+<=>|~$""";

/// The key weight of every ASCII character.
final List<int> _asciiWeights = () {
  final weights = List<int>.filled(128, _weightOtherSymbols);
  for (var c = 0; c < 0x20; c++) {
    weights[c] = _weightWhitespace;
  }
  weights[0x20] = _weightWhitespace;
  for (var i = 0; i < _punctuationOrder.length; i++) {
    weights[_punctuationOrder.codeUnitAt(i)] = _weightPunctuation + i;
  }
  for (var d = 0; d < 10; d++) {
    weights[0x30 + d] = _weightDigits + d;
  }
  for (var l = 0; l < 26; l++) {
    weights[0x61 + l] = _weightLatin + l;
    weights[0x41 + l] = _weightLatin + l;
  }
  return weights;
}();

const Map<String, String> _punctuationVariants = {
  '…': '.',
  '·': '.',
  '–': '-',
  '—': '-',
  '‐': '-',
  '‘': "'",
  '’': "'",
  '‚': "'",
  '´': "'",
  '“': '"',
  '”': '"',
  '„': '"',
  '«': '"',
  '»': '"',
  '¡': '!',
  '¿': '?',
};

final RegExp _whitespace = RegExp(r'\s', unicode: true);
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _digit = RegExp(r'\p{N}', unicode: true);

/// Compares like a culture-aware, case-insensitive comparer: by [collationKey] first, then case-insensitively, then
/// ordinally, so that the order is total and stable.
int compareText(String a, String b) {
  final primary = collationKey(a).compareTo(collationKey(b));
  if (primary != 0) return primary;
  final secondary = a.toLowerCase().compareTo(b.toLowerCase());
  return secondary != 0 ? secondary : a.compareTo(b);
}

/// Case-insensitive equality ("OrdinalIgnoreCase").
bool equalsIgnoreCase(String? a, String? b) {
  if (a == null || b == null) return a == b;
  return a.length == b.length && a.toLowerCase() == b.toLowerCase();
}

/// Case-insensitive containment ("Contains(..., OrdinalIgnoreCase)").
bool containsIgnoreCase(String? text, String part) => text != null && text.toLowerCase().contains(part.toLowerCase());

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{Nd}]', unicode: true);
final RegExp _control = RegExp(r'\p{Cc}', unicode: true);

/// True for a letter or a decimal digit.
bool isLetterOrDigit(String char) => _letterOrDigit.hasMatch(char);

/// True when [text] contains a control character.
bool hasControlCharacters(String text) => _control.hasMatch(text);

/// Keeps only the letters and digits of [text].
String lettersAndDigits(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (isLetterOrDigit(char)) buffer.write(char);
  }
  return buffer.toString();
}

/// Null for null, empty or whitespace-only text, the trimmed text otherwise.
String? cleanText(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// True when [value] is null, empty or whitespace only.
bool isBlank(String? value) => value == null || value.trim().isEmpty;
