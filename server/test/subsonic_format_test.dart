// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:test/test.dart';
import 'package:wiretune_server/src/subsonic/subsonic_format.dart';

/// The same answer as JSON and as XML.
void main() {
  group('the XML of an answer', () {
    String xml(Map<String, Object?> payload) => subsonicXml(subsonicEnvelope(payload));

    test('has the envelope as attributes of the root element', () {
      expect(
        xml({}),
        allOf(
          startsWith('<?xml version="1.0" encoding="UTF-8"?>\n<subsonic-response xmlns="http://subsonic.org/restapi" '),
          contains('status="ok"'),
          contains('version="$subsonicApiVersion"'),
          contains('openSubsonic="true"'),
          endsWith('/>'),
        ),
      );
    });

    test('turns values into attributes, maps into elements and lists into repeated elements', () {
      final text = xml({
        'artists': {
          'ignoredArticles': '',
          'index': [
            {
              'name': 'A',
              'artist': [
                {'id': '1', 'name': 'Alice', 'albumCount': 2},
                {'id': '2', 'name': 'Adam', 'albumCount': 0, 'starred': null},
              ],
            },
          ],
        },
      });
      expect(
        text,
        contains(
          '<artists ignoredArticles=""><index name="A">'
          '<artist id="1" name="Alice" albumCount="2"/><artist id="2" name="Adam" albumCount="0"/>'
          '</index></artists>',
        ),
      );
    });

    test('writes `value` as the text of the element, and booleans as words', () {
      expect(
        xml({
          'genres': {
            'genre': [
              {'value': 'Rock', 'songCount': 3, 'albumCount': 1},
            ],
          },
          'song': {'isDir': false},
        }),
        contains('<genre songCount="3" albumCount="1">Rock</genre>'),
      );
      expect(
        xml({
          'song': {'isDir': false},
        }),
        contains('<song isDir="false"/>'),
      );
    });

    test('escapes what XML reserves, and drops what it forbids', () {
      final text = xml({
        'song': {'title': 'Tom & "Jerry" <live> it\'s\u0001 here'},
      });
      expect(text, contains('title="Tom &amp; &quot;Jerry&quot; &lt;live&gt; it&apos;s here"'));
    });

    test('writes a failure with its code and message', () {
      final text = subsonicXml(subsonicEnvelope(const {}, const SubsonicFailure(40, 'Wrong username or password.')));
      expect(text, contains('status="failed"'));
      expect(text, contains('<error code="40" message="Wrong username or password."/>'));
    });
  });

  group('the JSON of an answer', () {
    test('is under subsonic-response, without the entries that are null', () async {
      final response = subsonicResponse(
        subsonicEnvelope({
          'album': {
            'id': '1',
            'coverArt': null,
            'song': [
              {'id': 's', 'bpm': null, 'artists': <Object?>[]},
            ],
          },
        }),
        json: true,
      );
      expect(response.headers['content-type'], 'application/json; charset=utf-8');
      final body = jsonDecode(await response.readAsString())['subsonic-response'] as Map<String, dynamic>;
      expect(body['status'], 'ok');
      expect(body['album'], {
        'id': '1',
        'song': [
          {'id': 's', 'artists': <Object?>[]},
        ],
      });
    });
  });
}
