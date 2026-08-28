# Guide d'utilisation — ZipMulti v0.3

ZipMulti sert à découper un ou plusieurs fichiers en lots ZIP de taille contrôlée, puis à reconstruire automatiquement les fichiers qui ont été fractionnés.

## Premier lancement

Au premier lancement, ZipMulti affiche un tutoriel en 6 étapes. Il explique :

1. le principe de ZipMulti ;
2. comment créer un lot ;
3. comment envoyer les volumes ;
4. comment reconstruire les fichiers ;
5. les différences Android / Windows ;
6. les erreurs fréquentes et leur solution.

Le tutoriel peut être rouvert à tout moment avec le bouton `?` en haut de l'écran.

## Créer un lot

1. Ouvrir **Créer un lot**.
2. Appuyer sur **Ajouter des fichiers**.
3. Choisir le **dossier de sortie**.
4. Donner un **nom au lot**.
5. Choisir la **taille maximale par ZIP**.
6. Laisser **Fractionnement intelligent** activé si de gros fichiers doivent être découpés.
7. Appuyer sur **Créer le lot ZIP**.

Exemple :

```text
partage_001.zip
partage_002.zip
partage_003.zip
```

## Envoyer le lot

Envoyer **tous** les ZIP créés. Ne pas supprimer de volume et, de préférence, ne pas les renommer avant la reconstruction.

Chez le destinataire, placer tous les ZIP dans le même dossier simplifie la détection automatique.

## Reconstruire

1. Ouvrir **Reconstruire**.
2. Sélectionner un ZIP du lot.
3. Sur Android, si ZipMulti ne peut pas voir les fichiers voisins, sélectionner tous les ZIP en une seule fois.
4. Choisir le dossier de destination.
5. Appuyer sur **Reconstruire maintenant**.

ZipMulti contrôle les volumes, vérifie les tailles et les empreintes SHA-256, assemble les parties dans l'ordre et recrée le fichier original.

## Message prêt à envoyer

Le tutoriel de l'application contient un bouton **Copier le message**. Il copie l'explication suivante :

> Pour reconstruire les fichiers que je t’envoie :
> 1. Mets tous les fichiers .zip du lot dans le même dossier.
> 2. Ouvre ZipMulti, puis va dans « Reconstruire ».
> 3. Choisis un ZIP du lot (ou tous les ZIP sur Android si nécessaire), choisis le dossier de destination et appuie sur « Reconstruire maintenant ».
>
> Important : garde tous les ZIP du lot et ne renomme pas les volumes avant la reconstruction.

## Problèmes fréquents

### Lot incomplet

Un ou plusieurs volumes n'ont pas été reçus. Vérifier que toute la série `_001.zip`, `_002.zip`, `_003.zip`… est présente.

### Android ne trouve pas les volumes voisins

Certains sélecteurs Android n'accordent l'accès qu'au fichier choisi. Dans ce cas, sélectionner tous les ZIP du lot en une seule fois dans ZipMulti.

### Échec SHA-256

Le volume ou la partie a probablement été tronqué(e) ou corrompu(e) pendant le transfert. Renvoyer le ZIP concerné.

### Deux lots ont été mélangés

ZipMulti utilise un identifiant de lot pour détecter ce problème. Replacer chaque série de ZIP dans un dossier séparé.

## Conseil de partage

Pour éviter presque toutes les erreurs :

- envoyer tous les volumes ensemble ;
- conserver leurs noms ;
- attendre la fin complète du transfert ;
- placer tous les ZIP dans le même dossier ;
- lancer la reconstruction depuis ZipMulti, et non depuis un décompresseur classique si un fichier a été fractionné.
