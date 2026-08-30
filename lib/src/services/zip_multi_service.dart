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

  /// Etat de reprise depose dans le dossier de sortie pendant la creation.
  static const String resumeName = 'ZIPMULTI_REPRISE.json';

  /// Note en clair glissee dans chaque volume, pour le destinataire qui ouvre
  /// un ZIP sans savoir de quoi il s'agit.
  static const String readmeName = 'LISEZMOI.txt';
  static const int formatVersion = 2;

  /// Part de la progression consacree a l'analyse et au decoupage ; le reste
  /// revient a l'ecriture des volumes.
  static const double _analysisWeight = 0.45;

  /// Écriture disque forcée toutes les 8 Mo pendant le découpage.
  static const int _flushInterval = 8 * 1024 * 1024;

  /// Marge réservée dans chaque volume pour les en-têtes ZIP et le descripteur
  /// de volume, en plus du manifeste lui-même.
  static const int _volumeOverhead = 8 * 1024;

  /// Reprend un lot laisse en plan, si son etat est encore exploitable.
  Future<PendingSet?> findPending(Directory workDirectory) async {
    final stateFile = File(p.join(workDirectory.path, resumeName));
    if (!await stateFile.exists()) return null;
    try {
      final decoded = jsonDecode(await stateFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final pending = PendingSet._(workDirectory, decoded);
      if (pending.remaining <= 0) return null;
      return pending;
    } catch (_) {
      return null;
    }
  }

  /// Efface l'etat et le dossier de travail, ainsi que les volumes deja ecrits.
  Future<void> discardPending(PendingSet pending) async {
    final output = pending.outputDirectory;
    for (var i = 1; i <= 999; i++) {
      final volume = File(_volumePath(output, pending.baseName, i));
      if (!await volume.exists()) break;
      try {
        await volume.delete();
      } catch (_) {
        // Volume verrouille : on laisse tomber celui-ci.
      }
    }
    try {
      if (await output.exists() && await output.list().isEmpty) {
        await output.delete();
      }
    } catch (_) {
      // Dossier non vide ou inaccessible : sans importance.
    }
    if (await pending.workDirectory.exists()) {
      await pending.workDirectory.delete(recursive: true);
    }
  }

  /// Prepare le dossier de travail sans le supprimer puis le recreer.
  ///
  /// Sur le stockage Android emule, enchainer suppression et creation du meme
  /// chemin laisse le cache du systeme de fichiers incoherent : les ecritures
  /// suivantes echouent alors avec « File exists ». On vide donc le contenu
  /// en gardant le dossier lui-meme.
  Future<void> _emptyWorkDirectory(Directory directory) async {
    await directory.create(recursive: true);
    try {
      await for (final entity in directory.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // Une entree recalcitrante sera de toute facon ecrasee plus bas.
        }
      }
    } catch (_) {
      // Dossier illisible : les ecritures suivantes signaleront le probleme.
    }
  }

  /// Renvoie un fichier garanti absent du disque, prêt à être écrit.
  Future<File> _freshFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Le mode ecriture tronquera le contenu restant.
      }
    }
    return file;
  }

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
    required Directory workDirectory,
    void Function(String message)? onProgress,
    void Function(double fraction)? onFraction,
    bool Function()? isCancelled,
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
    // Le travail vit dans l'espace prive de l'application : il survit a une
    // fermeture, ce qui permet la reprise, sans subir les regles du stockage
    // cloisonne d'Android qui s'appliquent a Telechargements.
    final tempDirectory = workDirectory;
    await _emptyWorkDirectory(tempDirectory);

    var volumesStarted = false;

    try {
      void checkCancelled() {
        if (isCancelled?.call() ?? false) throw const ZipMultiCancelled();
      }
      checkCancelled();
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

        checkCancelled();
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
          chunkFile = await _freshFile(p.join(partDir.path, partName));
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
              checkCancelled();
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

      final manifestFile =
          await _freshFile(p.join(tempDirectory.path, manifestName));
      await manifestFile.writeAsString(
        jsonPretty.convert(buildManifest(groups.length)),
        flush: true,
      );

      // L'etat de reprise n'est ecrit qu'une fois le plan complet etabli :
      // en dessous, il n'y aurait rien d'utile a reprendre.
      final readmeFile = await _freshFile(
        p.join(tempDirectory.path, readmeName),
      );
      await readmeFile.writeAsString(
        _readmeText(safeBaseName, groups.length, advancedSplit),
        flush: true,
      );

      final plan = _BuildPlan(
        setId: setId,
        baseName: safeBaseName,
        maxBytes: maxBytes,
        advancedSplit: advancedSplit,
        fileCount: manifestFiles.length,
        groups: groups,
        manifestPath: manifestFile.path,
        readmePath: readmeFile.path,
        outputPath: outputDirectory.path,
        volumeCount: groups.length,
      );
      await _saveResumeState(tempDirectory, plan, 0);

      volumesStarted = true;
      final result = await _writeVolumes(
        outputDirectory: outputDirectory,
        workDirectory: tempDirectory,
        plan: plan,
        startIndex: 0,
        onProgress: onProgress,
        onFraction: onFraction,
        isCancelled: isCancelled,
      );

      await _cleanUpAfterSuccess(tempDirectory);
      return result;
    } catch (_) {
      if (!volumesStarted) {
        // Rien d'exploitable : on ne laisse pas de dossier de travail derriere.
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      }
      // Sinon tout est conserve volontairement : l'utilisateur pourra reprendre.
      rethrow;
    }
  }

  /// Reprend l'ecriture des volumes la ou elle s'etait arretee.
  Future<ZipMultiResult> resumePending(
    PendingSet pending, {
    void Function(String message)? onProgress,
    void Function(double fraction)? onFraction,
    bool Function()? isCancelled,
  }) async {
    final outputDirectory = pending.outputDirectory;
    final workDirectory = pending.workDirectory;
    final plan = pending._plan;

    for (final group in plan.groups) {
      for (final entry in group) {
        if (!await entry.source.exists()) {
          throw ZipMultiException(
            'Impossible de reprendre : « ${p.basename(entry.source.path)} » '
            'n’est plus accessible. Relancez la création depuis le début.',
          );
        }
      }
    }
    if (!await File(plan.manifestPath).exists()) {
      throw ZipMultiException(
        'Impossible de reprendre : le manifeste du lot a disparu. '
        'Relancez la création depuis le début.',
      );
    }

    final result = await _writeVolumes(
      outputDirectory: outputDirectory,
      workDirectory: workDirectory,
      plan: plan,
      startIndex: pending.volumesDone,
      onProgress: onProgress,
      onFraction: onFraction,
      isCancelled: isCancelled,
    );

    await _cleanUpAfterSuccess(workDirectory);
    return result;
  }

  Future<ZipMultiResult> _writeVolumes({
    required Directory outputDirectory,
    required Directory workDirectory,
    required _BuildPlan plan,
    required int startIndex,
    void Function(String message)? onProgress,
    void Function(double fraction)? onFraction,
    bool Function()? isCancelled,
  }) async {
    final groups = plan.groups;
    final manifestFile = File(plan.manifestPath);
    final createdVolumes = <File>[];

    var plannedBytes = 0;
    var writtenBytes = 0;
    for (var i = 0; i < groups.length; i++) {
      for (final entry in groups[i]) {
        plannedBytes += entry.size;
        if (i < startIndex) writtenBytes += entry.size;
      }
    }
    if (plannedBytes <= 0) plannedBytes = 1;

    // Les volumes deja ecrits lors d'une tentative precedente sont conserves.
    for (var i = 0; i < startIndex; i++) {
      createdVolumes.add(File(_volumePath(outputDirectory, plan.baseName, i + 1)));
    }

    for (var i = startIndex; i < groups.length; i++) {
      if (isCancelled?.call() ?? false) throw const ZipMultiCancelled();

      final number = i + 1;
      final volumePath = _volumePath(outputDirectory, plan.baseName, number);
      onProgress?.call('Création du volume $number/${groups.length}…');

      final volumeInfo = <String, Object?>{
        'format': 'ZipMultiVolume',
        'version': formatVersion,
        'setId': plan.setId,
        'baseName': plan.baseName,
        'index': number,
        'count': groups.length,
      };
      final volumeInfoFile =
          await _freshFile(p.join(workDirectory.path, 'volume_$number.json'));
      await volumeInfoFile.writeAsString(jsonEncode(volumeInfo), flush: true);

      final volume = File(volumePath);
      createdVolumes.add(volume);

      final encoder = ZipFileEncoder();
      await _createArchive(encoder, volume);
      await encoder.addFile(manifestFile, manifestName, DeflateLevel.bestSpeed);
      await encoder.addFile(volumeInfoFile, volumeInfoName, DeflateLevel.bestSpeed);
      final readmeFile = File(plan.readmePath);
      if (await readmeFile.exists()) {
        await encoder.addFile(readmeFile, readmeName, DeflateLevel.bestSpeed);
      }
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
      if (actualSize > plan.maxBytes) {
        if (await volume.exists()) await volume.delete();
        throw ZipMultiException(
          'Le volume $number dépasse la limite choisie après création '
          '(${_formatBytes(actualSize)} > ${_formatBytes(plan.maxBytes)}). '
          'Essayez une limite légèrement supérieure.',
        );
      }

      // Point de reprise : ce volume est complet et verifie.
      await _saveResumeState(workDirectory, plan, number);
    }

    onFraction?.call(1);
    return ZipMultiResult(
      volumes: List.unmodifiable(createdVolumes),
      filesProcessed: plan.fileCount,
      integrityVerified: true,
      message: plan.advancedSplit
          ? '${createdVolumes.length} volume(s) créé(s). Le lot contient ${plan.fileCount} fichier(s), avec manifeste de reconstruction et empreintes SHA-256.'
          : '${createdVolumes.length} ZIP standard(s) créé(s). Les fichiers ne sont pas coupés et chaque volume reste ouvrable séparément.',
    );
  }

  String _readmeText(String baseName, int volumeCount, bool advancedSplit) {
    final buffer = StringBuffer()
      ..writeln('ZipMulti — lot « $baseName »')
      ..writeln('')
      ..writeln('Ce partage est composé de $volumeCount fichiers ZIP :')
      ..writeln('  ${baseName}_001.zip … '
          '${baseName}_${volumeCount.toString().padLeft(3, '0')}.zip')
      ..writeln('');

    if (advancedSplit) {
      buffer
        ..writeln('Les fichiers volumineux ont été découpés entre plusieurs')
        ..writeln('volumes. Un décompresseur classique ouvrira chaque ZIP mais')
        ..writeln('ne saura pas recoller les morceaux.')
        ..writeln('')
        ..writeln('POUR RÉCUPÉRER LES FICHIERS D’ORIGINE :')
        ..writeln('  1. Rassemblez les $volumeCount ZIP dans un même dossier.')
        ..writeln('  2. Installez ZipMulti (Android ou Windows) :')
        ..writeln('     https://janintibo-art.github.io/ZipMulti/')
        ..writeln('  3. Ouvrez l’onglet « Reconstruire », choisissez un des ZIP')
        ..writeln('     et lancez. Les fichiers sont réassemblés et vérifiés.')
        ..writeln('')
        ..writeln('Il faut impérativement les $volumeCount volumes : s’il en')
        ..writeln('manque un, la reconstruction est impossible.');
    } else {
      buffer
        ..writeln('Aucun fichier n’a été découpé : chaque ZIP peut être ouvert')
        ..writeln('séparément avec n’importe quel décompresseur.')
        ..writeln('')
        ..writeln('ZipMulti permet aussi de tout extraire d’un coup, avec')
        ..writeln('vérification d’intégrité :')
        ..writeln('  https://janintibo-art.github.io/ZipMulti/');
    }

    return buffer.toString();
  }

  /// Ouvre l'archive en écriture, en absorbant le « File exists » que le
  /// stockage Android renvoie parfois juste après une suppression : le cache du
  /// système de fichiers met un instant à se mettre à jour.
  Future<void> _createArchive(ZipFileEncoder encoder, File volume) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await volume.exists()) {
        try {
          await volume.delete();
        } catch (_) {
          // On tentera quand même l'ouverture ci-dessous.
        }
      }
      try {
        encoder.create(volume.path, level: DeflateLevel.bestSpeed);
        return;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  String _volumePath(Directory directory, String baseName, int number) {
    return p.join(
      directory.path,
      '${baseName}_${number.toString().padLeft(3, '0')}.zip',
    );
  }

  Future<void> _saveResumeState(
    Directory workDirectory,
    _BuildPlan plan,
    int volumesDone,
  ) async {
    final stateFile = File(p.join(workDirectory.path, resumeName));
    await stateFile.writeAsString(
      jsonEncode(plan.toJson(volumesDone)),
      flush: true,
    );
  }

  Future<void> _cleanUpAfterSuccess(Directory workDirectory) async {
    if (await workDirectory.exists()) {
      await workDirectory.delete(recursive: true);
    }
  }

  Future<ZipMultiResult> extractVolumes({
    required List<File> selectedVolumes,
    required Directory destination,
    void Function(String message)? onProgress,
    void Function(double fraction)? onFraction,
    bool Function()? isCancelled,
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
          // Volume illisible : signale plus bas par la lecture elle-meme.
        }
      }
      if (totalVolumeBytes <= 0) totalVolumeBytes = 1;
      var readBytes = 0;
      onFraction?.call(0);

      final acceptedVolumes = <File>[];
      Map<String, dynamic>? manifest;
      String? expectedSetId;
      int? expectedVolumeCount;
      final seenVolumeIndexes = <int>{};

      // Premiere passe : on ne lit que les deux fichiers de metadonnees de
      // chaque volume, sans rien decompresser d'autre. C'est instantane meme
      // sur un lot de plusieurs gigaoctets.
      for (var i = 0; i < volumes.length; i++) {
        final volume = volumes[i];
        onProgress?.call(
          'Lecture du volume ${i + 1}/${volumes.length} : ${p.basename(volume.path)}',
        );
        if (isCancelled?.call() ?? false) throw const ZipMultiCancelled();

        final metadata = await _readVolumeMetadata(volume);
        try {
          readBytes += await volume.length();
        } catch (_) {
          // La progression reste simplement figee pour ce volume.
        }
        onFraction?.call(
          _analysisWeight * (readBytes / totalVolumeBytes).clamp(0.0, 1.0),
        );

        final volumeManifest = metadata.manifest;
        final thisSetId = metadata.setId;
        final thisIndex = metadata.index;
        final thisCount = metadata.count;

        if (expectedSetId != null && thisSetId != null && expectedSetId != thisSetId) {
          // Deux lots peuvent partager le même nom de base dans un même dossier.
          // Quand les voisins ont été trouvés tout seuls, on ignore simplement
          // l'intrus ; quand l'utilisateur les a choisis lui-même, on le prévient.
          if (autoDiscovered) continue;
          throw ZipMultiException(
            'Les ZIP sélectionnés appartiennent à plusieurs lots différents. '
            'Placez uniquement les volumes d’un même partage ensemble.',
          );
        }

        expectedSetId ??= thisSetId;
        manifest ??= volumeManifest;
        expectedVolumeCount ??= thisCount;
        if (thisIndex != null) seenVolumeIndexes.add(thisIndex);
        acceptedVolumes.add(volume);
      }

      volumes = acceptedVolumes..sort(_compareVolumeFiles);
      if (volumes.isEmpty) {
        throw ZipMultiException('Aucun volume exploitable dans la sélection.');
      }

      if (manifest == null) {
        onProgress?.call('ZIP classiques détectés : extraction des fichiers…');
        for (final volume in volumes) {
          if (isCancelled?.call() ?? false) throw const ZipMultiCancelled();
          await extractFileToDisk(volume.path, destination.path);
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

      final files = manifest['files'];
      if (files is! List) {
        throw ZipMultiException('Liste de fichiers absente du manifeste ZipMulti.');
      }

      // Plan de reconstruction : pour chaque entree presente dans les volumes,
      // on sait vers quel fichier de sortie elle va et a quelle position.
      final plan = <String, _RebuildSlot>{};
      final outputs = <String, _RebuildTarget>{};
      var totalOutputBytes = 0;

      for (final raw in files) {
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry(key.toString(), value));
        final name = item['name']?.toString();
        if (name == null || name.trim().isEmpty) continue;
        final safeName = p.basename(name);
        final kind = item['kind']?.toString() ?? 'normal';
        totalOutputBytes += _asInt(item['size']) ?? 0;

        final target = _RebuildTarget(
          file: File(p.join(destination.path, safeName)),
          label: safeName,
          manifestEntry: item,
        );
        outputs[safeName] = target;

        if (kind == 'normal') {
          target.expectedParts = 1;
          plan[name.replaceAll('\\', '/')] =
              _RebuildSlot(target: target, order: 0, info: item);
        } else if (kind == 'chunks') {
          final chunks = item['chunks'];
          if (chunks is! List || chunks.isEmpty) {
            throw ZipMultiException('Aucune partie déclarée pour $safeName.');
          }
          target.expectedParts = chunks.length;
          for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
            final info = _normalizeChunkInfo(chunks[chunkIndex]);
            final chunkPath = info['path']?.toString();
            if (chunkPath == null) {
              throw ZipMultiException('Description de partie invalide pour $safeName.');
            }
            plan[chunkPath.replaceAll('\\', '/')] =
                _RebuildSlot(target: target, order: chunkIndex, info: info);
          }
        } else {
          throw ZipMultiException('Type de fichier ZipMulti inconnu : $kind');
        }
      }

      if (totalOutputBytes <= 0) totalOutputBytes = 1;
      var rebuiltBytes = 0;

      // Deuxieme passe : les volumes sont traites un par un et chaque partie
      // est ecrite directement dans le fichier final. Le disque n'a jamais a
      // heberger le lot entier decompresse, seulement une partie a la fois.
      final scratch = File(p.join(temp.path, 'partie.bin'));
      try {
        for (var i = 0; i < volumes.length; i++) {
          if (isCancelled?.call() ?? false) throw const ZipMultiCancelled();
          onProgress?.call(
            'Assemblage depuis le volume ${i + 1}/${volumes.length}…',
          );

          final input = InputFileStream(volumes[i].path);
          try {
            final archive = ZipDecoder().decodeStream(input);
            for (final entry in archive.files) {
              if (!entry.isFile) continue;
              final entryName = entry.name.replaceAll('\\', '/');
              if (entryName == manifestName ||
                  entryName == volumeInfoName ||
                  entryName == readmeName) {
                continue;
              }
              final slot = plan[entryName];
              if (slot == null) continue;
              if (slot.consumed) {
                throw ZipMultiException('Entrée dupliquée dans le lot : $entryName');
              }
              if (isCancelled?.call() ?? false) throw const ZipMultiCancelled();

              if (slot.order != slot.target.nextPart) {
                throw ZipMultiException(
                  'Les parties de ${slot.target.label} arrivent dans le désordre. '
                  'Vérifiez que tous les volumes du lot sont présents.',
                );
              }

              if (await scratch.exists()) await scratch.delete();
              final output = OutputFileStream(scratch.path);
              entry.writeContent(output);
              await output.close();

              await _verifyFileFromManifest(
                scratch,
                slot.info,
                label: slot.target.expectedParts > 1
                    ? '${slot.target.label} — partie ${slot.order + 1}'
                    : slot.target.label,
              );

              final sink = await slot.target.openSink();
              await sink.addStream(scratch.openRead());
              await scratch.delete();

              slot.consumed = true;
              slot.target.nextPart++;
              rebuiltBytes += _asInt(slot.info['size']) ?? 0;
              final done = (rebuiltBytes / totalOutputBytes).clamp(0.0, 1.0);
              onFraction?.call(
                _analysisWeight + (1 - _analysisWeight) * done,
              );
            }
          } finally {
            await input.close();
          }
        }
      } finally {
        for (final target in outputs.values) {
          await target.closeSink();
        }
        if (await scratch.exists()) await scratch.delete();
      }

      var reconstructed = 0;
      for (final target in outputs.values) {
        if (target.nextPart < target.expectedParts) {
          throw ZipMultiException(
            'Reconstruction impossible : il manque '
            '${target.expectedParts - target.nextPart} partie(s) de '
            '${target.label}.\n\n'
            'Sur Android, si la recherche automatique ne voit pas les fichiers '
            'voisins, sélectionnez tous les ZIP du lot en une seule fois.',
          );
        }
        if (target.expectedParts > 1) {
          await _verifyFileFromManifest(
            target.file,
            target.manifestEntry,
            label: target.label,
          );
        }
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

  /// Lit les deux fichiers de metadonnees d'un volume sans decompresser le
  /// reste de son contenu.
  Future<_VolumeMetadata> _readVolumeMetadata(File volume) async {
    final input = InputFileStream(volume.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      Map<String, dynamic>? manifest;
      String? setId;
      int? index;
      int? count;

      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final name = entry.name.replaceAll('\\', '/');
        if (name != manifestName && name != volumeInfoName) continue;

        final decoded = jsonDecode(utf8.decode(entry.readBytes() ?? <int>[]));
        if (decoded is! Map<String, dynamic>) {
          if (name == manifestName) {
            throw ZipMultiException(
              'Manifeste ZipMulti invalide dans ${p.basename(volume.path)}.',
            );
          }
          continue;
        }

        if (name == manifestName) {
          manifest = decoded;
          setId ??= decoded['setId']?.toString();
          count ??= _asInt(decoded['volumeCount']);
        } else {
          setId ??= decoded['setId']?.toString();
          index = _asInt(decoded['index']);
          count ??= _asInt(decoded['count']);
        }
      }

      return _VolumeMetadata(
        manifest: manifest,
        setId: setId,
        index: index,
        count: count,
      );
    } finally {
      await input.close();
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

/// Levée quand l'utilisateur interrompt volontairement un traitement.
class ZipMultiCancelled implements Exception {
  const ZipMultiCancelled();

  @override
  String toString() => 'Traitement annulé.';
}

/// Plan de fabrication d'un lot, suffisant pour reprendre l'écriture des
/// volumes sans refaire l'analyse ni le découpage.
class _BuildPlan {
  const _BuildPlan({
    required this.setId,
    required this.baseName,
    required this.maxBytes,
    required this.advancedSplit,
    required this.fileCount,
    required this.groups,
    required this.manifestPath,
    required this.readmePath,
    required this.outputPath,
    required this.volumeCount,
  });

  final String setId;
  final String baseName;
  final int maxBytes;
  final bool advancedSplit;
  final int fileCount;
  final List<List<_PlannedEntry>> groups;
  final String manifestPath;
  final String readmePath;
  final String outputPath;
  final int volumeCount;

  Map<String, Object?> toJson(int volumesDone) => <String, Object?>{
        'format': 'ZipMultiReprise',
        'setId': setId,
        'baseName': baseName,
        'maxBytes': maxBytes,
        'advancedSplit': advancedSplit,
        'fileCount': fileCount,
        'manifestPath': manifestPath,
        'readmePath': readmePath,
        'outputPath': outputPath,
        'volumeCount': volumeCount,
        'volumesDone': volumesDone,
        'groups': groups
            .map((group) => group
                .map((entry) => <String, Object?>{
                      'source': entry.source.path,
                      'archiveName': entry.archiveName,
                      'size': entry.size,
                    })
                .toList())
            .toList(),
      };

  static _BuildPlan fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'];
    final groups = <List<_PlannedEntry>>[];
    if (rawGroups is List) {
      for (final rawGroup in rawGroups) {
        final group = <_PlannedEntry>[];
        if (rawGroup is List) {
          for (final rawEntry in rawGroup) {
            if (rawEntry is! Map) continue;
            final source = rawEntry['source']?.toString();
            final archiveName = rawEntry['archiveName']?.toString();
            final size = rawEntry['size'];
            if (source == null || archiveName == null || size is! int) continue;
            group.add(_PlannedEntry(
              source: File(source),
              archiveName: archiveName,
              size: size,
            ));
          }
        }
        groups.add(group);
      }
    }

    return _BuildPlan(
      setId: json['setId']?.toString() ?? '',
      baseName: json['baseName']?.toString() ?? 'partage',
      maxBytes: json['maxBytes'] is int ? json['maxBytes'] as int : 100 * 1024 * 1024,
      advancedSplit: json['advancedSplit'] == true,
      fileCount: json['fileCount'] is int ? json['fileCount'] as int : 0,
      groups: groups,
      manifestPath: json['manifestPath']?.toString() ?? '',
      readmePath: json['readmePath']?.toString() ?? '',
      outputPath: json['outputPath']?.toString() ?? '',
      volumeCount: json['volumeCount'] is int ? json['volumeCount'] as int : groups.length,
    );
  }
}

/// Lot commencé puis interrompu, retrouvé au lancement suivant.
class PendingSet {
  PendingSet._(this.workDirectory, Map<String, dynamic> json)
      : _plan = _BuildPlan.fromJson(json),
        volumesDone = json['volumesDone'] is int ? json['volumesDone'] as int : 0;

  /// Dossier privé contenant l'état et les parties découpées.
  final Directory workDirectory;

  final _BuildPlan _plan;

  /// Dossier où les volumes terminés sont déposés.
  Directory get outputDirectory => Directory(_plan.outputPath);

  /// Nombre de volumes déjà écrits et vérifiés.
  final int volumesDone;

  String get baseName => _plan.baseName;

  int get volumeCount => _plan.volumeCount;

  int get remaining => volumeCount - volumesDone;
}

/// Métadonnées lues à la volée dans un volume, sans le décompresser.
class _VolumeMetadata {
  const _VolumeMetadata({
    this.manifest,
    this.setId,
    this.index,
    this.count,
  });

  final Map<String, dynamic>? manifest;
  final String? setId;
  final int? index;
  final int? count;
}

/// Fichier en cours de reconstruction, alimenté au fil des volumes.
class _RebuildTarget {
  _RebuildTarget({
    required this.file,
    required this.label,
    required this.manifestEntry,
  });

  final File file;
  final String label;
  final Map<String, Object?> manifestEntry;

  /// Nombre de parties attendues : 1 pour un fichier entier.
  int expectedParts = 1;

  /// Prochaine partie attendue ; sert à détecter un lot incomplet ou désordonné.
  int nextPart = 0;

  IOSink? _sink;

  Future<IOSink> openSink() async {
    final existing = _sink;
    if (existing != null) return existing;
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    _sink = sink;
    return sink;
  }

  Future<void> closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) await sink.close();
  }
}

/// Emplacement d'une entrée d'archive dans le fichier qu'elle reconstitue.
class _RebuildSlot {
  _RebuildSlot({
    required this.target,
    required this.order,
    required this.info,
  });

  final _RebuildTarget target;
  final int order;
  final Map<String, Object?> info;
  bool consumed = false;
}
