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

  test('tag text is the whole spec: format and resolution', () {
    expect(QualityTier.gold.tagText('FLAC 24bit/96kHz'), 'FLAC 24bit/96kHz');
    expect(QualityTier.bronze.tagText('MP3 320kbps'), 'MP3 320kbps');
  });

  test('a compact tag is the format alone in every tier, its colour telling the tier', () {
    expect(AudioFormat.compactSpec(QualityTier.gold, 'FLAC 24bit/96kHz'), 'FLAC');
    expect(AudioFormat.compactSpec(QualityTier.gold, 'ALAC 24bit/192kHz'), 'ALAC');
    expect(AudioFormat.compactSpec(QualityTier.silver, 'FLAC 16bit/44.1kHz'), 'FLAC');
    expect(AudioFormat.compactSpec(QualityTier.silver, 'ALAC 16bit/44.1kHz'), 'ALAC');
    expect(AudioFormat.compactSpec(QualityTier.silver, 'WAV 16bit/44.1kHz'), 'WAV');
    expect(AudioFormat.compactSpec(QualityTier.silver, ''), 'FLAC');
    expect(AudioFormat.compactSpec(QualityTier.bronze, 'MP3 320kbps'), 'MP3');
    expect(AudioFormat.compactSpec(QualityTier.bronze, 'AAC 256kbps'), 'AAC');
    expect(AudioFormat.compactSpec(QualityTier.bronze, 'OGG 192kbps'), 'OGG');
    expect(AudioFormat.compactSpec(QualityTier.bronze, ''), 'MP3');

    // As a list's tag says it: a hi-res FLAC reads FLAC too, in gold.
    expect(QualitySummary.of([_lossless(96000, 24)])!.compactSpec, 'FLAC');
    expect(QualitySummary.of([_lossless(44100, 16)])!.compactSpec, 'FLAC');
    expect(QualitySummary.of([_lossy(320)])!.compactSpec, 'MP3');
  });

  test('without a spec the tag is the tier word', () {
    for (final spec in [null, '', '   ']) {
      expect(QualityTier.gold.tagText(spec), 'GOLD');
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

  test('a summary is what most tracks are: their tier, then their format in it; a tie goes to the weaker', () {
    expect(QualitySummary.of(const []), isNull);
    String tag(List<AudioFormat> formats) {
      final summary = QualitySummary.of(formats)!;
      return '${summary.tier.name} ${summary.spec}';
    }

    final hiRes = _lossless(96000, 24);
    final cd = _lossless(44100, 16);
    expect(tag([hiRes, hiRes]), 'gold FLAC 24bit/96kHz');
    expect(tag([hiRes, hiRes, cd]), 'gold FLAC 24bit/96kHz'); // one bonus CD track doesn't pull an album down
    expect(tag([hiRes, cd, cd]), 'silver FLAC 16bit/44.1kHz');
    expect(tag([hiRes, cd]), 'silver FLAC 16bit/44.1kHz');
    expect(tag([cd, _lossy(320)]), 'bronze MP3 320kbps');

    // The tier first: four hi-res tracks in four formats outnumber three CD ones.
    expect(
      tag([cd, cd, cd, hiRes, _lossless(88200, 24), _lossless(192000, 24), _lossless(48000, 24)]),
      'gold FLAC 24bit/48kHz',
    );
    // Lossy files of every bitrate (VBR): the tier is bronze however their bitrates differ.
    expect(tag([cd, cd, _lossy(245), _lossy(251), _lossy(263)]), 'bronze MP3 245kbps');

    expect(tag([_lossless(192000, 24), hiRes]), 'gold FLAC 24bit/96kHz');
    expect(tag([_lossless(192000, 24), _lossless(192000, 24), hiRes]), 'gold FLAC 24bit/192kHz');
    expect(tag([_lossless(44100, 16, 'FLAC'), _lossless(44100, 16, 'flac')]), 'silver FLAC 16bit/44.1kHz');
  });

  test('albums carry their tier and tag spec', () async {
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
      make('m3', 'Mixed album', _lossless(96000, 24)),
    ]);
    service.initialize();

    (QualityTier, String) tag(String title) {
      final quality = service.albums.singleWhere((a) => a.title == title).quality;
      return (quality.tier, quality.spec);
    }

    expect(tag('Gold album'), (QualityTier.gold, 'FLAC 24bit/96kHz'));
    expect(tag('Silver album'), (QualityTier.silver, 'FLAC 16bit/44.1kHz'));
    expect(tag('Bronze album'), (QualityTier.bronze, 'MP3 320kbps'));
    expect(tag('Mixed album'), (QualityTier.gold, 'FLAC 24bit/96kHz'));
  });
}
