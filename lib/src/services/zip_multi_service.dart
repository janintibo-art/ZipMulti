import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class ZipMultiException implements Exception {
  ZipMultiException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ZipMultiResult {
  const ZipMultiResult({
    required this.volumes,
    required this.message,
    this.filesProcessed = 0,
    this.integrityVerified = false,
  });

  final List<File> volumes;
  final String message;
  final int filesProcessed;
  final bool integrityVerified;
}

class _PlannedEntry {
  const _PlannedEntry({
    required this.source,
    required this.archiveName,
    required this.size,
  });

  final File source;
  final String archiveName;
  final int size;
}

class ZipMultiService {
  static const String manifestName = 'ZIPMULTI_MANIFEST.json';
  static const String volumeInfoName = 'ZIPMULTI_VOLUME.json';
  static const String partsRoot = '__zipmulti_parts__';
  static const int formatVersion = 2;

  /// Part de la progression consacree a l'analyse et au decoupage ; le reste
  /// revient a l'ecriture des volumes.
  static const double _analysisWeight = 0.45;

  /// Écriture disque forcée toutes les 8 Mo pendant le découpage.
  static const int _flushInterval = 8 * 1024 * 1024;

  /// Marge réservée dans chaque volume pour les en-têtes ZIP et le descripteur
  /// de volume, en plus du manifeste lui-même.
  static const int _volumeOverhead = 8 * 1024;

  Future<void> _ensureNoPreviousSet(Directory directory, String baseName) async {
    final pattern = RegExp('^${RegExp.escape(baseName)}_[0-9]{3,}\\.zip\$',
        caseSensitive: false);
    final leftovers = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (pattern.hasMatch(name)) leftovers.add(name);
      }
    } on FileSystemException {
      return;
    }
    if (leftovers.isEmpty) return;

    leftovers.sort();
    throw ZipMultiException(
      'Le dossier de sortie contient déjà des volumes portant ce nom '
      '(${leftovers.take(3).join(', ')}${leftovers.length > 3 ? '…' : ''}).\n\n'
      'Un ancien volume oublié empêcherait la reconstruction du nouveau lot. '
      'Supprimez ces fichiers, ou choisissez un autre nom de lot.',
    );
  }

  Future<ZipMultiResult> createVolumes({
    required List<File> files,
    required Directory outputDirectory,
    required String baseName,
    required int maxBytes,
    required bool advancedSplit,
    void Function(String message)? onProgress,
    void Function(double fraction)? onFraction,
  }) async {
    if (files.isEmpty) {
      throw ZipMultiException('Aucun fichier sélectionné.');
    }
    if (maxBytes < 1024 * 1024) {
      throw ZipMultiException('La taille maximale doit être au moins de 1 Mo.');
    }

    await outputDirectory.create(recursive: true);
    final safeBaseName = _sanitizeBaseName(baseName);
    await _ensureNoPreviousSet(outputDirectory, safeBaseName);
    final tempDirectory = await Directory.systemTemp.createTemp('zipmulti_create_');
    final createdVolumes = <File>[];

    try {
      // Une marge volontaire laisse de la place aux en-têtes ZIP et au manifeste
      // présent dans chacun des volumes.
      final payloadTarget = max(256 * 1024, (maxBytes * 0.82).floor());
      final planned = <_PlannedEntry>[];
      final manifestFiles = <Map<String, Object?>>[];
      final usedNames = <String>{};
      final setId = _newSetId(safeBaseName);

      // La progression se mesure en octets et non en nombre de fichiers : un lot
      // contient souvent un fichier enorme et beaucoup de petits, et compter les
      // fichiers donnerait une barre qui saute puis reste bloquee.
      var totalSourceBytes = 0;
      for (final source in files) {
        try {
          totalSourceBytes += await source.length();
        } catch (_) {
          // Fichier illisible : il sera de toute facon ignore plus bas.
        }
      }
      if (totalSourceBytes <= 0) totalSourceBytes = 1;
      var analyzedBytes = 0;
      void reportAnalysis() {
        final done = (analyzedBytes / totalSourceBytes).clamp(0.0, 1.0);
        onFraction?.call(_analysisWeight * done);
      }

      onFraction?.call(0);

      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final source = files[fileIndex];
        if (!await source.exists()) continue;

        final stat = await source.stat();
        if (stat.type != FileSystemEntityType.file) continue;

        final uniqueName = _uniqueArchiveName(p.basename(source.path), usedNames);
        onProgress?.call(
          'Analyse ${fileIndex + 1}/${files.length} : $uniqueName (${_formatBytes(stat.size)})',
        );

        if (stat.size <= payloadTarget) {
          final hash = await _sha256File(source);
          planned.add(_PlannedEntry(
            source: source,
            archiveName: uniqueName,
            size: stat.size,
          ));
          manifestFiles.add({
            'name': uniqueName,
            'kind': 'normal',
            'size': stat.size,
            'sha256': hash,
          });
          analyzedBytes += stat.size;
          reportAnalysis();
          continue;
        }

        if (!advancedSplit) {
          throw ZipMultiException(
            'Le fichier "$uniqueName" fait ${_formatBytes(stat.size)} et dépasse '
            'la capacité sûre d’un ZIP de ${_formatBytes(maxBytes)}.\n\n'
            'Activez « Fractionnement intelligent » pour le découper. ZipMulti v0.3 '
            'saura ensuite le reconstruire automatiquement depuis les volumes.',
          );
        }

        final originalHashFuture = _sha256File(source);
        final fileId = 'f${fileIndex.toString().padLeft(5, '0')}';
        final chunks = <Map<String, Object?>>[];
        var chunkIndex = 0;
        var currentSize = 0;
        IOSink? chunkSink;
        File? chunkFile;
        String? chunkArchiveName;

        Future<void> openChunk() async {
          chunkIndex++;
          currentSize = 0;
          final partName = '${chunkIndex.toString().padLeft(6, '0')}.part';
          final partDir = Directory(p.join(tempDirectory.path, partsRoot, fileId));
          await partDir.create(recursive: true);
          chunkFile = File(p.join(partDir.path, partName));
          chunkArchiveName = p.posix.join(partsRoot, fileId, partName);
          chunkSink = chunkFile!.openWrite();
        }

        Future<void> closeAndRegisterChunk() async {
          final sink = chunkSink;
          final file = chunkFile;
          final archiveName = chunkArchiveName;
          if (sink == null || file == null || archiveName == null) return;

          await sink.close();
          final size = await file.length();
          if (size == 0) return;

          onProgress?.call(
            'Empreinte de $uniqueName — partie ${chunks.length + 1}…',
          );
          final hash = await _sha256File(file);
          planned.add(_PlannedEntry(
            source: file,
            archiveName: archiveName,
            size: size,
          ));
          chunks.add({
            'path': archiveName,
            'size': size,
            'sha256': hash,
          });
          analyzedBytes += size;
          reportAnalysis();
        }

        await openChunk();
        var sinceLastFlush = 0;
        await for (final data in source.openRead()) {
          var offset = 0;
          while (offset < data.length) {
            final remaining = payloadTarget - currentSize;
            final take = min(remaining, data.length - offset);
            chunkSink!.add(data.sublist(offset, offset + take));
            currentSize += take;
            offset += take;
            sinceLastFlush += take;

            if (currentSize >= payloadTarget) {
              await closeAndRegisterChunk();
              await openChunk();
              sinceLastFlush = 0;
            } else if (sinceLastFlush >= _flushInterval) {
              // Sans ce flush, IOSink accumule les octets en mémoire beaucoup
              // plus vite que le disque ne les écrit : sur un téléphone, un
              // fichier de plusieurs Go finit par faire planter l'application.
              await chunkSink!.flush();
              sinceLastFlush = 0;
            }
          }
        }
        await closeAndRegisterChunk();

        manifestFiles.add({
          'name': uniqueName,
          'kind': 'chunks',
          'size': stat.size,
          'sha256': await originalHashFuture,
          'chunks': chunks,
        });
      }

      if (planned.isEmpty) {
        throw ZipMultiException('Aucun fichier lisible à compresser.');
      }

      final createdUtc = DateTime.now().toUtc().toIso8601String();
      Map<String, Object?> buildManifest(int volumeCount) => <String, Object?>{
            'format': 'ZipMulti',
            'version': formatVersion,
            'setId': setId,
            'mode': advancedSplit ? 'smart-split' : 'compatible',
            'baseName': safeBaseName,
            'volumeCount': volumeCount,
            'maxBytes': maxBytes,
            'createdUtc': createdUtc,
            'files': manifestFiles,
          };

      // Le manifeste est recopié dans CHAQUE volume : sa taille doit être
      // retirée du budget de remplissage, sinon un volume peut dépasser la
      // limite demandée et toute la création est annulée à la dernière étape.
      const jsonPretty = JsonEncoder.withIndent('  ');
      final manifestProbe = utf8.encode(jsonPretty.convert(buildManifest(999999))).length;
      if (manifestProbe > maxBytes ~/ 8) {
        throw ZipMultiException(
          'Le manifeste est exceptionnellement volumineux (${_formatBytes(manifestProbe)}). '
          'Réduisez le nombre de fichiers sélectionnés par lot, ou augmentez la '
          'taille maximale par ZIP.',
        );
      }

      final groupBudget = max(64 * 1024, payloadTarget - manifestProbe - _volumeOverhead);
      final groups = _groupEntries(planned, groupBudget);
      if (groups.isEmpty) groups.add(<_PlannedEntry>[]);

      final manifestFile = File(p.join(tempDirectory.path, manifestName));
      await manifestFile.writeAsString(
        jsonPretty.convert(buildManifest(groups.length)),
        flush: true,
      );

      final plannedBytes =
          max(1, planned.fold<int>(0, (sum, entry) => sum + entry.size));
      var writtenBytes = 0;

      for (var i = 0; i < groups.length; i++) {
        final number = i + 1;
        final volumePath = p.join(
          outputDirectory.path,
          '${safeBaseName}_${number.toString().padLeft(3, '0')}.zip',
        );
        onProgress?.call('Création du volume $number/${groups.length}…');

        final volumeInfo = <String, Object?>{
          'format': 'ZipMultiVolume',
          'version': formatVersion,
          'setId': setId,
          'baseName': safeBaseName,
          'index': number,
          'count': groups.length,
        };
        final volumeInfoFile = File(p.join(tempDirectory.path, 'volume_$number.json'));
        await volumeInfoFile.writeAsString(jsonEncode(volumeInfo), flush: true);

        final volume = File(volumePath);
        createdVolumes.add(volume);

        final encoder = ZipFileEncoder();
        encoder.create(volumePath, level: DeflateLevel.bestSpeed);
        await encoder.addFile(manifestFile, manifestName, DeflateLevel.bestSpeed);
        await encoder.addFile(volumeInfoFile, volumeInfoName, DeflateLevel.bestSpeed);
        for (final entry in groups[i]) {
          await encoder.addFile(
            entry.source,
            entry.archiveName,
            DeflateLevel.bestSpeed,
          );
          writtenBytes += entry.size;
          final done = (writtenBytes / plannedBytes).clamp(0.0, 1.0);
          onFraction?.call(_analysisWeight + (1 - _analysisWeight) * done);
        }
        await encoder.close();

        final actualSize = await volume.length();
        if (actualSize > maxBytes) {
          if (await volume.exists()) {
            await volume.delete();
          }
          throw ZipMultiException(
            'Le volume $number dépasse la limite choisie après création '
            '(${_formatBytes(actualSize)} > ${_formatBytes(maxBytes)}). '
            'Essayez une limite légèrement supérieure.',
          );
        }
      }

      onFraction?.call(1);
      return ZipMultiResult(
        volumes: List.unmodifiable(createdVolumes),
        filesProcessed: manifestFiles.length,
        integrityVerified: true,
        message: advancedSplit
            ? '${createdVolumes.length} volume(s) créé(s). Le lot contient ${manifestFiles.length} fichier(s), avec manifeste de reconstruction et empreintes SHA-256.'
            : '${createdVolumes.length} ZIP standard(s) créé(s). Les fichiers ne sont pas coupés et chaque volume reste ouvrable séparément.',
      );
    } catch (_) {
      for (final volume in createdVolumes) {
        if (await volume.exists()) {
          await volume.delete();
        }
      }
      rethrow;
    } finally {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  }

  Future<ZipMultiResult> extractVolumes({
    required List<File> selectedVolumes,
    required Directory destination,
    void Function(String message)? onProgress,
    void Function(double fraction)? onFraction,
  }) async {
    if (selectedVolumes.isEmpty) {
      throw ZipMultiException('Aucun ZIP sélectionné.');
    }
    await destination.create(recursive: true);

    var volumes = _deduplicateExistingZipFiles(selectedVolumes);
    if (volumes.isEmpty) {
      throw ZipMultiException('Aucun fichier ZIP valide trouvé.');
    }

    // Si un seul volume est choisi, on tente de retrouver automatiquement tout le lot.
    var autoDiscovered = false;
    File? reference;
    if (volumes.length == 1) {
      final selected = volumes.first;
      final discovered = await discoverSiblingVolumes(selected);
      if (discovered.length > 1) {
        volumes = discovered;
        autoDiscovered = true;
        reference = selected;
      }
    }
    volumes.sort(_compareVolumeFiles);

    // Le volume réellement choisi sert de référence : c'est lui qui décide à
    // quel lot appartient la reconstruction, pas le premier trouvé par ordre
    // alphabétique.
    if (reference != null) {
      final key = p.normalize(reference.absolute.path).toLowerCase();
      final index = volumes.indexWhere(
        (file) => p.normalize(file.absolute.path).toLowerCase() == key,
      );
      if (index > 0) {
        final picked = volumes.removeAt(index);
        volumes.insert(0, picked);
      }
    }

    final temp = await Directory.systemTemp.createTemp('zipmulti_extract_');
    try {
      var totalVolumeBytes = 0;
      for (final volume in volumes) {
        try {
          totalVolumeBytes += await volume.length();
        } catch (_) {
          // Volume illisible : signale plus bas par l'extraction elle-meme.
        }
      }
      if (totalVolumeBytes <= 0) totalVolumeBytes = 1;
      var readBytes = 0;
      onFraction?.call(0);

      final extractedRoots = <Directory>[];
      final acceptedVolumes = <File>[];
      Map<String, dynamic>? manifest;
      String? expectedSetId;
      int? expectedVolumeCount;
      final seenVolumeIndexes = <int>{};

      for (var i = 0; i < volumes.length; i++) {
        final volume = volumes[i];
        final root = Directory(p.join(temp.path, 'v${(i + 1).toString().padLeft(4, '0')}'));
        await root.create(recursive: true);
        onProgress?.call('Lecture du volume ${i + 1}/${volumes.length} : ${p.basename(volume.path)}');
        await extractFileToDisk(volume.path, root.path);
        try {
          readBytes += await volume.length();
        } catch (_) {
          // La progression reste simplement figee pour ce volume.
        }
        onFraction?.call(
          _analysisWeight * (readBytes / totalVolumeBytes).clamp(0.0, 1.0),
        );

        final manifestFile = File(p.join(root.path, manifestName));
        final volumeInfoFile = File(p.join(root.path, volumeInfoName));

        Map<String, dynamic>? volumeManifest;
        String? thisSetId;
        int? thisIndex;
        int? thisCount;

        if (await manifestFile.exists()) {
          final decoded = jsonDecode(await manifestFile.readAsString());
          if (decoded is! Map<String, dynamic>) {
            throw ZipMultiException('Manifeste ZipMulti invalide dans ${p.basename(volume.path)}.');
          }
          volumeManifest = decoded;
          thisSetId = decoded['setId']?.toString();
          thisCount = _asInt(decoded['volumeCount']);
        }

        if (await volumeInfoFile.exists()) {
          final decoded = jsonDecode(await volumeInfoFile.readAsString());
          if (decoded is Map<String, dynamic>) {
            thisSetId ??= decoded['setId']?.toString();
            thisIndex = _asInt(decoded['index']);
            thisCount ??= _asInt(decoded['count']);
          }
        }

        if (expectedSetId != null && thisSetId != null && expectedSetId != thisSetId) {
          // Deux lots peuvent partager le même nom de base dans un même dossier.
          // Quand les voisins ont été trouvés tout seuls, on ignore simplement
          // l'intrus ; quand l'utilisateur les a choisis lui-même, on le prévient.
          if (autoDiscovered) {
            await root.delete(recursive: true);
            continue;
          }
          throw ZipMultiException(
            'Les ZIP sélectionnés appartiennent à plusieurs lots différents. '
            'Placez uniquement les volumes d’un même partage ensemble.',
          );
        }

        expectedSetId ??= thisSetId;
        manifest ??= volumeManifest;
        expectedVolumeCount ??= thisCount;
        if (thisIndex != null) seenVolumeIndexes.add(thisIndex);
        extractedRoots.add(root);
        acceptedVolumes.add(volume);
      }

      volumes = acceptedVolumes..sort(_compareVolumeFiles);
      if (volumes.isEmpty) {
        throw ZipMultiException('Aucun volume exploitable dans la sélection.');
      }

      if (manifest == null) {
        onProgress?.call('ZIP classiques détectés : extraction des fichiers…');
        for (final root in extractedRoots) {
          await _copyDirectoryContents(root, destination);
        }
        onFraction?.call(1);
        return ZipMultiResult(
          volumes: volumes,
          message: '${volumes.length} ZIP classique(s) extrait(s).',
        );
      }

      final version = _asInt(manifest['version']) ?? 1;
      if (version >= 2 && expectedVolumeCount != null) {
        final missing = <int>[];
        if (seenVolumeIndexes.isNotEmpty) {
          for (var i = 1; i <= expectedVolumeCount; i++) {
            if (!seenVolumeIndexes.contains(i)) missing.add(i);
          }
        } else if (volumes.length < expectedVolumeCount) {
          for (var i = volumes.length + 1; i <= expectedVolumeCount; i++) {
            missing.add(i);
          }
        }

        if (missing.isNotEmpty || volumes.length < expectedVolumeCount) {
          final base = manifest['baseName']?.toString() ?? 'archive';
          final names = missing.isNotEmpty
              ? missing.map((i) => '${base}_${i.toString().padLeft(3, '0')}.zip').join(', ')
              : '${expectedVolumeCount - volumes.length} volume(s)';
          throw ZipMultiException(
            'Lot incomplet : $names manquant(s).\n\n'
            'Sur Android, si la recherche automatique ne voit pas les fichiers voisins, '
            'sélectionnez tous les ZIP du lot en une seule fois.',
          );
        }
      }

      final payloads = <String, File>{};
      for (final root in extractedRoots) {
        await for (final entity in root.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final relative = p.relative(entity.path, from: root.path).replaceAll('\\', '/');
          if (relative == manifestName || relative == volumeInfoName) continue;
          if (payloads.containsKey(relative)) {
            throw ZipMultiException('Entrée dupliquée dans le lot : $relative');
          }
          payloads[relative] = entity;
        }
      }

      final files = manifest['files'];
      if (files is! List) {
        throw ZipMultiException('Liste de fichiers absente du manifeste ZipMulti.');
      }

      var totalOutputBytes = 0;
      for (final raw in files) {
        if (raw is! Map) continue;
        final declared = _asInt(raw['size']);
        if (declared != null) totalOutputBytes += declared;
      }
      if (totalOutputBytes <= 0) totalOutputBytes = 1;
      var rebuiltBytes = 0;

      var reconstructed = 0;
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final raw = files[fileIndex];
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry(key.toString(), value));
        final name = item['name']?.toString();
        if (name == null || name.trim().isEmpty) continue;
        final safeName = p.basename(name);
        final kind = item['kind']?.toString() ?? 'normal';
        final output = File(p.join(destination.path, safeName));
        await output.parent.create(recursive: true);

        onProgress?.call(
          'Reconstruction ${fileIndex + 1}/${files.length} : $safeName',
        );

        if (kind == 'normal') {
          final payload = payloads[name] ?? payloads[name.replaceAll('\\', '/')];
          if (payload == null || !await payload.exists()) {
            throw ZipMultiException('Fichier manquant dans le lot : $safeName');
          }
          await _verifyFileFromManifest(payload, item, label: safeName);
          await payload.copy(output.path);
        } else if (kind == 'chunks') {
          final chunks = item['chunks'];
          if (chunks is! List || chunks.isEmpty) {
            throw ZipMultiException('Aucune partie déclarée pour $safeName.');
          }

          final sink = output.openWrite();
          try {
            for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
              final chunkInfo = _normalizeChunkInfo(chunks[chunkIndex]);
              final chunkPath = chunkInfo['path']?.toString();
              if (chunkPath == null) {
                throw ZipMultiException('Description de partie invalide pour $safeName.');
              }
              final chunk = payloads[chunkPath];
              if (chunk == null || !await chunk.exists()) {
                throw ZipMultiException(
                  'Partie ${chunkIndex + 1}/${chunks.length} manquante pour $safeName.',
                );
              }
              await _verifyFileFromManifest(
                chunk,
                chunkInfo,
                label: '$safeName — partie ${chunkIndex + 1}',
              );
              await sink.addStream(chunk.openRead());
            }
          } finally {
            await sink.close();
          }
          await _verifyFileFromManifest(output, item, label: safeName);
        } else {
          throw ZipMultiException('Type de fichier ZipMulti inconnu : $kind');
        }
        rebuiltBytes += _asInt(item['size']) ?? 0;
        final done = (rebuiltBytes / totalOutputBytes).clamp(0.0, 1.0);
        onFraction?.call(_analysisWeight + (1 - _analysisWeight) * done);
        reconstructed++;
      }

      onFraction?.call(1);

      return ZipMultiResult(
        volumes: volumes,
        filesProcessed: reconstructed,
        integrityVerified: version >= 2,
        message: version >= 2
            ? 'Reconstruction terminée : $reconstructed fichier(s). Toutes les empreintes SHA-256 disponibles ont été vérifiées.'
            : 'Reconstruction terminée : $reconstructed fichier(s). Lot ZipMulti v1 importé avec compatibilité ascendante.',
      );
    } finally {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    }
  }

  Future<List<File>> discoverSiblingVolumes(File selectedVolume) async {
    if (!await selectedVolume.exists()) return [selectedVolume];
    final dir = selectedVolume.parent;
    final name = p.basename(selectedVolume.path);
    final match = RegExp(r'^(.*)_([0-9]{3,})\.zip$', caseSensitive: false).firstMatch(name);
    if (match == null) return [selectedVolume];

    final prefix = '${match.group(1)}_';
    final result = <File>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        if (base.toLowerCase().startsWith(prefix.toLowerCase()) &&
            RegExp(r'_[0-9]{3,}\.zip$', caseSensitive: false).hasMatch(base)) {
          result.add(entity);
        }
      }
    } on FileSystemException {
      return [selectedVolume];
    }

    result.sort(_compareVolumeFiles);
    return result.isEmpty ? [selectedVolume] : result;
  }

  List<List<_PlannedEntry>> _groupEntries(
    List<_PlannedEntry> entries,
    int targetBytes,
  ) {
    final groups = <List<_PlannedEntry>>[];
    var current = <_PlannedEntry>[];
    var currentBytes = 0;

    for (final entry in entries) {
      if (current.isNotEmpty && currentBytes + entry.size > targetBytes) {
        groups.add(current);
        current = <_PlannedEntry>[];
        currentBytes = 0;
      }
      current.add(entry);
      currentBytes += entry.size;
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  Future<void> _verifyFileFromManifest(
    File file,
    Map<String, Object?> info, {
    required String label,
  }) async {
    final expectedSize = _asInt(info['size']);
    if (expectedSize != null) {
      final actualSize = await file.length();
      if (actualSize != expectedSize) {
        throw ZipMultiException(
          'Contrôle d’intégrité échoué pour $label : taille incorrecte '
          '(${_formatBytes(actualSize)} au lieu de ${_formatBytes(expectedSize)}).',
        );
      }
    }

    final expectedHash = info['sha256']?.toString().toLowerCase();
    if (expectedHash != null && expectedHash.isNotEmpty) {
      final actualHash = await _sha256File(file);
      if (actualHash.toLowerCase() != expectedHash) {
        throw ZipMultiException(
          'Contrôle SHA-256 échoué pour $label. Le volume est incomplet ou corrompu.',
        );
      }
    }
  }

  Map<String, Object?> _normalizeChunkInfo(Object? raw) {
    // Compatibilité avec le manifeste v1 où chaque partie était une simple chaîne.
    if (raw is String) return {'path': raw};
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  List<File> _deduplicateExistingZipFiles(List<File> files) {
    final seen = <String>{};
    final result = <File>[];
    for (final file in files) {
      if (!file.path.toLowerCase().endsWith('.zip')) continue;
      final key = p.normalize(file.absolute.path).toLowerCase();
      if (seen.add(key) && file.existsSync()) result.add(file);
    }
    return result;
  }

  int _compareVolumeFiles(File a, File b) {
    int number(File file) {
      final match = RegExp(r'_([0-9]{3,})\.zip$', caseSensitive: false)
          .firstMatch(p.basename(file.path));
      return int.tryParse(match?.group(1) ?? '') ?? 0;
    }

    final an = number(a);
    final bn = number(b);
    if (an != bn) return an.compareTo(bn);
    return a.path.compareTo(b.path);
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: source.path);
      if (relative == '.') continue;

      final outputPath = p.join(destination.path, relative);
      if (entity is Directory) {
        await Directory(outputPath).create(recursive: true);
      } else if (entity is File) {
        await File(outputPath).parent.create(recursive: true);
        await entity.copy(outputPath);
      }
    }
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  String _newSetId(String baseName) {
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return '$baseName-$micros-$random';
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  String _sanitizeBaseName(String value) {
    final trimmed = value.trim().isEmpty ? 'archive' : value.trim();
    final cleaned = trimmed.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return cleaned.replaceAll(RegExp(r'\s+'), '_');
  }

  String _uniqueArchiveName(String name, Set<String> used) {
    var candidate = name;
    var index = 2;
    while (used.contains(candidate.toLowerCase())) {
      final ext = p.extension(name);
      final stem = p.basenameWithoutExtension(name);
      candidate = '$stem-$index$ext';
      index++;
    }
    used.add(candidate.toLowerCase());
    return candidate;
  }

  String _formatBytes(int bytes) {
    const units = ['o', 'Ko', 'Mo', 'Go', 'To'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
