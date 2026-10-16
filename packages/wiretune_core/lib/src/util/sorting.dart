// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// Sorts [list] in place, keeping the order of elements that compare equal (Dart's `List.sort` does not promise that;
/// the library's orderings, which sort by one key after another, rely on it).
void sortStable<T>(List<T> list, int Function(T a, T b) compare) {
  if (list.length < 2) return;
  final buffer = List<T>.of(list);
  _mergeSort(buffer, list, 0, list.length, compare);
}

/// Sorts `source[start..end)` into `target[start..end)`; both start with the same contents.
void _mergeSort<T>(List<T> source, List<T> target, int start, int end, int Function(T, T) compare) {
  if (end - start <= 12) {
    for (var i = start + 1; i < end; i++) {
      final value = target[i];
      var j = i - 1;
      while (j >= start && compare(target[j], value) > 0) {
        target[j + 1] = target[j];
        j--;
      }
      target[j + 1] = value;
    }
    return;
  }
  final middle = start + ((end - start) >> 1);
  // Sort both halves into source, then merge them into target.
  _mergeSort(target, source, start, middle, compare);
  _mergeSort(target, source, middle, end, compare);
  var i = start, j = middle, k = start;
  while (i < middle && j < end) {
    target[k++] = compare(source[j], source[i]) < 0 ? source[j++] : source[i++];
  }
  while (i < middle) {
    target[k++] = source[i++];
  }
  while (j < end) {
    target[k++] = source[j++];
  }
}

/// A comparator that applies [comparators] in turn until one of them tells the elements apart.
int Function(T, T) thenBy<T>(List<int Function(T, T)> comparators) => (a, b) {
  for (final compare in comparators) {
    final result = compare(a, b);
    if (result != 0) return result;
  }
  return 0;
};

/// [items] in the order of [compare] (A to Z, the lowest or the oldest first), turned round when [descending]. What
/// [missing] says has no value goes last in either direction. What ties goes in [thenBy]'s order, which is never turned
/// round, or else keeps its place.
List<T> sortedBy<T>(
  Iterable<T> items,
  int Function(T a, T b) compare, {
  bool descending = false,
  bool Function(T item)? missing,
  int Function(T a, T b)? thenBy,
}) {
  final list = List<T>.of(items);
  sortStable(list, (a, b) {
    if (missing != null) {
      final (noA, noB) = (missing(a), missing(b));
      if (noA != noB) return noA ? 1 : -1;
      if (noA) return thenBy?.call(a, b) ?? 0;
    }
    final order = descending ? compare(b, a) : compare(a, b);
    return order != 0 ? order : thenBy?.call(a, b) ?? 0;
  });
  return list;
}
