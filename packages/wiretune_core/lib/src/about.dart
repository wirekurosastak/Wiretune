// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// What Wiretune says about itself: its version, its copyright and where its source is (NOTICE.md).
abstract final class WiretuneInfo {
  /// The version of every part of Wiretune. A pubspec.yaml writes it the way semantic versioning allows, `1.0.2026+1`:
  /// the version name and the build number.
  static const String version = '1.0.2026.1';

  static const String copyright = 'Copyright (C) 2026 Wiretune contributors';

  static const String sourceUrl = 'https://github.com/wirekurosastak/Wiretune';

  /// The SPDX identifier of the license; NOTICE.md adds the terms its section 7 allows.
  static const String license = 'AGPL-3.0-only';

  /// How Wiretune introduces itself to the services it asks (LRCLIB, Deezer).
  static const String userAgent = 'Wiretune/$version (+$sourceUrl)';
}
