// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
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

  test('tag text is just the spec; compact keeps only the resolution', () {
    expect(QualityTier.gold.tagText('FLAC 24bit/96kHz'), 'FLAC 24bit/96kHz');
    expect(QualityTier.bronze.tagText('MP3 320kbps'), 'MP3 320kbps');
    expect(QualityTier.gold.tagText('FLAC 24bit/96kHz', compact: true), '24bit/96kHz');
    expect(QualityTier.bronze.tagText('MP3 320kbps', compact: true), '320kbps');
    expect(QualityTier.silver.tagText(QualitySummary.mixedSpec, compact: true), 'MIXED');
  });

  test('without a spec the tag is the tier word', () {
    for (final spec in [null, '', '   ']) {
      expect(QualityTier.gold.tagText(spec), 'GOLD');
      expect(QualityTier.gold.tagText(spec, compact: true), 'GOLD');
    }
  });

  test('every tier has a word and a hint', () {
    expect(QualityTier.gold.word, 'GOLD');
    expect(QualityTier.silver.word, 'SILVER');
    expect(QualityTier.bronze.word, 'BRONZE');
    for (final tier in QualityTier.values) {
      expect(tier.hint, isNot(contains('['))); // an unknown key renders as "[Key]"
      expect(tier.hint.trim(), isNotEmpty);
    }
    Localizer.instance.setLanguage('hu');
    expect(QualityTier.gold.word, 'ARANY');
    Localizer.instance.setLanguage('de');
    expect(QualityTier.silver.word, 'SILBER');
  });

  test('summaries', () {
    expect(QualitySummary.of(const []), isNull);

    final one = QualitySummary.of([_lossless(96000, 24), _lossless(96000, 24)])!;
    expect((one.tier, one.spec), (QualityTier.gold, 'FLAC 24bit/96kHz'));

    final sameTier = QualitySummary.of([_lossless(96000, 24), _lossless(192000, 24)])!;
    expect((sameTier.tier, sameTier.spec), (QualityTier.gold, QualitySummary.mixedSpec));
    expect(QualitySummary.of([_lossless(96000, 24), _lossless(44100, 16)])!.tier, QualityTier.silver);
    expect(QualitySummary.of([_lossless(96000, 24), _lossy(320)])!.tier, QualityTier.bronze);

    expect(QualitySummary.of([_lossy(128), _lossy(320)])!.spec, QualitySummary.mixedSpec);
    expect(QualitySummary.of([_lossy(320), _lossy(320)])!.spec, 'MP3 320kbps');
    expect(QualitySummary.of([_lossless(44100, 16, 'FLAC'), _lossless(44100, 16, 'flac')])!.spec, 'FLAC 16bit/44.1kHz');
  });

  test('albums carry their tier and tag spec', () async {
    final repo = MockRepository();
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
    repo.saveTracks([
      make('g1', 'Gold album', _lossless(96000, 24)),
      make('g2', 'Gold album', _lossless(96000, 24)),
      make('s1', 'Silver album', _lossless(44100, 16)),
      make('b1', 'Bronze album', _lossy(320)),
      make('m1', 'Mixed album', _lossless(96000, 24)),
      make('m2', 'Mixed album', _lossy(256)),
    ]);
    await service.initialize();

    Album find(String title) => service.albums.singleWhere((a) => a.title == title);
    expect((find('Gold album').tier, find('Gold album').tagSpec), (QualityTier.gold, 'FLAC 24bit/96kHz'));
    expect((find('Silver album').tier, find('Silver album').tagSpec), (QualityTier.silver, 'FLAC 16bit/44.1kHz'));
    expect((find('Bronze album').tier, find('Bronze album').tagSpec), (QualityTier.bronze, 'MP3 320kbps'));
    expect((find('Mixed album').tier, find('Mixed album').tagSpec), (QualityTier.bronze, 'MIXED'));
  });

  test('playlist applyQuality sets tier and spec, and an empty playlist has no tag', () {
    final playlist = Playlist(name: 'p');
    playlist.applyQuality([
      TestSupport.makeTrack('a', 'A', sampleRate: 96000, bits: 24),
      TestSupport.makeTrack('b', 'B', sampleRate: 96000, bits: 24),
    ]);
    expect((playlist.formatTier, playlist.formatSpec), (QualityTier.gold, 'FLAC 24bit/96kHz'));

    playlist.applyQuality([
      TestSupport.makeTrack('a', 'A', sampleRate: 96000, bits: 24),
      TestSupport.makeTrack('c', 'C', sampleRate: 44100, bits: 16),
    ]);
    expect((playlist.formatTier, playlist.formatSpec), (QualityTier.silver, 'MIXED'));

    playlist.applyQuality(const []);
    expect(playlist.formatSpec, isEmpty);
  });
}
