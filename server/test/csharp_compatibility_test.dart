import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

import 'support.dart';

/// A server that moves from the C# version to this one keeps its accounts, passwords, signing key and per-account data.
/// The fixture database was written by the C# server through its own HTTP API (test/fixtures/csharp-server.json says
/// what it holds).
void main() {
  final fixture = jsonDecode(File('test/fixtures/csharp-server.json').readAsStringSync()) as Map<String, dynamic>;
  late Directory root;
  late WiretuneServer server;
  late String baseUrl;

  setUp(() async {
    WiretuneLog.writeToConsole = false;
    root = Directory.systemTemp.createTempSync('wiretune_csharp_');
    final data = Directory(p.join(root.path, 'data', 'Server'))..createSync(recursive: true);
    File('test/fixtures/csharp-server.db').copySync(p.join(data.path, 'wiretune-server.db'));
    Directory(p.join(root.path, 'music')).createSync();
    server = await WiretuneServer.start(
      ServerOptions(
        libraryPath: p.join(root.path, 'music'),
        dataDirectory: data.path,
        scanIntervalMinutes: 0,
        urls: 'http://127.0.0.1:0',
      ),
    );
    baseUrl = 'http://127.0.0.1:${server.port}';
  });
  tearDown(() async {
    await server.close();
    root.deleteSync(recursive: true);
  });

  test('the accounts and their bcrypt passwords still work', () async {
    final client = Api(baseUrl);
    expect(json(await client.get('/api/auth/setup-required'))['setupRequired'], isFalse);

    final owner = await client.post('/api/auth/login', {'username': 'owner', 'password': fixture['ownerPassword']});
    expect(owner.statusCode, 200);
    final auth = AuthResponse.fromJson(json(owner));
    expect(auth.user.id, fixture['ownerId']);
    expect(auth.user.isAdmin, isTrue);

    final guest = await client.post('/api/auth/login', {'username': 'GUEST', 'password': fixture['guestPassword']});
    expect(guest.statusCode, 200);
    expect((await client.post('/api/auth/login', {'username': 'owner', 'password': 'wrong-password'})).statusCode, 401);
  });

  test("the account's favourites, play counts and playlists are there", () async {
    final (client, _) = await login(_FixtureServer(baseUrl), 'owner', fixture['ownerPassword'] as String);
    final data = UserDataSnapshot.fromJson(json(await client.get('/api/me/data')));
    expect(data.favorites, [fixture['trackId']]);
    expect(data.plays.single.trackId, fixture['trackId']);
    expect(data.plays.single.playCount, 1);
    expect(data.playlists.single.name, 'Road trip');
    expect(data.playlists.single.description, 'for the car');
    expect(data.playlists.single.trackIds, [fixture['trackId']]);
  });

  test('tokens the C# server signed are valid here (same key, same claims)', () {
    final db = sqlite3.open(p.join(root.path, 'data', 'Server', 'wiretune-server.db'));
    addTearDown(db.close);
    final secret = db.select("SELECT value FROM settings WHERE key = 'jwt_secret'").first['value'] as String;
    final jwt = Jwt(secret);
    final issuedAt = DateTime.fromMillisecondsSinceEpoch((fixture['issuedAtUnix'] as int) * 1000, isUtc: true);

    final claims = jwt.verify(
      fixture['token'] as String,
      issuer: AuthService.issuer,
      audiences: {AuthService.audience},
      now: issuedAt,
    )!;
    expect(claims[AuthService.nameIdClaim], fixture['ownerId']);
    expect(claims[AuthService.nameClaim], 'owner');
    expect(claims[AuthService.roleClaim], 'admin');

    final stream = jwt.verify(
      fixture['streamToken'] as String,
      issuer: AuthService.issuer,
      audiences: {AuthService.streamAudience},
      now: issuedAt,
    )!;
    expect(stream[AuthService.scopeClaim], AuthService.streamScope);
    expect(stream[AuthService.roleClaim], 'user');
  });

  test('a token the C# server signed is accepted by the API while it is valid', () async {
    // The fixture's token was issued for 90 days; past that only the signature test above can check it.
    final issuedAt = DateTime.fromMillisecondsSinceEpoch((fixture['issuedAtUnix'] as int) * 1000, isUtc: true);
    if (DateTime.now().toUtc().difference(issuedAt) > const Duration(days: 89)) {
      markTestSkipped('The fixture token has expired.');
      return;
    }
    final client = Api(baseUrl, fixture['token'] as String);
    final me = UserInfo.fromJson(json(await client.get('/api/auth/me')));
    expect(me.username, 'owner');
    expect((await client.get('/api/users')).statusCode, 200); // the admin role is read from the C# claim
  });
}

/// Lets the shared helpers sign in against a server that was not started by a [ServerFixture].
class _FixtureServer implements ServerFixture {
  _FixtureServer(this.baseUrl);

  @override
  final String baseUrl;

  @override
  Api client([String? token]) => Api(baseUrl, token);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
