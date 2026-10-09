import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import 'database_service.dart';

/// Sauvegarde et restauration locales : exporte/importe le fichier de base
/// SQLite complet (motos, versements, depenses, reglages). Il n'y a pas de
/// serveur distant — la sauvegarde est un fichier que l'utilisateur envoie
/// et conserve lui-meme (WhatsApp, email, stockage cloud personnel...), et
/// qu'il peut restaurer plus tard, y compris sur un autre telephone.
class BackupService {
  BackupService._();

  static Future<void> exporter() async {
    // Ferme la connexion active pour garantir que le fichier sur disque est
    // a jour (pas d'ecriture en cours) avant de le copier.
    await DatabaseService.instance.fermer();

    final cheminSource = await DatabaseService.instance.cheminBaseDeDonnees();
    final fichierSource = File(cheminSource);
    if (!await fichierSource.exists()) {
      throw Exception('Aucune donnee a exporter pour le moment.');
    }

    final horodatage = DateTime.now();
    final nomFichier = 'moto_taxi_douka_sauvegarde_'
        '${horodatage.year}${_deuxChiffres(horodatage.month)}${_deuxChiffres(horodatage.day)}_'
        '${_deuxChiffres(horodatage.hour)}${_deuxChiffres(horodatage.minute)}.db';

    // share_plus copie lui-meme le fichier fourni dans son propre dossier
    // de cache interne ("<cache>/share_plus/") avant de le partager. Si on
    // lui donne directement un fichier deja place dans ce dossier, il
    // refuse (il serait efface par son propre nettoyage) : il faut donc
    // ecrire l'export ailleurs, dans le dossier temporaire normal.
    final dossierTemp = await getTemporaryDirectory();
    final cheminExport = p.join(dossierTemp.path, nomFichier);
    await fichierSource.copy(cheminExport);

    await Share.shareXFiles(
      [XFile(cheminExport)],
      subject: 'Sauvegarde Douka Moto',
      text: 'Sauvegarde Douka Moto du ${_formaterDate(horodatage)}',
    );
  }

  /// Ouvre le selecteur de fichiers et retourne le chemin choisi (ou null
  /// si l'utilisateur annule).
  static Future<String?> choisirFichierSauvegarde() async {
    // Pas de filtre ".db" : sur Android, une extension sans type de fichier
    // connu rend la sauvegarde grisee (impossible a choisir, surtout depuis
    // WhatsApp ou Telechargements). Le contenu est verifie a la restauration
    // (voir _verifierSauvegarde), un mauvais fichier est refuse proprement.
    final resultat = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Choisir une sauvegarde (.db)',
    );
    if (resultat == null || resultat.files.isEmpty) return null;
    return resultat.files.single.path;
  }

  /// Remplace la base de donnees actuelle par le fichier choisi.
  /// Destructif et irreversible : toutes les donnees actuelles sont
  /// ecrasees par celles de la sauvegarde.
  static Future<void> restaurer(String cheminFichierChoisi) async {
    final fichierChoisi = File(cheminFichierChoisi);
    if (!await fichierChoisi.exists()) {
      throw Exception('Fichier introuvable.');
    }
    // Verifie AVANT d'ecraser quoi que ce soit : un mauvais fichier rendait
    // l'app inutilisable et faisait perdre toutes les donnees.
    await _verifierSauvegarde(cheminFichierChoisi);

    await DatabaseService.instance.fermer();
    final cheminDestination = await DatabaseService.instance.cheminBaseDeDonnees();
    final copieSecours = File('$cheminDestination.bak');
    if (await File(cheminDestination).exists()) await File(cheminDestination).copy(copieSecours.path);
    try {
      // Fichiers annexes de l'ancienne base : melanges a la nouvelle, ils la
      // corrompraient.
      for (final suffixe in ['-wal', '-shm', '-journal']) {
        final annexe = File('$cheminDestination$suffixe');
        if (await annexe.exists()) await annexe.delete();
      }
      await fichierChoisi.copy(cheminDestination);
    } catch (_) {
      // Copie interrompue (stockage plein...) : on remet la base d'avant.
      if (await copieSecours.exists()) await copieSecours.copy(cheminDestination);
      rethrow;
    }
  }

  static const _pasUneSauvegarde = 'Ce fichier n\'est pas une sauvegarde de l\'application.';

  /// Leve une exception claire si le fichier n'est pas une sauvegarde de
  /// l'app, ou s'il vient d'une version plus recente qu'elle ne sait pas lire.
  static Future<void> _verifierSauvegarde(String chemin) async {
    Database? sauvegarde;
    try {
      sauvegarde = await openDatabase(chemin, readOnly: true, singleInstance: false);
      final tables = await sauvegarde.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'motos'");
      if (tables.isEmpty) throw Exception(_pasUneSauvegarde);
      if (await sauvegarde.getVersion() > AppConstants.dbVersion) {
        throw Exception('Cette sauvegarde vient d\'une version plus recente de l\'application : '
            'mettez l\'application a jour avant de la restaurer.');
      }
    } on DatabaseException {
      throw Exception(_pasUneSauvegarde);
    } finally {
      await sauvegarde?.close();
    }
  }

  static String _deuxChiffres(int n) => n.toString().padLeft(2, '0');

  static String _formaterDate(DateTime d) =>
      '${_deuxChiffres(d.day)}/${_deuxChiffres(d.month)}/${d.year}';
}
