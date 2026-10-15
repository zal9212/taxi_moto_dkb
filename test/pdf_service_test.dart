import 'package:flutter_test/flutter_test.dart';
import 'package:moto_taxi_douka/core/constants.dart';
import 'package:moto_taxi_douka/models/versement.dart';
import 'package:moto_taxi_douka/services/pdf_service.dart';

void main() {
  test('releve : une semaine passee en dette puis remboursee montre la date de son remboursement', () {
    final remboursements = {7: DateTime(2026, 10, 15)};
    Versement v(String statut, {DateTime? validation, int? dette}) => Versement(
        motoId: 1,
        dateEcheance: DateTime(2026, 10, 7),
        montantPrevu: 185000,
        statut: statut,
        dateValidation: validation,
        detteId: dette);

    expect(PdfService.dateDeLigne(v(AppConstants.versementEnDette, dette: 7), remboursements), DateTime(2026, 10, 15));
    expect(PdfService.dateDeLigne(v(AppConstants.versementEnDette, dette: 8), remboursements), isNull,
        reason: 'pas encore remboursee');
    expect(
        PdfService.dateDeLigne(v(AppConstants.versementPaye, validation: DateTime(2026, 10, 8)), remboursements),
        DateTime(2026, 10, 8));
  });
}
