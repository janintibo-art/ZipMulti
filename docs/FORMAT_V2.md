# Format interne ZipMulti v2

Chaque volume `nom_001.zip`, `nom_002.zip`, etc. contient :

- `ZIPMULTI_MANIFEST.json` : description complète du lot ;
- `ZIPMULTI_VOLUME.json` : numéro du volume et identifiant du lot ;
- les fichiers normaux affectés à ce volume ;
- et/ou des parties dans `__zipmulti_parts__/...`.

## Manifeste

Champs principaux :

```json
{
  "format": "ZipMulti",
  "version": 2,
  "setId": "partage-...",
  "mode": "smart-split",
  "baseName": "partage",
  "volumeCount": 4,
  "maxBytes": 104857600,
  "files": []
}
```

Un fichier normal possède son nom, sa taille et son SHA-256.

Un fichier fractionné possède en plus une liste ordonnée de parties. Chaque partie possède :

- son chemin interne ;
- sa taille exacte ;
- son SHA-256.

## Reconstruction

Le lecteur :

1. extrait chaque volume dans un espace temporaire séparé ;
2. vérifie que tous les `setId` correspondent ;
3. vérifie que tous les numéros de volume sont présents ;
4. vérifie taille et SHA-256 de chaque partie ;
5. assemble les parties dans l'ordre ;
6. vérifie la taille et le SHA-256 du fichier final ;
7. supprime l'espace temporaire.

Les chemins de sortie issus du manifeste sont réduits au nom de fichier afin d'éviter qu'un manifeste ne puisse écrire arbitrairement hors du dossier de destination.
