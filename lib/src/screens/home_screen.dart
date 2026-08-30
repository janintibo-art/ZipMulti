import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/media_index.dart';
import '../services/storage_locations.dart';
import '../services/zip_multi_service.dart';
import 'tutorial_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialZipPaths = const []});

  final List<String> initialZipPaths;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _tutorialSeenKey = 'tutorial_seen_v03';
  static const _pendingDirKey = 'pending_output_dir';
  static const _lastNameKey = 'last_batch_name';
  static const _lastSizeKey = 'last_batch_size_mb';

  final _service = ZipMultiService();
  SharedPreferencesAsync get _preferences => SharedPreferencesAsync();
  final _nameController = TextEditingController(text: 'partage');
  final _sizeController = TextEditingController(text: '100');
  final _extractNameController = TextEditingController(text: 'reconstruit');

  List<File> _files = [];
  int _inputBytes = 0;
  List<File> _zipVolumes = [];
  bool _smartSplit = true;
  bool _busy = false;
  bool _picking = false;
  bool _cancelRequested = false;
  PendingSet? _pending;
  List<File> _lastVolumes = const [];
  String? _lastFolderLabel;
  double? _progress;
  int _section = 0;
  String _status = 'Prêt à créer ou reconstruire un lot ZipMulti.';
  StreamSubscription<List<SharedMediaFile>>? _sharingSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.initialZipPaths.isNotEmpty) {
      _zipVolumes = widget.initialZipPaths.map(File.new).toList();
      _section = 1;
      _status = 'ZIP reçu depuis Windows. Choisissez le dossier de destination puis lancez la reconstruction.';
    }
    unawaited(_listenForIncomingZipShares());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showTutorialOnFirstLaunch());
    });
    unawaited(_lookForPendingSet());
    unawaited(_restorePreferences());
  }


  Future<void> _showTutorialOnFirstLaunch() async {
    try {
      final seen = await _preferences.getBool(_tutorialSeenKey) ?? false;
      if (seen || !mounted) return;
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => const TutorialScreen(firstLaunch: true),
        ),
      );
      if (completed == true) {
        await _preferences.setBool(_tutorialSeenKey, true);
      }
    } catch (_) {
      // Le tutoriel reste accessible manuellement si les préférences sont indisponibles.
    }
  }

  /// Restaure le nom de lot et la taille utilises la fois precedente.
  Future<void> _restorePreferences() async {
    try {
      final name = await _preferences.getString(_lastNameKey);
      final size = await _preferences.getString(_lastSizeKey);
      if (!mounted) return;
      setState(() {
        if (name != null && name.isNotEmpty) _nameController.text = name;
        if (size != null && size.isNotEmpty) _sizeController.text = size;
      });
    } catch (_) {
      // Premiere ouverture ou preferences indisponibles.
    }
  }

  /// Ouvre la feuille de partage du systeme avec les volumes du dernier lot.
  Future<void> _shareLastVolumes() async {
    final volumes = _lastVolumes;
    if (volumes.isEmpty) return;

    final existing = <XFile>[];
    for (final volume in volumes) {
      if (await volume.exists()) existing.add(XFile(volume.path));
    }
    if (!mounted) return;
    if (existing.isEmpty) {
      _show('Les volumes ne sont plus accessibles à cet emplacement.');
      return;
    }

    try {
      await SharePlus.instance.share(
        ShareParams(
          files: existing,
          subject: 'Partage ZipMulti',
          text: TutorialScreen.shareMessage,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _show(
        'Le partage a échoué : $e\n\n'
        'Beaucoup d’applications refusent un envoi de cette taille. '
        'Essayez d’envoyer les volumes par petits groupes depuis votre '
        'gestionnaire de fichiers.',
      );
    }
  }

  /// Un lot interrompu laisse son etat dans son dossier de sortie ; on retient
  /// ce chemin dans les preferences pour le retrouver au lancement suivant.
  Future<void> _lookForPendingSet() async {
    try {
      final path = await _preferences.getString(_pendingDirKey);
      if (path == null || path.isEmpty) return;
      final pending = await _service.findPending(Directory(path));
      if (!mounted) return;
      if (pending == null) {
        await _preferences.remove(_pendingDirKey);
        return;
      }
      setState(() => _pending = pending);
    } catch (_) {
      // Aucune reprise possible : l'application demarre normalement.
    }
  }

  Future<void> _resumePending() async {
    final pending = _pending;
    if (pending == null) return;

    setState(() {
      _busy = true;
      _cancelRequested = false;
      _progress = 0;
      _status = 'Reprise du lot « ${pending.baseName} »…';
    });

    try {
      final result = await _service.resumePending(
        pending,
        onProgress: (message) {
          if (mounted) setState(() => _status = message);
        },
        onFraction: (fraction) {
          if (mounted) setState(() => _progress = fraction);
        },
        isCancelled: () => _cancelRequested,
      );
      await _preferences.remove(_pendingDirKey);
      await MediaIndex.announceDirectory(pending.outputDirectory);
      if (!mounted) return;
      setState(() {
        _pending = null;
        _status = result.message;
        _lastVolumes = result.volumes;
        _lastFolderLabel = StorageLocations.describe(pending.outputDirectory);
      });
      _show(
        '${result.message}\n\n'
        'Dossier : ${StorageLocations.describe(pending.outputDirectory)}',
        offerCopyInstructions: true,
      );
    } on ZipMultiCancelled {
      if (mounted) {
        setState(() => _status = 'Reprise interrompue. Le lot reste disponible.');
      }
    } on ZipMultiException catch (e) {
      if (mounted) {
        setState(() => _pending = null);
        _show(e.message);
      }
      await _preferences.remove(_pendingDirKey);
    } catch (e) {
      if (mounted) _show('Erreur inattendue : $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _discardPending() async {
    final pending = _pending;
    if (pending == null) return;
    try {
      await _service.discardPending(pending.outputDirectory);
    } catch (_) {
      // Le dossier a peut-etre deja ete nettoye a la main.
    }
    await _preferences.remove(_pendingDirKey);
    if (!mounted) return;
    setState(() {
      _pending = null;
      _status = 'Lot inachevé abandonné.';
    });
  }

  Future<void> _openTutorial() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const TutorialScreen(),
      ),
    );
  }

  Future<void> _listenForIncomingZipShares() async {
    if (!Platform.isAndroid) return;

    _sharingSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      _acceptIncomingShares,
      onError: (_) {},
    );

    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      _acceptIncomingShares(initial);
      await ReceiveSharingIntent.instance.reset();
    } catch (_) {
      // L'application reste utilisable avec le sélecteur de fichiers classique.
    }
  }

  void _acceptIncomingShares(List<SharedMediaFile> shared) {
    final zipFiles = shared
        .map((item) => item.path)
        .where((path) => path.toLowerCase().endsWith('.zip'))
        .map(File.new)
        .where((file) => file.existsSync())
        .toList();

    if (zipFiles.isEmpty || !mounted) return;
    setState(() {
      _zipVolumes = zipFiles;
      _section = 1;
      _status = zipFiles.length == 1
          ? 'ZIP reçu depuis Android. Choisissez le dossier de destination puis lancez la reconstruction.'
          : '${zipFiles.length} ZIP reçus depuis Android et prêts à être reconstruits.';
    });
  }

  @override
  void dispose() {
    final subscription = _sharingSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    _nameController.dispose();
    _sizeController.dispose();
    _extractNameController.dispose();
    super.dispose();
  }

  Future<void> _pickInputFiles() async {
    setState(() {
      _picking = true;
      _status = 'Sélection en cours, patientez…';
    });
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choisir les fichiers à compresser',
      allowMultiple: true,
      withData: false,
    );
    final paths = picked.map((f) => f.path).whereType<String>().toList();
    final files = paths.map(File.new).toList();
    final bytes = await _measure(files);
    if (!mounted) return;
    setState(() {
      _picking = false;
      _files = files;
      _inputBytes = bytes;
      _status = '${files.length} fichier(s) sélectionné(s) — ${_formatBytes(bytes)}.';
    });
  }

  Future<void> _pickZipVolumes() async {
    setState(() {
      _picking = true;
      _status = 'Sélection en cours, patientez…';
    });
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choisir un ZIP du lot ou plusieurs volumes',
      allowMultiple: true,
      withData: false,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final paths = picked.map((f) => f.path).whereType<String>().toList();
    if (!mounted) return;
    setState(() {
      _picking = false;
      _zipVolumes = paths.map(File.new).toList();
      _status = _zipVolumes.length == 1
          ? 'Un volume choisi. ZipMulti recherchera automatiquement les autres dans le même dossier.'
          : '${_zipVolumes.length} volumes sélectionnés pour la reconstruction.';
    });
  }

  Future<void> _compress() async {
    if (_files.isEmpty) {
      _show('Sélectionnez au moins un fichier.');
      return;
    }
    final mb = double.tryParse(_sizeController.text.replaceAll(',', '.'));
    if (mb == null || mb <= 0) {
      _show('La taille maximale par ZIP est invalide.');
      return;
    }

    setState(() {
      _busy = true;
      _cancelRequested = false;
      _progress = 0;
      _status = 'Préparation du lot…';
    });

    try {
      final target = await StorageLocations.prepare(_nameController.text);
      await _preferences.setString(_pendingDirKey, target.directory.path);
      await _preferences.setString(_lastNameKey, _nameController.text.trim());
      await _preferences.setString(_lastSizeKey, _sizeController.text.trim());
      final result = await _service.createVolumes(
        files: _files,
        outputDirectory: target.directory,
        baseName: _nameController.text,
        maxBytes: (mb * 1024 * 1024).round(),
        advancedSplit: _smartSplit,
        onProgress: (message) {
          if (mounted) setState(() => _status = message);
        },
        onFraction: (fraction) {
          if (mounted) setState(() => _progress = fraction);
        },
        isCancelled: () => _cancelRequested,
      );
      await _preferences.remove(_pendingDirKey);
      await MediaIndex.announceDirectory(target.directory);
      if (!mounted) return;
      setState(() {
        _status = result.message;
        _lastVolumes = result.volumes;
        _lastFolderLabel = StorageLocations.describe(target.directory);
      });
      _show(
        '${result.message}\n\n'
        'Dossier : ${StorageLocations.describe(target.directory)}\n'
        '${_locationNote(target)}\n'
        'Vous pouvez envoyer tous les ZIP du lot. Le destinataire pourra sélectionner '
        'n’importe lequel dans ZipMulti v0.3 pour lancer la reconstruction.',
        offerCopyInstructions: true,
      );
    } on ZipMultiCancelled {
      await _lookForPendingSet();
      if (mounted) {
        setState(() => _status = 'Création interrompue. Vous pourrez reprendre.');
      }
    } on ZipMultiException catch (e) {
      if (mounted) _show(e.message);
    } catch (e) {
      await _lookForPendingSet();
      if (mounted) _show('Erreur inattendue : $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _extract() async {
    if (_zipVolumes.isEmpty) {
      _show('Sélectionnez au moins un ZIP du lot.');
      return;
    }

    setState(() {
      _busy = true;
      _cancelRequested = false;
      _progress = 0;
      _status = 'Analyse du lot et recherche des volumes…';
    });

    try {
      // Les fichiers reconstruits peuvent être de n'importe quel type ; on
      // vérifie donc que les médias passent avant de choisir l'emplacement.
      final target = await StorageLocations.prepare(
        _extractNameController.text,
        probeExtensions: const ['.jpg', '.mp4', '.mp3', '.zip'],
      );
      final result = await _service.extractVolumes(
        selectedVolumes: _zipVolumes,
        destination: target.directory,
        onProgress: (message) {
          if (mounted) setState(() => _status = message);
        },
        onFraction: (fraction) {
          if (mounted) setState(() => _progress = fraction);
        },
        isCancelled: () => _cancelRequested,
      );
      await MediaIndex.announceDirectory(target.directory);
      if (!mounted) return;
      setState(() => _status = result.message);
      _show(
        '${result.message}\n\n'
        'Destination : ${StorageLocations.describe(target.directory)}\n'
        '${_locationNote(target)}\n'
        '${result.integrityVerified ? 'Intégrité vérifiée : OK.' : 'Extraction terminée.'}',
      );
    } on ZipMultiCancelled {
      if (mounted) setState(() => _status = 'Reconstruction interrompue.');
    } on ZipMultiException catch (e) {
      if (mounted) _show(e.message);
    } catch (e) {
      if (mounted) _show('Erreur inattendue : $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// Explique, le cas échéant, pourquoi le dossier n'est pas exactement
  /// celui que l'utilisateur attendait.
  String _locationNote(ResolvedDirectory target) {
    final notes = <String>[];
    if (target.renamed) {
      notes.add('Un lot du même nom existait déjà : un suffixe a été ajouté.');
    }
    if (target.isFallback) {
      notes.add(
        'Android a refusé l’écriture dans Téléchargements, le lot a été placé '
        'dans l’espace réservé à ZipMulti.',
      );
    }
    return notes.isEmpty ? '' : '\n${notes.join('\n')}\n';
  }

  /// Mesure les fichiers une seule fois, au moment de la sélection.
  /// Appeler lengthSync() depuis build() bloquait le thread UI à chaque image.
  Future<int> _measure(List<File> files) async {
    var total = 0;
    for (final file in files) {
      try {
        total += await file.length();
      } catch (_) {
        // Un fichier devenu inaccessible sera ignoré ici puis contrôlé par le service.
      }
    }
    return total;
  }

  int get _totalInputBytes => _inputBytes;

  int? get _estimatedVolumes {
    final mb = double.tryParse(_sizeController.text.replaceAll(',', '.'));
    if (mb == null || mb <= 0 || _totalInputBytes <= 0) return null;
    final safePayload = mb * 1024 * 1024 * 0.82;
    return max(1, (_totalInputBytes / safePayload).ceil());
  }

  /// Remplace l'icone du bouton par un rond de progression pendant l'import
  /// Android, qui peut durer plusieurs minutes sur un gros lot.
  Widget _pickingSpinner(Widget icon) {
    if (!_picking) return icon;
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2.2),
    );
  }

  void _setPreset(int mb) {
    _sizeController.text = '$mb';
    setState(() {
      _status = 'Taille maximale réglée à $mb Mo par ZIP.';
    });
  }

  void _show(String text, {bool offerCopyInstructions = false}) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.folder_zip_rounded),
            SizedBox(width: 10),
            Text('ZipMulti v0.3'),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SelectableText(text),
        ),
        actions: [
          if (offerCopyInstructions)
            TextButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(dialogContext);
                final navigator = Navigator.of(dialogContext);
                await Clipboard.setData(
                  const ClipboardData(text: TutorialScreen.shareMessage),
                );
                navigator.pop();
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Instructions destinataire copiées.'),
                  ),
                );
              },
              icon: const Icon(Icons.copy_all_rounded),
              label: const Text('Copier les instructions'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF080A10),
              Color(0xFF101326),
              Color(0xFF0B0D15),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1020),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                children: [
                  _topBar(),
                  if (_pending != null) ...[
                    const SizedBox(height: 14),
                    _pendingBanner(_pending!),
                  ],
                  const SizedBox(height: 18),
                  _hero(),
                  const SizedBox(height: 18),
                  _sectionSwitcher(),
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    child: _section == 0
                        ? _compressionCard(key: const ValueKey('create'))
                        : _rebuildCard(key: const ValueKey('rebuild')),
                  ),
                  const SizedBox(height: 14),
                  _statusCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: [Color(0xFF8B5CF6), Color(0xFF38BDF8)],
            ),
          ),
          child: const Icon(Icons.folder_zip_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ZipMulti',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: .2,
                    ),
              ),
              Text(
                'v0.3 • Android + Windows',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white60,
                    ),
              ),
            ],
          ),
        ),
        IconButton.filledTonal(
          onPressed: _busy ? null : _openTutorial,
          tooltip: 'Tutoriel et aide',
          icon: const Icon(Icons.help_outline_rounded),
        ),
        if (MediaQuery.sizeOf(context).width > 560) ...[
          const SizedBox(width: 8),
          const _Badge(icon: Icons.verified_user_outlined, text: 'SHA-256'),
        ],
      ],
    );
  }

  Widget _hero() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .09)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF7C3AED).withValues(alpha: .28),
            const Color(0xFF0284C7).withValues(alpha: .14),
            Colors.white.withValues(alpha: .035),
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 680;
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Découpez. Envoyez. Reconstruisez.',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Créez des ZIP à la taille que vous choisissez. Les gros fichiers peuvent '
                'être fractionnés, puis reconstruits automatiquement à l’arrivée avec '
                'contrôle d’intégrité.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.white70,
                      height: 1.45,
                    ),
              ),
            ],
          );
          final chips = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              _Badge(icon: Icons.phone_android, text: 'Android'),
              _Badge(icon: Icons.desktop_windows_outlined, text: 'Windows'),
              _Badge(icon: Icons.auto_awesome, text: 'Reconstruction auto'),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 16), chips],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 24),
              SizedBox(width: 230, child: chips),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionSwitcher() {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment<int>(
          value: 0,
          icon: Icon(Icons.call_split_rounded),
          label: Text('Créer un lot'),
        ),
        ButtonSegment<int>(
          value: 1,
          icon: Icon(Icons.merge_type_rounded),
          label: Text('Reconstruire'),
        ),
      ],
      selected: {_section},
      onSelectionChanged: _busy
          ? null
          : (selection) => setState(() => _section = selection.first),
      showSelectedIcon: false,
    );
  }

  Widget _compressionCard({Key? key}) {
    final estimate = _estimatedVolumes;
    return _Panel(
      key: key,
      title: 'Créer des volumes ZIP',
      subtitle: 'Les volumes restent des fichiers .zip standards. En mode intelligent, les gros fichiers sont découpés en parties reconstructibles.',
      icon: Icons.call_split_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: (_busy || _picking) ? null : _pickInputFiles,
                icon: _pickingSpinner(const Icon(Icons.add_rounded)),
                label: Text(
                  _picking
                      ? 'Import en cours…'
                      : _files.isEmpty
                          ? 'Ajouter des fichiers'
                          : '${_files.length} fichier(s)',
                ),
              ),
            ],
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 12),
            _infoStrip(
              icon: Icons.data_usage_rounded,
              text: '${_files.length} fichier(s) • ${_formatBytes(_totalInputBytes)}'
                  '${estimate == null ? '' : ' • environ $estimate volume(s)'}',
            ),
          ],
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final name = TextField(
                controller: _nameController,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Nom du lot et du dossier',
                  prefixIcon: const Icon(Icons.drive_file_rename_outline),
                  hintText: 'partage',
                  helperMaxLines: 2,
                  helperText: 'Téléchargements / '
                      '${StorageLocations.sanitizeFolderName(_nameController.text)} /',
                ),
                onChanged: (_) => setState(() {}),
              );
              final size = TextField(
                controller: _sizeController,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Taille max / ZIP (Mo)',
                  prefixIcon: Icon(Icons.straighten_rounded),
                  hintText: '100',
                ),
              );
              if (compact) {
                return Column(
                  children: [name, const SizedBox(height: 12), size],
                );
              }
              return Row(
                children: [
                  Expanded(flex: 2, child: name),
                  const SizedBox(width: 12),
                  Expanded(child: size),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [25, 100, 250, 500, 1024]
                .map(
                  (mb) => ActionChip(
                    avatar: const Icon(Icons.bolt_rounded, size: 18),
                    label: Text('$mb Mo'),
                    onPressed: _busy ? null : () => _setPreset(mb),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _smartSplit,
            onChanged: _busy ? null : (value) => setState(() => _smartSplit = value),
            title: const Text('Fractionnement intelligent'),
            subtitle: const Text(
              'Si un fichier dépasse la limite choisie, il est découpé puis pourra être reconstruit automatiquement par ZipMulti.',
            ),
            secondary: const Icon(Icons.auto_fix_high_rounded),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _compress,
            icon: const Icon(Icons.folder_zip_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Créer le lot ZIP'),
            ),
          ),
          if (_lastVolumes.isNotEmpty) ...[
            const SizedBox(height: 14),
            _infoStrip(
              icon: Icons.check_circle_outline_rounded,
              text: '${_lastVolumes.length} volume(s) prêt(s)'
                  '${_lastFolderLabel == null ? '' : ' dans $_lastFolderLabel'}.',
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _shareLastVolumes,
              icon: const Icon(Icons.ios_share_rounded),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('Envoyer les volumes'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rebuildCard({Key? key}) {
    return _Panel(
      key: key,
      title: 'Reconstruire automatiquement',
      subtitle: 'Sélectionnez n’importe quel volume du lot. ZipMulti tente de retrouver les autres, vérifie les parties et recompose les fichiers originaux.',
      icon: Icons.merge_type_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: (_busy || _picking) ? null : _pickZipVolumes,
                icon: _pickingSpinner(const Icon(Icons.folder_zip_outlined)),
                label: Text(
                  _picking
                      ? 'Import en cours…'
                      : _zipVolumes.isEmpty
                          ? 'Choisir un ZIP du lot'
                          : '${_zipVolumes.length} ZIP sélectionné(s)',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _extractNameController,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Nom du dossier de destination',
              prefixIcon: const Icon(Icons.drive_file_rename_outline),
              hintText: 'reconstruit',
              helperMaxLines: 2,
              helperText: 'Téléchargements / '
                  '${StorageLocations.sanitizeFolderName(_extractNameController.text)} /',
            ),
          ),
          const SizedBox(height: 14),
          _infoStrip(
            icon: Icons.info_outline_rounded,
            text: 'Sur Windows, un seul volume suffit généralement. Sur Android, selon le sélecteur de fichiers, il peut être nécessaire de sélectionner tous les ZIP du lot en une fois.',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _featureTile(
                  Icons.search_rounded,
                  'Détection',
                  'Recherche des volumes voisins',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _featureTile(
                  Icons.shield_outlined,
                  'Contrôle',
                  'Taille + SHA-256',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _featureTile(
                  Icons.merge_rounded,
                  'Fusion',
                  'Reconstruction automatique',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _extract,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Reconstruire maintenant'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .045),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: .07)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_busy || _picking)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          else
            const Icon(Icons.terminal_rounded, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (_busy || _picking) ? 'Traitement en cours' : 'État',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  _status,
                  style: const TextStyle(color: Colors.white70, height: 1.35),
                ),
                if (_busy) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _cancelRequested
                          ? null
                          : () => setState(() {
                                _cancelRequested = true;
                                _status = 'Interruption demandée…';
                              }),
                      icon: const Icon(Icons.stop_circle_outlined, size: 20),
                      label: Text(
                        _cancelRequested ? 'Interruption en cours…' : 'Annuler',
                      ),
                    ),
                  ),
                ],
                if (_busy && _progress != null) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      // null pendant les phases non mesurables : la barre
                      // defile alors au lieu d'afficher un faux pourcentage.
                      value: _progress,
                      minHeight: 7,
                      backgroundColor: Colors.white.withValues(alpha: .09),
                    ),
                  ),
                  if (_progress != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${(_progress! * 100).round()} %',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingBanner(PendingSet pending) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFFFBBF24).withValues(alpha: .10),
        border: Border.all(color: const Color(0xFFFBBF24).withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, color: Color(0xFFFCD34D)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Lot inachevé : « ${pending.baseName} »',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${pending.volumesDone} volume(s) sur ${pending.volumeCount} sont déjà '
            'écrits. Il en reste ${pending.remaining} à produire.',
            style: const TextStyle(color: Colors.white70, height: 1.35),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _resumePending,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Reprendre'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _discardPending,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Abandonner'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoStrip({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: .04),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.white70),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureTile(IconData icon, String title, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: .055)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
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

class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF121521).withValues(alpha: .94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: .075)),
        boxShadow: [
          BoxShadow(
            blurRadius: 35,
            spreadRadius: -18,
            color: Colors.black.withValues(alpha: .7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  color: const Color(0xFF8B5CF6).withValues(alpha: .16),
                ),
                child: Icon(icon, color: const Color(0xFFC4B5FD)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.white60, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: .065),
        border: Border.all(color: Colors.white.withValues(alpha: .07)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
