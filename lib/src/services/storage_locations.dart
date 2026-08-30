import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Dossier retenu pour écrire un lot, et d'où il vient.
class ResolvedDirectory {
  const ResolvedDirectory({
    required this.directory,
    required this.isFallback,
    required this.renamed,
  });

  /// Dossier prêt à l'emploi, déjà créé et testé en écriture.
  final Directory directory;

  /// Vrai quand Téléchargements a été refusé et qu'un emplacement de repli
  /// a été utilisé. L'interface le signale à l'utilisateur.
  final bool isFallback;

  /// Vrai quand un suffixe a été ajouté parce qu'un lot du même nom existait.
  final bool renamed;
}

/// Choisit tout seul où écrire, plutôt que de demander un dossier.
///
/// Sur Android récent, une application ne peut plus écrire n'importe où par
/// chemin de fichier : les cartes SD externes sont refusées, et Téléchargements
/// lui-même dépend de la version du système. On essaie donc plusieurs
/// emplacements dans l'ordre, en vérifiant réellement l'écriture à chaque fois.
class StorageLocations {
  StorageLocations._();

  static const String _androidDownloads = '/storage/emulated/0/Download';

  /// Retire tout ce qui ne peut pas figurer dans un nom de dossier.
  static String sanitizeFolderName(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    return cleaned.isEmpty ? 'zipmulti' : cleaned;
  }

  /// Prépare un sous-dossier portant [folderName] dans Téléchargements.
  ///
  /// Si un lot du même nom s'y trouve déjà, un suffixe numérique est ajouté
  /// plutôt que d'écraser ou de faire échouer l'opération.
  ///
  /// [probeExtensions] liste les types de fichiers qui devront réellement y
  /// être écrits. C'est indispensable : depuis Android 11, une application peut
  /// créer un .zip dans Téléchargements mais se voir refuser un .jpg au même
  /// endroit, car les médias passent obligatoirement par MediaStore. Tester
  /// avec un nom neutre donnerait donc un faux feu vert.
  static Future<ResolvedDirectory> prepare(
    String folderName, {
    List<String> probeExtensions = const ['.zip'],
  }) async {
    final safe = sanitizeFolderName(folderName);
    final roots = await _candidateRoots();

    for (var index = 0; index < roots.length; index++) {
      final root = roots[index];
      final picked = await _firstFreeName(root, safe, probeExtensions);
      if (picked == null) continue;
      return ResolvedDirectory(
        directory: picked.$1,
        isFallback: index > 0,
        renamed: picked.$2,
      );
    }

    throw const FileSystemException(
      'Aucun emplacement accessible en écriture n’a été trouvé.',
    );
  }

  static Future<List<Directory>> _candidateRoots() async {
    final roots = <Directory>[];

    if (Platform.isAndroid) {
      roots.add(Directory(_androidDownloads));
      try {
        final external = await getExternalStorageDirectory();
        if (external != null) roots.add(external);
      } catch (_) {
        // Emplacement indisponible : on passe au suivant.
      }
    } else {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) roots.add(downloads);
      } catch (_) {
        // Bureau sans dossier Téléchargements standard.
      }
    }

    try {
      roots.add(await getApplicationDocumentsDirectory());
    } catch (_) {
      // Dernier recours ci-dessous.
    }
    roots.add(Directory.systemTemp);

    return roots;
  }

  /// Renvoie le premier nom libre sous [root], ou null si [root] est
  /// inaccessible en écriture.
  static Future<(Directory, bool)?> _firstFreeName(
    Directory root,
    String base,
    List<String> probeExtensions,
  ) async {
    for (var suffix = 0; suffix < 200; suffix++) {
      final name = suffix == 0 ? base : '$base-${suffix + 1}';
      final candidate = Directory(p.join(root.path, name));

      if (await candidate.exists() && await _containsZip(candidate)) {
        continue; // Un lot occupe déjà ce nom, on essaie le suivant.
      }
      if (await _canWrite(candidate, probeExtensions)) {
        return (candidate, suffix > 0);
      }
      // La racine est refusée pour ces types de fichiers. On retire le dossier
      // vide qu'on vient de créer pour ne pas laisser de trace inutile.
      try {
        if (await candidate.exists() &&
            await candidate.list().isEmpty) {
          await candidate.delete();
        }
      } catch (_) {
        // Sans importance : le dossier restera vide.
      }
      return null;
    }
    return null;
  }

  static Future<bool> _containsZip(Directory directory) async {
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.zip')) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Crée le dossier puis y écrit réellement un fichier témoin : c'est le seul
  /// moyen fiable de savoir si Android acceptera l'écriture.
  static Future<bool> _canWrite(
    Directory directory,
    List<String> probeExtensions,
  ) async {
    try {
      await directory.create(recursive: true);
      for (final extension in probeExtensions) {
        final probe = File(p.join(directory.path, '.zipmulti_test$extension'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Chemin affiché à l'utilisateur, raccourci quand c'est possible.
  static String describe(Directory directory) {
    final path = directory.path;
    if (path.startsWith('$_androidDownloads/')) {
      return 'Téléchargements/${path.substring(_androidDownloads.length + 1)}';
    }
    return path;
  }
}
