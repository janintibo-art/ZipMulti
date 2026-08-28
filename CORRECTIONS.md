# Analyse et corrections — ZipMulti v0.3

Revue complète du code livré, des dépendances, de la CI et de l'installeur.

## Ce qui allait déjà bien

Les points suivants ont été vérifiés et sont corrects, y compris par rapport aux
API réelles des paquets utilisés :

- `FilePicker.pickFiles()` / `FilePicker.getDirectoryPath()` en appels statiques
  retournant `List<PlatformFile>` : conforme à file_picker 12.x, qui a supprimé
  `FilePickerResult` et `FilePicker.platform`.
- `ZipFileEncoder.create(path, level:)` et `addFile(file, name, level)` avec des
  niveaux `DeflateLevel` : conforme à archive 4.2.
- `ReceiveSharingIntent.instance.getMediaStream() / getInitialMedia() / reset()` :
  conforme à receive_sharing_intent 1.9.
- `SharedPreferencesAsync` : conforme à shared_preferences 2.5.
- Le manifeste, l'identifiant de lot, les SHA-256 par partie et par fichier
  original, et la réduction des chemins de sortie à `p.basename` (protection
  contre l'écriture hors du dossier de destination).
- La compatibilité ascendante v1 via `_normalizeChunkInfo`.

## Corrections appliquées

### 1. Un volume pouvait dépasser la taille demandée — `zip_multi_service.dart`

Le budget de remplissage d'un volume était `payloadTarget = 0,82 × maxBytes`,
mais le manifeste, recopié **dans chaque volume**, n'était jamais déduit de ce
budget. Le garde-fou autorisait par ailleurs un manifeste allant jusqu'à
`maxBytes / 4`, soit 25 % : `82 % + 25 % = 107 %`. Sur un lot contenant beaucoup
de fichiers, le contrôle final `actualSize > maxBytes` se déclenchait, tous les
volumes déjà écrits étaient supprimés, et la création échouait après avoir
travaillé plusieurs minutes.

Le manifeste est désormais sérialisé une première fois pour être mesuré, sa
taille et une marge d'en-têtes sont retirées du budget de regroupement, et le
garde-fou est passé à `maxBytes / 8`. Le pire cas théorique retombe à environ
95 % de la limite.

### 2. Saturation mémoire sur les gros fichiers — `zip_multi_service.dart`

Le découpage faisait `chunkSink.add(...)` en boucle sans jamais appeler `flush`.
`IOSink` accepte les octets bien plus vite que le disque ne les écrit, donc la
lecture prenait de l'avance sur l'écriture et l'écart s'accumulait en mémoire.
Sur un téléphone, un fichier de plusieurs Go finissait par faire tuer le
processus par Android. Un `flush` est maintenant forcé tous les 8 Mo.

### 3. Deux lots homonymes dans un même dossier — `zip_multi_service.dart`

`discoverSiblingVolumes` ramasse tous les fichiers `nom_###.zip` du dossier. Si
deux partages successifs portaient le nom `partage`, la découverte automatique
mélangeait les deux séries et la reconstruction s'arrêtait sur « les ZIP
appartiennent à plusieurs lots différents » — alors que l'utilisateur n'avait
sélectionné qu'un seul fichier et n'avait rien fait de mal.

Deux changements : le volume réellement choisi est traité en premier et sert de
référence pour l'identifiant de lot ; et quand les voisins ont été trouvés
automatiquement, les intrus sont silencieusement écartés au lieu de faire
échouer l'opération. Le message d'erreur reste inchangé lorsque c'est
l'utilisateur qui a sélectionné des fichiers incompatibles.

### 4. Reste d'un lot précédent — `zip_multi_service.dart`

Recréer un lot de 3 volumes dans un dossier qui en contenait 5 laissait
`partage_004.zip` et `partage_005.zip` sur place. Le destinataire recevait un
mélange indémêlable. La création refuse maintenant de démarrer et explique quoi
supprimer.

### 5. `flutter analyze` en échec sur la CI — `home_screen.dart`

Dans la boîte de dialogue, `Navigator.pop(dialogContext)` et
`ScaffoldMessenger.of(context)` étaient appelés après un `await`, protégés par
`if (!mounted)`. Ce garde-fou porte sur le `State`, pas sur `dialogContext` :
la règle `use_build_context_synchronously` se déclenche, et `flutter analyze`
retourne un code d'erreur, ce qui arrête le workflow avant la compilation. Le
`Navigator` et le `ScaffoldMessenger` sont désormais capturés avant l'`await`.

### 6. Lecture disque synchrone dans `build()` — `home_screen.dart`

`_totalInputBytes` appelait `lengthSync()` sur chaque fichier sélectionné, et
était lu depuis `build()` via `_estimatedVolumes`. Avec 200 fichiers, chaque
image de l'interface déclenchait 200 accès disque bloquants sur le thread UI.
La taille totale est maintenant mesurée une seule fois, en asynchrone, au moment
de la sélection.

### 7. `flutter create` régénérait un test cassé — `build.yml`

`flutter create .` recrée les fichiers manquants du modèle, dont
`test/widget_test.dart`, qui référence une classe `MyApp` inexistante ici. Les
étapes `flutter analyze` et `flutter test` échouaient donc systématiquement sur
un dépôt neuf. Le fichier est supprimé juste après la génération, sur les deux
jobs. `flutter analyze --no-fatal-infos` évite en plus qu'une simple suggestion
de style ne bloque une compilation.

### 8. Divers

- Suppression du paramètre mort `excludeZipMultiInternals`, toujours appelé
  avec `false`.
- `.gitignore` : ajout de `installer/output/`, suppression d'un doublon.

## Limites connues, non corrigées

Elles ne sont pas des bugs mais méritent d'être connues avant la v0.4 :

- **Espace disque à la reconstruction.** `extractVolumes` décompresse *tous* les
  volumes dans le dossier temporaire avant d'assembler, puis recopie vers la
  destination. Il faut donc environ deux fois la taille du lot en espace libre.
  Un traitement volume par volume, en flux, supprimerait ce coût.
- **Fichiers homonymes.** Deux fichiers portant le même nom mais venant de
  dossiers différents sont renommés (`photo-2.jpg`) et le nom d'origine n'est
  pas conservé dans le manifeste.
- **Partage Android.** Un fichier reçu via « Partager » arrive dans le cache de
  l'application : la recherche des volumes voisins ne peut pas fonctionner dans
  ce cas, il faut sélectionner tous les ZIP à la main. C'est une contrainte
  d'Android, pas un défaut du code.
- **Aucune signature APK.** Le workflow produit un APK signé avec la clé de
  débogage par défaut.
