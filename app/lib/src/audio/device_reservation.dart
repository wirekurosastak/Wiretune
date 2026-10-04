import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Wiretune's claim on an ALSA card, in the device reservation protocol that PipeWire (WirePlumber) and PulseAudio
/// follow: owning the D-Bus name `org.freedesktop.ReserveDevice1.Audio<card>`. The sound server that holds the card is
/// asked to let go of it, and it takes the card back as soon as the name is free again.
///
/// The name belongs to this process's own bus connection, so the bus frees it however the process ends: closed,
/// crashed or killed. (A helper process such as `pw-reserve` outlives a player that is closed without cleaning up, and
/// keeps the card away from the sound server, silent, until it is stopped by hand.)
class AlsaCardReservation {
  AlsaCardReservation._(this._bus, this.card);

  static const String _interface = 'org.freedesktop.ReserveDevice1';

  /// Above the sound servers' own claims (WirePlumber's is -20), so they give the card up when asked.
  static const int priority = 10;

  final DBusClient _bus;
  final int card;

  /// The bus name that stands for the card.
  static String nameOf(int card) => '$_interface.Audio$card';

  /// Claims [card] on the session bus, or on [bus], which then belongs to the reservation. Null when the bus cannot be
  /// reached or the card's holder does not let go of it.
  static Future<AlsaCardReservation?> acquire(int card, {DBusClient? bus}) async {
    final client = bus ?? DBusClient.session();
    final name = nameOf(card);
    try {
      await client.registerObject(_ReservationObject(card));
      // Not open to replacement: while Wiretune plays exclusively, nobody takes the card over.
      var reply = await client.requestName(name, flags: {DBusRequestNameFlag.doNotQueue});
      if (reply == DBusRequestNameReply.exists) {
        // Someone holds the card, normally the sound server: ask it to let go, then take the name over.
        final holder = DBusRemoteObject(client, name: name, path: _ReservationObject.pathOf(card));
        final answer = await holder
            .callMethod(_interface, 'RequestRelease', [const DBusInt32(priority)], replySignature: DBusSignature('b'))
            .timeout(const Duration(seconds: 5));
        if (answer.returnValues.first.asBoolean()) {
          reply = await client.requestName(
            name,
            flags: {DBusRequestNameFlag.doNotQueue, DBusRequestNameFlag.replaceExisting},
          );
        }
      }
      if (reply == DBusRequestNameReply.primaryOwner || reply == DBusRequestNameReply.alreadyOwner) {
        return AlsaCardReservation._(client, card);
      }
      WiretuneLog.warn('DeviceReservation', 'Audio$card is held by another program, which did not release it.');
    } catch (e) {
      WiretuneLog.warn('DeviceReservation', 'Could not reserve Audio$card: $e');
    }
    await client.close();
    return null;
  }

  /// Gives the card back: the connection closes, the name is freed, and the sound server takes the card again.
  Future<void> release() => _bus.close();
}

/// What other programs see of the claim: who holds the card, and a refusal when they ask for it.
class _ReservationObject extends DBusObject {
  _ReservationObject(this.card) : super(pathOf(card));

  final int card;

  static DBusObjectPath pathOf(int card) => DBusObjectPath('/org/freedesktop/ReserveDevice1/Audio$card');

  Map<String, DBusValue> get _properties => {
    'ApplicationName': const DBusString('Wiretune'),
    'ApplicationDeviceName': DBusString('hw:$card'),
    'Priority': const DBusInt32(AlsaCardReservation.priority),
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != AlsaCardReservation._interface) return DBusMethodErrorResponse.unknownInterface();
    if (methodCall.name != 'RequestRelease') return DBusMethodErrorResponse.unknownMethod();
    // The card is in use for exclusive playback; it is given back when that ends.
    return DBusMethodSuccessResponse([const DBusBoolean(false)]);
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == AlsaCardReservation._interface ? _properties[name] : null;
    return value == null ? DBusMethodErrorResponse.unknownProperty() : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(interface == AlsaCardReservation._interface ? _properties : const {});
}
