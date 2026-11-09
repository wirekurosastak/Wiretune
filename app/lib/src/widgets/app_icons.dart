// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

/// Play next: the queue's list with its first place taken by ▶, at [size] in [color] (the [IconTheme]'s by default).
/// Material has none in the queue's family (a bulleted list: [Icons.format_list_bulleted_rounded] the queue,
/// [Icons.format_list_bulleted_add] Add to queue); its own is a playlist's (plain lines, as Add to playlist's).
class PlayNextIcon extends StatelessWidget {
  const PlayNextIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    return SizedBox.square(
      dimension: side,
      child: CustomPaint(painter: _PlayNextPainter(color ?? theme.color ?? const Color(0xFF000000))),
    );
  }
}

/// [PlayNextIcon] on Material's 24-point grid, as its rounded bulleted list is drawn: three lines 2 thick with round
/// ends, bullets of 1.5 at the left; the first bullet a ▶ (its line a little shorter, to leave it room).
class _PlayNextPainter extends CustomPainter {
  const _PlayNextPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    void line(double from, double y) =>
        canvas.drawRRect(RRect.fromLTRBR(from, y - 1, 21, y + 1, const Radius.circular(1)), fill);
    line(9, 6);
    line(7, 12);
    line(7, 18);
    canvas.drawCircle(const Offset(4, 12), 1.5, fill);
    canvas.drawCircle(const Offset(4, 18), 1.5, fill);
    // The triangle with softened corners: filled, and its edge stroked round.
    final triangle = Path()
      ..moveTo(2.6, 3.4)
      ..lineTo(6.6, 6)
      ..lineTo(2.6, 8.6)
      ..close();
    canvas.drawPath(triangle, fill);
    canvas.drawPath(
      triangle,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_PlayNextPainter oldDelegate) => oldDelegate.color != color;
}
