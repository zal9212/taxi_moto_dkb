import 'package:flutter_test/flutter_test.dart';
import 'package:moto_taxi_douka/core/constants.dart';
import 'package:moto_taxi_douka/models/moto.dart';
import 'package:moto_taxi_douka/models/versement.dart';
import 'package:moto_taxi_douka/services/schedule_service.dart';

const hebdo = AppConstants.freqHebdomadaire;
const mensuelle = AppConstants.freqMensuelle;
const perso = AppConstants.freqPersonnalisee;
const paye = AppConstants.versementPaye;
const enRetard = AppConstants.versementEnRetard;
const enAttente = AppConstants.versementEnAttente;

/// Samedi 3 octobre 2026 : "aujourd'hui" fixe pour tous les scenarios.
final aujourdHui = DateTime(2026, 10, 3);

Versement echeance(DateTime date, String statut) =>
    Versement(motoId: 1, dateEcheance: date, montantPrevu: 50000, statut: statut);

Moto moto(String type, int valeur, {DateTime? dateDebut}) => Moto(
      id: 1,
      nom: 'Moto 1',
      chauffeur: 'Mamadou',
      montantVersement: 50000,
      frequenceType: type,
      frequenceValeur: valeur,
      dateDebut: dateDebut ?? DateTime(2026, 9, 14),
    );

/// Moto hebdomadaire du lundi : un retard le 14/09, payee les 21 et 28/09,
/// et ses 4 prochaines echeances (lundis 5, 12, 19 et 26/10).
List<Versement> historiqueLundis() => [
      echeance(DateTime(2026, 9, 14), enRetard),
      echeance(DateTime(2026, 9, 21), paye),
      echeance(DateTime(2026, 9, 28), paye),
      echeance(DateTime(2026, 10, 5), enAttente),
      echeance(DateTime(2026, 10, 12), enAttente),
      echeance(DateTime(2026, 10, 19), enAttente),
      echeance(DateTime(2026, 10, 26), enAttente),
    ];

List<DateTime> dates(List<Versement> versements) => versements.map((v) => v.dateEcheance).toList();

void main() {
  group('echeanceSuivante', () {
    test('hebdomadaire : le jour choisi est applique (lundi -> mercredi)', () {
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 9, 28), type: hebdo, valeur: DateTime.wednesday),
        DateTime(2026, 9, 30),
      );
    });

    test('hebdomadaire : meme jour -> 7 jours plus tard', () {
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 9, 28), type: hebdo, valeur: DateTime.monday),
        DateTime(2026, 10, 5),
      );
    });

    test('mensuelle : passe au jour choisi suivant, meme dans le mois en cours (5 -> 20)', () {
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 9, 5), type: mensuelle, valeur: 20),
        DateTime(2026, 9, 20),
      );
    });

    test('mensuelle : le 31 devient le dernier jour des mois courts puis revient au 31', () {
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 1, 31), type: mensuelle, valeur: 31),
        DateTime(2026, 2, 28),
      );
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 2, 28), type: mensuelle, valeur: 31),
        DateTime(2026, 3, 31),
      );
    });

    test('personnalisee : un intervalle de 0 avance quand meme d\'un jour', () {
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 10, 3), type: perso, valeur: 0),
        DateTime(2026, 10, 4),
      );
    });

    test('ignore l\'heure de la date fournie', () {
      expect(
        ScheduleService.echeanceSuivante(dateActuelle: DateTime(2026, 9, 28, 14, 32), type: hebdo, valeur: DateTime.monday),
        DateTime(2026, 10, 5),
      );
    });
  });

  group('premiereEcheance', () {
    test('mensuelle : jamais avant la date de debut (cree le 20, jour 5 -> le 5 du mois suivant)', () {
      expect(
        ScheduleService.premiereEcheance(dateDebut: DateTime(2026, 3, 20), type: mensuelle, valeur: 5),
        DateTime(2026, 4, 5),
      );
    });

    test('hebdomadaire : le jour meme s\'il correspond', () {
      expect(
        ScheduleService.premiereEcheance(dateDebut: DateTime(2026, 9, 30), type: hebdo, valeur: DateTime.wednesday),
        DateTime(2026, 9, 30),
      );
    });

    test('personnalisee : la date elle-meme, sans l\'heure', () {
      expect(
        ScheduleService.premiereEcheance(dateDebut: DateTime(2026, 10, 3, 14, 32), type: perso, valeur: 10),
        DateTime(2026, 10, 3),
      );
    });
  });

  group('datesAGenerer', () {
    test('le retard continue de grossir quand le chauffeur ne paie plus (plus de plafond a 4 echeances)', () {
      final existants = [
        echeance(DateTime(2026, 8, 31), enRetard),
        echeance(DateTime(2026, 9, 7), enRetard),
        echeance(DateTime(2026, 9, 14), enRetard),
        echeance(DateTime(2026, 9, 21), enRetard),
      ];

      final nouvelles = ScheduleService.datesAGenerer(
        existants: existants,
        premiere: DateTime(2026, 9, 28),
        type: hebdo,
        valeur: DateTime.monday,
        aujourdHui: aujourdHui,
      );

      expect(nouvelles, [
        DateTime(2026, 9, 28), // passee : un retard de plus
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
    });

    test('ne cree aucune echeance dans la periode deja payee', () {
      final existants = [
        echeance(DateTime(2026, 9, 7), paye),
        echeance(DateTime(2026, 9, 14), paye),
        echeance(DateTime(2026, 9, 21), paye),
        echeance(DateTime(2026, 9, 28), paye),
      ];

      final nouvelles = ScheduleService.datesAGenerer(
        existants: existants,
        premiere: DateTime(2026, 8, 1),
        type: hebdo,
        valeur: DateTime.monday,
        aujourdHui: aujourdHui,
      );

      expect(nouvelles, [
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 3),
        DateTime(2026, 8, 10),
        DateTime(2026, 8, 17),
        DateTime(2026, 8, 24),
        DateTime(2026, 8, 31),
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
    });

    test('rien a creer quand les 4 prochaines echeances existent deja', () {
      final nouvelles = ScheduleService.datesAGenerer(
        existants: historiqueLundis(),
        premiere: DateTime(2026, 11, 2),
        type: hebdo,
        valeur: DateTime.monday,
        aujourdHui: aujourdHui,
      );

      expect(nouvelles, isEmpty);
    });
  });

  group('datesManquantes (echeances oubliees)', () {
    final existants = [
      echeance(DateTime(2026, 9, 7), paye),
      echeance(DateTime(2026, 9, 14), paye),
      // 21/09 et 28/09 n'existent pas
      echeance(DateTime(2026, 10, 5), enAttente),
    ];

    test('trouve les echeances manquantes au milieu de l\'historique', () {
      expect(
        ScheduleService.datesManquantes(
          existants: existants,
          depuis: DateTime(2026, 9, 7),
          type: hebdo,
          valeur: DateTime.monday,
          aujourdHui: aujourdHui,
        ),
        [DateTime(2026, 9, 21), DateTime(2026, 9, 28)],
      );
    });

    test('periodes a payer : retards, partielles, manquantes et a venir, sans les payees ni les dettes', () {
      final periodes = ScheduleService.periodesAPayer(
        existants: [
          echeance(DateTime(2026, 8, 31), paye),
          Versement(
            motoId: 1,
            dateEcheance: DateTime(2026, 9, 7),
            montantPrevu: 50000,
            montantPaye: 30000,
            statut: paye,
          ),
          echeance(DateTime(2026, 9, 14), enRetard),
          // 21/09 n'existe pas
          echeance(DateTime(2026, 9, 28), AppConstants.versementEnDette),
          echeance(DateTime(2026, 10, 5), enAttente),
        ],
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 8, 31)),
        aujourdHui: aujourdHui,
      );

      expect(periodes.map((p) => p.date),
          [DateTime(2026, 9, 7), DateTime(2026, 9, 14), DateTime(2026, 9, 21), DateTime(2026, 10, 5)]);
      expect(periodes.map((p) => p.etat), ['partiel', 'en retard', 'manquante', 'a venir']);
      expect(periodes.map((p) => p.reste), [20000, 50000, 50000, 50000]);
    });

    test('repartition : la plus ancienne periode est payee d\'abord, le reste passe a la suivante', () {
      final periodes = [
        (date: DateTime(2026, 9, 14), etat: 'en retard', reste: 50000.0),
        (date: DateTime(2026, 9, 21), etat: 'manquante', reste: 50000.0),
        (date: DateTime(2026, 10, 5), etat: 'a venir', reste: 50000.0),
      ];

      expect(ScheduleService.repartirPaiement(periodes, 80000).map((a) => (a.date, a.montant)), [
        (DateTime(2026, 9, 14), 50000),
        (DateTime(2026, 9, 21), 30000),
      ]);
    });

    test('repartition : un trop-paye au-dela de toutes les periodes reste sur la derniere (avance)', () {
      final periodes = [
        (date: DateTime(2026, 9, 14), etat: 'en retard', reste: 50000.0),
        (date: DateTime(2026, 10, 5), etat: 'a venir', reste: 50000.0),
      ];

      expect(ScheduleService.repartirPaiement(periodes, 120000).map((a) => (a.date, a.montant)), [
        (DateTime(2026, 9, 14), 50000),
        (DateTime(2026, 10, 5), 70000),
      ]);
    });

    test('trouve aussi celles d\'avant la premiere echeance, et jamais de date future', () {
      expect(
        ScheduleService.datesManquantes(
          existants: existants,
          depuis: DateTime(2026, 8, 24),
          type: hebdo,
          valeur: DateTime.monday,
          aujourdHui: aujourdHui,
        ),
        [DateTime(2026, 8, 24), DateTime(2026, 8, 31), DateTime(2026, 9, 21), DateTime(2026, 9, 28)],
      );
    });
  });

  group('replanifier (modification d\'une moto)', () {
    test('regle 1 : passer du lundi au mercredi deplace le prochain versement au mercredi suivant', () {
      final plan = ScheduleService.replanifier(
        existants: historiqueLundis(),
        moto: moto(hebdo, DateTime.wednesday),
        depuisDateDebut: false,
        aujourdHui: aujourdHui,
      );

      expect(dates(plan.aSupprimer), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
      expect(plan.aCreer, [
        DateTime(2026, 10, 7),
        DateTime(2026, 10, 14),
        DateTime(2026, 10, 21),
        DateTime(2026, 10, 28),
      ]);
    });

    test('regle 2 : changer la date de debut fixe le 1er versement a cette date, la suite suit la frequence', () {
      final plan = ScheduleService.replanifier(
        existants: historiqueLundis(),
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 10, 14)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      // Le retard du 14/09 n'est jamais supprime : seules les echeances a venir sont recalculees.
      expect(dates(plan.aSupprimer), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
      expect(plan.aCreer, [
        DateTime(2026, 10, 14),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
      ]);
    });

    test('regle 2 : avancer la date de debut ajoute les 2 versements oublies du debut, sans rien supprimer', () {
      // Debut fixe au 14/09 alors que le chauffeur devait deja le 31/08 et le 07/09.
      final existants = [
        echeance(DateTime(2026, 9, 14), paye),
        echeance(DateTime(2026, 9, 21), paye),
        echeance(DateTime(2026, 9, 28), paye),
        echeance(DateTime(2026, 10, 5), enAttente),
        echeance(DateTime(2026, 10, 12), enAttente),
        echeance(DateTime(2026, 10, 19), enAttente),
        echeance(DateTime(2026, 10, 26), enAttente),
      ];

      final plan = ScheduleService.replanifier(
        existants: existants,
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 8, 31)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      expect(plan.aCreer.take(2), [DateTime(2026, 8, 31), DateTime(2026, 9, 7)]);
      expect(plan.aCreer.skip(2), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
      expect(plan.aSupprimer.every((v) => v.statut == enAttente && !v.dateEcheance.isBefore(aujourdHui)), isTrue);
    });

    test('regle 2 : reculer la date de debut ne supprime aucun retard', () {
      final plan = ScheduleService.replanifier(
        existants: historiqueLundis(),
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 10, 12)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      expect(dates(plan.aSupprimer), isNot(contains(DateTime(2026, 9, 14))));
      expect(plan.aCreer, [
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
      ]);
    });

    test('regle 3 : passer a tous les 10 jours prend effet au prochain versement prevu', () {
      final plan = ScheduleService.replanifier(
        existants: historiqueLundis(),
        moto: moto(perso, 10),
        depuisDateDebut: false,
        aujourdHui: aujourdHui,
      );

      expect(plan.aCreer, [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 15),
        DateTime(2026, 10, 25),
        DateTime(2026, 11, 4),
      ]);
    });

    test('regle 3 : passer de la semaine au mois (le 15) prend effet au prochain versement prevu', () {
      final plan = ScheduleService.replanifier(
        existants: historiqueLundis(),
        moto: moto(mensuelle, 15),
        depuisDateDebut: false,
        aujourdHui: aujourdHui,
      );

      expect(plan.aCreer, [
        DateTime(2026, 10, 15),
        DateTime(2026, 11, 15),
        DateTime(2026, 12, 15),
        DateTime(2027, 1, 15),
      ]);
    });

    test('changer seulement le montant garde les memes dates a venir, et le retard deja du reste du', () {
      final plan = ScheduleService.replanifier(
        existants: historiqueLundis(),
        moto: moto(hebdo, DateTime.monday),
        depuisDateDebut: false,
        aujourdHui: aujourdHui,
      );

      expect(dates(plan.aSupprimer), isNot(contains(DateTime(2026, 9, 14))));
      expect(plan.aCreer, [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
    });
  });
}
