import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:moto_taxi_douka/utils/messages.dart';

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  test('la relance liste chaque periode due et le total', () {
    final message = messageRelance(
      chauffeur: 'Mamadou',
      moto: 'Moto 1',
      dues: [
        (date: DateTime(2026, 9, 14), etat: 'en retard', reste: 50000),
        (date: DateTime(2026, 9, 21), etat: 'partiel', reste: 20000),
      ],
      devise: 'FG',
    );

    expect(message, contains('Mamadou'));
    expect(message, contains('Moto 1'));
    expect(message, contains('14/09/2026'));
    expect(message, contains('21/09/2026'));
    expect(message, contains('70 000 FG'));
  });

  test('le recu indique le montant, les periodes payees et le reste du', () {
    final message = messageRecu(
      chauffeur: 'Mamadou',
      moto: 'Moto 1',
      montant: 80000,
      date: DateTime(2026, 10, 3),
      affectations: [(date: DateTime(2026, 9, 14), montant: 50000), (date: DateTime(2026, 9, 21), montant: 30000)],
      resteDu: 20000,
      devise: 'FG',
    );

    expect(message, contains('80 000 FG'));
    expect(message, contains('03/10/2026'));
    expect(message, contains('14/09/2026'));
    expect(message, contains('Reste du : 20 000 FG'));
  });

  test('le recu dit "a jour" quand plus rien n\'est du', () {
    final message = messageRecu(
      chauffeur: 'Mamadou',
      moto: 'Moto 1',
      montant: 50000,
      date: DateTime(2026, 10, 3),
      affectations: [(date: DateTime(2026, 9, 28), montant: 50000)],
      resteDu: 0,
      devise: 'FG',
    );

    expect(message, contains('A jour'));
  });
}
