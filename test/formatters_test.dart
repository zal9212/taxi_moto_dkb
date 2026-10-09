import 'package:flutter_test/flutter_test.dart';
import 'package:moto_taxi_douka/utils/formatters.dart';

void main() {
  group('lireMontant', () {
    test('accepte les separateurs de milliers courants', () {
      expect(lireMontant('50000'), 50000);
      expect(lireMontant('10 000'), 10000);
      expect(lireMontant('10.000'), 10000);
      expect(lireMontant('10,000'), 10000);
      expect(lireMontant(' 1 234 567 '), 1234567);
    });

    test('relit un montant tel que l\'app l\'affiche (espace fine insecable)', () {
      expect(lireMontant('10 000'), 10000);
      expect(lireMontant('10 000'), 10000);
    });

    test('refuse les centimes au lieu de les lire de travers (12,50 n\'est pas 1250)', () {
      expect(lireMontant('12,50'), isNull);
      expect(lireMontant('12.5'), isNull);
    });

    test('refuse vide, zero, negatif et texte', () {
      expect(lireMontant(''), isNull);
      expect(lireMontant(null), isNull);
      expect(lireMontant('0'), isNull);
      expect(lireMontant('-500'), isNull);
      expect(lireMontant('abc'), isNull);
    });
  });

  group('normaliserDevise', () {
    test('"fg " et "FG" donnent la meme devise (un seul total)', () {
      expect(normaliserDevise('fg '), 'FG');
      expect(normaliserDevise(' Fcfa'), 'FCFA');
    });

    test('vide -> null (repli sur la devise globale)', () {
      expect(normaliserDevise('   '), isNull);
    });
  });
}
