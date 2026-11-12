// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

AudioFormat _lossless(int sampleRate, int bits, [String codec = 'FLAC']) =>
    AudioFormat(codec: codec, sampleRate: sampleRate, bitsPerSample: bits, isLossless: true);

AudioFormat _lossy(int kbps, [String codec = 'MP3', int sampleRate = 44100]) =>
    AudioFormat(codec: codec, sampleRate: sampleRate, bitsPerSample: 0, bitrateKbps: kbps, isLossless: false);

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  group('lossless is silver at CD resolution and gold above', () {
    for (final (rate, bits, tier) in [
      (44100, 16, QualityTier.silver), // CD quality
      (48000, 16, QualityTier.silver), // 48 kHz is still not above 48 kHz
      (44100, 24, QualityTier.gold),
      (96000, 24, QualityTier.gold),
      (192000, 24, QualityTier.gold),
      (96000, 16, QualityTier.gold), // a sample rate above 48 kHz is hi-res as well
      (2822400, 1, QualityTier.gold), // DSD64
    ]) {
      test('$rate/$bits', () => expect(_lossless(rate, bits).tier, tier));
    }
  });

  test('lossy is always bronze', () {
    expect(_lossy(320).tier, QualityTier.bronze);
    expect(_lossy(256, 'AAC', 48000).tier, QualityTier.bronze);
    expect(_lossy(192, 'OGG', 96000).tier, QualityTier.bronze); // however high its sample rate is
  });

  test('tag spec reads like the tag it belongs to', () {
    expect(_lossless(96000, 24).tagSpec, 'FLAC 24bit/96kHz');
    expect(_lossless(44100, 16).tagSpec, 'FLAC 16bit/44.1kHz');
    expect(_lossless(88200, 24, 'alac').tagSpec, 'ALAC 24bit/88.2kHz');
    expect(_lossy(320).tagSpec, 'MP3 320kbps');
  });

  test('a short tag says the tier, or a lossy file its codec', () {
    expect(_lossless(96000, 24).badge, 'HI-RES');
    expect(_lossless(44100, 16, 'ALAC').badge, 'CD');
    expect(_lossy(320).badge, 'MP3');
    expect(_lossy(256, 'aac').badge, 'AAC');
  });

  test("the player's tag adds the format; a lossy one's format starts with its codec already", () {
    expect(_lossless(96000, 24).playerTag, 'HI-RES · FLAC 24bit/96kHz');
    expect(_lossless(44100, 16).playerTag, 'CD · FLAC 16bit/44.1kHz');
    expect(_lossy(320).playerTag, 'MP3 320kbps');
  });

  test('every tier has a hint', () {
    for (final tier in QualityTier.values) {
      expect(tier.hint.trim(), isNotEmpty);
    }
  });

  test('summaries: the weakest tier, never a word for mixed formats', () {
    expect(QualitySummary.of(const []), isNull);

    final sameTier = QualitySummary.of([_lossless(96000, 24), _lossless(192000, 24)])!;
    expect((sameTier.tier, sameTier.badge), (QualityTier.gold, 'HI-RES'));
    final withCd = QualitySummary.of([_lossless(96000, 24), _lossless(44100, 16)])!;
    expect((withCd.tier, withCd.badge), (QualityTier.silver, 'CD'));
    final withMp3 = QualitySummary.of([_lossless(96000, 24), _lossy(320)])!;
    expect((withMp3.tier, withMp3.badge), (QualityTier.bronze, 'MP3'));
    expect(QualitySummary.of([_lossy(128), _lossy(320)])!.badge, 'MP3');

    // Lossy codecs that differ: the word for lossy, in the interface's language.
    final codecs = QualitySummary.of([_lossy(320), _lossy(256, 'AAC')])!;
    expect(codecs.badge, 'LOSSY');
    Localizer.instance.setLanguage('hu');
    expect(codecs.badge, 'VESZTESÉGES');
  });

  test('albums carry their tier and tags', () async {
    final repo = testRepository();
    final service = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    Track make(String id, String album, AudioFormat format) => Track(
      id: id,
      title: id,
      artist: 'Artist',
      album: album,
      trackNumber: 1,
      filePath: '/music/$album/$id.x',
      format: format,
    );
    repo.replaceAllTracks([
      make('g1', 'Gold album', _lossless(96000, 24)),
      make('g2', 'Gold album', _lossless(96000, 24)),
      make('s1', 'Silver album', _lossless(44100, 16)),
      make('b1', 'Bronze album', _lossy(320)),
      make('m1', 'Mixed album', _lossless(96000, 24)),
      make('m2', 'Mixed album', _lossy(256)),
    ]);
    service.initialize();

    (QualityTier, String) tag(String title) {
      final quality = service.albums.singleWhere((a) => a.title == title).quality;
      return (quality.tier, quality.badge);
    }

    expect(tag('Gold album'), (QualityTier.gold, 'HI-RES'));
    expect(tag('Silver album'), (QualityTier.silver, 'CD'));
    expect(tag('Bronze album'), (QualityTier.bronze, 'MP3'));
    expect(tag('Mixed album'), (QualityTier.bronze, 'MP3'));
  });

  test("a playlist's tag is its tracks', and an empty playlist has none", () {
    final hiRes = qualityOf([
      TestSupport.makeTrack('a', 'A', sampleRate: 96000, bits: 24),
      TestSupport.makeTrack('b', 'B', sampleRate: 96000, bits: 24),
    ])!;
    expect((hiRes.tier, hiRes.badge), (QualityTier.gold, 'HI-RES'));

    final mixed = qualityOf([
      TestSupport.makeTrack('a', 'A', sampleRate: 96000, bits: 24),
      TestSupport.makeTrack('c', 'C', sampleRate: 44100, bits: 16),
    ])!;
    expect((mixed.tier, mixed.badge), (QualityTier.silver, 'CD'));

    expect(qualityOf(const []), isNull);
  });
}
