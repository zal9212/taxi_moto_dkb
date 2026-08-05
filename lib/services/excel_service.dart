import 'dart:io';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../models/depense.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import 'database_service.dart';

/// Une erreur de validation sur une ligne precise d'une feuille, remontee
/// a l'utilisateur apres import (le reste du fichier continue d'etre
/// traite, seule la ligne en erreur est ignoree).
class LigneErreurImport {
  final String feuille;
  final int ligne; // numero de ligne tel qu'affiche dans Excel
  final String message;
  LigneErreurImport(this.feuille, this.ligne, this.message);

  @override
  String toString() => '$feuille, ligne $ligne : $message';
}

/// Resultat d'un import : compte des lignes traitees avec succes et
/// liste des lignes rejetees avec leur raison.
class RapportImportExcel {
  int motosCreees = 0;
  int motosMisesAJour = 0;
  int versementsCrees = 0;
  int versementsMisAJour = 0;
  int depensesCreees = 0;
  int depensesMisesAJour = 0;
  final List<LigneErreurImport> erreurs = [];

  int get totalTraite =>
      motosCreees + motosMisesAJour + versementsCrees + versementsMisAJour + depensesCreees + depensesMisesAJour;
}

/// Export et import des donnees (motos, versements, depenses) au format
/// Excel (.xlsx) : plus lisible et modifiable qu'une sauvegarde .db brute.
///
/// Feuilles generees : "Motos", "Versements", "Depenses". La colonne "ID"
/// identifie une ligne existante (mise a jour) ; laissee vide, elle cree
/// un nouvel enregistrement. Les versements/depenses referencent leur
/// moto par son NOM (pas par ID interne), pour rester modifiables a la
/// main sans connaitre les identifiants internes.
class ExcelService {
  ExcelService._();

  static const _feuilleMotos = 'Motos';
  static const _feuilleVersements = 'Versements';
  static const _feuilleDepenses = 'Depenses';

  // -------------------------------------------------------------------
  // EXPORT
  // -------------------------------------------------------------------

  static Future<void> exporter() async {
    final db = DatabaseService.instance;
    final motos = await db.listerMotos();
    final motosParId = {for (final m in motos) m.id: m};
    final categories = await db.listerCategories();
    final categoriesParId = {for (final c in categories) c.id: c};

    final excel = Excel.createExcel();
    final feuilleParDefaut = excel.getDefaultSheet();

    final sMotos = excel[_feuilleMotos];
    sMotos.appendRow([
      TextCellValue('ID'),
      TextCellValue('Nom'),
      TextCellValue('Chauffeur'),
      TextCellValue('Montant par versement'),
      TextCellValue('Frequence'),
      TextCellValue('Valeur frequence'),
      TextCellValue('Date debut'),
      TextCellValue('Statut'),
      TextCellValue('Notes'),
    ]);
    for (final m in motos) {
      sMotos.appendRow([
        m.id != null ? IntCellValue(m.id!) : null,
        TextCellValue(m.nom),
        TextCellValue(m.chauffeur),
        DoubleCellValue(m.montantVersement),
        TextCellValue(m.frequenceType),
        IntCellValue(m.frequenceValeur),
        TextCellValue(_iso(m.dateDebut)),
        TextCellValue(m.statut),
        m.notes != null ? TextCellValue(m.notes!) : null,
      ]);
    }

    final sVersements = excel[_feuilleVersements];
    sVersements.appendRow([
      TextCellValue('ID'),
      TextCellValue('Moto'),
      TextCellValue('Date echeance'),
      TextCellValue('Date validation'),
      TextCellValue('Montant prevu'),
      TextCellValue('Montant paye'),
      TextCellValue('Statut'),
      TextCellValue('Notes'),
    ]);
    for (final m in motos) {
      if (m.id == null) continue;
      final versements = await db.listerVersementsParMoto(m.id!);
      for (final v in versements) {
        sVersements.appendRow([
          v.id != null ? IntCellValue(v.id!) : null,
          TextCellValue(motosParId[v.motoId]?.nom ?? ''),
          TextCellValue(_iso(v.dateEcheance)),
          v.dateValidation != null ? TextCellValue(_iso(v.dateValidation!)) : null,
          DoubleCellValue(v.montantPrevu),
          v.montantPaye != null ? DoubleCellValue(v.montantPaye!) : null,
          TextCellValue(v.statut),
          v.notes != null ? TextCellValue(v.notes!) : null,
        ]);
      }
    }

    final sDepenses = excel[_feuilleDepenses];
    sDepenses.appendRow([
      TextCellValue('ID'),
      TextCellValue('Moto'),
      TextCellValue('Categorie'),
      TextCellValue('Montant'),
      TextCellValue('Date'),
      TextCellValue('Description'),
    ]);
    for (final m in motos) {
      if (m.id == null) continue;
      final depenses = await db.listerDepensesParMoto(m.id!);
      for (final d in depenses) {
        sDepenses.appendRow([
          d.id != null ? IntCellValue(d.id!) : null,
          TextCellValue(motosParId[d.motoId]?.nom ?? ''),
          TextCellValue(categoriesParId[d.categorieId]?.nom ?? ''),
          DoubleCellValue(d.montant),
          TextCellValue(_iso(d.date)),
          d.description != null ? TextCellValue(d.description!) : null,
        ]);
      }
    }

    if (feuilleParDefaut != null && feuilleParDefaut != _feuilleMotos) {
      excel.delete(feuilleParDefaut);
    }

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Echec de la generation du fichier Excel.');
    }

    final horodatage = DateTime.now();
    final nomFichier = 'moto_taxi_douka_${_isoCompact(horodatage)}.xlsx';

    // share_plus copie lui-meme le fichier fourni dans son propre dossier
    // de cache interne ("<cache>/share_plus/") avant de le partager ; lui
    // donner un fichier deja place dedans le fait refuser (meme contrainte
    // que pour la sauvegarde .db, voir BackupService.exporter()).
    final dossierTemp = await getTemporaryDirectory();
    final cheminExport = p.join(dossierTemp.path, nomFichier);
    await File(cheminExport).writeAsBytes(bytes);

    await Share.shareXFiles(
      [XFile(cheminExport)],
      subject: 'Export Excel Moto Taxi Douka',
      text: 'Export Excel Moto Taxi Douka du ${_formaterDate(horodatage)}',
    );
  }

  // -------------------------------------------------------------------
  // IMPORT
  // -------------------------------------------------------------------

  static Future<String?> choisirFichierExcel() async {
    final resultat = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      dialogTitle: 'Choisir un fichier Excel (.xlsx)',
    );
    if (resultat == null || resultat.files.isEmpty) return null;
    return resultat.files.single.path;
  }

  /// Importe un fichier Excel genere par [exporter] (ou construit sur ce
  /// modele). Deux modes :
  /// - [remplacementComplet] = true : toutes les motos/versements/depenses
  ///   actuels sont effaces avant l'import (comme une restauration).
  /// - [remplacementComplet] = false : fusion — une ligne avec un ID
  ///   existant met a jour l'enregistrement correspondant, une ligne sans
  ///   ID (ou avec un ID inconnu) cree un nouvel enregistrement. Rien
  ///   n'est supprime.
  static Future<RapportImportExcel> importer(
    String cheminFichier, {
    required bool remplacementComplet,
  }) async {
    final bytes = await File(cheminFichier).readAsBytes();
    final excel = Excel.decodeBytes(bytes);
    final rapport = RapportImportExcel();

    final sMotos = excel.tables[_feuilleMotos];
    if (sMotos == null) {
      throw Exception('Feuille "$_feuilleMotos" introuvable dans ce fichier.');
    }

    final db = DatabaseService.instance;

    if (remplacementComplet) {
      await db.viderToutesLesDonnees();
    }

    // nom (minuscules) -> id, pour resoudre les references des feuilles
    // Versements/Depenses vers une moto (existante ou creee pendant cet
    // import).
    final idMotoParNom = <String, int>{
      for (final m in await db.listerMotos())
        if (m.id != null) m.nom.toLowerCase(): m.id!
    };

    for (var i = 1; i < sMotos.maxRows; i++) {
      final ligne = sMotos.rows[i];
      if (_ligneVide(ligne)) continue;
      final numeroLigne = i + 1;
      try {
        final idTxte = _texte(_valeur(ligne, 0));
        final nom = _texte(_valeur(ligne, 1));
        final chauffeur = _texte(_valeur(ligne, 2));
        final montantTxt = _texte(_valeur(ligne, 3));
        final frequence = _texte(_valeur(ligne, 4));
        final valeurFreqTxt = _texte(_valeur(ligne, 5));
        final dateDebutTxt = _texte(_valeur(ligne, 6));
        final statut = _texte(_valeur(ligne, 7)) ?? AppConstants.motoActive;
        final notes = _texte(_valeur(ligne, 8));

        if (nom == null ||
            chauffeur == null ||
            montantTxt == null ||
            frequence == null ||
            valeurFreqTxt == null ||
            dateDebutTxt == null) {
          rapport.erreurs.add(LigneErreurImport(
              _feuilleMotos, numeroLigne, 'Champs obligatoires manquants (Nom, Chauffeur, Montant, Frequence, Valeur frequence, Date debut).'));
          continue;
        }
        if (![AppConstants.freqHebdomadaire, AppConstants.freqMensuelle, AppConstants.freqPersonnalisee]
            .contains(frequence)) {
          rapport.erreurs.add(LigneErreurImport(_feuilleMotos, numeroLigne, 'Frequence invalide : "$frequence".'));
          continue;
        }
        if (![AppConstants.motoActive, AppConstants.motoSuspendue, AppConstants.motoArchivee].contains(statut)) {
          rapport.erreurs.add(LigneErreurImport(_feuilleMotos, numeroLigne, 'Statut invalide : "$statut".'));
          continue;
        }
        final montant = double.tryParse(montantTxt);
        final valeurFreq = int.tryParse(valeurFreqTxt);
        final dateDebut = DateTime.tryParse(dateDebutTxt);
        if (montant == null || valeurFreq == null || dateDebut == null) {
          rapport.erreurs.add(
              LigneErreurImport(_feuilleMotos, numeroLigne, 'Montant, valeur de frequence ou date debut invalide.'));
          continue;
        }

        final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
        final moto = Moto(
          id: idFourni,
          nom: nom,
          chauffeur: chauffeur,
          montantVersement: montant,
          frequenceType: frequence,
          frequenceValeur: valeurFreq,
          dateDebut: dateDebut,
          statut: statut,
          notes: notes,
        );

        int idFinal;
        var misAJour = false;
        if (moto.id != null) {
          final lignesAffectees = await db.modifierMoto(moto);
          misAJour = lignesAffectees > 0;
        }
        if (misAJour) {
          idFinal = moto.id!;
          rapport.motosMisesAJour++;
        } else {
          idFinal = await db.insererMoto(moto);
          rapport.motosCreees++;
        }
        idMotoParNom[nom.toLowerCase()] = idFinal;
      } catch (e) {
        rapport.erreurs.add(LigneErreurImport(_feuilleMotos, numeroLigne, 'Erreur inattendue : $e'));
      }
    }

    // nom (minuscules) -> id, cree a la volee si une categorie inconnue
    // est referencee (les categories sont un simple tag, sans risque).
    final idCategorieParNom = <String, int>{
      for (final c in await db.listerCategories())
        if (c.id != null) c.nom.toLowerCase(): c.id!
    };

    final sVersements = excel.tables[_feuilleVersements];
    if (sVersements != null) {
      for (var i = 1; i < sVersements.maxRows; i++) {
        final ligne = sVersements.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final motoNom = _texte(_valeur(ligne, 1));
          final dateEcheanceTxt = _texte(_valeur(ligne, 2));
          final dateValidationTxt = _texte(_valeur(ligne, 3));
          final montantPrevuTxt = _texte(_valeur(ligne, 4));
          final montantPayeTxt = _texte(_valeur(ligne, 5));
          final statut = _texte(_valeur(ligne, 6));
          final notes = _texte(_valeur(ligne, 7));

          if (motoNom == null || dateEcheanceTxt == null || montantPrevuTxt == null || statut == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleVersements, numeroLigne,
                'Champs obligatoires manquants (Moto, Date echeance, Montant prevu, Statut).'));
            continue;
          }
          final motoId = idMotoParNom[motoNom.toLowerCase()];
          if (motoId == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleVersements, numeroLigne, 'Moto "$motoNom" introuvable.'));
            continue;
          }
          if (![AppConstants.versementEnAttente, AppConstants.versementPaye, AppConstants.versementEnRetard]
              .contains(statut)) {
            rapport.erreurs.add(LigneErreurImport(_feuilleVersements, numeroLigne, 'Statut invalide : "$statut".'));
            continue;
          }
          final dateEcheance = DateTime.tryParse(dateEcheanceTxt);
          final montantPrevu = double.tryParse(montantPrevuTxt);
          if (dateEcheance == null || montantPrevu == null) {
            rapport.erreurs.add(
                LigneErreurImport(_feuilleVersements, numeroLigne, 'Date d\'echeance ou montant prevu invalide.'));
            continue;
          }
          final dateValidation = dateValidationTxt != null ? DateTime.tryParse(dateValidationTxt) : null;
          final montantPaye = montantPayeTxt != null ? double.tryParse(montantPayeTxt) : null;

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final versement = Versement(
            id: idFourni,
            motoId: motoId,
            dateEcheance: dateEcheance,
            dateValidation: dateValidation,
            montantPrevu: montantPrevu,
            montantPaye: montantPaye,
            statut: statut,
            notes: notes,
          );

          var misAJour = false;
          if (versement.id != null) {
            final lignesAffectees = await db.modifierVersement(versement);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            rapport.versementsMisAJour++;
          } else {
            await db.insererVersement(versement);
            rapport.versementsCrees++;
          }
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleVersements, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    final sDepenses = excel.tables[_feuilleDepenses];
    if (sDepenses != null) {
      for (var i = 1; i < sDepenses.maxRows; i++) {
        final ligne = sDepenses.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final motoNom = _texte(_valeur(ligne, 1));
          final categorieNom = _texte(_valeur(ligne, 2));
          final montantTxt = _texte(_valeur(ligne, 3));
          final dateTxt = _texte(_valeur(ligne, 4));
          final description = _texte(_valeur(ligne, 5));

          if (motoNom == null || categorieNom == null || montantTxt == null || dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleDepenses, numeroLigne, 'Champs obligatoires manquants (Moto, Categorie, Montant, Date).'));
            continue;
          }
          final motoId = idMotoParNom[motoNom.toLowerCase()];
          if (motoId == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleDepenses, numeroLigne, 'Moto "$motoNom" introuvable.'));
            continue;
          }
          var categorieId = idCategorieParNom[categorieNom.toLowerCase()];
          if (categorieId == null) {
            categorieId = await db.insererCategorie(CategorieDepense(nom: categorieNom, icone: 'dots'));
            idCategorieParNom[categorieNom.toLowerCase()] = categorieId;
          }
          final montant = double.tryParse(montantTxt);
          final date = DateTime.tryParse(dateTxt);
          if (montant == null || date == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleDepenses, numeroLigne, 'Montant ou date invalide.'));
            continue;
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final depense = Depense(
            id: idFourni,
            motoId: motoId,
            categorieId: categorieId,
            montant: montant,
            date: date,
            description: description,
          );

          var misAJour = false;
          if (depense.id != null) {
            final lignesAffectees = await db.modifierDepense(depense);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            rapport.depensesMisesAJour++;
          } else {
            await db.insererDepense(depense);
            rapport.depensesCreees++;
          }
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleDepenses, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    return rapport;
  }

  // -------------------------------------------------------------------
  // Utilitaires
  // -------------------------------------------------------------------

  static bool _ligneVide(List<Data?> ligne) => ligne.every((c) => _texte(c?.value) == null);

  static CellValue? _valeur(List<Data?> ligne, int index) => index < ligne.length ? ligne[index]?.value : null;

  /// Convertit n'importe quel type de cellule Excel en texte, quel que
  /// soit la facon dont la cellule a ete saisie (texte, nombre, date...).
  static String? _texte(CellValue? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static String _iso(DateTime d) => d.toIso8601String().substring(0, 10);

  static String _isoCompact(DateTime d) {
    String deuxChiffres(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${deuxChiffres(d.month)}${deuxChiffres(d.day)}_'
        '${deuxChiffres(d.hour)}${deuxChiffres(d.minute)}';
  }

  static String _formaterDate(DateTime d) {
    String deuxChiffres(int n) => n.toString().padLeft(2, '0');
    return '${deuxChiffres(d.day)}/${deuxChiffres(d.month)}/${d.year}';
  }
}
