# ZipMulti v0.3

ZipMulti est une application Flutter Android + Windows qui crée des lots de ZIP avec une taille maximale choisie et sait reconstruire automatiquement les fichiers fractionnés.

## Nouveautés v0.3

- **tutoriel embarqué en 6 étapes** au premier lancement ;
- bouton **Tutoriel et aide** accessible à tout moment depuis l'écran principal ;
- mémorisation locale du tutoriel déjà vu ;
- page spéciale Android / Windows ;
- rubrique **Problèmes fréquents** ;
- **message d'explication prêt à copier** et à envoyer avec les ZIP ;
- interface principale adaptée aux petits écrans pour conserver le bouton d'aide visible ;
- conservation de toutes les fonctions v0.2 : fractionnement, reconstruction, détection des volumes, SHA-256, Android et Windows.

Le tutoriel utilise `shared_preferences` uniquement pour mémoriser localement qu'il a déjà été affiché. Aucune donnée de fichier ou contenu d'archive n'y est enregistrée.

## Fonctionnement du fractionnement

Exemple avec une limite de 100 Mo :

```text
partage_001.zip
partage_002.zip
partage_003.zip
...
```

Chaque élément est un vrai fichier ZIP. Pour un petit fichier, ZipMulti le stocke normalement dans un volume. Pour un fichier plus gros que la limite, ZipMulti le découpe en parties internes et enregistre dans chaque ZIP un manifeste décrivant comment reconstituer le fichier original.

À la réception :

1. placer les ZIP du lot ensemble ;
2. ouvrir ZipMulti ;
3. aller dans **Reconstruire** ;
4. sélectionner un ZIP du lot, ou tous les volumes sur Android si le sélecteur ne permet pas l'accès aux voisins ;
5. choisir le dossier de destination ;
6. lancer **Reconstruire maintenant**.

ZipMulti contrôle les volumes, vérifie les empreintes SHA-256, assemble les parties dans le bon ordre et recrée le fichier original.

Le guide complet se trouve dans [`docs/UTILISATION.md`](docs/UTILISATION.md).

## Important : compatibilité avec les décompresseurs classiques

Le mode sans fractionnement individuel produit des ZIP classiques indépendants, lisibles par les outils Android/Windows habituels.

Quand **un seul gros fichier est coupé entre plusieurs volumes**, un décompresseur ZIP classique peut ouvrir chaque ZIP, mais il ne connaît pas le protocole ZipMulti et ne peut pas recréer automatiquement le fichier original. La reconstruction automatique est donc faite directement par ZipMulti v0.3.

## Sécurité et intégrité

Le format actuel reste le **format ZipMulti v2** :

- manifeste présent dans chaque volume ;
- identifiant unique de lot ;
- contrôle de taille ;
- SHA-256 de chaque partie et du fichier original ;
- détection des volumes manquants ;
- compatibilité de lecture avec les anciens lots ZipMulti v0.1.

## Compiler automatiquement sur GitHub

1. Créer un dépôt GitHub vide.
2. Envoyer le contenu de ce dossier à la racine du dépôt.
3. Faire un commit sur `main` ou `master`.
4. Ouvrir **Actions**.
5. Lancer **Build ZipMulti Android + Windows** si nécessaire.
6. Télécharger les artifacts générés :
   - `ZipMulti-v0.3-Android-APK` ;
   - `ZipMulti-v0.3-Windows-Portable` ;
   - `ZipMulti-v0.3-Windows-Setup-EXE`.

Le workflow crée lui-même les dossiers Flutter `android/` et `windows/`, applique la configuration Android pour recevoir les ZIP, lance `flutter analyze`, les tests, puis les builds release.

## Compilation locale

Flutter 3.38+ et Dart 3.10+ sont nécessaires. La configuration Android du projet fixe `minSdk = 24`.

```bash
flutter create . --platforms=android,windows --project-name zip_multi --org com.zipmulti
python3 tool/patch_android_manifest.py
flutter pub get
flutter test
flutter run
```

Android :

```bash
flutter build apk --release
```

Windows :

```bash
flutter build windows --release
```

## Arborescence

```text
ZipMulti/
├── .github/workflows/build.yml
├── docs/
│   ├── COMPATIBILITE.md
│   ├── FORMAT_V2.md
│   └── UTILISATION.md
├── installer/zipmulti.iss
├── lib/
│   ├── main.dart
│   └── src/
│       ├── screens/
│       │   ├── home_screen.dart
│       │   └── tutorial_screen.dart
│       └── services/zip_multi_service.dart
├── test/
│   ├── smoke_test.dart
│   └── zip_multi_service_test.dart
├── tool/patch_android_manifest.py
├── analysis_options.yaml
├── pubspec.yaml
└── README.md
```

## Idées pour la suite

- glisser-déposer sous Windows ;
- sélection de dossiers complets avec conservation de l'arborescence ;
- progression réelle en octets, vitesse et temps restant ;
- partage direct de tous les volumes depuis Android ;
- analyse d'un lot avant reconstruction avec liste claire des volumes présents / manquants ;
- bouton « Tester le lot » juste après sa création ;
- reprise d'une reconstruction interrompue ;
- icône et identité visuelle définitives ;
- signature APK/AAB avec secrets GitHub.
