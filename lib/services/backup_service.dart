import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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

    // Le FileProvider de share_plus n'expose que le sous-dossier
    // "share_plus/" du cache (voir flutter_share_file_paths.xml du plugin) :
    // le fichier a partager doit imperativement y etre place.
    final dossierTemp = await getTemporaryDirectory();
    final dossierPartage = Directory(p.join(dossierTemp.path, 'share_plus'));
    if (!await dossierPartage.exists()) {
      await dossierPartage.create(recursive: true);
    }
    final cheminExport = p.join(dossierPartage.path, nomFichier);
    await fichierSource.copy(cheminExport);

    await Share.shareXFiles(
      [XFile(cheminExport)],
      subject: 'Sauvegarde Moto Taxi Douka',
      text: 'Sauvegarde Moto Taxi Douka du ${_formaterDate(horodatage)}',
    );
  }

  /// Ouvre le selecteur de fichiers et retourne le chemin choisi (ou null
  /// si l'utilisateur annule).
  static Future<String?> choisirFichierSauvegarde() async {
    final resultat = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
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

    await DatabaseService.instance.fermer();
    final cheminDestination = await DatabaseService.instance.cheminBaseDeDonnees();
    await fichierChoisi.copy(cheminDestination);
  }

  static String _deuxChiffres(int n) => n.toString().padLeft(2, '0');

  static String _formaterDate(DateTime d) =>
      '${_deuxChiffres(d.day)}/${_deuxChiffres(d.month)}/${d.year}';
}
