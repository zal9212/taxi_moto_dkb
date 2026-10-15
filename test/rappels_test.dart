import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:moto_taxi_douka/core/constants.dart';
import 'package:moto_taxi_douka/models/moto.dart';
import 'package:moto_taxi_douka/models/versement.dart';
import 'package:moto_taxi_douka/services/notification_service.dart';
import 'package:timezone/data/latest.dart' as tzdata;

/// Faux systeme de notifications : garde les rappels programmes et compte
/// les appels (chacun traverse le pont Flutter -> Android, lent).
class _FauxSysteme {
  final programmes = <int, Map<Object?, Object?>>{};
  var appels = 0;

  Future<Object?> repondre(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'pendingNotificationRequests':
        return [
          for (final p in programmes.values)
            {'id': p['id'], 'title': p['title'], 'body': p['body'], 'payload': p['payload']},
        ];
      case 'zonedSchedule':
        appels++;
        programmes[args['id'] as int] = Map.of(args);
        return null;
      case 'cancel':
        appels++;
        programmes.remove(args['id'] ?? call.arguments);
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FauxSysteme systeme;

  setUpAll(() async {
    tzdata.initializeTimeZones();
    await initializeDateFormatting('fr_FR');
  });

  setUp(() {
    systeme = _FauxSysteme();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'), systeme.repondre);
  });

  test('les rappels ne sont touches que s\'ils changent (pas des milliers d\'appels a chaque ecran)', () async {
    final aujourdHui = DateTime.now();
    final moto = Moto(
      id: 1,
      nom: 'TVs 125',
      chauffeur: 'Abdoul',
      montantVersement: 185000,
      frequenceType: AppConstants.freqHebdomadaire,
      frequenceValeur: DateTime.monday,
      dateDebut: aujourdHui.subtract(const Duration(days: 365)),
    );
    // Un an d'historique paye + 4 echeances a venir.
    final versements = [
      for (var i = 0; i < 52; i++)
        Versement(
            id: i + 1,
            motoId: 1,
            dateEcheance: aujourdHui.subtract(Duration(days: 7 * (52 - i))),
            montantPrevu: 185000,
            montantPaye: 185000,
            statut: AppConstants.versementPaye),
      for (var i = 1; i <= 4; i++)
        Versement(
            id: 100 + i,
            motoId: 1,
            dateEcheance: aujourdHui.add(Duration(days: 7 * i)),
            montantPrevu: 185000,
            statut: AppConstants.versementEnAttente),
    ];

    await NotificationService.synchroniserRappelsMoto(moto: moto, versements: versements, delaiHeures: 24);
    expect(systeme.programmes.length, 8, reason: '2 rappels par echeance a venir, aucun pour les payees');
    final premiers = systeme.appels;
    expect(premiers, 8);

    // Deuxieme ouverture d'ecran, rien n'a change : aucun appel.
    await NotificationService.synchroniserRappelsMoto(moto: moto, versements: versements, delaiHeures: 24);
    expect(systeme.appels, premiers, reason: 'rien a changer : zero appel au systeme');

    // La premiere echeance a venir est payee : ses 2 rappels sont annules, rien d'autre.
    final apres = [
      for (final v in versements)
        v.id == 101 ? v.copyWith(montantPaye: 185000, statut: AppConstants.versementPaye) : v,
    ];
    await NotificationService.synchroniserRappelsMoto(moto: moto, versements: apres, delaiHeures: 24);
    expect(systeme.appels, premiers + 2);
    expect(systeme.programmes.keys, isNot(contains(101)));
  });
}
