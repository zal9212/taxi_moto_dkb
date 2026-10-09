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
      final avant = await db.soldeNet(motoId: moto);

      await rembourser(await nouvelleDette(lienType: AppConstants.detteLienMoto, lienId: moto), 30000, DateTime(2026, 9, 10));

      expect(await db.soldeNet(motoId: moto), avant);
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

      expect(await db.soldeNet(motoId: moto), 0);
    });

    test('le retard global ignore les motos suspendues et l\'avance d\'une moto ne compense pas une autre', () async {
      final enRetard = await nouvelleMoto();
      final enAvance = await nouvelleMoto();
      final suspendue = await nouvelleMoto(statut: AppConstants.motoSuspendue);
      await echeance(enRetard, DateTime(2026, 9, 1));
      await echeance(enAvance, DateTime(2026, 9, 1), paye: 80000);
      await echeance(suspendue, DateTime(2026, 9, 1), prevu: 300000, paye: 300000);

      final soldes = await db.soldesMotosActives();

      expect(soldes, {enRetard: -50000, enAvance: 30000});
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
      expect(await db.soldeNet(motoId: moto.id), -50000);

      final detteId = await db.marquerEnDette(v, moto);

      final dette = (await db.obtenirDette(detteId))!;
      expect(dette.montantInitial, 50000);
      expect(dette.lienType, AppConstants.detteLienMoto);
      expect(dette.lienId, moto.id);
      final apres = (await db.listerVersementsParMoto(moto.id!)).single;
      expect(apres.statut, AppConstants.versementEnDette);
      expect(apres.detteId, detteId);
      expect(await db.soldeNet(motoId: moto.id), 0);
      expect(await db.soldesMotosActives(motoId: moto.id), {moto.id!: 0});
      expect(await db.prochainVersement(moto.id!), isNull);
    });

    test('supprimer la dette remet l\'echeance en retard (aucun retard perdu)', () async {
      final moto = (await db.obtenirMoto(await nouvelleMoto()))!;
      final detteId = await db.marquerEnDette(await retard(moto.id!, DateTime(2026, 9, 14)), moto);

      await db.supprimerDette(detteId);

      final v = (await db.listerVersementsParMoto(moto.id!)).single;
      expect(v.statut, AppConstants.versementEnRetard);
      expect(v.detteId, isNull);
      expect(await db.soldeNet(motoId: moto.id), -50000);
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
    /// Moto du lundi depuis le 07/09 : payee le 07/09, en retard le 14/09,
    /// le 21/09 n'a jamais ete enregistre.
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
      return moto;
    }

    Future<Map<DateTime, Versement>> parDate(int motoId) async =>
        {for (final v in await db.listerVersementsParMoto(motoId)) v.dateEcheance: v};

    test('80 000 soldent le retard du 14/09 et paient 30 000 sur le 21/09 (cree, partiel)', () async {
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

      expect(await db.soldeNet(motoId: moto), -50000);
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
