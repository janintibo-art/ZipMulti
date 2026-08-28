import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key, this.firstLaunch = false});

  static const shareMessage = '''Pour reconstruire les fichiers que je t’envoie :
1. Mets tous les fichiers .zip du lot dans le même dossier.
2. Ouvre ZipMulti, puis va dans « Reconstruire ».
3. Choisis un ZIP du lot (ou tous les ZIP sur Android si nécessaire), choisis le dossier de destination et appuie sur « Reconstruire maintenant ».

Important : garde tous les ZIP du lot et ne renomme pas les volumes avant la reconstruction.''';

  final bool firstLaunch;

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  static const _pages = <_TutorialPageData>[
    _TutorialPageData(
      icon: Icons.auto_awesome_rounded,
      title: 'Bienvenue dans ZipMulti',
      subtitle: 'Créer, partager et reconstruire de gros fichiers devient beaucoup plus simple.',
      bullets: [
        'Choisissez vous-même la taille maximale de chaque ZIP.',
        'ZipMulti peut découper un fichier trop gros entre plusieurs volumes.',
        'À l’arrivée, ZipMulti retrouve les morceaux et reconstruit le fichier original.',
      ],
    ),
    _TutorialPageData(
      icon: Icons.call_split_rounded,
      title: '1. Créer un lot',
      subtitle: 'Dans « Créer un lot », préparez les fichiers à envoyer.',
      bullets: [
        'Appuyez sur « Ajouter des fichiers » et sélectionnez vos fichiers.',
        'Choisissez le dossier de sortie.',
        'Donnez un nom au lot et choisissez la taille maximale de chaque ZIP.',
        'Laissez « Fractionnement intelligent » activé pour les très gros fichiers.',
        'Appuyez sur « Créer le lot ZIP ».',
      ],
    ),
    _TutorialPageData(
      icon: Icons.send_rounded,
      title: '2. Envoyer le lot',
      subtitle: 'Envoyez toujours tous les volumes créés ensemble.',
      bullets: [
        'Exemple : partage_001.zip, partage_002.zip, partage_003.zip…',
        'Ne supprimez aucun volume : chaque morceau peut être nécessaire.',
        'Évitez de renommer les ZIP avant la reconstruction automatique.',
        'Le plus simple est de placer tous les ZIP dans le même dossier chez le destinataire.',
      ],
    ),
    _TutorialPageData(
      icon: Icons.merge_type_rounded,
      title: '3. Reconstruire',
      subtitle: 'Le destinataire n’a pas besoin d’un outil d’assemblage supplémentaire.',
      bullets: [
        'Ouvrez ZipMulti puis choisissez « Reconstruire ».',
        'Sélectionnez un ZIP du lot. Sur Windows, ZipMulti cherchera les autres automatiquement.',
        'Sur certains téléphones Android, sélectionnez tous les ZIP du lot en une seule fois.',
        'Choisissez le dossier de destination puis appuyez sur « Reconstruire maintenant ».',
        'ZipMulti vérifie les tailles et les empreintes SHA-256 avant de terminer.',
      ],
    ),
    _TutorialPageData(
      icon: Icons.phone_android_rounded,
      title: 'Android et Windows',
      subtitle: 'Quelques différences à connaître selon l’appareil.',
      bullets: [
        'Android : vous pouvez partager ou ouvrir un ZIP avec ZipMulti depuis un gestionnaire de fichiers compatible.',
        'Android : si les ZIP voisins ne sont pas visibles, sélectionnez tous les volumes manuellement.',
        'Windows : un clic droit sur un ZIP peut proposer « Reconstruire avec ZipMulti » après installation.',
        'Un ZIP standard reste ouvrable avec les outils classiques, mais un gros fichier fractionné doit être reconstruit par ZipMulti.',
      ],
    ),
    _TutorialPageData(
      icon: Icons.build_circle_outlined,
      title: 'En cas de problème',
      subtitle: 'Les messages de ZipMulti indiquent généralement exactement ce qui manque.',
      bullets: [
        '« Lot incomplet » : vérifiez que tous les ZIP ont bien été reçus.',
        '« SHA-256 échoué » : un volume est probablement incomplet ou corrompu, renvoyez-le.',
        'Deux lots mélangés : replacez chaque série de ZIP dans son propre dossier.',
        'Conservez les noms des volumes jusqu’à la reconstruction.',
      ],
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_page >= _pages.length - 1) {
      Navigator.of(context).pop(true);
      return;
    }
    await _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _previous() async {
    if (_page == 0) return;
    await _controller.previousPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _copyShareMessage() async {
    await Clipboard.setData(const ClipboardData(text: TutorialScreen.shareMessage));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message d’explication copié.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.firstLaunch ? 'Premiers pas' : 'Tutoriel et aide'),
        actions: [
          if (widget.firstLaunch)
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Passer'),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _pages.length,
                    onPageChanged: (value) => setState(() => _page = value),
                    itemBuilder: (context, index) {
                      final data = _pages[index];
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                        child: _TutorialPage(
                          data: data,
                          showShareMessage: index == _pages.length - 1,
                          onCopyShareMessage: _copyShareMessage,
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          _pages.length,
                          (index) => AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: index == _page ? 26 : 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(99),
                              color: index == _page
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white24,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _page == 0 ? null : _previous,
                              icon: const Icon(Icons.arrow_back_rounded),
                              label: const Text('Précédent'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _next,
                              icon: Icon(
                                isLast ? Icons.check_rounded : Icons.arrow_forward_rounded,
                              ),
                              label: Text(isLast ? 'J’ai compris' : 'Suivant'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TutorialPage extends StatelessWidget {
  const _TutorialPage({
    required this.data,
    required this.showShareMessage,
    required this.onCopyShareMessage,
  });

  final _TutorialPageData data;
  final bool showShareMessage;
  final VoidCallback onCopyShareMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 82,
          height: 82,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              colors: [Color(0xFF7C3AED), Color(0xFF0284C7)],
            ),
          ),
          child: Icon(data.icon, size: 42, color: Colors.white),
        ),
        const SizedBox(height: 22),
        Text(
          data.title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          data.subtitle,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.white70,
                height: 1.45,
              ),
        ),
        const SizedBox(height: 22),
        ...data.bullets.map(
          (text) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: .16),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showShareMessage) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .045),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: .08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.content_copy_rounded),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Explication prête à envoyer',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  TutorialScreen.shareMessage,
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onCopyShareMessage,
                  icon: const Icon(Icons.copy_all_rounded),
                  label: const Text('Copier le message'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _TutorialPageData {
  const _TutorialPageData({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.bullets,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> bullets;
}
