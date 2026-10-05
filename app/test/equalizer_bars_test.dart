import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/widgets/equalizer_bars.dart';

/// The bars that mark the current track bounce while it plays, and only then: never while it is paused, and never on a
/// phone or tablet, where every frame costs battery.
void main() {
  Future<void> show(WidgetTester tester, {required bool playing}) => tester.pumpWidget(
    Center(
      child: EqualizerBars(playing: playing, color: const Color(0xFFFFFFFF)),
    ),
  );

  testWidgets('on a desktop they bounce while the track plays, and stand still once it is paused', (tester) async {
    AppPlatform.forTesting(system: 'linux');
    await show(tester, playing: true);
    expect(tester.binding.transientCallbackCount, 1);

    await show(tester, playing: false);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('on a phone they stand still, also while the track plays', (tester) async {
    AppPlatform.forTesting(system: 'android');
    await show(tester, playing: true);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
