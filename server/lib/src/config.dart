import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wiretune_core/wiretune_core.dart';

/// Where the server listens.
class ListenAddress {
  const ListenAddress(this.host, this.port);

  final String host;
  final int port;

  /// The address to bind: `0.0.0.0`, `::`, `127.0.0.1`, a host name, or `*`/`+` for every interface.
  InternetAddress? get bindAddress => switch (host) {
    '*' || '+' || '0.0.0.0' => InternetAddress.anyIPv4,
    '::' || '[::]' => InternetAddress.anyIPv6,
    'localhost' => InternetAddress.loopbackIPv4,
    _ => InternetAddress.tryParse(host.replaceAll('[', '').replaceAll(']', '')),
  };

  @override
  String toString() => 'http://${host.contains(':') && !host.startsWith('[') ? '[$host]' : host}:$port';
}

/// The server's settings. They are read, in rising precedence, from `appsettings.json` (section `Wiretune`),
/// environment variables (`Wiretune__Port=8080`) and the command line (`--Wiretune:Port=8080`), as the C# server did.
class ServerOptions {
  ServerOptions({
    this.libraryPath,
    this.dataDirectory,
    this.port = 5200,
    this.setupCode,
    this.scanIntervalMinutes = 30,
    this.urls,
    this.forwardedHeaders = false,
    String? contentRoot,
  }) : contentRoot = contentRoot ?? Directory.current.path;

  /// Music library root. A relative path is resolved against [contentRoot].
  String? libraryPath;

  /// Where the server keeps its database, cover cache and log. Default: `<app data>/Wiretune/Server`.
  String? dataDirectory;

  int port;

  /// Code the first administrator must enter. Blank: the server makes a random one and prints it in its log at every
  /// start for as long as no account exists.
  String? setupCode;

  /// Periodic incremental rescan interval; 0 disables periodic rescans (start-up and requested scans still run).
  int scanIntervalMinutes;

  /// Listen addresses (`http://0.0.0.0:5200;http://[::]:5200`); null listens on every IPv4 interface at [port].
  String? urls;

  /// Trust `X-Forwarded-For` / `X-Forwarded-Proto` (behind a reverse proxy only).
  bool forwardedHeaders;

  /// The folder relative paths are resolved against: the working directory.
  final String contentRoot;

  /// The addresses to listen on.
  List<ListenAddress> get listenAddresses {
    final spec = urls?.trim();
    if (spec == null || spec.isEmpty) return [ListenAddress('0.0.0.0', port)];
    final addresses = <ListenAddress>[];
    for (final part in spec.split(RegExp('[;,]'))) {
      final text = part.trim();
      if (text.isEmpty) continue;
      if (text.toLowerCase().startsWith('https://')) {
        throw FormatException(
          'HTTPS is not supported by the server itself ("$text"); put a reverse proxy in front of it.',
        );
      }
      final match = RegExp(r'^(?:http://)?(\[[^\]]+\]|[^:/]+)(?::(\d+))?/?$', caseSensitive: false).firstMatch(text);
      if (match == null) throw FormatException('Not a listen address: "$text".');
      addresses.add(ListenAddress(match.group(1)!, int.tryParse(match.group(2) ?? '') ?? 80));
    }
    return addresses;
  }

  /// Reads the settings from [args], the environment and `appsettings.json` (in the working directory, else next to the
  /// executable).
  static ServerOptions load(List<String> args, {Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final values = <String, String>{};

    // 1. appsettings.json
    for (final candidate in [
      p.join(Directory.current.path, 'appsettings.json'),
      p.join(p.dirname(Platform.resolvedExecutable), 'appsettings.json'),
      p.join(p.dirname(p.fromUri(Platform.script)), '..', 'appsettings.json'),
    ]) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      try {
        final json = jsonDecode(file.readAsStringSync());
        if (json is Map) {
          final section = json.entries.where((e) => '${e.key}'.toLowerCase() == 'wiretune').firstOrNull?.value;
          if (section is Map) {
            section.forEach((key, value) {
              if (value != null) values['$key'.toLowerCase()] = '$value';
            });
          }
          final topUrls = json.entries.where((e) => '${e.key}'.toLowerCase() == 'urls').firstOrNull?.value;
          if (topUrls is String) values['urls'] = topUrls;
        }
      } catch (e) {
        stderr.writeln("Ignoring unreadable settings file '$candidate': $e");
      }
      break;
    }

    // 2. Environment variables.
    env.forEach((name, value) {
      final lower = name.toLowerCase();
      if (lower.startsWith('wiretune__')) values[lower.substring('wiretune__'.length)] = value;
    });
    final envUrls = env['WIRETUNE_URLS'] ?? env['ASPNETCORE_URLS'];
    if (envUrls != null && envUrls.isNotEmpty) values['urls'] = envUrls;
    final forwarded = env['WIRETUNE_FORWARDED_HEADERS'] ?? env['ASPNETCORE_FORWARDEDHEADERS_ENABLED'];
    if (forwarded != null) values['forwardedheaders'] = forwarded;

    // 3. Command line: --Wiretune:Key=Value, --Wiretune:Key Value, --urls=...
    for (var i = 0; i < args.length; i++) {
      var arg = args[i];
      if (!arg.startsWith('--') && !arg.startsWith('/')) continue;
      arg = arg.replaceFirst(RegExp(r'^(--|/)'), '');
      String key, value;
      final equals = arg.indexOf('=');
      if (equals >= 0) {
        key = arg.substring(0, equals);
        value = arg.substring(equals + 1);
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        key = arg;
        value = args[++i];
      } else {
        continue;
      }
      final lower = key.toLowerCase();
      if (lower.startsWith('wiretune:')) {
        values[lower.substring('wiretune:'.length)] = value;
      } else if (lower == 'urls') {
        values['urls'] = value;
      }
    }

    String? text(String key) => values[key]?.trim().isEmpty ?? true ? null : values[key]!.trim();
    int number(String key, int fallback) {
      final raw = values[key];
      if (raw == null || raw.trim().isEmpty) return fallback;
      final parsed = int.tryParse(raw.trim());
      if (parsed == null) throw FormatException("Wiretune:$key must be a whole number, not '$raw'.");
      return parsed;
    }

    return ServerOptions(
      libraryPath: text('librarypath'),
      dataDirectory: text('datadirectory'),
      port: number('port', 5200),
      setupCode: text('setupcode'),
      scanIntervalMinutes: number('scanintervalminutes', 30),
      urls: text('urls'),
      forwardedHeaders: values['forwardedheaders']?.trim().toLowerCase() == 'true',
    );
  }

  /// The library folder: [libraryPath] (relative to [contentRoot]) when it exists, otherwise the user's music folder.
  String resolveLibraryRoot() {
    final configured = libraryPath;
    if (configured != null && configured.trim().isNotEmpty) {
      final resolved = AppPaths.fullPath(p.isAbsolute(configured) ? configured : p.join(contentRoot, configured));
      if (Directory(resolved).existsSync()) return resolved;
      WiretuneLog.warn('Server', "Configured library path '$resolved' does not exist.");
    }

    final musicDir = AppPaths.musicFolder();
    if (configured == null || configured.trim().isEmpty || Directory(musicDir).existsSync()) {
      WiretuneLog.warn(
        'Server',
        "Falling back to the user's music folder: '$musicDir'. Set Wiretune:LibraryPath to choose another folder.",
      );
      return AppPaths.fullPath(musicDir);
    }
    return AppPaths.fullPath(p.isAbsolute(configured) ? configured : p.join(contentRoot, configured));
  }
}
