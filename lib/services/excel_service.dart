import 'dart:io';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../models/categorie_activite.dart';
import '../models/categorie_entite.dart';
import '../models/categorie_transaction.dart';
import '../models/depense.dart';
import '../models/dette.dart';
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
  // Categories d'activite (ex: Boutiques) et dettes : presentes seulement
  // dans les fichiers generes depuis la mise a jour qui les inclut. Un
  // fichier plus ancien, sans ces feuilles, laisse simplement ces compteurs
  // a zero.
  int categoriesCreees = 0;
  int categoriesMisesAJour = 0;
  int entitesCreees = 0;
  int entitesMisesAJour = 0;
  int transactionsCreees = 0;
  int transactionsMisesAJour = 0;
  int dettesCreees = 0;
  int dettesMisesAJour = 0;
  int remboursementsCrees = 0;
  int remboursementsMisAJour = 0;
  final List<LigneErreurImport> erreurs = [];

  int get totalTraite =>
      motosCreees +
      motosMisesAJour +
      versementsCrees +
      versementsMisAJour +
      depensesCreees +
      depensesMisesAJour +
      categoriesCreees +
      categoriesMisesAJour +
      entitesCreees +
      entitesMisesAJour +
      transactionsCreees +
      transactionsMisesAJour +
      dettesCreees +
      dettesMisesAJour +
      remboursementsCrees +
      remboursementsMisAJour;
}

/// Resultat d'un import Excel pour une categorie d'activite (ex: Boutiques).
class RapportImportCategorie {
  int entitesCreees = 0;
  int entitesMisesAJour = 0;
  int transactionsCreees = 0;
  int transactionsMisesAJour = 0;
  final List<LigneErreurImport> erreurs = [];

  int get totalTraite => entitesCreees + entitesMisesAJour + transactionsCreees + transactionsMisesAJour;
}

/// Resultat d'un import Excel pour les dettes.
class RapportImportDettes {
  int dettesCreees = 0;
  int dettesMisesAJour = 0;
  int remboursementsCrees = 0;
  int remboursementsMisAJour = 0;
  final List<LigneErreurImport> erreurs = [];

  int get totalTraite => dettesCreees + dettesMisesAJour + remboursementsCrees + remboursementsMisAJour;
}

/// Export et import de TOUTES les donnees de l'app (motos, versements,
/// depenses, categories d'activite generiques avec leurs entites et
/// transactions, dettes avec leurs remboursements) au format Excel (.xlsx) :
/// plus lisible et modifiable qu'une sauvegarde .db brute.
///
/// Feuilles generees : "Motos", "Versements", "Depenses", "Categories",
/// "CategorieEntites", "CategorieTransactions", "Dettes",
/// "Remboursements". La colonne "ID" identifie une ligne existante (mise
/// a jour) ; laissee vide, elle cree un nouvel enregistrement. Les lignes
/// qui referencent un autre enregistrement (ex: "Moto ID" sur un
/// versement, "Categorie ID" sur une entite) utilisent cet ID de
/// preference — fiable meme en cas de doublon de nom — avec le nom
/// affiche a cote juste pour la lisibilite humaine ; si l'ID est vide
/// (ligne ajoutee a la main), le nom sert de repli.
///
/// Retro-compatibilite : seule la feuille "Motos" est obligatoire. Un
/// fichier genere avant l'ajout des categories/dettes (donc sans les
/// feuilles correspondantes) s'importe normalement, ces sections sont
/// simplement ignorees.
class ExcelService {
  ExcelService._();

  static const _feuilleMotos = 'Motos';
  static const _feuilleVersements = 'Versements';
  static const _feuilleDepenses = 'Depenses';
  static const _feuilleCategories = 'Categories';
  static const _feuilleCategorieEntites = 'CategorieEntites';
  static const _feuilleCategorieTransactions = 'CategorieTransactions';

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
      TextCellValue('Moto ID'),
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
      // Seuls les versements reellement effectues sont exportes : les
      // echeances en attente/en retard ne sont pas encore de l'argent
      // recu, et sont de toute facon regenerees automatiquement par
      // assurerEcheances() (fenetre glissante) au premier chargement.
      for (final v in versements.where((v) => v.statut == AppConstants.versementPaye)) {
        sVersements.appendRow([
          v.id != null ? IntCellValue(v.id!) : null,
          IntCellValue(v.motoId),
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
      TextCellValue('Moto ID'),
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
          IntCellValue(d.motoId),
          TextCellValue(motosParId[d.motoId]?.nom ?? ''),
          TextCellValue(categoriesParId[d.categorieId]?.nom ?? ''),
          DoubleCellValue(d.montant),
          TextCellValue(_iso(d.date)),
          d.description != null ? TextCellValue(d.description!) : null,
        ]);
      }
    }

    // Categories d'activite generiques (ex: Boutiques), toutes confondues,
    // avec leurs entites et transactions.
    final categoriesActivite = await db.listerCategoriesActivite();

    final sCategories = excel[_feuilleCategories];
    sCategories.appendRow([
      TextCellValue('ID'),
      TextCellValue('Nom'),
      TextCellValue('Couleur'),
      TextCellValue('Devise'),
      TextCellValue('Date creation'),
    ]);
    for (final c in categoriesActivite) {
      sCategories.appendRow([
        c.id != null ? IntCellValue(c.id!) : null,
        TextCellValue(c.nom),
        TextCellValue(c.couleur),
        TextCellValue(c.deviseSymbole),
        TextCellValue(_iso(c.dateCreation)),
      ]);
    }

    final sCategorieEntites = excel[_feuilleCategorieEntites];
    sCategorieEntites.appendRow([
      TextCellValue('ID'),
      TextCellValue('Categorie ID'),
      TextCellValue('Categorie'),
      TextCellValue('Nom'),
      TextCellValue('Statut'),
      TextCellValue('Notes'),
    ]);
    final entitesActiviteParId = <int, CategorieEntite>{};
    for (final c in categoriesActivite) {
      if (c.id == null) continue;
      final entites = await db.listerEntitesCategorie(c.id!);
      for (final e in entites) {
        if (e.id != null) entitesActiviteParId[e.id!] = e;
        sCategorieEntites.appendRow([
          e.id != null ? IntCellValue(e.id!) : null,
          IntCellValue(e.categorieId),
          TextCellValue(c.nom),
          TextCellValue(e.nom),
          TextCellValue(e.statut),
          e.notes != null ? TextCellValue(e.notes!) : null,
        ]);
      }
    }

    final sCategorieTransactions = excel[_feuilleCategorieTransactions];
    sCategorieTransactions.appendRow([
      TextCellValue('ID'),
      TextCellValue('Entite ID'),
      TextCellValue('Entite'),
      TextCellValue('Categorie'),
      TextCellValue('Type'),
      TextCellValue('Montant'),
      TextCellValue('Date'),
      TextCellValue('Description'),
    ]);
    for (final c in categoriesActivite) {
      if (c.id == null) continue;
      final transactions = await db.listerTransactionsCategorie(c.id!);
      for (final t in transactions) {
        sCategorieTransactions.appendRow([
          t.id != null ? IntCellValue(t.id!) : null,
          IntCellValue(t.entiteId),
          TextCellValue(entitesActiviteParId[t.entiteId]?.nom ?? ''),
          TextCellValue(c.nom),
          TextCellValue(t.type),
          DoubleCellValue(t.montant),
          TextCellValue(_iso(t.date)),
          t.description != null ? TextCellValue(t.description!) : null,
        ]);
      }
    }

    // Dettes et remboursements (feuilles partagees avec exporterDettes()).
    await _ecrireFeuillesDettes(excel, motosParId);

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
      subject: 'Export Excel Douka Moto',
      text: 'Export Excel Douka Moto du ${_formaterDate(horodatage)}',
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
      // Portee au contenu reellement present dans le fichier : un ancien
      // fichier sans ces feuilles ne doit pas effacer des categories/dettes
      // que l'utilisateur a creees depuis et qui n'y figurent pas.
      if (excel.tables[_feuilleCategories] != null) {
        await db.viderToutesLesCategoriesActivite();
      }
      if (excel.tables[_feuilleDettes] != null) {
        await db.viderDettes();
      }
    }

    // nom (minuscules) -> id, utilise en repli si une ligne Versements/
    // Depenses ne precise pas de "Moto ID" (ex: ligne ajoutee a la main).
    final idMotoParNom = <String, int>{
      for (final m in await db.listerMotos())
        if (m.id != null) m.nom.toLowerCase(): m.id!
    };
    // ID moto tel qu'ecrit dans le fichier (colonne "ID" de la feuille
    // Motos) -> ID reel en base apres import. Reference prioritaire et non
    // ambigue pour les feuilles Versements/Depenses, y compris quand
    // plusieurs motos partagent le meme nom (le nom seul ne suffirait pas
    // a les distinguer). En mode remplacement, les ID du fichier ne
    // correspondent plus a rien en base : cette table sert alors juste a
    // relier les lignes entre elles au sein du meme fichier.
    final idMotoFichierVersDb = <int, int>{};

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
        final idFichier = idTxte != null ? int.tryParse(idTxte) : null;
        if (idFichier != null) idMotoFichierVersDb[idFichier] = idFinal;
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
          final motoIdTxte = _texte(_valeur(ligne, 1));
          final motoNom = _texte(_valeur(ligne, 2));
          final dateEcheanceTxt = _texte(_valeur(ligne, 3));
          final dateValidationTxt = _texte(_valeur(ligne, 4));
          final montantPrevuTxt = _texte(_valeur(ligne, 5));
          final montantPayeTxt = _texte(_valeur(ligne, 6));
          final statut = _texte(_valeur(ligne, 7));
          final notes = _texte(_valeur(ligne, 8));

          if ((motoIdTxte == null && motoNom == null) ||
              dateEcheanceTxt == null ||
              montantPrevuTxt == null ||
              statut == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleVersements, numeroLigne,
                'Champs obligatoires manquants (Moto ID ou Moto, Date echeance, Montant prevu, Statut).'));
            continue;
          }
          // "Moto ID" est prioritaire : fiable meme si plusieurs motos
          // partagent le meme nom. Le nom ne sert de repli que si aucun
          // "Moto ID" n'est fourni (ligne ajoutee a la main).
          final motoIdFichier = motoIdTxte != null ? int.tryParse(motoIdTxte) : null;
          final motoId = (motoIdFichier != null ? idMotoFichierVersDb[motoIdFichier] : null) ??
              (motoNom != null ? idMotoParNom[motoNom.toLowerCase()] : null);
          if (motoId == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleVersements, numeroLigne, 'Moto introuvable (ID "$motoIdTxte" / nom "$motoNom").'));
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
          final motoIdTxte = _texte(_valeur(ligne, 1));
          final motoNom = _texte(_valeur(ligne, 2));
          final categorieNom = _texte(_valeur(ligne, 3));
          final montantTxt = _texte(_valeur(ligne, 4));
          final dateTxt = _texte(_valeur(ligne, 5));
          final description = _texte(_valeur(ligne, 6));

          if ((motoIdTxte == null && motoNom == null) ||
              categorieNom == null ||
              montantTxt == null ||
              dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleDepenses, numeroLigne,
                'Champs obligatoires manquants (Moto ID ou Moto, Categorie, Montant, Date).'));
            continue;
          }
          final motoIdFichier = motoIdTxte != null ? int.tryParse(motoIdTxte) : null;
          final motoId = (motoIdFichier != null ? idMotoFichierVersDb[motoIdFichier] : null) ??
              (motoNom != null ? idMotoParNom[motoNom.toLowerCase()] : null);
          if (motoId == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleDepenses, numeroLigne, 'Moto introuvable (ID "$motoIdTxte" / nom "$motoNom").'));
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

    // -------------------------------------------------------------------
    // Categories d'activite generiques (ex: Boutiques), avec leurs entites
    // et transactions. Feuilles absentes des fichiers generes avant leur
    // ajout : chaque bloc est simplement saute si sa feuille n'existe pas,
    // ce qui garde les anciens fichiers importables tels quels.
    // -------------------------------------------------------------------

    final idCategorieActiviteParNom = <String, int>{
      for (final c in await db.listerCategoriesActivite())
        if (c.id != null) c.nom.toLowerCase(): c.id!
    };
    final idCategorieActiviteFichierVersDb = <int, int>{};

    final sCategories = excel.tables[_feuilleCategories];
    if (sCategories != null) {
      for (var i = 1; i < sCategories.maxRows; i++) {
        final ligne = sCategories.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final nom = _texte(_valeur(ligne, 1));
          final couleur = _texte(_valeur(ligne, 2));
          final devise = _texte(_valeur(ligne, 3));
          final dateCreationTxt = _texte(_valeur(ligne, 4));

          if (nom == null || couleur == null || devise == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleCategories, numeroLigne, 'Champs obligatoires manquants (Nom, Couleur, Devise).'));
            continue;
          }
          final dateCreation = dateCreationTxt != null ? DateTime.tryParse(dateCreationTxt) : null;

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final categorie = CategorieActivite(
            id: idFourni,
            nom: nom,
            couleur: couleur,
            deviseSymbole: devise,
            dateCreation: dateCreation,
          );

          int idFinal;
          var misAJour = false;
          if (categorie.id != null) {
            final lignesAffectees = await db.modifierCategorieActivite(categorie);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            idFinal = categorie.id!;
            rapport.categoriesMisesAJour++;
          } else {
            idFinal = await db.insererCategorieActivite(categorie);
            rapport.categoriesCreees++;
          }
          idCategorieActiviteParNom[nom.toLowerCase()] = idFinal;
          final idFichier = idTxte != null ? int.tryParse(idTxte) : null;
          if (idFichier != null) idCategorieActiviteFichierVersDb[idFichier] = idFinal;
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleCategories, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    // "categorieId::nom" (minuscules) -> id entite : le nom seul ne suffit
    // pas, deux entites de categories differentes pouvant le partager.
    final idEntiteActiviteParNomScope = <String, int>{
      for (final c in await db.listerCategoriesActivite())
        if (c.id != null)
          for (final e in await db.listerEntitesCategorie(c.id!))
            if (e.id != null) '${c.id}::${e.nom.toLowerCase()}': e.id!
    };
    final idEntiteActiviteFichierVersDb = <int, int>{};

    final sCategorieEntites = excel.tables[_feuilleCategorieEntites];
    if (sCategorieEntites != null) {
      for (var i = 1; i < sCategorieEntites.maxRows; i++) {
        final ligne = sCategorieEntites.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final categorieIdTxte = _texte(_valeur(ligne, 1));
          final categorieNom = _texte(_valeur(ligne, 2));
          final nom = _texte(_valeur(ligne, 3));
          final statut = _texte(_valeur(ligne, 4)) ?? AppConstants.motoActive;
          final notes = _texte(_valeur(ligne, 5));

          if ((categorieIdTxte == null && categorieNom == null) || nom == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleCategorieEntites, numeroLigne,
                'Champs obligatoires manquants (Categorie ID ou Categorie, Nom).'));
            continue;
          }
          if (![AppConstants.motoActive, AppConstants.motoSuspendue, AppConstants.motoArchivee].contains(statut)) {
            rapport.erreurs
                .add(LigneErreurImport(_feuilleCategorieEntites, numeroLigne, 'Statut invalide : "$statut".'));
            continue;
          }
          final categorieIdFichier = categorieIdTxte != null ? int.tryParse(categorieIdTxte) : null;
          final categorieId = (categorieIdFichier != null
                  ? idCategorieActiviteFichierVersDb[categorieIdFichier]
                  : null) ??
              (categorieNom != null ? idCategorieActiviteParNom[categorieNom.toLowerCase()] : null);
          if (categorieId == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleCategorieEntites, numeroLigne,
                'Categorie introuvable (ID "$categorieIdTxte" / nom "$categorieNom").'));
            continue;
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final entite = CategorieEntite(
            id: idFourni,
            categorieId: categorieId,
            nom: nom,
            statut: statut,
            notes: notes,
          );

          int idFinal;
          var misAJour = false;
          if (entite.id != null) {
            final lignesAffectees = await db.modifierEntiteCategorie(entite);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            idFinal = entite.id!;
            rapport.entitesMisesAJour++;
          } else {
            idFinal = await db.insererEntiteCategorie(entite);
            rapport.entitesCreees++;
          }
          idEntiteActiviteParNomScope['$categorieId::${nom.toLowerCase()}'] = idFinal;
          final idFichier = idTxte != null ? int.tryParse(idTxte) : null;
          if (idFichier != null) idEntiteActiviteFichierVersDb[idFichier] = idFinal;
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleCategorieEntites, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    final sCategorieTransactions = excel.tables[_feuilleCategorieTransactions];
    if (sCategorieTransactions != null) {
      for (var i = 1; i < sCategorieTransactions.maxRows; i++) {
        final ligne = sCategorieTransactions.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final entiteIdTxte = _texte(_valeur(ligne, 1));
          final entiteNom = _texte(_valeur(ligne, 2));
          final categorieNom = _texte(_valeur(ligne, 3));
          final type = _texte(_valeur(ligne, 4));
          final montantTxt = _texte(_valeur(ligne, 5));
          final dateTxt = _texte(_valeur(ligne, 6));
          final description = _texte(_valeur(ligne, 7));

          if ((entiteIdTxte == null && (entiteNom == null || categorieNom == null)) ||
              type == null ||
              montantTxt == null ||
              dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleCategorieTransactions, numeroLigne,
                'Champs obligatoires manquants (Entite ID, ou Categorie + Entite, Type, Montant, Date).'));
            continue;
          }
          final entiteIdFichier = entiteIdTxte != null ? int.tryParse(entiteIdTxte) : null;
          int? entiteId = entiteIdFichier != null ? idEntiteActiviteFichierVersDb[entiteIdFichier] : null;
          if (entiteId == null && entiteNom != null && categorieNom != null) {
            final categorieId = idCategorieActiviteParNom[categorieNom.toLowerCase()];
            if (categorieId != null) {
              entiteId = idEntiteActiviteParNomScope['$categorieId::${entiteNom.toLowerCase()}'];
            }
          }
          if (entiteId == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleCategorieTransactions, numeroLigne,
                'Entite introuvable (ID "$entiteIdTxte" / "$categorieNom / $entiteNom").'));
            continue;
          }
          if (![AppConstants.transactionRevenu, AppConstants.transactionDepense].contains(type)) {
            rapport.erreurs
                .add(LigneErreurImport(_feuilleCategorieTransactions, numeroLigne, 'Type invalide : "$type".'));
            continue;
          }
          final montant = double.tryParse(montantTxt);
          final date = DateTime.tryParse(dateTxt);
          if (montant == null || date == null) {
            rapport.erreurs
                .add(LigneErreurImport(_feuilleCategorieTransactions, numeroLigne, 'Montant ou date invalide.'));
            continue;
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final transaction = CategorieTransaction(
            id: idFourni,
            entiteId: entiteId,
            type: type,
            montant: montant,
            date: date,
            description: description,
          );

          var misAJour = false;
          if (transaction.id != null) {
            final lignesAffectees = await db.modifierTransactionCategorie(transaction);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            rapport.transactionsMisesAJour++;
          } else {
            await db.insererTransactionCategorie(transaction);
            rapport.transactionsCreees++;
          }
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleCategorieTransactions, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    // -------------------------------------------------------------------
    // Dettes et remboursements. "Lien ID" resout d'abord parmi les motos/
    // entites importees dans ce meme fichier, puis, a defaut, parmi celles
    // deja en base (utile pour un fichier "Dettes" seul, genere par
    // exporterDettes(), sans feuilles Motos/Categories/CategorieEntites).
    // -------------------------------------------------------------------

    final motosIdsEnBase = (await db.listerMotos()).map((m) => m.id).whereType<int>().toSet();
    final idDetteFichierVersDb = <int, int>{};

    final sDettes = excel.tables[_feuilleDettes];
    if (sDettes != null) {
      for (var i = 1; i < sDettes.maxRows; i++) {
        final ligne = sDettes.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final nomPersonne = _texte(_valeur(ligne, 1));
          final montantTxt = _texte(_valeur(ligne, 2));
          final dateTxt = _texte(_valeur(ligne, 3));
          final notes = _texte(_valeur(ligne, 4));
          final lienType = _texte(_valeur(ligne, 5));
          final lienIdTxt = _texte(_valeur(ligne, 6));
          // Colonne 8 : absente des fichiers generes avant son ajout (voir
          // _ecrireFeuillesDettes) — _valeur() renvoie alors simplement null.
          final devise = _texte(_valeur(ligne, 8));

          if (nomPersonne == null || montantTxt == null || dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleDettes, numeroLigne, 'Champs obligatoires manquants (Nom personne, Montant initial, Date).'));
            continue;
          }
          final montant = double.tryParse(montantTxt);
          final date = DateTime.tryParse(dateTxt);
          if (montant == null || date == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleDettes, numeroLigne, 'Montant initial ou date invalide.'));
            continue;
          }

          String? lienTypeFinal;
          int? lienIdFinal;
          final lienIdFichier = lienIdTxt != null ? int.tryParse(lienIdTxt) : null;
          if (lienType == AppConstants.detteLienMoto && lienIdFichier != null) {
            final lienId =
                idMotoFichierVersDb[lienIdFichier] ?? (motosIdsEnBase.contains(lienIdFichier) ? lienIdFichier : null);
            if (lienId != null) {
              lienTypeFinal = lienType;
              lienIdFinal = lienId;
            }
          } else if (lienType == AppConstants.detteLienCategorieEntite && lienIdFichier != null) {
            final lienId = idEntiteActiviteFichierVersDb[lienIdFichier] ?? lienIdFichier;
            final entite = await db.obtenirEntiteCategorie(lienId);
            if (entite != null) {
              lienTypeFinal = lienType;
              lienIdFinal = lienId;
            }
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final dette = Dette(
            id: idFourni,
            nomPersonne: nomPersonne,
            montantInitial: montant,
            date: date,
            notes: notes,
            lienType: lienTypeFinal,
            lienId: lienIdFinal,
            // Sans effet si un lien est actif (deviseEffectiveDette() se
            // base alors sur le lien) ; utile seulement pour une dette
            // independante, ou comme simple valeur inerte sinon.
            deviseSymbole: devise,
          );

          int idFinal;
          var misAJour = false;
          if (dette.id != null) {
            final lignesAffectees = await db.modifierDette(dette);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            idFinal = dette.id!;
            rapport.dettesMisesAJour++;
          } else {
            idFinal = await db.insererDette(dette);
            rapport.dettesCreees++;
          }
          final idFichier = idTxte != null ? int.tryParse(idTxte) : null;
          if (idFichier != null) idDetteFichierVersDb[idFichier] = idFinal;
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleDettes, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    final sRemboursements = excel.tables[_feuilleRemboursements];
    if (sRemboursements != null) {
      for (var i = 1; i < sRemboursements.maxRows; i++) {
        final ligne = sRemboursements.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final detteIdTxte = _texte(_valeur(ligne, 1));
          final montantTxt = _texte(_valeur(ligne, 3));
          final dateTxt = _texte(_valeur(ligne, 4));
          final notes = _texte(_valeur(ligne, 5));

          if (detteIdTxte == null || montantTxt == null || dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleRemboursements, numeroLigne, 'Champs obligatoires manquants (Dette ID, Montant, Date).'));
            continue;
          }
          final detteIdFichier = int.tryParse(detteIdTxte);
          final detteId = detteIdFichier != null ? idDetteFichierVersDb[detteIdFichier] : null;
          if (detteId == null) {
            rapport.erreurs.add(
                LigneErreurImport(_feuilleRemboursements, numeroLigne, 'Dette introuvable (ID "$detteIdTxte").'));
            continue;
          }
          final montant = double.tryParse(montantTxt);
          final date = DateTime.tryParse(dateTxt);
          if (montant == null || date == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleRemboursements, numeroLigne, 'Montant ou date invalide.'));
            continue;
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final remboursement = DetteRemboursement(
            id: idFourni,
            detteId: detteId,
            montant: montant,
            date: date,
            notes: notes,
          );

          var misAJour = false;
          if (remboursement.id != null) {
            final lignesAffectees = await db.modifierRemboursement(remboursement);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            rapport.remboursementsMisAJour++;
          } else {
            await db.insererRemboursement(remboursement);
            rapport.remboursementsCrees++;
          }
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleRemboursements, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    return rapport;
  }

  // -------------------------------------------------------------------
  // EXPORT / IMPORT - Categorie d'activite (ex: Boutiques)
  // -------------------------------------------------------------------

  static const _feuilleEntites = 'Entites';
  static const _feuilleTransactions = 'Transactions';

  /// Exporte les entites et transactions d'une seule categorie (chaque
  /// categorie a sa propre devise, jamais melangee avec une autre).
  static Future<void> exporterCategorie(CategorieActivite categorie) async {
    final db = DatabaseService.instance;
    final entites = await db.listerEntitesCategorie(categorie.id!);
    final entitesParId = {for (final e in entites) e.id: e};
    final transactions = await db.listerTransactionsCategorie(categorie.id!);

    final excel = Excel.createExcel();
    final feuilleParDefaut = excel.getDefaultSheet();

    final sEntites = excel[_feuilleEntites];
    sEntites.appendRow([
      TextCellValue('ID'),
      TextCellValue('Nom'),
      TextCellValue('Statut'),
      TextCellValue('Notes'),
    ]);
    for (final e in entites) {
      sEntites.appendRow([
        e.id != null ? IntCellValue(e.id!) : null,
        TextCellValue(e.nom),
        TextCellValue(e.statut),
        e.notes != null ? TextCellValue(e.notes!) : null,
      ]);
    }

    final sTransactions = excel[_feuilleTransactions];
    sTransactions.appendRow([
      TextCellValue('ID'),
      TextCellValue('Entite ID'),
      TextCellValue('Entite'),
      TextCellValue('Type'),
      TextCellValue('Montant'),
      TextCellValue('Date'),
      TextCellValue('Description'),
    ]);
    for (final t in transactions) {
      sTransactions.appendRow([
        t.id != null ? IntCellValue(t.id!) : null,
        IntCellValue(t.entiteId),
        TextCellValue(entitesParId[t.entiteId]?.nom ?? ''),
        TextCellValue(t.type),
        DoubleCellValue(t.montant),
        TextCellValue(_iso(t.date)),
        t.description != null ? TextCellValue(t.description!) : null,
      ]);
    }

    if (feuilleParDefaut != null && feuilleParDefaut != _feuilleEntites) {
      excel.delete(feuilleParDefaut);
    }

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Echec de la generation du fichier Excel.');
    }

    final horodatage = DateTime.now();
    final nomFichierSuffixe = categorie.nom.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final nomFichier = 'douka_${nomFichierSuffixe}_${_isoCompact(horodatage)}.xlsx';

    final dossierTemp = await getTemporaryDirectory();
    final cheminExport = p.join(dossierTemp.path, nomFichier);
    await File(cheminExport).writeAsBytes(bytes);

    await Share.shareXFiles(
      [XFile(cheminExport)],
      subject: 'Export Excel ${categorie.nom}',
      text: 'Export Excel ${categorie.nom} du ${_formaterDate(horodatage)}',
    );
  }

  /// Importe un fichier Excel genere par [exporterCategorie] dans une
  /// categorie precise (les entites/transactions importees lui sont
  /// rattachees, peu importe la categorie d'origine du fichier).
  static Future<RapportImportCategorie> importerCategorie(
    String cheminFichier,
    int categorieId, {
    required bool remplacementComplet,
  }) async {
    final bytes = await File(cheminFichier).readAsBytes();
    final excel = Excel.decodeBytes(bytes);
    final rapport = RapportImportCategorie();

    final sEntites = excel.tables[_feuilleEntites];
    if (sEntites == null) {
      throw Exception('Feuille "$_feuilleEntites" introuvable dans ce fichier.');
    }

    final db = DatabaseService.instance;

    if (remplacementComplet) {
      await db.viderDonneesCategorie(categorieId);
    }

    final idEntiteParNom = <String, int>{
      for (final e in await db.listerEntitesCategorie(categorieId))
        if (e.id != null) e.nom.toLowerCase(): e.id!
    };
    final idEntiteFichierVersDb = <int, int>{};

    for (var i = 1; i < sEntites.maxRows; i++) {
      final ligne = sEntites.rows[i];
      if (_ligneVide(ligne)) continue;
      final numeroLigne = i + 1;
      try {
        final idTxte = _texte(_valeur(ligne, 0));
        final nom = _texte(_valeur(ligne, 1));
        final statut = _texte(_valeur(ligne, 2)) ?? AppConstants.motoActive;
        final notes = _texte(_valeur(ligne, 3));

        if (nom == null) {
          rapport.erreurs.add(LigneErreurImport(_feuilleEntites, numeroLigne, 'Champ obligatoire manquant (Nom).'));
          continue;
        }
        if (![AppConstants.motoActive, AppConstants.motoSuspendue, AppConstants.motoArchivee].contains(statut)) {
          rapport.erreurs.add(LigneErreurImport(_feuilleEntites, numeroLigne, 'Statut invalide : "$statut".'));
          continue;
        }

        final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
        final entite = CategorieEntite(
          id: idFourni,
          categorieId: categorieId,
          nom: nom,
          statut: statut,
          notes: notes,
        );

        int idFinal;
        var misAJour = false;
        if (entite.id != null) {
          final lignesAffectees = await db.modifierEntiteCategorie(entite);
          misAJour = lignesAffectees > 0;
        }
        if (misAJour) {
          idFinal = entite.id!;
          rapport.entitesMisesAJour++;
        } else {
          idFinal = await db.insererEntiteCategorie(entite);
          rapport.entitesCreees++;
        }
        idEntiteParNom[nom.toLowerCase()] = idFinal;
        final idFichier = idTxte != null ? int.tryParse(idTxte) : null;
        if (idFichier != null) idEntiteFichierVersDb[idFichier] = idFinal;
      } catch (e) {
        rapport.erreurs.add(LigneErreurImport(_feuilleEntites, numeroLigne, 'Erreur inattendue : $e'));
      }
    }

    final sTransactions = excel.tables[_feuilleTransactions];
    if (sTransactions != null) {
      for (var i = 1; i < sTransactions.maxRows; i++) {
        final ligne = sTransactions.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final entiteIdTxte = _texte(_valeur(ligne, 1));
          final entiteNom = _texte(_valeur(ligne, 2));
          final type = _texte(_valeur(ligne, 3));
          final montantTxt = _texte(_valeur(ligne, 4));
          final dateTxt = _texte(_valeur(ligne, 5));
          final description = _texte(_valeur(ligne, 6));

          if ((entiteIdTxte == null && entiteNom == null) || type == null || montantTxt == null || dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleTransactions, numeroLigne,
                'Champs obligatoires manquants (Entite ID ou Entite, Type, Montant, Date).'));
            continue;
          }
          final entiteIdFichier = entiteIdTxte != null ? int.tryParse(entiteIdTxte) : null;
          final entiteId = (entiteIdFichier != null ? idEntiteFichierVersDb[entiteIdFichier] : null) ??
              (entiteNom != null ? idEntiteParNom[entiteNom.toLowerCase()] : null);
          if (entiteId == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleTransactions, numeroLigne, 'Entite introuvable (ID "$entiteIdTxte" / nom "$entiteNom").'));
            continue;
          }
          if (![AppConstants.transactionRevenu, AppConstants.transactionDepense].contains(type)) {
            rapport.erreurs.add(LigneErreurImport(_feuilleTransactions, numeroLigne, 'Type invalide : "$type".'));
            continue;
          }
          final montant = double.tryParse(montantTxt);
          final date = DateTime.tryParse(dateTxt);
          if (montant == null || date == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleTransactions, numeroLigne, 'Montant ou date invalide.'));
            continue;
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final transaction = CategorieTransaction(
            id: idFourni,
            entiteId: entiteId,
            type: type,
            montant: montant,
            date: date,
            description: description,
          );

          var misAJour = false;
          if (transaction.id != null) {
            final lignesAffectees = await db.modifierTransactionCategorie(transaction);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            rapport.transactionsMisesAJour++;
          } else {
            await db.insererTransactionCategorie(transaction);
            rapport.transactionsCreees++;
          }
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleTransactions, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    return rapport;
  }

  // -------------------------------------------------------------------
  // EXPORT / IMPORT - Dettes
  // -------------------------------------------------------------------

  static const _feuilleDettes = 'Dettes';
  static const _feuilleRemboursements = 'Remboursements';

  static Future<void> exporterDettes() async {
    final db = DatabaseService.instance;

    // Noms lisibles des liens (moto ou entite de categorie), juste pour
    // affichage humain a cote des ID qui font foi.
    final motos = await db.listerMotos();
    final motosParId = {for (final m in motos) m.id: m};

    final excel = Excel.createExcel();
    final feuilleParDefaut = excel.getDefaultSheet();

    await _ecrireFeuillesDettes(excel, motosParId);

    if (feuilleParDefaut != null && feuilleParDefaut != _feuilleDettes) {
      excel.delete(feuilleParDefaut);
    }

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Echec de la generation du fichier Excel.');
    }

    final horodatage = DateTime.now();
    final nomFichier = 'douka_dettes_${_isoCompact(horodatage)}.xlsx';

    final dossierTemp = await getTemporaryDirectory();
    final cheminExport = p.join(dossierTemp.path, nomFichier);
    await File(cheminExport).writeAsBytes(bytes);

    await Share.shareXFiles(
      [XFile(cheminExport)],
      subject: 'Export Excel Dettes',
      text: 'Export Excel Dettes du ${_formaterDate(horodatage)}',
    );
  }

  /// Importe un fichier Excel genere par [exporterDettes]. "Lien ID" doit
  /// etre un ID de moto ou d'entite de categorie deja existant en base
  /// (ces donnees ne sont pas touchees par cet import) : si introuvable,
  /// la dette est importee sans lien plutot que rejetee.
  static Future<RapportImportDettes> importerDettes(
    String cheminFichier, {
    required bool remplacementComplet,
  }) async {
    final bytes = await File(cheminFichier).readAsBytes();
    final excel = Excel.decodeBytes(bytes);
    final rapport = RapportImportDettes();

    final sDettes = excel.tables[_feuilleDettes];
    if (sDettes == null) {
      throw Exception('Feuille "$_feuilleDettes" introuvable dans ce fichier.');
    }

    final db = DatabaseService.instance;

    if (remplacementComplet) {
      await db.viderDettes();
    }

    final motosIds = (await db.listerMotos()).map((m) => m.id).whereType<int>().toSet();
    final idDetteFichierVersDb = <int, int>{};

    for (var i = 1; i < sDettes.maxRows; i++) {
      final ligne = sDettes.rows[i];
      if (_ligneVide(ligne)) continue;
      final numeroLigne = i + 1;
      try {
        final idTxte = _texte(_valeur(ligne, 0));
        final nomPersonne = _texte(_valeur(ligne, 1));
        final montantTxt = _texte(_valeur(ligne, 2));
        final dateTxt = _texte(_valeur(ligne, 3));
        final notes = _texte(_valeur(ligne, 4));
        final lienType = _texte(_valeur(ligne, 5));
        final lienIdTxt = _texte(_valeur(ligne, 6));
        // Colonne 8 : absente des fichiers generes avant son ajout (voir
        // _ecrireFeuillesDettes) — _valeur() renvoie alors simplement null.
        final devise = _texte(_valeur(ligne, 8));

        if (nomPersonne == null || montantTxt == null || dateTxt == null) {
          rapport.erreurs.add(LigneErreurImport(
              _feuilleDettes, numeroLigne, 'Champs obligatoires manquants (Nom personne, Montant initial, Date).'));
          continue;
        }
        final montant = double.tryParse(montantTxt);
        final date = DateTime.tryParse(dateTxt);
        if (montant == null || date == null) {
          rapport.erreurs.add(LigneErreurImport(_feuilleDettes, numeroLigne, 'Montant initial ou date invalide.'));
          continue;
        }

        String? lienTypeFinal;
        int? lienIdFinal;
        final lienId = lienIdTxt != null ? int.tryParse(lienIdTxt) : null;
        if (lienType == AppConstants.detteLienMoto && lienId != null && motosIds.contains(lienId)) {
          lienTypeFinal = lienType;
          lienIdFinal = lienId;
        } else if (lienType == AppConstants.detteLienCategorieEntite && lienId != null) {
          final entite = await db.obtenirEntiteCategorie(lienId);
          if (entite != null) {
            lienTypeFinal = lienType;
            lienIdFinal = lienId;
          }
        }

        final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
        final dette = Dette(
          id: idFourni,
          nomPersonne: nomPersonne,
          montantInitial: montant,
          date: date,
          notes: notes,
          lienType: lienTypeFinal,
          lienId: lienIdFinal,
          // Sans effet si un lien est actif (deviseEffectiveDette() se base
          // alors sur le lien) ; utile seulement pour une dette independante.
          deviseSymbole: devise,
        );

        int idFinal;
        var misAJour = false;
        if (dette.id != null) {
          final lignesAffectees = await db.modifierDette(dette);
          misAJour = lignesAffectees > 0;
        }
        if (misAJour) {
          idFinal = dette.id!;
          rapport.dettesMisesAJour++;
        } else {
          idFinal = await db.insererDette(dette);
          rapport.dettesCreees++;
        }
        final idFichier = idTxte != null ? int.tryParse(idTxte) : null;
        if (idFichier != null) idDetteFichierVersDb[idFichier] = idFinal;
      } catch (e) {
        rapport.erreurs.add(LigneErreurImport(_feuilleDettes, numeroLigne, 'Erreur inattendue : $e'));
      }
    }

    final sRemboursements = excel.tables[_feuilleRemboursements];
    if (sRemboursements != null) {
      for (var i = 1; i < sRemboursements.maxRows; i++) {
        final ligne = sRemboursements.rows[i];
        if (_ligneVide(ligne)) continue;
        final numeroLigne = i + 1;
        try {
          final idTxte = _texte(_valeur(ligne, 0));
          final detteIdTxte = _texte(_valeur(ligne, 1));
          final montantTxt = _texte(_valeur(ligne, 3));
          final dateTxt = _texte(_valeur(ligne, 4));
          final notes = _texte(_valeur(ligne, 5));

          if (detteIdTxte == null || montantTxt == null || dateTxt == null) {
            rapport.erreurs.add(LigneErreurImport(
                _feuilleRemboursements, numeroLigne, 'Champs obligatoires manquants (Dette ID, Montant, Date).'));
            continue;
          }
          final detteIdFichier = int.tryParse(detteIdTxte);
          final detteId = detteIdFichier != null ? idDetteFichierVersDb[detteIdFichier] : null;
          if (detteId == null) {
            rapport.erreurs
                .add(LigneErreurImport(_feuilleRemboursements, numeroLigne, 'Dette introuvable (ID "$detteIdTxte").'));
            continue;
          }
          final montant = double.tryParse(montantTxt);
          final date = DateTime.tryParse(dateTxt);
          if (montant == null || date == null) {
            rapport.erreurs.add(LigneErreurImport(_feuilleRemboursements, numeroLigne, 'Montant ou date invalide.'));
            continue;
          }

          final idFourni = !remplacementComplet && idTxte != null ? int.tryParse(idTxte) : null;
          final remboursement = DetteRemboursement(
            id: idFourni,
            detteId: detteId,
            montant: montant,
            date: date,
            notes: notes,
          );

          var misAJour = false;
          if (remboursement.id != null) {
            final lignesAffectees = await db.modifierRemboursement(remboursement);
            misAJour = lignesAffectees > 0;
          }
          if (misAJour) {
            rapport.remboursementsMisAJour++;
          } else {
            await db.insererRemboursement(remboursement);
            rapport.remboursementsCrees++;
          }
        } catch (e) {
          rapport.erreurs.add(LigneErreurImport(_feuilleRemboursements, numeroLigne, 'Erreur inattendue : $e'));
        }
      }
    }

    return rapport;
  }

  // -------------------------------------------------------------------
  // Utilitaires
  // -------------------------------------------------------------------

  /// Ecrit les feuilles "Dettes" et "Remboursements" dans [excel] — logique
  /// partagee entre l'export global ([exporter]) et l'export dedie
  /// ([exporterDettes]), identique dans les deux cas.
  static Future<void> _ecrireFeuillesDettes(Excel excel, Map<int?, Moto> motosParId) async {
    final db = DatabaseService.instance;
    final dettes = await db.listerDettes();

    final sDettes = excel[_feuilleDettes];
    sDettes.appendRow([
      TextCellValue('ID'),
      TextCellValue('Nom personne'),
      TextCellValue('Montant initial'),
      TextCellValue('Date'),
      TextCellValue('Notes'),
      TextCellValue('Lien type'),
      TextCellValue('Lien ID'),
      TextCellValue('Lien nom'),
      // Ajoutee en derniere position (jamais inseree entre les colonnes
      // existantes) : un ancien fichier sans cette colonne reste
      // importable normalement, voir ExcelService._valeur().
      TextCellValue('Devise'),
    ]);
    for (final d in dettes) {
      String? lienNom;
      if (d.lienType == AppConstants.detteLienMoto && d.lienId != null) {
        lienNom = motosParId[d.lienId]?.nom;
      } else if (d.lienType == AppConstants.detteLienCategorieEntite && d.lienId != null) {
        final entite = await db.obtenirEntiteCategorie(d.lienId!);
        lienNom = entite?.nom;
      }
      // Toujours la devise EFFECTIVE (celle du lien s'il y en a un), pour
      // que le fichier reflete ce que l'app affiche reellement.
      final devise = await db.deviseEffectiveDette(d);
      sDettes.appendRow([
        d.id != null ? IntCellValue(d.id!) : null,
        TextCellValue(d.nomPersonne),
        DoubleCellValue(d.montantInitial),
        TextCellValue(_iso(d.date)),
        d.notes != null ? TextCellValue(d.notes!) : null,
        d.lienType != null ? TextCellValue(d.lienType!) : null,
        d.lienId != null ? IntCellValue(d.lienId!) : null,
        lienNom != null ? TextCellValue(lienNom) : null,
        TextCellValue(devise),
      ]);
    }

    final sRemboursements = excel[_feuilleRemboursements];
    sRemboursements.appendRow([
      TextCellValue('ID'),
      TextCellValue('Dette ID'),
      TextCellValue('Nom personne'),
      TextCellValue('Montant'),
      TextCellValue('Date'),
      TextCellValue('Notes'),
    ]);
    for (final d in dettes) {
      if (d.id == null) continue;
      final remboursements = await db.listerRemboursements(d.id!);
      for (final r in remboursements) {
        sRemboursements.appendRow([
          r.id != null ? IntCellValue(r.id!) : null,
          IntCellValue(r.detteId),
          TextCellValue(d.nomPersonne),
          DoubleCellValue(r.montant),
          TextCellValue(_iso(r.date)),
          r.notes != null ? TextCellValue(r.notes!) : null,
        ]);
      }
    }
  }

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
