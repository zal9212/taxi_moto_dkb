import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:moto_taxi_douka/core/constants.dart';
import 'package:moto_taxi_douka/core/theme.dart';
import 'package:moto_taxi_douka/models/categorie_activite.dart';
import 'package:moto_taxi_douka/models/categorie_entite.dart';
import 'package:moto_taxi_douka/models/categorie_gerant.dart';
import 'package:moto_taxi_douka/models/categorie_transaction.dart';
import 'package:moto_taxi_douka/models/depense.dart';
import 'package:moto_taxi_douka/models/dette.dart';
import 'package:moto_taxi_douka/models/moto.dart';
import 'package:moto_taxi_douka/screens/add_edit_moto_screen.dart';
import 'package:moto_taxi_douka/screens/add_expense_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/add_categorie_transaction_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/add_edit_categorie_entite_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/categorie_entite_detail_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/categorie_home_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/categories_screen.dart';
import 'package:moto_taxi_douka/screens/categorie/creer_modifier_categorie_screen.dart';
import 'package:moto_taxi_douka/screens/dette/add_edit_dette_screen.dart';
import 'package:moto_taxi_douka/screens/dette/dette_detail_screen.dart';
import 'package:moto_taxi_douka/screens/dette/dettes_screen.dart';
import 'package:moto_taxi_douka/screens/expenses_screen.dart';
import 'package:moto_taxi_douka/screens/home_screen.dart';
import 'package:moto_taxi_douka/screens/lock_screen.dart';
import 'package:moto_taxi_douka/screens/moto_detail_screen.dart';
import 'package:moto_taxi_douka/screens/settings_screen.dart';
import 'package:moto_taxi_douka/screens/setup_pin_screen.dart';
import 'package:moto_taxi_douka/screens/stats_screen.dart';
import 'package:moto_taxi_douka/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Ouvre chaque page de l'app sur un ecran de telephone, avec des donnees
/// realistes : echoue si une page plante ou deborde. Avec la variable
/// d'environnement CAPTURES_PAGES=<dossier>, enregistre aussi une capture
/// de chaque page pour la relire a l'oeil.

final db = DatabaseService.instance;
final _captures = Platform.environment['CAPTURES_PAGES'];
const _cleCapture = Key('capture');

/// Donnees de demonstration : une moto en retard avec des versements, des
/// depenses, une boutique avec gerants et note vocale, une dette.
Future<({Moto moto, CategorieActivite categorie, CategorieEntite entite, int detteId})> donnees() async {
  final motoId = await db.insererMoto(Moto(
    nom: 'Moto Bajaj 01',
    chauffeur: 'Mamadou Diallo',
    montantVersement: 50000,
    frequenceType: AppConstants.freqHebdomadaire,
    frequenceValeur: DateTime.monday,
    dateDebut: DateTime.now().subtract(const Duration(days: 35)),
  ));
  final moto = (await db.obtenirMoto(motoId))!;
  await db.assurerEcheances(moto);
  await db.encaisser(moto, 80000);
  final categorieDepense = (await db.listerCategories()).first;
  await db.insererDepense(Depense(
      motoId: motoId, categorieId: categorieDepense.id!, montant: 25000, date: DateTime.now(), description: 'Vidange'));

  final categorieId = await db
      .insererCategorieActivite(CategorieActivite(nom: 'Boutiques', couleur: '#2D6CDF', deviseSymbole: 'FG'));
  final entiteId = await db.insererEntiteCategorie(CategorieEntite(categorieId: categorieId, nom: 'Boutique Madina'));
  final ibrahim = await db.insererGerant(CategorieGerant(entiteId: entiteId, nom: 'Ibrahim'));
  await db.insererGerant(CategorieGerant(entiteId: entiteId, nom: 'Aissatou', statut: AppConstants.motoArchivee));
  await db.insererTransactionCategorie(CategorieTransaction(
      entiteId: entiteId, type: AppConstants.transactionRevenu, montant: 1250000, date: DateTime.now(),
      description: 'Ventes de la semaine'));
  await db.insererTransactionCategorie(
      CategorieTransaction(
          entiteId: entiteId, type: AppConstants.transactionDepense, montant: 300000, date: DateTime.now(),
          gerantId: ibrahim),
      audio: Uint8List.fromList([1, 2, 3]));

  final detteId = await db.insererDette(Dette(
    nomPersonne: 'Alpha Bah',
    montantInitial: 200000,
    date: DateTime.now().subtract(const Duration(days: 10)),
    lienType: AppConstants.detteLienMoto,
    lienId: motoId,
  ));
  await db.insererRemboursement(DetteRemboursement(detteId: detteId, montant: 50000, date: DateTime.now()));

  return (
    moto: moto,
    categorie: (await db.obtenirCategorieActivite(categorieId))!,
    entite: (await db.obtenirEntiteCategorie(entiteId))!,
    detteId: detteId,
  );
}

Future<T> io<T>(WidgetTester tester, Future<T> Function() f) async => (await tester.runAsync(f)) as T;

Future<void> charger(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Affiche [page] sur un telephone de 411 x 891 points et verifie qu'elle
/// s'ouvre sans erreur (exception, debordement).
Future<void> afficher(WidgetTester tester, String nom, Widget page, {Future<void> Function()? ensuite}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(RepaintBoundary(
    key: _cleCapture,
    child: MaterialApp(theme: AppTheme.light, debugShowCheckedModeBanner: false, home: page),
  ));
  await charger(tester);
  if (ensuite != null) {
    await ensuite();
    await charger(tester);
  }
  final erreur = tester.takeException();
  // Detail complet (widget en cause) : le resume seul ne dit pas ou chercher.
  expect(erreur, isNull,
      reason: 'la page "$nom" a leve une erreur :\n${erreur is FlutterError ? erreur.toStringDeep() : erreur}');

  if (_captures != null) {
    final rendu = tester.renderObject<RenderRepaintBoundary>(find.byKey(_cleCapture));
    await tester.runAsync(() async {
      final image = await rendu.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$_captures/$nom.png').writeAsBytes(png!.buffer.asUint8List());
    });
  }
  // Libere l'ecran en temps reel (plugins, minuteurs) avant le test suivant.
  await tester.pumpWidget(const SizedBox());
  await charger(tester);
}

Future<void> chargerPolice(String famille, List<String> fichiers) async {
  final dossier = '${Platform.environment['FLUTTER_ROOT'] ?? r'C:\Users\USER\develop\flutter'}'
      '/bin/cache/artifacts/material_fonts';
  final police = FontLoader(famille);
  for (final f in fichiers) {
    final fichier = File('$dossier/$f');
    if (!fichier.existsSync()) return; // sans police : la verification tourne quand meme
    police.addFont(Future.value(ByteData.sublistView(fichier.readAsBytesSync())));
  }
  await police.load();
}

late Directory dossierBase;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    dossierBase = await Directory.systemTemp.createTemp('verification_pages');
    await databaseFactory.setDatabasesPath(dossierBase.path);
    await initializeDateFormatting('fr_FR');
    if (_captures != null) {
      await chargerPolice('Roboto', ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']);
      await chargerPolice('MaterialIcons', ['materialicons-regular.otf']);
    }
    final messager = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messager.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => Directory.systemTemp.path);
    // PIN deja configure (ecran de verrouillage avec clavier), rien d'autre en stockage securise.
    messager.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'read' && (call.arguments as Map)['key'] == 'pin_hash' ? 'hash' : null);
    messager.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/local_auth'), (_) async => false);
    messager.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'), (_) async => null);
    // Micro des notes vocales (ecran "nouvelle operation") : rien a enregistrer ici.
    messager.setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);
  });

  tearDownAll(() async {
    await db.fermer();
    await dossierBase.delete(recursive: true);
  });

  setUp(() async {
    await db.fermer();
    await databaseFactory.deleteDatabase(await db.cheminBaseDeDonnees());
  });

  testWidgets('01 verrouillage', (t) async => afficher(t, '01_verrouillage', const LockScreen()));
  testWidgets('02 creation du PIN', (t) async => afficher(t, '02_creation_pin', SetupPinScreen(onTermine: () {})));

  for (final (i, onglet) in [(3, null), (4, 'Motos'), (5, 'Depenses'), (6, 'Reglages')]) {
    testWidgets('0$i accueil ${onglet ?? ''}', (t) async {
      await io(t, donnees);
      await afficher(t, '0${i}_accueil_${onglet ?? 'tableau'}', const HomeScreen(),
          ensuite: onglet == null ? null : () => t.tap(find.text(onglet).last));
    });
  }

  testWidgets('07 fiche moto', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '07_fiche_moto', MotoDetailScreen(motoId: d.moto.id!));
  });
  testWidgets('07b fiche moto a jour : le bouton relancer reste la et explique', (t) async {
    final id = await io(t, () => db.insererMoto(Moto(
          nom: 'Moto neuve',
          chauffeur: 'Ousmane',
          montantVersement: 50000,
          frequenceType: AppConstants.freqHebdomadaire,
          frequenceValeur: DateTime.monday,
          dateDebut: DateTime.now().add(const Duration(days: 3)),
        )));
    await afficher(t, '07b_fiche_moto_a_jour', MotoDetailScreen(motoId: id), ensuite: () async {
      await t.tap(find.byTooltip('Relancer le chauffeur'));
      await t.pump();
      expect(find.textContaining('Rien a relancer'), findsOneWidget);
    });
  });
  testWidgets('07c ajouter versement : periodes cochees, montant, enregistre comme un versement', (t) async {
    final d = await io(t, donnees);
    final avant = await io(t, () => db.totalEncaisse(motoId: d.moto.id!));
    await afficher(t, '07c_ajouter_versement', MotoDetailScreen(motoId: d.moto.id!), ensuite: () async {
      await t.tap(find.text('Ajouter versement'));
      await charger(t);
      expect(find.text('Periodes payees'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsWidgets);
      await t.tap(find.text('Enregistrer'));
      await charger(t);
    });
    expect(await io(t, () => db.totalEncaisse(motoId: d.moto.id!)), greaterThan(avant));
  });
  testWidgets('07d semaine ancienne impayee : la passer en dette pour payer les suivantes', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '07d_semaine_en_dette', MotoDetailScreen(motoId: d.moto.id!), ensuite: () async {
      await t.tap(find.text('Ajouter versement'));
      await charger(t);
      // La plus ancienne semaine due, cochee d'avance : on la decoche.
      await t.tap(find.byType(Checkbox).first);
      await charger(t);
      expect(find.text('Semaines anterieures impayees'), findsOneWidget);
      await t.tap(find.text('Passer en dette'));
      await charger(t);
      expect(find.textContaining('Passera en dette'), findsOneWidget);
      await t.tap(find.text('Enregistrer'));
      await charger(t);
    });
    final versements = await io(t, () => db.listerVersementsParMoto(d.moto.id!));
    expect(versements.where((v) => v.statut == AppConstants.versementEnDette).length, 1);
    final retards = versements.where((v) => v.statut == AppConstants.versementEnRetard);
    expect(retards, isEmpty, reason: 'les autres semaines dues sont payees');
  });
  testWidgets('08 nouvelle moto', (t) async => afficher(t, '08_nouvelle_moto', const AddEditMotoScreen()));
  testWidgets('09 modifier moto', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '09_modifier_moto', AddEditMotoScreen(motoExistante: d.moto));
  });
  testWidgets('10 nouvelle depense', (t) async {
    await io(t, donnees);
    await afficher(t, '10_nouvelle_depense', const AddExpenseScreen());
  });
  testWidgets('11 depenses', (t) async {
    await io(t, donnees);
    await afficher(t, '11_depenses', const ExpensesScreen());
  });
  testWidgets('12 statistiques', (t) async {
    await io(t, donnees);
    await afficher(t, '12_statistiques', const StatsScreen());
  });
  testWidgets('13 reglages', (t) async {
    await io(t, donnees);
    await afficher(t, '13_reglages', const SettingsScreen());
  });
  testWidgets('14 categories', (t) async {
    await io(t, donnees);
    await afficher(t, '14_categories', const CategoriesScreen());
  });
  testWidgets('15 accueil categorie', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '15_accueil_categorie', CategorieHomeScreen(categorieId: d.categorie.id!));
  });
  testWidgets('16 fiche boutique', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '16_fiche_boutique', CategorieEntiteDetailScreen(entiteId: d.entite.id!, categorie: d.categorie));
  });
  testWidgets('17 nouvelle operation', (t) async {
    final d = await io(t, donnees);
    final gerants = (await io(t, () => db.listerGerants(d.entite.id!)))
        .where((g) => g.statut == AppConstants.motoActive)
        .toList();
    await afficher(t, '17_nouvelle_operation',
        AddCategorieTransactionScreen(categorie: d.categorie, entite: d.entite, gerants: gerants));
  });
  testWidgets('18 nouvelle categorie', (t) async => afficher(t, '18_nouvelle_categorie', const CreerModifierCategorieScreen()));
  testWidgets('19 nouvelle boutique', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '19_nouvelle_boutique', AddEditCategorieEntiteScreen(categorie: d.categorie));
  });
  testWidgets('20 dettes', (t) async {
    await io(t, donnees);
    await afficher(t, '20_dettes', const DettesScreen());
  });
  testWidgets('21 fiche dette', (t) async {
    final d = await io(t, donnees);
    await afficher(t, '21_fiche_dette', DetteDetailScreen(detteId: d.detteId));
  });
  testWidgets('22 nouvelle dette', (t) async {
    await io(t, donnees);
    await afficher(t, '22_nouvelle_dette', const AddEditDetteScreen());
  });
}
