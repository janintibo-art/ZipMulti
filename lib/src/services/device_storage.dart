import 'dart:io';

import 'package:flutter/services.dart';

/// Interroge Android sur l'espace de stockage restant.
///
/// Dart n'expose rien pour ça, et un manque de place est la cause d'échec la
/// plus courante sur un téléphone : mieux vaut le dire avant de lancer un
/// traitement de plusieurs minutes que de planter au milieu.
class DeviceStorage {
  DeviceStorage._();

  static const MethodChannel _channel = MethodChannel('zipmulti/media');

  /// Octets libres sur le volume contenant [path], ou null si l'information
  /// n'est pas disponible — auquel cas l'appelant ne doit rien bloquer.
  static Future<int?> freeBytes(String path) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('freeSpace', <String, Object?>{
        'path': path,
      });
    } catch (_) {
      return null;
    }
  }

  /// Espace restant là où ZipMulti dépose ses lots.
  static Future<int?> freeBytesInDownloads() =>
      freeBytes('/storage/emulated/0/Download');
}
