import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moto_taxi_douka/core/constants.dart';
import 'package:moto_taxi_douka/models/categorie_activite.dart';
import 'package:moto_taxi_douka/models/categorie_entite.dart';
import 'package:moto_taxi_douka/models/categorie_gerant.dart';
import 'package:moto_taxi_douka/models/categorie_transaction.dart';
import 'package:moto_taxi_douka/models/depense.dart';
import 'package:moto_taxi_douka/models/dette.dart';
import 'package:moto_taxi_douka/models/moto.dart';
import 'package:moto_taxi_douka/models/versement.dart';
import 'package:moto_taxi_douka/services/backup_service.dart';
import 'package:moto_taxi_douka/services/database_service.dart';
import 'package:moto_taxi_douka/services/schedule_service.dart';
import 'package:moto_taxi_douka/services/excel_service.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final db = DatabaseService.instance;

Future<int> nouvelleMoto({String statut = AppConstants.motoActive}) => db.insererMoto(Moto(
      nom: 'Moto 1',
      chauffeur: 'Mamadou',
      montantVersement: 50000,
      frequenceType: AppConstants.freqHebdomadaire,
      frequenceValeur: DateTime.monday,
      dateDebut: DateTime(2026, 9, 7),
      statut: statut,
    ));

/// Categorie "Boutiques" dans sa propre devise, et une entite dedans.
Future<({int categorieId, int entiteId})> nouvelleEntite({String devise = 'FCFA'}) async {
  final categorieId = await db.insererCategorieActivite(
    CategorieActivite(nom: 'Boutiques', couleur: '#2D6CDF', deviseSymbole: devise),
  );
  final entiteId = await db.insererEntiteCategorie(CategorieEntite(categorieId: categorieId, nom: 'Boutique A'));
  return (categorieId: categorieId, entiteId: entiteId);
}

/// Dette liee ; [deviseSaisie] imite la valeur que le formulaire enregistrait
/// (la devise globale, meme pour une dette liee).
Future<int> nouvelleDette({String? lienType, int? lienId, String? deviseSaisie = 'FG', double montant = 100000}) =>
    db.insererDette(Dette(
      nomPersonne: 'Alpha',
      montantInitial: montant,
      date: DateTime(2026, 9, 1),
      lienType: lienType,
      lienId: lienId,
      deviseSymbole: deviseSaisie,
    ));

Future<void> deviseGlobale(String devise) async =>
    db.enregistrerParametres((await db.obtenirParametres()).copyWith(deviseSymbole: devise));

/// Repart d'un fichier de base vide avant chaque test.
Future<void> baseVide() async {
  await db.fermer();
  await databaseFactory.deleteDatabase(await db.cheminBaseDeDonnees());
}

/// Cree a la main une ancienne base (version [version]) puis la ferme : le
/// prochain acces via DatabaseService jouera la migration jusqu'a la
/// version actuelle, comme sur le telephone d'un utilisateur qui met a jour.
Future<void> ancienneBase(int version, {List<String> sql = const []}) async {
  final ancienne = await databaseFactory.openDatabase(
    await db.cheminBaseDeDonnees(),
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (d, _) async {
        for (final s in sql) {
          await d.execute(s);
        }
      },
    ),
  );
  await ancienne.close();
}

/// Tables presentes dans toute base v3 ou plus (celles que les migrations
/// suivantes modifient).
const tablesV3 = [
  'CREATE TABLE versements (id INTEGER PRIMARY KEY AUTOINCREMENT, moto_id INTEGER NOT NULL, '
      'date_echeance TEXT NOT NULL, date_validation TEXT, montant_prevu REAL NOT NULL, montant_paye REAL, '
      'statut TEXT NOT NULL, notes TEXT)',
  'CREATE TABLE parametres (id INTEGER PRIMARY KEY, pin_code_hash TEXT, '
      "biometrie_active INTEGER NOT NULL DEFAULT 0, devise_symbole TEXT NOT NULL DEFAULT 'FG', "
      'delai_notification_heures INTEGER NOT NULL DEFAULT 24, categorie_active_id INTEGER)',
  "INSERT INTO parametres (id) VALUES (1)",
  'CREATE TABLE categories_activite (id INTEGER PRIMARY KEY AUTOINCREMENT, devise_symbole TEXT NOT NULL)',
  'CREATE TABLE categorie_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, entite_id INTEGER NOT NULL, '
      'type TEXT NOT NULL, montant REAL NOT NULL, date TEXT NOT NULL, description TEXT)',
];

Future<List<String>> colonnes(String table) async {
  final lignes = await (await db.database).rawQuery('PRAGMA table_info($table)');
  return lignes.map((l) => l['name'] as String).toList();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(baseVide);
  tearDownAll(baseVide);

  group('migration', () {
    test('une base v3 (avant les dettes) se met a jour sans planter', () async {
      await ancienneBase(3, sql: tablesV3);

      expect(await colonnes('dettes'), contains('devise_symbole'));
    });

    test('une base v5 recoit le lien echeance -> dette et la liste des devises deja utilisees', () async {
      await ancienneBase(5, sql: [
        ...tablesV3,
        "UPDATE parametres SET devise_symbole = 'fg '",
        "INSERT INTO categories_activite (devise_symbole) VALUES ('Fcfa')",
        'CREATE TABLE dettes (id INTEGER PRIMARY KEY AUTOINCREMENT, devise_symbole TEXT)',
        "INSERT INTO dettes (devise_symbole) VALUES ('USD'), (NULL)",
      ]);

      expect(await colonnes('versements'), contains('dette_id'));
      expect(await db.listerDevises(), ['FCFA', 'FG', 'USD']);
      expect((await db.obtenirParametres()).deviseSymbole, 'FG');
    });

    test('une base v4 (dettes sans devise) recoit la colonne devise_symbole', () async {
      await ancienneBase(4, sql: [
        ...tablesV3,
        'CREATE TABLE dettes (id INTEGER PRIMARY KEY AUTOINCREMENT, nom_personne TEXT NOT NULL, '
            'montant_initial REAL NOT NULL, date TEXT NOT NULL, notes TEXT, date_creation TEXT NOT NULL, '
            'lien_type TEXT, lien_id INTEGER)',
      ]);

      expect(await colonnes('dettes'), contains('devise_symbole'));
    });
  });

  group('changement du montant de versement', () {
    Future<Map<int, double>> montantsParJour(int motoId) async =>
        {for (final v in await db.listerVersementsParMoto(motoId)) v.dateEcheance.day: v.montantPrevu};

    test('applique depuis sa date de mise en vigueur, meme aux periodes passees ou payees', () async {
      final motoId = await nouvelleMoto();
      // Un lundi par semaine (regle : un seul versement par semaine).
      Future<void> echeance(int mois, int jour, String statut, {double? paye}) => db.insererVersement(Versement(
          motoId: motoId, dateEcheance: DateTime(2026, mois, jour), montantPrevu: 50000, montantPaye: paye, statut: statut));
      await echeance(9, 7, AppConstants.versementPaye, paye: 50000); // avant la date : ancien montant
      await echeance(9, 14, AppConstants.versementPaye, paye: 50000); // payee a l'ancien montant
      await echeance(9, 21, AppConstants.versementPaye); // ancien import : payee sans montant
      await echeance(9, 28, AppConstants.versementEnRetard);
      await echeance(10, 5, AppConstants.versementEnDette); // la dette garde son montant
      await echeance(10, 12, AppConstants.versementEnAttente);

      expect(await db.changerMontant(motoId, 60000, DateTime(2026, 9, 14, 15, 30)), 4);

      expect(await montantsParJour(motoId), {7: 50000, 14: 60000, 21: 60000, 28: 60000, 5: 50000, 12: 60000});
      final parJour = {for (final v in await db.listerVersementsParMoto(motoId)) v.dateEcheance.day: v};
      // La plus ancienne d'abord : le 14/09 (passe a 60 000) est complete avec
      // l'argent du 21/09, le manque se retrouve sur la semaine la plus recente.
      expect(parJour[14]!.montantPaye, 60000);
      expect(parJour[21]!.montantPaye, 40000);
      expect(await db.listerChangementsMontant(motoId), [(depuis: DateTime(2026, 9, 14), montant: 60000.0)]);
      // Le montant de depart de la moto ne bouge pas.
      expect((await db.obtenirMoto(motoId))!.montantVersement, 50000);
    });

    test('chaque changement s\'arrete au suivant ; annuler un changement rend le montant d\'avant', () async {
      final motoId = await nouvelleMoto();
      for (final jour in [7, 14, 21, 28]) {
        await db.insererVersement(Versement(
            motoId: motoId, dateEcheance: DateTime(2026, 9, jour), montantPrevu: 50000,
            statut: AppConstants.versementEnRetard));
      }

      await db.changerMontant(motoId, 70000, DateTime(2026, 9, 21));
      await db.changerMontant(motoId, 60000, DateTime(2026, 9, 14)); // saisi apres, mais plus tot
      expect(await montantsParJour(motoId), {7: 50000, 14: 60000, 21: 70000, 28: 70000});

      await db.changerMontant(motoId, 65000, DateTime(2026, 9, 14)); // meme jour : remplace
      expect(await montantsParJour(motoId), {7: 50000, 14: 65000, 21: 70000, 28: 70000});
      expect((await db.listerChangementsMontant(motoId)).map((c) => c.montant), [65000, 70000]);

      await db.supprimerChangementMontant(motoId, DateTime(2026, 9, 21));
      expect(await montantsParJour(motoId), {7: 50000, 14: 65000, 21: 65000, 28: 65000});

      await db.supprimerChangementMontant(motoId, DateTime(2026, 9, 14));
      expect(await montantsParJour(motoId), {7: 50000, 14: 50000, 21: 50000, 28: 50000});
      expect(await db.listerChangementsMontant(motoId), isEmpty);
    });

    test('changement prevu : les echeances creees plus tard prennent le montant de leur date', () async {
      final aujourdHui = DateTime.now();
      final debut = DateTime(aujourdHui.year, aujourdHui.month, aujourdHui.day);
      final moto = Moto(
        nom: 'Moto 1',
        chauffeur: 'Mamadou',
        montantVersement: 50000,
        frequenceType: AppConstants.freqHebdomadaire,
        frequenceValeur: debut.weekday,
        dateDebut: debut,
      );
      final motoId = await db.insererMoto(moto);
      await db.changerMontant(motoId, 60000, DateTime(debut.year, debut.month, debut.day + 14));

      await db.assurerEcheances(moto.copyWith(id: motoId));

      final versements = (await db.listerVersementsParMoto(motoId)).reversed;
      expect(versements.map((v) => v.montantPrevu), [50000, 50000, 60000, 60000]);
    });

    test('l\'historique suit l\'export Excel et revient a l\'import ; supprime avec la moto', () async {
      final motoId = await nouvelleMoto();
      await db.changerMontant(motoId, 60000, DateTime(2026, 9, 14));
      await db.changerMontant(motoId, 65000.5, DateTime(2027, 1, 1));
      final dossier = await Directory.systemTemp.createTemp('montants_test');
      addTearDown(() => dossier.delete(recursive: true));
      final chemin = '${dossier.path}/export.xlsx';
      await File(chemin).writeAsBytes(await ExcelService.classeurComplet());

      final rapport = await ExcelService.importer(chemin, remplacementComplet: true);

      expect(rapport.erreurs, isEmpty);
      final importee = (await db.listerMotos()).single;
      expect(importee.montantVersement, 50000);
      expect(await db.listerChangementsMontant(importee.id!), [
        (depuis: DateTime(2026, 9, 14), montant: 60000.0),
        (depuis: DateTime(2027, 1, 1), montant: 65000.5),
      ]);

      await db.supprimerMoto(importee.id!);
      final restants = await (await db.database).query('montants_moto');
      expect(restants, isEmpty);
    });

    test('une base v8 recoit la table de l\'historique des montants', () async {
      await ancienneBase(8, sql: [...tablesV3, 'CREATE TABLE motos (id INTEGER PRIMARY KEY)']);

      expect(await colonnes('montants_moto'), ['moto_id', 'depuis', 'montant']);
    });
  });

  group('comptes par personne dans une entite (proprietaire + gerants)', () {
    Future<void> operation(int entiteId, String type, double montant, {int? gerantId}) =>
        db.insererTransactionCategorie(CategorieTransaction(
            entiteId: entiteId, type: type, montant: montant, date: DateTime(2026, 10, 1), gerantId: gerantId));

    test('chaque personne a son solde, le total general en est la somme (negatif autorise)', () async {
      final e = await nouvelleEntite();
      final ibrahim = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'Ibrahim'));
      final aissatou = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'Aissatou'));
      await operation(e.entiteId, AppConstants.transactionRevenu, 1000000);
      await operation(e.entiteId, AppConstants.transactionRevenu, 800000, gerantId: ibrahim);
      await operation(e.entiteId, AppConstants.transactionDepense, 100000, gerantId: ibrahim);
      await operation(e.entiteId, AppConstants.transactionDepense, 150000, gerantId: aissatou);

      expect(await db.soldesParPersonne(e.entiteId), {null: 1000000, ibrahim: 700000, aissatou: -150000});
      expect(await db.soldeEntiteCategorie(e.entiteId), 1550000);
    });

    test('un gerant avec des operations ne peut pas etre supprime, seulement archive', () async {
      final e = await nouvelleEntite();
      final sansOperation = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'A'));
      final avecOperation = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'B'));
      await operation(e.entiteId, AppConstants.transactionRevenu, 5000, gerantId: avecOperation);

      await db.supprimerGerant(sansOperation);
      await expectLater(db.supprimerGerant(avecOperation), throwsException);
      expect((await db.listerGerants(e.entiteId)).map((g) => g.id), [avecOperation]);
    });

    test('un nom de gerant vide, "Proprietaire" ou deja pris dans l\'entite est refuse', () async {
      final e = await nouvelleEntite();
      final autre = await db.insererEntiteCategorie(CategorieEntite(categorieId: e.categorieId, nom: 'Boutique B'));
      final ibrahim = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'Ibrahim'));
      final aissatou = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'Aïssatou'));

      for (final nom in ['  ', 'proprietaire', ' ibrahim ', 'AÏSSATOU']) {
        await expectLater(db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: nom)), throwsException);
      }
      final renommee = (await db.listerGerants(e.entiteId)).firstWhere((g) => g.id == aissatou);
      await expectLater(db.modifierGerant(renommee.copyWith(nom: 'IBRAHIM')), throwsException);

      // Meme nom dans une autre entite, renommer en gardant son nom, archiver : permis.
      await db.insererGerant(CategorieGerant(entiteId: autre, nom: 'Ibrahim'));
      final g = (await db.listerGerants(e.entiteId)).firstWhere((g) => g.id == ibrahim);
      await db.modifierGerant(g.copyWith(nom: ' Ibrahim ', statut: AppConstants.motoArchivee));
      final archive = (await db.listerGerants(e.entiteId)).firstWhere((g) => g.id == ibrahim);
      expect((archive.nom, archive.statut), ('Ibrahim', AppConstants.motoArchivee));
    });

    test('supprimer l\'entite supprime aussi ses gerants', () async {
      final e = await nouvelleEntite();
      await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'A'));

      await db.supprimerEntiteCategorie(e.entiteId);

      expect(await db.listerGerants(e.entiteId), isEmpty);
    });

    test('une base v7 garde ses operations, toutes sur le compte du proprietaire', () async {
      await ancienneBase(7, sql: [
        ...tablesV3,
        "INSERT INTO categorie_transactions (entite_id, type, montant, date) "
            "VALUES (1, 'revenu', 30000, '2026-09-01T00:00:00.000')",
      ]);

      expect(await db.soldesParPersonne(1), {null: 30000});
      expect(await db.listerGerants(1), isEmpty);
      expect(await db.obtenirAudioTransaction(1), isNull);
    });
  });

  group('note vocale d\'une operation', () {
    final audio = Uint8List.fromList([1, 2, 3, 4]);

    Future<int> operation(int entiteId, {Uint8List? audio}) => db.insererTransactionCategorie(
        CategorieTransaction(
            entiteId: entiteId, type: AppConstants.transactionDepense, montant: 1000, date: DateTime(2026, 10, 1)),
        audio: audio);

    test('la note est gardee avec l\'operation et reecoutee telle quelle', () async {
      final e = await nouvelleEntite();
      final avec = await operation(e.entiteId, audio: audio);
      final sans = await operation(e.entiteId);

      expect(await db.obtenirAudioTransaction(avec), audio);
      expect(await db.obtenirAudioTransaction(sans), isNull);
      expect(await db.transactionsAvecAudio(e.entiteId), {avec});
    });

    test('supprimer l\'operation, l\'entite ou vider la categorie supprime ses notes', () async {
      final e = await nouvelleEntite();
      final t1 = await operation(e.entiteId, audio: audio);
      final t2 = await operation(e.entiteId, audio: audio);
      await db.supprimerTransactionCategorie(t1);
      expect(await db.obtenirAudioTransaction(t1), isNull);
      expect(await db.obtenirAudioTransaction(t2), audio);

      await db.supprimerEntiteCategorie(e.entiteId);
      expect(await db.obtenirAudioTransaction(t2), isNull);

      final e2 = await nouvelleEntite();
      final t3 = await operation(e2.entiteId, audio: audio);
      await db.viderDonneesCategorie(e2.categorieId);
      expect(await db.obtenirAudioTransaction(t3), isNull);

      final e3 = await nouvelleEntite();
      final t4 = await operation(e3.entiteId, audio: audio);
      await db.supprimerCategorieActivite(e3.categorieId);
      expect(await db.obtenirAudioTransaction(t4), isNull);

      final e4 = await nouvelleEntite();
      final t5 = await operation(e4.entiteId, audio: audio);
      await db.viderToutesLesCategoriesActivite();
      expect(await db.obtenirAudioTransaction(t5), isNull);
    });
  });

  group('dettes liees a une moto ou une entite supprimee', () {
    test('supprimer une moto garde ses dettes, detachees, dans la devise globale', () async {
      await deviseGlobale('GNF');
      final motoId = await nouvelleMoto();
      final detteId = await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: motoId);

      await db.supprimerMoto(motoId);

      final dette = (await db.obtenirDette(detteId))!;
      expect(dette.lienType, isNull);
      expect(dette.lienId, isNull);
      expect(await db.deviseEffectiveDette(dette), 'GNF');
    });

    test('vider une categorie (import "tout remplacer") detache les dettes de ses entites, dans sa devise', () async {
      final boutique = await nouvelleEntite(devise: 'FCFA');
      final autre = await nouvelleEntite(devise: 'USD');
      final detteVidee = await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId);
      final detteGardee = await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: autre.entiteId);

      await db.viderDonneesCategorie(boutique.categorieId);

      final videe = (await db.obtenirDette(detteVidee))!;
      expect(videe.lienType, isNull);
      expect(await db.deviseEffectiveDette(videe), 'FCFA');
      expect((await db.obtenirDette(detteGardee))!.lienId, autre.entiteId);
    });

    test('supprimer une entite garde ses dettes, detachees, dans la devise de sa categorie', () async {
      final boutique = await nouvelleEntite(devise: 'FCFA');
      final detteId = await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId);

      await db.supprimerEntiteCategorie(boutique.entiteId);

      final dette = (await db.obtenirDette(detteId))!;
      expect(dette.lienType, isNull);
      expect(await db.deviseEffectiveDette(dette), 'FCFA');
    });

    test('supprimer une categorie detache les dettes de ses entites, dans sa devise', () async {
      final boutique = await nouvelleEntite(devise: 'FCFA');
      final detteId = await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId);

      await db.supprimerCategorieActivite(boutique.categorieId);

      final dette = (await db.obtenirDette(detteId))!;
      expect(dette.lienType, isNull);
      expect(await db.deviseEffectiveDette(dette), 'FCFA');
    });

    test('un import "tout remplacer" detache les dettes des motos et des entites effacees', () async {
      final motoId = await nouvelleMoto();
      final boutique = await nouvelleEntite(devise: 'FCFA');
      final detteMoto = await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: motoId);
      final detteBoutique =
          await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId);

      await db.viderToutesLesDonnees();
      await db.viderToutesLesCategoriesActivite();

      expect((await db.obtenirDette(detteMoto))!.lienType, isNull);
      final boutiqueDetachee = (await db.obtenirDette(detteBoutique))!;
      expect(boutiqueDetachee.lienType, isNull);
      expect(await db.deviseEffectiveDette(boutiqueDetachee), 'FCFA');
    });
  });

  group('soldes et devises des dettes (en lot)', () {
    test('le solde de chaque dette tient compte de ses remboursements', () async {
      final a = await nouvelleDette(montant: 100000);
      final b = await nouvelleDette(montant: 80000);
      await db.insererRemboursement(DetteRemboursement(detteId: a, montant: 30000, date: DateTime(2026, 9, 10)));
      await db.insererRemboursement(DetteRemboursement(detteId: a, montant: 20000, date: DateTime(2026, 9, 20)));

      expect(await db.soldesDettes(), {a: 50000, b: 80000});
    });

    test('les devises en lot sont celles de chaque dette prise seule', () async {
      final motoId = await nouvelleMoto();
      final boutique = await nouvelleEntite(devise: 'FCFA');
      final dettes = [
        await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: motoId),
        await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId),
        await nouvelleDette(deviseSaisie: 'GNF'),
      ];

      final enLot = await db.devisesEffectivesDettes([for (final id in dettes) (await db.obtenirDette(id))!]);

      expect(enLot, {dettes[0]: 'FG', dettes[1]: 'FCFA', dettes[2]: 'GNF'});
    });

    test('les totaux en cours sont groupes par devise et ignorent les dettes soldees', () async {
      final motoId = await nouvelleMoto();
      final boutique = await nouvelleEntite(devise: 'FCFA');
      await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: motoId, montant: 100000);
      await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId, montant: 50000);
      final soldee = await nouvelleDette(deviseSaisie: 'GNF', montant: 30000);
      await db.insererRemboursement(DetteRemboursement(detteId: soldee, montant: 30000, date: DateTime(2026, 9, 5)));

      expect(await db.totauxDettesEnCoursParDevise(), {'FG': 100000, 'FCFA': 50000});
    });
  });

  group('remboursement de dette -> caisse de la moto', () {
    Future<void> versementPaye(int motoId, double montant, DateTime date) => db.insererVersement(Versement(
          motoId: motoId,
          dateEcheance: date,
          dateValidation: date,
          montantPrevu: montant,
          montantPaye: montant,
          statut: AppConstants.versementPaye,
        ));

    Future<void> rembourser(int detteId, double montant, DateTime date) =>
        db.insererRemboursement(DetteRemboursement(detteId: detteId, montant: montant, date: date));

    test('le remboursement d\'une dette liee entre dans la caisse de sa moto, et seulement elle', () async {
      final motoA = await nouvelleMoto();
      final motoB = await nouvelleMoto();
      final boutique = await nouvelleEntite();
      await versementPaye(motoA, 50000, DateTime(2026, 9, 8));
      await rembourser(await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: motoA), 30000, DateTime(2026, 9, 10));
      await rembourser(await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: motoB), 10000, DateTime(2026, 9, 11));
      await rembourser(await nouvelleDette(), 5000, DateTime(2026, 9, 12));
      await rembourser(
          await nouvelleDette(lienType: AppConstants.detteLienCategorieEntite, lienId: boutique.entiteId),
          7000,
          DateTime(2026, 9, 13));

      expect(await db.totalEncaisse(motoId: motoA), 80000);
      expect(await db.totalEncaisse(motoId: motoB), 10000);
      expect(await db.totalEncaisse(), 90000);
    });

    test('la periode filtre le remboursement sur sa propre date', () async {
      final moto = await nouvelleMoto();
      await rembourser(await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: moto), 30000, DateTime(2026, 9, 10));

      expect(await db.totalEncaisse(motoId: moto, debut: DateTime(2026, 9, 1), fin: DateTime(2026, 9, 30)), 30000);
      expect(await db.totalEncaisse(motoId: moto, debut: DateTime(2026, 9, 15)), 0);
    });

    test('le remboursement ne change pas le retard ou l\'avance du chauffeur sur ses versements', () async {
      final moto = await nouvelleMoto();
      final avant = await db.compteMoto(motoId: moto);

      await rembourser(await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: moto), 30000, DateTime(2026, 9, 10));

      expect(await db.compteMoto(motoId: moto), avant);
    });

    test('les statistiques par periode et l\'activite recente incluent le remboursement', () async {
      final moto = await nouvelleMoto();
      final maintenant = DateTime.now();
      await versementPaye(moto, 50000, maintenant);
      await rembourser(await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: moto), 30000, maintenant);

      final parMois = await db.totalEncaisseParPeriode(periode: 'mois', motoId: moto, nombrePeriodes: 2);
      final activite = await db.listerRemboursementsMotos(motoId: moto);

      expect(parMois.last.value, 80000);
      expect(activite.single.remboursement.montant, 30000);
      expect(activite.single.dette.nomPersonne, 'Alpha');
    });
  });

  group('retards', () {
    final aujourdHui = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    Future<int> echeance(int motoId, DateTime date, {double prevu = 50000, double? paye}) => db.insererVersement(Versement(
          motoId: motoId,
          dateEcheance: date,
          dateValidation: paye != null ? date : null,
          montantPrevu: prevu,
          montantPaye: paye,
          statut: paye != null ? AppConstants.versementPaye : AppConstants.versementEnAttente,
        ));

    Future<String> statut(int motoId, DateTime date) async => (await db.listerVersementsParMoto(motoId))
        .firstWhere((v) => v.dateEcheance == date)
        .statut;

    test('une echeance du jour n\'est pas en retard le jour meme, celle d\'hier l\'est', () async {
      final moto = await nouvelleMoto();
      final hier = aujourdHui.subtract(const Duration(days: 1));
      await echeance(moto, aujourdHui);
      await echeance(moto, hier);

      await db.actualiserRetards();

      expect(await statut(moto, aujourdHui), AppConstants.versementEnAttente);
      expect(await statut(moto, hier), AppConstants.versementEnRetard);
    });

    test('le solde ne compte l\'echeance du jour comme due qu\'a partir du lendemain', () async {
      final moto = await nouvelleMoto();
      await echeance(moto, aujourdHui);

      expect(await db.compteMoto(motoId: moto), (retard: 0.0, avance: 0.0));
    });

    test('retard global : moto par moto, l\'avance d\'une moto ne compense pas une autre, moto suspendue comprise', () async {
      final enRetard = await nouvelleMoto();
      final enAvance = await nouvelleMoto();
      final suspendue = await nouvelleMoto(statut: AppConstants.motoSuspendue);
      await echeance(enRetard, DateTime(2026, 9, 1));
      await echeance(enAvance, DateTime(2026, 9, 1), paye: 80000);
      await echeance(suspendue, DateTime(2026, 9, 1), prevu: 300000, paye: 300000);

      final comptes = await db.comptesMotos();

      expect(comptes, {
        enRetard: (retard: 50000.0, avance: 0.0),
        enAvance: (retard: 0.0, avance: 30000.0),
        suspendue: (retard: 0.0, avance: 0.0),
      });
    });
  });

  group('accueil', () {
    test('l\'activite recente montre les versements payes, meme avec beaucoup d\'echeances a venir', () async {
      final moto = await nouvelleMoto();
      await db.insererVersement(Versement(
        motoId: moto,
        dateEcheance: DateTime(2026, 9, 7),
        dateValidation: DateTime(2026, 9, 7),
        montantPrevu: 50000,
        montantPaye: 50000,
        statut: AppConstants.versementPaye,
      ));
      for (var i = 0; i < 20; i++) {
        await db.insererVersement(Versement(motoId: moto, dateEcheance: DateTime(2027, 1, 1 + i), montantPrevu: 50000));
      }

      final recents = await db.listerPaiementsRecents(limite: 15);

      expect(recents.single.montant, 50000);
      expect(recents.single.date, DateTime(2026, 9, 7));
      expect(recents.single.motoId, moto);
    });

    test('les depenses recentes suivent le filtre de periode', () async {
      final moto = await nouvelleMoto();
      final categorie = (await db.listerCategories()).first.id!;
      await db.insererDepense(Depense(motoId: moto, categorieId: categorie, montant: 5000, date: DateTime(2026, 8, 20)));
      await db.insererDepense(Depense(motoId: moto, categorieId: categorie, montant: 7000, date: DateTime(2026, 9, 20)));

      final septembre = await db.listerDepensesRecentes(debut: DateTime(2026, 9, 1), fin: DateTime(2026, 9, 30));

      expect(septembre.single.montant, 7000);
    });

    test('deux chargements simultanes ne creent pas d\'echeances en double', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;

      await Future.wait([db.assurerEcheances(moto), db.assurerEcheances(moto)]);

      final dates = (await db.listerVersementsParMoto(moto.id!)).map((v) => v.dateEcheance).toList();
      expect(dates.toSet().length, dates.length);
    });
  });

  test('invariants : l\'app s\'adapte seule a chaque modification (jour, frequence, date, montant, pause, dette)', () async {
    final aujourdHui = ScheduleService.aujourdHui();
    var moto = (await db.obtenirMoto(await db.insererMoto(Moto(
      nom: 'TVs 125',
      chauffeur: 'Abdoul',
      montantVersement: 185000,
      frequenceType: AppConstants.freqHebdomadaire,
      frequenceValeur: DateTime.monday,
      dateDebut: aujourdHui.subtract(const Duration(days: 70)),
    ))))!;
    await db.assurerEcheances(moto);
    var encaisse = 0.0;

    Future<void> verifier(String etape) async {
      final echeances = (await db.listerVersementsParMoto(moto.id!)).map((v) => v.dateEcheance).toList()..sort();
      // 1. Un seul versement par semaine du calendrier (tous les rythmes ici : une semaine ou plus).
      for (var i = 1; i < echeances.length; i++) {
        expect(
            ScheduleService.memePeriode(echeances[i - 1], echeances[i],
                type: AppConstants.freqHebdomadaire, valeur: DateTime.monday),
            isFalse,
            reason: '$etape : ${echeances[i - 1]} et ${echeances[i]} dans la meme semaine');
      }
      // 5. Jamais plus que son montant sur une echeance (un surplus va aux periodes suivantes).
      for (final v in await db.listerVersementsParMoto(moto.id!)) {
        expect((v.montantPaye ?? 0) <= v.montantPrevu, isTrue,
            reason: '$etape : ${v.dateEcheance} payee ${v.montantPaye} pour ${v.montantPrevu}');
      }
      // 6. La plus ancienne d'abord : pas d'echeance incomplete suivie d'une echeance payee (hors dettes et pause).
      final aVenir = (await db.listerVersementsParMoto(moto.id!))
          .where((v) =>
              v.statut != AppConstants.versementEnDette &&
              !(moto.statut != AppConstants.motoActive && v.statut == AppConstants.versementEnAttente))
          .toList()
        ..sort((a, b) => a.dateEcheance.compareTo(b.dateEcheance));
      for (var i = 1; i < aVenir.length; i++) {
        if ((aVenir[i].montantPaye ?? 0) > 0) {
          expect(ScheduleService.resteDu(aVenir[i - 1]), 0,
              reason: '$etape : ${aVenir[i - 1].dateEcheance} incomplete avant ${aVenir[i].dateEcheance} payee');
        }
      }
      // 2. Rien de deja paye n'est perdu ni compte deux fois.
      expect(await db.totalEncaisse(motoId: moto.id!), encaisse, reason: etape);
      // 3. Fiche, accueil et relance disent la meme chose.
      final fiche = await db.compteMoto(motoId: moto.id!);
      final relance = ScheduleService.periodesAPayer(
        existants: await db.listerVersementsParMoto(moto.id!),
        moto: moto,
        aujourdHui: aujourdHui,
      ).where((p) => p.date.isBefore(aujourdHui)).fold<double>(0, (t, p) => t + p.reste);
      expect(relance, fiche.retard, reason: '$etape : relance $relance, fiche $fiche');
      if (moto.statut == AppConstants.motoActive) {
        expect((await db.comptesMotos())[moto.id], fiche, reason: etape);
        // 4. Toujours les prochaines echeances a venir.
        expect(
            (await db.listerVersementsParMoto(moto.id!))
                .where((v) => v.statut == AppConstants.versementEnAttente && !v.dateEcheance.isBefore(aujourdHui))
                .length,
            ScheduleService.fenetreEcheances,
            reason: etape);
      }
    }

    Future<void> changerPlan(String etape, Moto nouveau, {bool depuisDateDebut = false}) async {
      final retardAvant = (await db.compteMoto(motoId: moto.id!)).retard;
      moto = nouveau;
      await db.modifierMoto(moto);
      await db.replanifierEcheances(moto, depuisDateDebut: depuisDateDebut);
      await verifier(etape);
      // 7. Un changement de plan n'efface jamais un retard deja du.
      expect((await db.compteMoto(motoId: moto.id!)).retard, greaterThanOrEqualTo(retardAvant),
          reason: '$etape : retard efface');
    }

    Future<void> encaisser(String etape, double montant, {Set<DateTime>? choisies}) async {
      await db.encaisser(moto, montant, choisies: choisies);
      encaisse += montant;
      await db.assurerEcheances(moto); // comme la fiche moto au rechargement
      await verifier(etape);
    }

    await verifier('creation');
    await encaisser('premier paiement', 400000);
    await changerPlan('lundi -> vendredi', moto.copyWith(frequenceValeur: DateTime.friday));
    await changerPlan('vendredi -> mercredi', moto.copyWith(frequenceValeur: DateTime.wednesday));
    await changerPlan(
        'date de debut avancee + vendredi',
        moto.copyWith(
            frequenceValeur: DateTime.friday, dateDebut: aujourdHui.subtract(const Duration(days: 90))),
        depuisDateDebut: true);
    await changerPlan('hebdomadaire -> mensuel (le 15)',
        moto.copyWith(frequenceType: AppConstants.freqMensuelle, frequenceValeur: 15));
    await changerPlan('mensuel -> hebdomadaire (lundi)',
        moto.copyWith(frequenceType: AppConstants.freqHebdomadaire, frequenceValeur: DateTime.monday));
    await changerPlan('tous les 10 jours',
        moto.copyWith(frequenceType: AppConstants.freqPersonnalisee, frequenceValeur: 10));
    await db.changerMontant(moto.id!, 200000, aujourdHui.subtract(const Duration(days: 30)));
    await verifier('nouveau montant depuis 30 jours');
    final unRetard = (await db.listerVersementsParMoto(moto.id!))
        .lastWhere((v) => v.statut == AppConstants.versementEnRetard);
    await db.marquerEnDette(unRetard, moto);
    await verifier('retard passe en dette');
    await db.changerMontant(moto.id!, 150000, aujourdHui.subtract(const Duration(days: 20)));
    await verifier('montant baisse : le trop-paye devient de l\'avance');
    final aValider = (await db.listerVersementsParMoto(moto.id!)).firstWhere(
        (v) => v.statut == AppConstants.versementEnRetard || v.statut == AppConstants.versementEnAttente);
    await db.validerVersement(aValider.id!, montantPaye: aValider.montantPrevu + 100000);
    encaisse += aValider.montantPrevu + 100000;
    await db.assurerEcheances(moto); // comme la fiche moto au rechargement
    await verifier('valider avec 100 000 de plus');
    final aCorriger = (await db.listerVersementsParMoto(moto.id!))
        .firstWhere((v) => v.statut == AppConstants.versementPaye && (v.montantPaye ?? 0) > 0);
    await db.modifierMontantPaye(aCorriger.id!, aCorriger.montantPaye! + 50000);
    encaisse += 50000;
    await db.assurerEcheances(moto); // comme la fiche moto au rechargement
    await verifier('corriger un paiement a la hausse');
    moto = moto.copyWith(statut: AppConstants.motoSuspendue);
    await db.modifierMoto(moto);
    await verifier('suspendue');
    moto = moto.copyWith(statut: AppConstants.motoActive);
    await db.modifierMoto(moto);
    await db.redemarrerEcheancesApresReactivation(moto);
    await verifier('reactivee');
    final futures = ScheduleService.periodesChoisissables(
            moto: moto,
            existants: await db.listerVersementsParMoto(moto.id!),
            changements: await db.listerChangementsMontant(moto.id!),
            aujourdHui: aujourdHui)
        .toList();
    await encaisser('versement sur toutes les periodes proposees, retards compris (dont des pas encore creees)',
        futures.fold<double>(0, (t, p) => t + p.reste),
        choisies: futures.map((p) => p.date).toSet());
    await encaisser('gros paiement (avance)', 2000000);
    await db.changerMontant(moto.id!, 260000, aujourdHui);
    await db.assurerEcheances(moto); // comme la fiche moto au rechargement
    await verifier('avance en cours, montant en hausse');
    await db.changerMontant(moto.id!, 120000, aujourdHui);
    await db.assurerEcheances(moto);
    await verifier('avance en cours, montant en baisse');
  });

  test('ajouter versement : periodes choisies, une future creee au rythme, journal et solde a jour', () async {
    final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
    await db.assurerEcheances(moto);
    final avant = await db.compteMoto(motoId: moto.id!);
    final periodes = ScheduleService.periodesChoisissables(
        moto: moto,
        existants: await db.listerVersementsParMoto(moto.id!),
        changements: const [],
        aujourdHui: ScheduleService.aujourdHui());
    final futureNonCreee = periodes.last.date; // au-dela des echeances deja creees
    expect((await db.listerVersementsParMoto(moto.id!)).any((v) => v.dateEcheance == futureNonCreee), isFalse);

    // La plus ancienne d'abord : toutes les periodes jusqu'a celle choisie.
    final total = periodes.fold<double>(0, (t, p) => t + p.reste);
    final affectations = await db.encaisser(moto, total, choisies: periodes.map((p) => p.date).toSet());

    expect(affectations.map((a) => a.date), periodes.map((p) => p.date));
    final apres = await db.listerVersementsParMoto(moto.id!);
    final creee = apres.singleWhere((v) => v.dateEcheance == futureNonCreee);
    expect((creee.statut, creee.montantPaye, creee.montantPrevu), (AppConstants.versementPaye, 50000, 50000));
    expect(await db.totalEncaisse(motoId: moto.id!), total);
    // Tout le retard est paye, le reste est de l'avance.
    expect(await db.compteMoto(motoId: moto.id!), (retard: 0.0, avance: total - avant.retard));
    // Le roulement ne recree rien dans la periode payee d'avance.
    await db.assurerEcheances(moto);
    expect((await db.listerVersementsParMoto(moto.id!)).where((v) => v.dateEcheance == futureNonCreee).length, 1);
  });

  test('coherence : fiche, accueil et relance donnent le meme du apres changement de jour, paiement et dette', () async {
    var moto = (await db.obtenirMoto(await nouvelleMoto()))!;
    await db.assurerEcheances(moto);
    // Lundi -> mercredi, comme la TVs 125.
    moto = moto.copyWith(frequenceValeur: DateTime.wednesday);
    await db.modifierMoto(moto);
    await db.replanifierEcheances(moto, depuisDateDebut: false);
    await db.encaisser(moto, 80000);
    final enRetard = (await db.listerVersementsParMoto(moto.id!))
        .where((v) => v.statut == AppConstants.versementEnRetard)
        .last;
    await db.marquerEnDette(enRetard, moto);

    final aujourdHui = ScheduleService.aujourdHui();
    final relance = ScheduleService.periodesAPayer(
      existants: await db.listerVersementsParMoto(moto.id!),
      moto: moto,
      aujourdHui: aujourdHui,
    ).where((p) => p.date.isBefore(aujourdHui)).fold<double>(0, (t, p) => t + p.reste);
    final fiche = await db.compteMoto(motoId: moto.id!);

    expect(relance, greaterThan(0));
    expect(fiche.retard, relance);
    expect((await db.comptesMotos())[moto.id], fiche);
  });

  group('regles du client : un versement par periode, l\'argent en trop devient de l\'avance', () {
    Future<int> echeanceDe(int motoId, DateTime date, {double paye = 0, String? statut}) => db.insererVersement(Versement(
          motoId: motoId,
          dateEcheance: date,
          dateValidation: paye > 0 ? date : null,
          montantPrevu: 50000,
          montantPaye: paye > 0 ? paye : null,
          statut: statut ?? (paye > 0 ? AppConstants.versementPaye : AppConstants.versementEnRetard),
        ));
    Future<Map<DateTime, Versement>> parDate(int motoId) async =>
        {for (final v in await db.listerVersementsParMoto(motoId)) v.dateEcheance: v};

    test('doublon dans la meme semaine (lundi 14/09 + mercredi 16/09) : le second disparait, rien n\'est perdu', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!.copyWith(frequenceValeur: DateTime.wednesday);
      await db.modifierMoto(moto);
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      await echeanceDe(moto.id!, DateTime(2026, 9, 16));
      await echeanceDe(moto.id!, DateTime(2026, 9, 23));

      await db.normaliser(moto.id!);

      expect((await parDate(moto.id!)).keys.toList()..sort(), [DateTime(2026, 9, 14), DateTime(2026, 9, 23)]);
    });

    test('doublon deja paye : son argent passe a l\'echeance gardee de la semaine, a sa date de paiement', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      await echeanceDe(moto.id!, DateTime(2026, 9, 16), paye: 50000);
      final encaisse = await db.totalEncaisse(motoId: moto.id!);

      await db.normaliser(moto.id!);

      final v = await parDate(moto.id!);
      expect(v.containsKey(DateTime(2026, 9, 16)), isFalse);
      expect((v[DateTime(2026, 9, 14)]!.statut, v[DateTime(2026, 9, 14)]!.montantPaye), (AppConstants.versementPaye, 50000));
      expect(await db.totalEncaisse(motoId: moto.id!), encaisse);
      // L'argent garde sa vraie date : le 16/09.
      expect(await db.totalEncaisse(motoId: moto.id!, debut: DateTime(2026, 9, 16), fin: DateTime(2026, 9, 16, 23)), 50000);
    });

    test('valider avec plus que le montant : le surplus est une avance deduite des echeances suivantes', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final quatorze = await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      await echeanceDe(moto.id!, DateTime(2026, 9, 21));
      await echeanceDe(moto.id!, DateTime(2026, 9, 28));

      await db.validerVersement(quatorze, montantPaye: 120000);

      final v = await parDate(moto.id!);
      expect(v[DateTime(2026, 9, 14)]!.montantPaye, 50000);
      expect(v[DateTime(2026, 9, 21)]!.montantPaye, 50000);
      expect(v[DateTime(2026, 9, 28)]!.montantPaye, 20000);
      expect(await db.totalEncaisse(motoId: moto.id!), 120000);
    });

    test('corriger un montant paye a la hausse : le surplus va a l\'echeance suivante', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final quatorze = await echeanceDe(moto.id!, DateTime(2026, 9, 14), paye: 50000);
      await echeanceDe(moto.id!, DateTime(2026, 9, 21));

      await db.modifierMontantPaye(quatorze, 80000);

      final v = await parDate(moto.id!);
      expect((v[DateTime(2026, 9, 14)]!.montantPaye, v[DateTime(2026, 9, 21)]!.montantPaye), (50000, 30000));
      expect(await db.totalEncaisse(motoId: moto.id!), 80000);
    });

    test('avance en cours et nouveau montant : l\'avance se redistribue selon le nouveau montant', () async {
      final aujourdHui = ScheduleService.aujourdHui();
      final moto = (await db.obtenirMoto(await db.insererMoto(Moto(
        nom: 'Moto 1',
        chauffeur: 'Mamadou',
        montantVersement: 50000,
        frequenceType: AppConstants.freqHebdomadaire,
        frequenceValeur: DateTime.monday,
        dateDebut: aujourdHui, // aucun retard : seulement de l'avance
      ))))!;
      await db.assurerEcheances(moto);
      final futures = (await db.listerVersementsParMoto(moto.id!))
          .where((v) => !v.dateEcheance.isBefore(aujourdHui))
          .map((v) => v.dateEcheance)
          .toList()
        ..sort();
      // Deux semaines payees d'avance a 50 000.
      await db.encaisser(moto, 100000, choisies: {futures[0], futures[1]});
      Future<List<(double, double?)>> avance() async {
        final v = {for (final x in await db.listerVersementsParMoto(moto.id!)) x.dateEcheance: x};
        return [for (final d in futures.take(3)) (v[d]!.montantPrevu, v[d]!.montantPaye)];
      }

      await db.changerMontant(moto.id!, 60000, aujourdHui);
      // Pas deux echeances partielles : la 1re est complete, le reste va sur la 2e.
      expect(await avance(), [(60000, 60000), (60000, 40000), (60000, null)]);

      await db.changerMontant(moto.id!, 40000, aujourdHui);
      expect(await avance(), [(40000, 40000), (40000, 40000), (40000, 20000)]);
      expect(await db.totalEncaisse(motoId: moto.id!), 100000);
      expect((await db.compteMoto(motoId: moto.id!)).avance, 100000);
    });

    test('semaine ancienne impayee : payer une semaine plus recente paie d\'abord l\'ancienne', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      final vingtEtUn = await echeanceDe(moto.id!, DateTime(2026, 9, 21));

      await db.validerVersement(vingtEtUn, montantPaye: 50000);

      final v = await parDate(moto.id!);
      expect((v[DateTime(2026, 9, 14)]!.statut, v[DateTime(2026, 9, 14)]!.montantPaye), (AppConstants.versementPaye, 50000));
      expect((v[DateTime(2026, 9, 21)]!.statut, v[DateTime(2026, 9, 21)]!.montantPaye), (AppConstants.versementEnRetard, null));
      expect(await db.totalEncaisse(motoId: moto.id!), 50000);
    });

    test('semaine ancienne passee en dette : le versement paie bien la semaine choisie', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final quatorze = await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      final vingtEtUn = await echeanceDe(moto.id!, DateTime(2026, 9, 21));
      await db.marquerEnDette((await parDate(moto.id!))[DateTime(2026, 9, 14)]!, moto);

      await db.validerVersement(vingtEtUn, montantPaye: 50000);

      final v = await parDate(moto.id!);
      expect(v[DateTime(2026, 9, 14)]!.statut, AppConstants.versementEnDette);
      expect(v[DateTime(2026, 9, 21)]!.montantPaye, 50000);
      expect(quatorze, isNotNull);
    });

    test('encaisser refuse de sauter une semaine impayee (il faut la payer ou la passer en dette)', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      await echeanceDe(moto.id!, DateTime(2026, 9, 21));

      expect(() => db.encaisser(moto, 50000, choisies: {DateTime(2026, 9, 21)}), throwsArgumentError);
      expect(await db.totalEncaisse(motoId: moto.id!), 0);
    });

    test('baisser le montant : ce qui a ete paye en trop devient de l\'avance sur la suite', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14), paye: 50000);
      await echeanceDe(moto.id!, DateTime(2026, 9, 21), paye: 50000);
      await echeanceDe(moto.id!, DateTime(2026, 9, 28));

      await db.changerMontant(moto.id!, 40000, DateTime(2026, 9, 14));

      final v = await parDate(moto.id!);
      expect([for (final d in [14, 21, 28]) v[DateTime(2026, 9, d)]!.montantPaye], [40000, 40000, 20000]);
      expect(await db.totalEncaisse(motoId: moto.id!), 100000);
    });
  });

  group('audit : aucune perte d\'argent', () {
    Future<int> echeanceDe(int motoId, DateTime date, {double paye = 0}) => db.insererVersement(Versement(
          motoId: motoId,
          dateEcheance: date,
          dateValidation: paye > 0 ? date : null,
          montantPrevu: 50000,
          montantPaye: paye > 0 ? paye : null,
          statut: paye > 0 ? AppConstants.versementPaye : AppConstants.versementEnRetard,
        ));
    Future<Versement> ligne(int motoId, DateTime date) async =>
        (await db.listerVersementsParMoto(motoId)).singleWhere((v) => v.dateEcheance == date);

    test('passer d\'hebdomadaire a mensuel garde chaque semaine impayee (aucun retard efface)', () async {
      var moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      for (final j in [7, 14, 21, 28]) {
        await echeanceDe(moto.id!, DateTime(2026, 9, j));
      }
      final avant = (await db.compteMoto(motoId: moto.id!)).retard;

      moto = moto.copyWith(frequenceType: AppConstants.freqMensuelle, frequenceValeur: 15);
      await db.modifierMoto(moto);
      await db.replanifierEcheances(moto, depuisDateDebut: false);

      final dates = (await db.listerVersementsParMoto(moto.id!)).map((v) => v.dateEcheance);
      for (final j in [7, 14, 21, 28]) {
        expect(dates, contains(DateTime(2026, 9, j)));
      }
      expect((await db.compteMoto(motoId: moto.id!)).retard, greaterThanOrEqualTo(avant));
    });

    test('supprimer une dette venant d\'une echeance garde ses remboursements (paiements de l\'echeance)', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      final detteId = await db.marquerEnDette(await ligne(moto.id!, DateTime(2026, 9, 14)), moto);
      await db.insererRemboursement(DetteRemboursement(detteId: detteId, montant: 30000, date: DateTime(2026, 9, 20)));
      final encaisse = await db.totalEncaisse(motoId: moto.id!);

      await db.supprimerDette(detteId);

      final v = await ligne(moto.id!, DateTime(2026, 9, 14));
      expect((v.statut, v.montantPaye), (AppConstants.versementPaye, 30000));
      expect(await db.totalEncaisse(motoId: moto.id!), encaisse);
      // L'argent garde sa date : le 20/09.
      expect(await db.totalEncaisse(motoId: moto.id!, debut: DateTime(2026, 9, 20), fin: DateTime(2026, 9, 20, 23)), 30000);
      expect((await db.compteMoto(motoId: moto.id!)).retard, 20000);
    });

    test('valider une echeance deja payee en partie ajoute l\'argent, sans effacer le premier paiement', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final id = await echeanceDe(moto.id!, DateTime(2026, 9, 14), paye: 20000);

      await db.validerVersement(id, montantPaye: 30000);

      expect((await ligne(moto.id!, DateTime(2026, 9, 14))).montantPaye, 50000);
      expect(await db.totalEncaisse(motoId: moto.id!), 50000);
    });

    test('marquer deux fois la meme echeance en dette (double appui) ne cree qu\'une dette', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      final v = await ligne(moto.id!, DateTime(2026, 9, 14));

      final ids = await Future.wait([db.marquerEnDette(v, moto), db.marquerEnDette(v, moto)]);

      expect(ids.toSet().length, 1);
      expect((await db.listerDettes()).length, 1);
    });

    test('import Excel des dettes en "tout remplacer" : la semaine reste en dette, jamais aussi en retard', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await echeanceDe(moto.id!, DateTime(2026, 9, 14));
      await db.marquerEnDette(await ligne(moto.id!, DateTime(2026, 9, 14)), moto);
      final dossier = await Directory.systemTemp.createTemp('dettes_test');
      addTearDown(() => dossier.delete(recursive: true));
      final chemin = '${dossier.path}/export.xlsx';
      await File(chemin).writeAsBytes(await ExcelService.classeurComplet());

      await ExcelService.importerDettes(chemin, remplacementComplet: true);

      final v = await ligne(moto.id!, DateTime(2026, 9, 14));
      expect(v.statut, AppConstants.versementEnDette);
      expect((await db.listerDettes()).map((d) => d.id), contains(v.detteId));
      expect((await db.compteMoto(motoId: moto.id!)).retard, 0);
    });
  });

  group('echeance marquee en dette', () {
    Future<Versement> retard(int motoId, DateTime date) async {
      final id = await db.insererVersement(Versement(
        motoId: motoId,
        dateEcheance: date,
        montantPrevu: 50000,
        statut: AppConstants.versementEnRetard,
      ));
      return (await db.listerVersementsParMoto(motoId)).firstWhere((v) => v.id == id);
    }

    test('la dette apparait dans Dettes, liee a la moto, et ne compte plus dans le retard', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final v = await retard(moto.id!, DateTime(2026, 9, 14));
      expect((await db.compteMoto(motoId: moto.id!)).retard, 50000);

      final detteId = await db.marquerEnDette(v, moto);

      final dette = (await db.obtenirDette(detteId))!;
      expect(dette.montantInitial, 50000);
      expect(dette.lienType, AppConstants.detteLienMoto);
      expect(dette.lienId, moto.id);
      final apres = (await db.listerVersementsParMoto(moto.id!)).single;
      expect(apres.statut, AppConstants.versementEnDette);
      expect(apres.detteId, detteId);
      expect(await db.compteMoto(motoId: moto.id!), (retard: 0.0, avance: 0.0));
      expect(await db.comptesMotos(motoId: moto.id), {moto.id!: (retard: 0.0, avance: 0.0)});
      expect(await db.prochainVersement(moto.id!), isNull);
    });

    test('supprimer la dette remet l\'echeance en retard (aucun retard perdu)', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final detteId = await db.marquerEnDette(await retard(moto.id!, DateTime(2026, 9, 14)), moto);

      await db.supprimerDette(detteId);

      final v = (await db.listerVersementsParMoto(moto.id!)).single;
      expect(v.statut, AppConstants.versementEnRetard);
      expect(v.detteId, isNull);
      expect((await db.compteMoto(motoId: moto.id!)).retard, 50000);
    });

    test('la reactivation garde les retards et dettes d\'avant la pause, et retire seulement les echeances de la pause', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await retard(moto.id!, DateTime(2026, 8, 31));
      await db.marquerEnDette(await retard(moto.id!, DateTime(2026, 9, 7)), moto);
      await db.insererVersement(Versement(motoId: moto.id!, dateEcheance: DateTime(2026, 9, 14), montantPrevu: 50000));

      await db.redemarrerEcheancesApresReactivation(moto);

      final statuts = {for (final v in await db.listerVersementsParMoto(moto.id!)) v.dateEcheance: v.statut};
      expect(statuts[DateTime(2026, 8, 31)], AppConstants.versementEnRetard);
      expect(statuts[DateTime(2026, 9, 7)], AppConstants.versementEnDette);
      expect(statuts.containsKey(DateTime(2026, 9, 14)), isFalse);
    });

  });

  group('encaisser un montant (repartition automatique)', () {
    /// Moto du lundi depuis le 07/09 : payee le 07/09, en retard les 14 et 21/09.
    Future<Moto> motoAvecRetards() async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await db.insererVersement(Versement(
        motoId: moto.id!,
        dateEcheance: DateTime(2026, 9, 7),
        dateValidation: DateTime(2026, 9, 7),
        montantPrevu: 50000,
        montantPaye: 50000,
        statut: AppConstants.versementPaye,
      ));
      await db.insererVersement(Versement(
        motoId: moto.id!,
        dateEcheance: DateTime(2026, 9, 14),
        montantPrevu: 50000,
        statut: AppConstants.versementEnRetard,
      ));
      await db.insererVersement(Versement(
        motoId: moto.id!,
        dateEcheance: DateTime(2026, 9, 21),
        montantPrevu: 50000,
        statut: AppConstants.versementEnRetard,
      ));
      return moto;
    }

    Future<Map<DateTime, Versement>> parDate(int motoId) async =>
        {for (final v in await db.listerVersementsParMoto(motoId)) v.dateEcheance: v};

    test('80 000 soldent le retard du 14/09 et paient 30 000 sur le 21/09 (partiel)', () async {
      final moto = await motoAvecRetards();

      final affectations = await db.encaisser(moto, 80000);

      expect(affectations.map((a) => (a.date, a.montant)), [(DateTime(2026, 9, 14), 50000), (DateTime(2026, 9, 21), 30000)]);
      final v = await parDate(moto.id!);
      expect(v[DateTime(2026, 9, 14)]!.statut, AppConstants.versementPaye);
      expect(v[DateTime(2026, 9, 14)]!.montantPaye, 50000);
      expect(v[DateTime(2026, 9, 21)]!.montantPaye, 30000);
      expect(v[DateTime(2026, 9, 21)]!.montantPrevu, 50000);
    });

    test('le versement suivant complete d\'abord la periode partielle', () async {
      final moto = await motoAvecRetards();
      await db.encaisser(moto, 80000);

      await db.encaisser(moto, 20000);

      expect((await parDate(moto.id!))[DateTime(2026, 9, 21)]!.montantPaye, 50000);
      expect(await db.totalEncaisse(motoId: moto.id), 150000);
    });

    test('aucun doublon : une periode existante est completee, jamais recreee', () async {
      final moto = await motoAvecRetards();

      await db.encaisser(moto, 50000);

      final quatorze = (await db.listerVersementsParMoto(moto.id!))
          .where((v) => v.dateEcheance == DateTime(2026, 9, 14))
          .toList();
      expect(quatorze.length, 1);
      expect(quatorze.single.montantPaye, 50000);
    });
  });

  group('solde d\'une moto suspendue', () {
    test('les retards d\'avant la pause restent dus, les echeances de la pause ne comptent pas', () async {
      final moto = await nouvelleMoto(statut: AppConstants.motoSuspendue);
      await db.insererVersement(Versement(
        motoId: moto,
        dateEcheance: DateTime(2026, 8, 31),
        dateValidation: DateTime(2026, 8, 31),
        montantPrevu: 50000,
        montantPaye: 50000,
        statut: AppConstants.versementPaye,
      ));
      await db.insererVersement(Versement(
        motoId: moto,
        dateEcheance: DateTime(2026, 9, 7),
        montantPrevu: 50000,
        statut: AppConstants.versementEnRetard,
      ));
      // Tombee pendant la pause : restee "en attente".
      await db.insererVersement(Versement(motoId: moto, dateEcheance: DateTime(2026, 9, 14), montantPrevu: 50000));

      expect((await db.compteMoto(motoId: moto)).retard, 50000);
    });
  });

  group('journal des paiements (date reelle de chaque somme recue)', () {
    test('une base v6 recoit un paiement par versement deja paye, a sa date de validation', () async {
      await ancienneBase(6, sql: [
        ...tablesV3,
        "INSERT INTO versements (moto_id, date_echeance, date_validation, montant_prevu, montant_paye, statut) "
            "VALUES (1, '2026-09-07T00:00:00.000', '2026-09-08T10:00:00.000', 50000, 45000, 'paye'), "
            "(1, '2026-09-14T00:00:00.000', NULL, 50000, NULL, 'en_retard')",
      ]);

      final paiements = await db.listerPaiementsRecents();

      expect(paiements.length, 1);
      expect(paiements.single.montant, 45000);
      expect(paiements.single.date, DateTime(2026, 9, 8, 10));
    });

    test('corriger le montant d\'une echeance payee en deux fois ne deplace pas l\'argent d\'un mois a l\'autre', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await db.insererVersement(Versement(
          motoId: moto.id!, dateEcheance: DateTime(2026, 9, 21), montantPrevu: 50000, statut: AppConstants.versementEnRetard));
      final v = (await db.listerVersementsParMoto(moto.id!)).single;
      await db.ajouterPaiement(v.id!, 20000, date: DateTime(2026, 9, 25));
      await db.ajouterPaiement(v.id!, 10000, date: DateTime(2026, 10, 2));
      Future<double> mois(int m) =>
          db.totalEncaisse(motoId: moto.id, debut: DateTime(2026, m, 1), fin: DateTime(2026, m + 1, 0, 23, 59));

      await db.modifierMontantPaye(v.id!, 45000); // +15 000 : a la date du dernier paiement
      expect((await mois(9), await mois(10)), (20000, 25000));

      await db.modifierMontantPaye(v.id!, 30000); // -15 000 : retire des paiements les plus recents
      expect((await mois(9), await mois(10)), (20000, 10000));
    });

    test('une echeance payee en deux fois compte chaque somme dans le mois ou elle a ete recue', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await db.insererVersement(Versement(
        motoId: moto.id!,
        dateEcheance: DateTime(2026, 9, 21),
        montantPrevu: 50000,
        statut: AppConstants.versementEnRetard,
      ));
      final v = (await db.listerVersementsParMoto(moto.id!)).single;

      await db.ajouterPaiement(v.id!, 30000, date: DateTime(2026, 9, 25));
      await db.ajouterPaiement(v.id!, 20000, date: DateTime(2026, 10, 2));

      expect(await db.totalEncaisse(motoId: moto.id, debut: DateTime(2026, 9, 1), fin: DateTime(2026, 9, 30)), 30000);
      expect(await db.totalEncaisse(motoId: moto.id, debut: DateTime(2026, 10, 1), fin: DateTime(2026, 10, 31)), 20000);
      final apres = (await db.listerVersementsParMoto(moto.id!)).single;
      expect(apres.montantPaye, 50000);
      expect(apres.statut, AppConstants.versementPaye);
    });

    test('corriger ou annuler un versement reecrit son paiement (pas de montant fantome)', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await db.insererVersement(Versement(motoId: moto.id!, dateEcheance: DateTime(2026, 9, 21), montantPrevu: 50000));
      final v = (await db.listerVersementsParMoto(moto.id!)).single;
      await db.validerVersement(v.id!, montantPaye: 5000);

      await db.modifierMontantPaye(v.id!, 50000);
      expect(await db.totalEncaisse(motoId: moto.id), 50000);

      await db.annulerValidationVersement(v.id!);
      expect(await db.totalEncaisse(motoId: moto.id), 0);
      expect(await db.listerPaiementsRecents(), isEmpty);
    });

    test('supprimer une moto supprime aussi ses paiements', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      await db.insererVersement(Versement(
        motoId: moto.id!,
        dateEcheance: DateTime(2026, 9, 7),
        dateValidation: DateTime(2026, 9, 7),
        montantPrevu: 50000,
        montantPaye: 50000,
        statut: AppConstants.versementPaye,
      ));

      await db.supprimerMoto(moto.id!);

      expect(await db.listerPaiementsRecents(), isEmpty);
    });
  });

  group('import Excel', () {
    late Directory dossier;
    setUp(() async => dossier = await Directory.systemTemp.createTemp('import_test'));
    tearDown(() async => dossier.delete(recursive: true));

    /// Ecrit un classeur avec les feuilles donnees (ligne d'en-tete + lignes).
    Future<String> classeur(Map<String, List<List<String>>> feuilles) async {
      final excel = Excel.createExcel();
      for (final f in feuilles.entries) {
        final s = excel[f.key];
        for (final ligne in f.value) {
          s.appendRow([for (final c in ligne) c.isEmpty ? null : TextCellValue(c)]);
        }
      }
      final chemin = '${dossier.path}/import.xlsx';
      await File(chemin).writeAsBytes(excel.encode()!);
      return chemin;
    }

    const enteteMotos = ['ID', 'Nom', 'Chauffeur', 'Montant', 'Frequence', 'Valeur', 'Date debut', 'Statut', 'Notes'];

    /// Boutique avec une operation du proprietaire et deux d'Ibrahim.
    Future<CategorieActivite> boutiqueAvecGerant() async {
      final e = await nouvelleEntite();
      final ibrahim = await db.insererGerant(CategorieGerant(entiteId: e.entiteId, nom: 'Ibrahim'));
      for (final (montant, gerantId, type) in [
        (1000.0, null, AppConstants.transactionRevenu),
        (500.0, ibrahim, AppConstants.transactionRevenu),
        (200.0, ibrahim, AppConstants.transactionDepense),
      ]) {
        await db.insererTransactionCategorie(CategorieTransaction(
            entiteId: e.entiteId, type: type, montant: montant, date: DateTime(2026, 10, 1), gerantId: gerantId));
      }
      return (await db.obtenirCategorieActivite(e.categorieId))!;
    }

    /// Comptes de l'unique boutique de [categorie], par nom de personne.
    Future<Map<String, double>> comptesParNom(int categorieId) async {
      final entiteId = (await db.listerEntitesCategorie(categorieId)).single.id!;
      final noms = {for (final g in await db.listerGerants(entiteId)) g.id: g.nom};
      return {
        for (final s in (await db.soldesParPersonne(entiteId)).entries)
          noms[s.key] ?? AppConstants.libelleProprietaire: s.value,
      };
    }

    test('export puis import d\'une categorie : chaque operation garde sa personne', () async {
      final categorie = await boutiqueAvecGerant();
      final chemin = '${dossier.path}/categorie.xlsx';
      await File(chemin).writeAsBytes(await ExcelService.classeurCategorie(categorie));

      await ExcelService.importerCategorie(chemin, categorie.id!, remplacementComplet: true);

      expect(await comptesParNom(categorie.id!), {AppConstants.libelleProprietaire: 1000, 'Ibrahim': 300});
    });

    test('export puis import complet : chaque operation garde sa personne', () async {
      await boutiqueAvecGerant();
      final chemin = '${dossier.path}/complet.xlsx';
      await File(chemin).writeAsBytes(await ExcelService.classeurComplet());

      await ExcelService.importer(chemin, remplacementComplet: true);

      final categorieId = (await db.listerCategoriesActivite()).single.id!;
      expect(await comptesParNom(categorieId), {AppConstants.libelleProprietaire: 1000, 'Ibrahim': 300});
    });

    test('la colonne Personne rattache chaque operation a son gerant (cree une fois) ou au proprietaire', () async {
      final categorieId = await db.insererCategorieActivite(
          CategorieActivite(nom: 'Boutiques', couleur: '#2D6CDF', deviseSymbole: 'FG'));
      final chemin = await classeur({
        'Entites': [
          ['ID', 'Nom', 'Statut', 'Notes'],
          ['3', 'Boutique A', 'actif', ''],
        ],
        'Transactions': [
          ['ID', 'Entite ID', 'Entite', 'Type', 'Montant', 'Date', 'Description', 'Personne'],
          ['1', '3', 'Boutique A', 'revenu', '1000', '2026-10-01', '', ''],
          ['2', '3', 'Boutique A', 'revenu', '500', '2026-10-01', '', 'Ibrahim'],
          ['3', '3', 'Boutique A', 'depense', '200', '2026-10-01', '', 'ibrahim'],
          ['4', '3', 'Boutique A', 'depense', '100', '2026-10-01', '', AppConstants.libelleProprietaire],
        ],
      });

      await ExcelService.importerCategorie(chemin, categorieId, remplacementComplet: true);

      final entiteId = (await db.listerEntitesCategorie(categorieId)).single.id!;
      final gerants = await db.listerGerants(entiteId);
      expect(gerants.map((g) => g.nom), ['Ibrahim']);
      expect(await db.soldesParPersonne(entiteId), {null: 900, gerants.single.id: 300});
    });

    test('ancien export d\'une categorie (sans colonne Personne) : tout va au proprietaire', () async {
      final categorieId = await db.insererCategorieActivite(
          CategorieActivite(nom: 'Boutiques', couleur: '#2D6CDF', deviseSymbole: 'FG'));
      final chemin = await classeur({
        'Entites': [
          ['ID', 'Nom', 'Statut', 'Notes'],
          ['3', 'Boutique A', 'actif', ''],
        ],
        'Transactions': [
          ['ID', 'Entite ID', 'Entite', 'Type', 'Montant', 'Date', 'Description'],
          ['1', '3', 'Boutique A', 'revenu', '1000', '2026-10-01', 'vente'],
          ['2', '3', 'Boutique A', 'depense', '300', '2026-10-02', ''],
        ],
      });

      final rapport = await ExcelService.importerCategorie(chemin, categorieId, remplacementComplet: true);

      expect(rapport.erreurs, isEmpty);
      final entiteId = (await db.listerEntitesCategorie(categorieId)).single.id!;
      expect(await db.soldesParPersonne(entiteId), {null: 700});
      expect(await db.listerGerants(entiteId), isEmpty);
    });

    test('ancien export complet (sans colonne Personne) : tout va au proprietaire', () async {
      final chemin = await classeur({
        'Motos': [enteteMotos],
        'Categories': [
          ['ID', 'Nom', 'Couleur', 'Devise', 'Date creation'],
          ['1', 'Boutiques', '#2D6CDF', 'FG', ''],
        ],
        'CategorieEntites': [
          ['ID', 'Categorie ID', 'Categorie', 'Nom', 'Statut', 'Notes'],
          ['3', '1', 'Boutiques', 'Boutique A', 'actif', ''],
        ],
        'CategorieTransactions': [
          ['ID', 'Entite ID', 'Entite', 'Categorie', 'Type', 'Montant', 'Date', 'Description'],
          ['1', '3', 'Boutique A', 'Boutiques', 'revenu', '1000', '2026-10-01', 'vente'],
          ['2', '3', 'Boutique A', 'Boutiques', 'depense', '300', '2026-10-02', ''],
        ],
      });

      final rapport = await ExcelService.importer(chemin, remplacementComplet: true);

      expect(rapport.erreurs, isEmpty);
      final categorieId = (await db.listerCategoriesActivite()).single.id!;
      final entiteId = (await db.listerEntitesCategorie(categorieId)).single.id!;
      expect(await db.soldesParPersonne(entiteId), {null: 700});
    });

    test('ancien export reimporte en fusion sur le meme telephone : mis a jour, sans doublon', () async {
      final locale = await nouvelleEntite();
      final operation = await db.insererTransactionCategorie(CategorieTransaction(
          entiteId: locale.entiteId, type: AppConstants.transactionRevenu, montant: 1000, date: DateTime(2026, 10, 1)));
      final chemin = await classeur({
        'Entites': [
          ['ID', 'Nom', 'Statut', 'Notes'],
          ['${locale.entiteId}', 'Boutique A', 'actif', ''],
        ],
        'Transactions': [
          ['ID', 'Entite ID', 'Entite', 'Type', 'Montant', 'Date', 'Description'],
          ['$operation', '${locale.entiteId}', 'Boutique A', 'revenu', '1000', '2026-10-01', 'vente'],
        ],
      });

      await ExcelService.importerCategorie(chemin, locale.categorieId, remplacementComplet: false);

      expect((await db.listerEntitesCategorie(locale.categorieId)).map((e) => e.nom), ['Boutique A']);
      final operations = await db.listerTransactionsEntite(locale.entiteId);
      expect(operations.map((t) => (t.id, t.description)), [(operation, 'vente')]);
    });

    test('fusion : une categorie d\'un autre telephone au meme numero est ajoutee, pas ecrasee', () async {
      final locale = await nouvelleEntite();
      final chemin = await classeur({
        'Motos': [enteteMotos],
        'Categories': [
          ['ID', 'Nom', 'Couleur', 'Devise', 'Date creation'],
          ['${locale.categorieId}', 'Restaurants', '#0EA5A5', 'FG', ''],
        ],
      });

      await ExcelService.importer(chemin, remplacementComplet: false);

      expect((await db.listerCategoriesActivite()).map((c) => c.nom).toSet(), {'Boutiques', 'Restaurants'});
    });

    test('fusion : une entite d\'un autre telephone au meme numero est ajoutee, pas ecrasee', () async {
      final locale = await nouvelleEntite();
      final chemin = await classeur({
        'Entites': [
          ['ID', 'Nom', 'Statut', 'Notes'],
          ['${locale.entiteId}', 'Kaloum', 'actif', ''],
        ],
      });

      await ExcelService.importerCategorie(chemin, locale.categorieId, remplacementComplet: false);

      expect((await db.listerEntitesCategorie(locale.categorieId)).map((e) => e.nom).toSet(), {'Boutique A', 'Kaloum'});
    });

    test('fusion : une autre operation au meme numero est ajoutee ; la locale garde sa note vocale', () async {
      final locale = await nouvelleEntite();
      final operation = await db.insererTransactionCategorie(
          CategorieTransaction(
              entiteId: locale.entiteId, type: AppConstants.transactionRevenu, montant: 1000, date: DateTime(2026, 10, 1)),
          audio: Uint8List.fromList([1, 2, 3]));
      final chemin = await classeur({
        'Entites': [
          ['ID', 'Nom', 'Statut', 'Notes'],
          ['${locale.entiteId}', 'Boutique A', 'actif', ''],
        ],
        'Transactions': [
          ['ID', 'Entite ID', 'Entite', 'Type', 'Montant', 'Date', 'Description', 'Personne'],
          ['$operation', '${locale.entiteId}', 'Boutique A', 'revenu', '5000', '2026-10-05', '', ''],
        ],
      });

      await ExcelService.importerCategorie(chemin, locale.categorieId, remplacementComplet: false);

      final operations = await db.listerTransactionsEntite(locale.entiteId);
      expect(operations.map((t) => t.montant).toSet(), {1000, 5000});
      expect(operations.firstWhere((t) => t.id == operation).montant, 1000);
      expect(await db.obtenirAudioTransaction(operation), [1, 2, 3]);
    });

    test('fusion : la meme operation corrigee dans Excel (montant) est mise a jour, pas dupliquee', () async {
      final locale = await nouvelleEntite();
      final operation = await db.insererTransactionCategorie(CategorieTransaction(
          entiteId: locale.entiteId, type: AppConstants.transactionRevenu, montant: 1000, date: DateTime(2026, 10, 1)));
      final chemin = await classeur({
        'Entites': [
          ['ID', 'Nom', 'Statut', 'Notes'],
          ['${locale.entiteId}', 'Boutique A', 'actif', ''],
        ],
        'Transactions': [
          ['ID', 'Entite ID', 'Entite', 'Type', 'Montant', 'Date', 'Description', 'Personne'],
          ['$operation', '${locale.entiteId}', 'Boutique A', 'revenu', '1500', '2026-10-01', '', ''],
        ],
      });

      await ExcelService.importerCategorie(chemin, locale.categorieId, remplacementComplet: false);

      final operations = await db.listerTransactionsEntite(locale.entiteId);
      expect(operations.map((t) => (t.id, t.montant)), [(operation, 1500)]);
    });

    test('fusion : le fichier d\'un autre telephone n\'ecrase pas une moto differente au meme numero', () async {
      final locale = await nouvelleMoto();
      final chemin = await classeur({
        'Motos': [
          enteteMotos,
          ['$locale', 'Moto B', 'Ibrahima', '40000', AppConstants.freqHebdomadaire, '1', '2026-09-07', 'actif', ''],
        ],
      });

      await ExcelService.importer(chemin, remplacementComplet: false);

      final noms = (await db.listerMotos()).map((m) => m.nom).toSet();
      expect(noms, {'Moto 1', 'Moto B'});
    });

    test('les retards et les echeances passees en dette survivent a l\'import (lien vers la dette refait)', () async {
      final chemin = await classeur({
        'Motos': [
          enteteMotos,
          ['5', 'Moto 1', 'Mamadou', '50000', AppConstants.freqHebdomadaire, '1', '2026-09-07', 'actif', ''],
        ],
        'Versements': [
          ['ID', 'Moto ID', 'Moto', 'Date echeance', 'Date validation', 'Montant prevu', 'Montant paye', 'Statut', 'Notes', 'Dette ID'],
          ['1', '5', 'Moto 1', '2026-09-14', '', '50000', '', AppConstants.versementEnRetard, '', ''],
          ['2', '5', 'Moto 1', '2026-09-21', '', '50000', '', AppConstants.versementEnDette, '', '7'],
        ],
        'Dettes': [
          ['ID', 'Nom', 'Montant', 'Date', 'Notes', 'Lien type', 'Lien ID', 'Lien nom', 'Devise'],
          ['7', 'Mamadou', '50000', '2026-09-21', '', AppConstants.detteLienMoto, '5', 'Moto 1', 'FG'],
        ],
      });

      await ExcelService.importer(chemin, remplacementComplet: true);

      final moto = (await db.listerMotos()).single;
      final v = {for (final x in await db.listerVersementsParMoto(moto.id!)) x.dateEcheance: x};
      expect(v[DateTime(2026, 9, 14)]!.statut, AppConstants.versementEnRetard);
      final enDette = v[DateTime(2026, 9, 21)]!;
      expect(enDette.statut, AppConstants.versementEnDette);
      final dette = (await db.obtenirDette(enDette.detteId!))!;
      expect(dette.lienId, moto.id);
    });
  });

  group('liste des devises', () {
    test('on ajoute une devise une fois (normalisee, sans doublon) puis on la choisit', () async {
      await db.ajouterDevise('fcfa ');
      await db.ajouterDevise('FCFA');

      expect(await db.listerDevises(), ['FCFA', 'FG']);

      await db.supprimerDevise('FCFA');
      expect(await db.listerDevises(), ['FG']);
    });
  });

  group('restauration d\'une sauvegarde', () {
    late Directory dossier;
    setUp(() async => dossier = await Directory.systemTemp.createTemp('sauvegarde_test'));
    tearDown(() async => dossier.delete(recursive: true));

    Future<List<String>> nomsDesMotos() async => (await db.listerMotos()).map((m) => m.nom).toList();

    test('un fichier qui n\'est pas une sauvegarde est refuse, sans toucher aux donnees', () async {
      await nouvelleMoto();
      final faux = File('${dossier.path}/releve.db')..writeAsStringSync('ceci est un releve PDF, pas une base');

      await expectLater(BackupService.restaurer(faux.path), throwsException);

      expect(await nomsDesMotos(), ['Moto 1']);
    });

    test('une sauvegarde d\'une version plus recente de l\'app est refusee', () async {
      await nouvelleMoto();
      final recente = await databaseFactory.openDatabase('${dossier.path}/recente.db',
          options: OpenDatabaseOptions(
            version: AppConstants.dbVersion + 1,
            onCreate: (d, _) => d.execute('CREATE TABLE motos (id INTEGER PRIMARY KEY)'),
          ));
      await recente.close();

      await expectLater(BackupService.restaurer('${dossier.path}/recente.db'), throwsException);

      expect(await nomsDesMotos(), ['Moto 1']);
    });

    test('une vraie sauvegarde remplace les donnees actuelles', () async {
      await nouvelleMoto();
      await db.fermer();
      final sauvegarde = '${dossier.path}/sauvegarde.db';
      await File(await db.cheminBaseDeDonnees()).copy(sauvegarde);
      await db.supprimerMoto((await db.listerMotos()).single.id!);

      await BackupService.restaurer(sauvegarde);

      expect(await nomsDesMotos(), ['Moto 1']);
    });
  });
}
