import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:moto_taxi_douka/core/constants.dart';
import 'package:moto_taxi_douka/models/categorie_activite.dart';
import 'package:moto_taxi_douka/models/categorie_entite.dart';
import 'package:moto_taxi_douka/models/categorie_gerant.dart';
import 'package:moto_taxi_douka/models/categorie_transaction.dart';
import 'package:moto_taxi_douka/screens/categorie/add_categorie_transaction_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/categorie_entite_detail_screen.dart';
import 'package:moto_taxi_douka/services/database_service.dart';
import 'package:moto_taxi_douka/utils/formatters.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final db = DatabaseService.instance;
const devise = 'FG';

/// Boutique : proprietaire 1 000 000, Ibrahim 700 000, Aissatou (archivee) -150 000.
Future<({CategorieActivite categorie, CategorieEntite entite, int ibrahim, int aissatou})> boutique() async {
  final categorieId =
      await db.insererCategorieActivite(CategorieActivite(nom: 'Boutiques', couleur: '#2D6CDF', deviseSymbole: devise));
  final entiteId = await db.insererEntiteCategorie(CategorieEntite(categorieId: categorieId, nom: 'Madina'));
  final ibrahim = await db.insererGerant(CategorieGerant(entiteId: entiteId, nom: 'Ibrahim'));
  final aissatou = await db.insererGerant(
      CategorieGerant(entiteId: entiteId, nom: 'Aissatou', statut: AppConstants.motoArchivee));
  for (final (montant, gerantId, type, description) in [
    (1000000.0, null, AppConstants.transactionRevenu, 'vente proprio'),
    (800000.0, ibrahim, AppConstants.transactionRevenu, 'vente ibrahim'),
    (100000.0, ibrahim, AppConstants.transactionDepense, 'sortie ibrahim'),
    (150000.0, aissatou, AppConstants.transactionDepense, 'sortie aissatou'),
  ]) {
    await db.insererTransactionCategorie(CategorieTransaction(
        entiteId: entiteId,
        type: type,
        montant: montant,
        date: DateTime(2026, 10, 1),
        description: description,
        gerantId: gerantId));
  }
  return (
    categorie: (await db.obtenirCategorieActivite(categorieId))!,
    entite: (await db.obtenirEntiteCategorie(entiteId))!,
    ibrahim: ibrahim,
    aissatou: aissatou,
  );
}

/// Les acces a la base font de vraies E/S, qui n'avancent pas dans le temps
/// simule de testWidgets : on les execute en temps reel.
Future<T> io<T>(WidgetTester tester, Future<T> Function() f) async => (await tester.runAsync(f)) as T;

/// Laisse l'ecran finir ses chargements en base, puis le redessine.
Future<void> charger(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Ferme l'ecran en temps reel : la liberation du micro (verrou partage du
/// paquet record) doit aboutir avant le test suivant.
Future<void> fermerEcran(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await charger(tester);
}

/// Ouvre [ecran] par-dessus une page d'accueil (il peut ainsi se refermer).
Future<void> ouvrir(WidgetTester tester, Widget ecran) async {
  // Ecran haut : la liste ne construit que ce qui est visible.
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ecran)),
        child: const Text('ouvrir'),
      ),
    ),
  ));
  await tester.tap(find.text('ouvrir'));
  await charger(tester);
}

/// Micro simule : permission accordee ; comme le vrai, stop() ne rend le
/// fichier enregistre qu'une fois (null si rien n'est en cours).
class _FauxMicro extends RecordPlatform {
  int demarrages = 0;
  String? dernierChemin;
  String? _enCours;

  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    // Comme la vraie demande (boite de dialogue) : un second appui peut arriver avant la reponse.
    await Future.delayed(const Duration(milliseconds: 50));
    return true;
  }
  @override
  Future<void> start(String recorderId, RecordConfig config, {required String path}) async {
    demarrages++;
    File(path).writeAsBytesSync([1, 2, 3]);
    _enCours = dernierChemin = path;
  }

  @override
  Future<String?> stop(String recorderId) async {
    final chemin = _enCours;
    _enCours = null;
    return chemin;
  }

  @override
  Future<void> cancel(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Montant affiche sur la ligne de compte de [nom].
Finder soldeDuCompte(String nom, double montant) => find.descendant(
    of: find.ancestor(of: find.text(nom), matching: find.byType(Row)).first,
    matching: find.text(formaterMontant(montant, devise)));

final micro = _FauxMicro();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Base a part : les fichiers de test tournent en parallele.
    await databaseFactory.setDatabasesPath((await Directory.systemTemp.createTemp('gerants_ecrans')).path);
    await initializeDateFormatting('fr_FR');
    RecordPlatform.instance = micro;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
  });

  setUp(() async {
    micro.demarrages = 0;
    await db.fermer();
    await databaseFactory.deleteDatabase(await db.cheminBaseDeDonnees());
  });

  group('fiche d\'une boutique', () {
    testWidgets('affiche le total general et le compte de chaque personne, archive compris', (tester) async {
      final b = await io(tester, boutique);

      await ouvrir(tester, CategorieEntiteDetailScreen(entiteId: b.entite.id!, categorie: b.categorie));

      expect(find.text('Total general'), findsOneWidget);
      expect(find.text(formaterMontant(1550000, devise)), findsOneWidget);
      expect(soldeDuCompte(AppConstants.libelleProprietaire, 1000000), findsOneWidget);
      expect(soldeDuCompte('Ibrahim', 700000), findsOneWidget);
      expect(soldeDuCompte('Aissatou (archive)', -150000), findsOneWidget);
    });

    testWidgets('toucher un compte filtre l\'historique sur cette personne, retoucher l\'enleve', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, CategorieEntiteDetailScreen(entiteId: b.entite.id!, categorie: b.categorie));

      await tester.tap(find.text('Ibrahim'));
      await tester.pumpAndSettle();

      expect(find.text('Historique - Ibrahim'), findsOneWidget);
      expect(find.text('vente ibrahim'), findsOneWidget);
      expect(find.text('sortie ibrahim'), findsOneWidget);
      expect(find.text('vente proprio'), findsNothing);
      expect(find.text('sortie aissatou'), findsNothing);

      await tester.tap(find.text('Ibrahim'));
      await tester.pumpAndSettle();
      expect(find.text('Historique'), findsOneWidget);
      expect(find.text('vente proprio'), findsOneWidget);
    });

    testWidgets('sans gerant : "Solde" comme avant, et le bouton pour en ajouter', (tester) async {
      final (categorie, entiteId) = await io(tester, () async {
        final categorieId = await db
            .insererCategorieActivite(CategorieActivite(nom: 'Boutiques', couleur: '#2D6CDF', deviseSymbole: devise));
        final entiteId = await db.insererEntiteCategorie(CategorieEntite(categorieId: categorieId, nom: 'Madina'));
        return ((await db.obtenirCategorieActivite(categorieId))!, entiteId);
      });

      await ouvrir(tester, CategorieEntiteDetailScreen(entiteId: entiteId, categorie: categorie));

      expect(find.text('Solde'), findsOneWidget);
      expect(find.text('Total general'), findsNothing);
      expect(find.text(AppConstants.libelleProprietaire), findsNothing);
      expect(find.text('Ajouter un gerant'), findsOneWidget);
    });

    /// Choisit [action] dans le menu du compte de [nom].
    Future<void> menuDuGerant(WidgetTester tester, String nom, String action) async {
      await tester.tap(find.descendant(
          of: find.ancestor(of: find.text(nom), matching: find.byType(Row)).first,
          matching: find.byIcon(Icons.more_vert)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await charger(tester);
    }

    testWidgets('menu du gerant : archiver puis reactiver', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, CategorieEntiteDetailScreen(entiteId: b.entite.id!, categorie: b.categorie));

      await menuDuGerant(tester, 'Ibrahim', 'Archiver');
      expect(find.text('Ibrahim (archive)'), findsOneWidget);

      await menuDuGerant(tester, 'Ibrahim (archive)', 'Reactiver');
      expect(find.text('Ibrahim'), findsOneWidget);
    });

    testWidgets('menu du gerant : supprimer un gerant avec operations est refuse, avec un message', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, CategorieEntiteDetailScreen(entiteId: b.entite.id!, categorie: b.categorie));

      await menuDuGerant(tester, 'Ibrahim', 'Supprimer');

      expect(find.textContaining('archivez-le'), findsOneWidget);
      expect(find.text('Ibrahim'), findsOneWidget);
    });

    testWidgets('le gerant archive n\'est pas propose dans "Qui ?"', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, CategorieEntiteDetailScreen(entiteId: b.entite.id!, categorie: b.categorie));

      await tester.tap(find.text('Ajouter un revenu / une depense'));
      await charger(tester);
      await tester.tap(find.text(AppConstants.libelleProprietaire));
      await tester.pumpAndSettle();

      expect(find.text('Ibrahim'), findsWidgets);
      expect(find.text('Aissatou'), findsNothing);
    });
  });

  group('nouvelle operation', () {
    testWidgets('l\'operation est enregistree sur la personne choisie dans "Qui ?"', (tester) async {
      final b = await io(tester, boutique);
      final ibrahim = (await io(tester, () => db.listerGerants(b.entite.id!))).firstWhere((g) => g.id == b.ibrahim);
      await ouvrir(tester, AddCategorieTransactionScreen(categorie: b.categorie, entite: b.entite, gerants: [ibrahim]));

      await tester.tap(find.text(AppConstants.libelleProprietaire));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ibrahim').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '50000');
      await tester.tap(find.text('Enregistrer'));
      await charger(tester);

      expect((await io(tester, () => db.soldesParPersonne(b.entite.id!)))[b.ibrahim], 700000 + 50000);
    });

    testWidgets('sans gerant actif, pas de "Qui ?" : tout va au proprietaire', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, AddCategorieTransactionScreen(categorie: b.categorie, entite: b.entite));

      expect(find.text('Qui ?'), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, '1000');
      await tester.tap(find.text('Enregistrer'));
      await charger(tester);

      expect((await io(tester, () => db.soldesParPersonne(b.entite.id!)))[null], 1000000 + 1000);
    });

    testWidgets('une personne preselectionnee mais archivee retombe sur le proprietaire', (tester) async {
      final b = await io(tester, boutique);
      final ibrahim = (await io(tester, () => db.listerGerants(b.entite.id!))).firstWhere((g) => g.id == b.ibrahim);
      await ouvrir(
          tester,
          AddCategorieTransactionScreen(
              categorie: b.categorie, entite: b.entite, gerants: [ibrahim], gerantInitial: b.aissatou));

      expect(find.text(AppConstants.libelleProprietaire), findsOneWidget);
    });

    testWidgets('pendant une note vocale, l\'operation ne peut pas etre enregistree', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, AddCategorieTransactionScreen(categorie: b.categorie, entite: b.entite));
      await tester.enterText(find.byType(TextFormField).first, '1000');

      await tester.tap(find.text('Enregistrer une note vocale'));
      await charger(tester);

      expect(find.text('Arretez d\'abord la note vocale'), findsOneWidget);
      await tester.tap(find.text('Arretez d\'abord la note vocale'));
      await charger(tester);
      expect(await io(tester, () => db.soldesParPersonne(b.entite.id!)), isNot(containsValue(1000000 + 1000)));

      await tester.tap(find.textContaining('Arreter ('));
      await charger(tester);
      expect(find.text('Enregistrer'), findsOneWidget);      await fermerEcran(tester);
    });

    testWidgets('le fichier brut de l\'enregistrement est efface une fois la note recuperee', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, AddCategorieTransactionScreen(categorie: b.categorie, entite: b.entite));
      await tester.tap(find.text('Enregistrer une note vocale'));
      await charger(tester);
      final fichierBrut = File(micro.dernierChemin!);
      expect(fichierBrut.existsSync(), isTrue);

      await tester.tap(find.textContaining('Arreter ('));
      await charger(tester);

      expect(find.textContaining('Ecouter la note'), findsOneWidget);
      expect(fichierBrut.existsSync(), isFalse);
      await fermerEcran(tester);
    });

    testWidgets('un double appui sur "Arreter" garde la note (micro arrete une seule fois)', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, AddCategorieTransactionScreen(categorie: b.categorie, entite: b.entite));
      await tester.enterText(find.byType(TextFormField).first, '1000');
      await tester.tap(find.text('Enregistrer une note vocale'));
      await charger(tester);

      await tester.tap(find.textContaining('Arreter ('));
      await tester.tap(find.textContaining('Arreter ('));
      await charger(tester);

      expect(find.textContaining('Ecouter la note'), findsOneWidget);
      await tester.tap(find.text('Enregistrer'));
      await charger(tester);
      expect(await io(tester, () => db.transactionsAvecAudio(b.entite.id!)), hasLength(1));      await fermerEcran(tester);
    });

    testWidgets('un double appui sur "Enregistrer une note vocale" demarre le micro une seule fois', (tester) async {
      final b = await io(tester, boutique);
      await ouvrir(tester, AddCategorieTransactionScreen(categorie: b.categorie, entite: b.entite));

      await tester.tap(find.text('Enregistrer une note vocale'));
      await tester.tap(find.text('Enregistrer une note vocale'));
      await charger(tester);

      expect(micro.demarrages, 1);
      await fermerEcran(tester);
    });
  });
}
