import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Sorting by name, as the C# player's culture-aware comparer (ICU) sorted.
void main() {
  List<String> sorted(List<String> names) => [...names]..sort(compareText);

  test('punctuation sorts before digits, digits before letters, as the C# player showed them', () {
    expect(
      sorted([
        'Acoustic Live',
        '808',
        '5 Years of Great Stuff',
        '0',
        '#SzuperCsillagParaszt',
        '…I Care Because You Do',
      ]),
      ['…I Care Because You Do', '#SzuperCsillagParaszt', '0', '5 Years of Great Stuff', '808', 'Acoustic Live'],
    );
  });

  test('case and accents do not change the order of letters', () {
    expect(sorted(['zebra', 'Ábel', 'abel', 'Émile', 'eve']), ['abel', 'Ábel', 'Émile', 'eve', 'zebra']);
  });

  test('typographic punctuation sorts with its ASCII counterpart', () {
    expect(compareText('…a', 'a') < 0, isTrue);
    expect(compareText('‘Round Midnight', 'Round') < 0, isTrue);
  });

  test('a space sorts before any letter, so a shorter word comes first', () {
    expect(sorted(['ab', 'a b', 'a']), ['a', 'a b', 'ab']);
  });

  test('other scripts sort after Latin letters', () {
    expect(sorted(['Кино', 'Zappa', 'ABBA']), ['ABBA', 'Zappa', 'Кино']);
  });
}
