// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Random access to a file: the tag readers read only the headers and fields they need instead of whole files.
class ByteSource {
  ByteSource(this._file) : length = _file.lengthSync();

  /// Opens [path] for reading; close it with [close].
  factory ByteSource.open(String path) => ByteSource(File(path).openSync());

  final RandomAccessFile _file;
  final int length;

  /// Up to [count] bytes from [offset]; fewer at the end of the file, none past it.
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= length || count <= 0) return Uint8List(0);
    final available = count > length - offset ? length - offset : count;
    _file.setPositionSync(offset);
    return _file.readSync(available);
  }

  /// Exactly [count] bytes from [offset], or null when the file ends first.
  Uint8List? readExact(int offset, int count) {
    final bytes = read(offset, count);
    return bytes.length == count ? bytes : null;
  }

  void close() {
    try {
      _file.closeSync();
    } catch (_) {}
  }
}

/// Reading numbers and text out of a byte array.
extension ByteReading on Uint8List {
  int u16be(int o) => (this[o] << 8) | this[o + 1];
  int u16le(int o) => this[o] | (this[o + 1] << 8);
  int u24be(int o) => (this[o] << 16) | (this[o + 1] << 8) | this[o + 2];
  int u32be(int o) => (this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3];
  int u32le(int o) => this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24);
  int u64be(int o) => (u32be(o) << 32) | u32be(o + 4);
  int u64le(int o) => u32le(o) | (u32le(o + 4) << 32);

  /// A 28-bit "synchsafe" integer (seven bits per byte), as ID3v2 sizes are written.
  int syncsafe32(int o) =>
      ((this[o] & 0x7F) << 21) | ((this[o + 1] & 0x7F) << 14) | ((this[o + 2] & 0x7F) << 7) | (this[o + 3] & 0x7F);

  /// [count] bytes from [o] as ASCII (Latin-1) text.
  String ascii(int o, int count) => latin1.decode(Uint8List.sublistView(this, o, o + count), allowInvalid: true);

  bool matches(int o, String ascii) {
    if (o + ascii.length > length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (this[o + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }
}

/// Decodes text the way tags store it; never throws.
String decodeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

String decodeLatin1(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);

/// UTF-16 with an optional byte order mark (big-endian without one, unless [littleEndian]).
String decodeUtf16(List<int> bytes, {bool littleEndian = false}) {
  var start = 0;
  var le = littleEndian;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      le = true;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      le = false;
      start = 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// Text with trailing NUL characters and surrounding white space removed.
String trimNul(String text) => text.replaceAll(RegExp('\u0000+\$'), '').trim();
