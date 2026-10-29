// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The version of the Subsonic API the server answers as.
const String subsonicApiVersion = '1.16.1';

/// Subsonic's error codes.
abstract final class SubsonicError {
  static const int generic = 0;
  static const int missingParameter = 10;
  static const int wrongCredentials = 40;
  static const int tokenNotSupported = 41;
  static const int mechanismNotSupported = 42;
  static const int conflictingMechanisms = 43;
  static const int invalidApiKey = 44;
  static const int notAuthorized = 50;
  static const int notFound = 70;
}

/// An answer that is not "ok": the code and message Subsonic apps show.
class SubsonicFailure implements Exception {
  const SubsonicFailure(this.code, this.message);

  final int code;
  final String message;
}

/// The whole answer of a call as a map: `status`, the version, who answers, and [payload] (the call's result) beside
/// them. A map in this shape is the JSON of the answer (under `subsonic-response`) and, through [subsonicXml], its XML.
Map<String, Object?> subsonicEnvelope([Map<String, Object?> payload = const {}, SubsonicFailure? failure]) => {
  'status': failure == null ? 'ok' : 'failed',
  'version': subsonicApiVersion,
  'type': 'Wiretune',
  'serverVersion': WiretuneInfo.version,
  'openSubsonic': true,
  if (failure != null) 'error': {'code': failure.code, 'message': failure.message},
  ...payload,
};

/// [envelope] as an HTTP answer: JSON when the app asked for `f=json` (or `jsonp`), XML otherwise, as Subsonic does.
Response subsonicResponse(Map<String, Object?> envelope, {required bool json}) {
  if (json) {
    return Response.ok(
      utf8.encode(jsonEncode({'subsonic-response': _withoutNulls(envelope)})),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  return Response.ok(utf8.encode(subsonicXml(envelope)), headers: {'content-type': 'text/xml; charset=utf-8'});
}

/// [value] without the entries that are null, at every depth (an app is told what there is, not what there isn't).
Object? _withoutNulls(Object? value) => switch (value) {
  Map() => {
    for (final MapEntry(:key, :value) in value.entries)
      if (value != null) key: _withoutNulls(value),
  },
  List() => [for (final item in value) _withoutNulls(item)],
  _ => value,
};

/// The XML of an answer. The JSON shape converts by a few rules: a value that is not a list or a map is an attribute,
/// a map is a child element, a list is a child element for each of its items, and `value` is the element's text.
String subsonicXml(Map<String, Object?> envelope) {
  final xml = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n');
  _element(xml, 'subsonic-response', envelope, namespace: 'http://subsonic.org/restapi');
  return xml.toString();
}

void _element(StringBuffer xml, String name, Map<String, Object?> node, {String? namespace}) {
  xml.write('<$name');
  if (namespace != null) xml.write(' xmlns="$namespace"');
  final children = <MapEntry<String, Object?>>[];
  String? text;
  for (final MapEntry(:key, :value) in node.entries) {
    if (value == null) continue;
    if (key == 'value') {
      text = '$value';
    } else if (value is Map || value is List) {
      children.add(MapEntry(key, value));
    } else {
      xml.write(' $key="${_escape('$value')}"');
    }
  }
  if (children.isEmpty && text == null) {
    xml.write('/>');
    return;
  }
  xml.write('>');
  if (text != null) xml.write(_escape(text));
  for (final MapEntry(:key, :value) in children) {
    if (value is List) {
      for (final item in value) {
        if (item is Map<String, Object?>) {
          _element(xml, key, item);
        } else if (item != null) {
          xml.write('<$key>${_escape('$item')}</$key>');
        }
      }
    } else {
      _element(xml, key, value as Map<String, Object?>);
    }
  }
  xml.write('</$name>');
}

final RegExp _notXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

String _escape(String text) => text
    .replaceAll(_notXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
