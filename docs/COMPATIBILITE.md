# Compatibilité ZipMulti v0.3

## ZIP standards

Tous les volumes produits par ZipMulti portent l'extension `.zip` et sont des conteneurs ZIP standards.

Pour les fichiers plus petits que la limite choisie, le fichier original est directement présent dans un volume. Un décompresseur classique peut donc l'extraire normalement.

## Gros fichier fractionné

Quand un fichier unique dépasse la limite maximale, ZipMulti v0.3 peut le découper en plusieurs parties internes réparties dans plusieurs ZIP.

Un outil ZIP classique sait ouvrir les conteneurs mais ne connaît pas le manifeste ZipMulti et ne sait pas que les fichiers internes `.part` doivent être concaténés puis vérifiés.

ZipMulti assure donc lui-même cette reconstruction.

## Pourquoi ne pas utiliser uniquement `.z01`, `.z02`, `.zip` ?

Les archives ZIP multi-volumes traditionnelles ne sont pas prises en charge de façon uniforme par les gestionnaires de fichiers Android intégrés. ZipMulti privilégie donc des fichiers `.zip` standards transportables, avec un protocole de reconstruction explicite.

## Android

ZipMulti v0.3 peut recevoir des fichiers ZIP depuis Android via le sélecteur interne et, lorsque le gestionnaire de fichiers le permet, via « Ouvrir avec » / « Partager ».

Android peut fournir à une application uniquement une copie mise en cache du fichier choisi, sans autorisation d'énumérer les fichiers voisins. Dans ce cas, sélectionnez tous les volumes en une seule fois dans ZipMulti.

## Windows

Sur Windows, lorsque les volumes sont dans le même dossier, sélectionner un seul volume permet normalement à ZipMulti de retrouver automatiquement toute la série.

## Compatibilité v0.1

Le lecteur v0.3 comprend également le manifeste v1. Les anciens lots peuvent donc être reconstruits. Ils ne possèdent toutefois pas les empreintes SHA-256 ajoutées en v0.2.
