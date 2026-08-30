import 'dart:io';

import 'package:flutter/services.dart';

/// Signale à Android les fichiers que ZipMulti vient d'écrire.
///
/// Une application qui écrit directement sur le disque reste invisible pour
/// MediaStore, l'index qui alimente le raccourci « Téléchargements » et une
/// partie des sélecteurs de fichiers. Sans cette déclaration, un lot fraîchement
/// créé n'apparaît qu'après qu'un gestionnaire de fichiers ait parcouru le vrai
/// dossier, ce qui donne l'impression que rien n'a été produit.
///
/// Le scan est asynchrone côté système : comptez quelques secondes avant que
/// les fichiers ne remontent dans les listes.
class MediaIndex {
  MediaIndex._();

  static const MethodChannel _channel = MethodChannel('zipmulti/media');

  /// Déclare [paths] à l'index. Sans effet hors Android, et silencieuse en cas
  /// d'échec : l'indexation est un confort, jamais une condition de réussite.
  static Future<void> announce(Iterable<String> paths) async {
    if (!Platform.isAndroid) return;
    final list = paths.toList(growable: false);
    if (list.isEmpty) return;

    try {
      await _channel.invokeMethod<bool>('scan', <String, Object?>{
        'paths': list,
      });
    } catch (_) {
      // Canal absent (ancienne version installée) ou scan refusé : les fichiers
      // sont bien sur le disque, seule leur visibilité immédiate est perdue.
    }
  }

  /// Déclare tout le contenu d'un dossier, une fois un traitement terminé.
  static Future<void> announceDirectory(Directory directory) async {
    if (!Platform.isAndroid) return;
    final paths = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) paths.add(entity.path);
      }
    } catch (_) {
      return;
    }
    await announce(paths);
  }
}
