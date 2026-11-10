// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:wiretune_core/wiretune_core.dart';

/// The link in the QR codes that connect a phone: `wiretune://connect?server=<address>`, and with `&code=<code>` a
/// one-time sign-in code ([SignInCode]) as well. The phone's camera opens Wiretune with it (Android and iOS hand a
/// link of the app's own scheme to Flutter, which passes it on as a route).
abstract final class ConnectLink {
  static const String _scheme = 'wiretune';
  static const String _host = 'connect';

  static String build(String server, {String? code}) =>
      Uri(scheme: _scheme, host: _host, queryParameters: {'server': server, 'code': ?code}).toString();

  /// The server and the code in [link], or null when it isn't such a link, or names no usable address or code.
  static ({String server, String? code})? parse(String? link) {
    final uri = link == null ? null : Uri.tryParse(link);
    if (uri == null || uri.scheme != _scheme || uri.host != _host) return null;
    final server = ServerSession.normalizeServerUrl(uri.queryParameters['server']);
    final code = uri.queryParameters['code'];
    if (server == null || (code != null && !RegExp(r'^[A-Za-z0-9]{1,64}$').hasMatch(code))) return null;
    return (server: server, code: code);
  }

  /// [server] as a phone on the same network reaches it: this computer's address on the home network in place of
  /// `localhost` (a server on the same machine), which on the phone would be the phone itself. Unchanged otherwise, or
  /// when no such address is found.
  static Future<String> reachable(String server) async {
    final uri = Uri.tryParse(server);
    if (uri == null || !const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) return server;
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      // A home network's address, before those of virtual networks (containers, VMs, VPNs).
      const virtual = ['docker', 'br-', 'virbr', 'veth', 'vmnet', 'vboxnet', 'tailscale', 'tun', 'wg', 'zt'];
      bool home(String address) =>
          address.startsWith('192.168.') ||
          address.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(address);
      final candidates = [
        for (final interface in interfaces)
          if (!virtual.any(interface.name.toLowerCase().startsWith))
            for (final address in interface.addresses)
              if (home(address.address)) address.address,
      ];
      if (candidates.isEmpty) return server;
      return uri.replace(host: candidates.first).toString();
    } on SocketException catch (e) {
      WiretuneLog.warn('ConnectLink', "This computer's network addresses can't be read: ${e.message}");
      return server;
    }
  }
}
