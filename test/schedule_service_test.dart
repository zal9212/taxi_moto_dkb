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

      // Debut un samedi (semaine du 27/07) : le lundi 03/08 ouvre une nouvelle semaine.
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

  group('argent du (seule definition : periodes a payer et solde)', () {
    test('periodes a payer : retards, partielles et a venir, sans les payees ni les dettes', () {
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
          // 21/09 n'a pas d'echeance (effacee) : rien n'est du
          echeance(DateTime(2026, 9, 28), AppConstants.versementEnDette),
          echeance(DateTime(2026, 10, 5), enAttente),
        ],
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 8, 31)),
        aujourdHui: aujourdHui,
      );

      expect(periodes.map((p) => (p.date, p.etat, p.reste)), [
        (DateTime(2026, 9, 7), 'partiel', 20000),
        (DateTime(2026, 9, 14), 'en retard', 50000),
        (DateTime(2026, 10, 5), 'a venir', 50000),
      ]);
    });

    test('montant en vigueur : depart avant le 1er changement, puis chaque changement jusqu\'au suivant', () {
      final m = moto(hebdo, DateTime.monday);
      final changements = [
        (depuis: DateTime(2026, 9, 14), montant: 60000.0),
        (depuis: DateTime(2026, 12, 1), montant: 65000.0), // prevu
      ];
      double au(DateTime d) => ScheduleService.montantAu(m, changements, d);

      expect(au(DateTime(2026, 9, 13, 23)), 50000);
      expect(au(DateTime(2026, 9, 14, 8)), 60000); // l'heure ne compte pas
      expect(au(DateTime(2026, 11, 30)), 60000);
      expect(au(DateTime(2027, 1, 1)), 65000);
      expect(ScheduleService.montantAu(m, const [], DateTime(2027)), 50000);
    });

    test('moto suspendue puis reactivee : les semaines de pause ne sont pas dues', () {
      // Lundis payes jusqu'au 07/09, pause du 08/09 au 27/09, reprise le lundi 28/09.
      final periodes = ScheduleService.periodesAPayer(
        existants: [
          echeance(DateTime(2026, 8, 31), paye),
          echeance(DateTime(2026, 9, 7), paye),
          echeance(DateTime(2026, 9, 28), enRetard),
          echeance(DateTime(2026, 10, 5), enAttente),
        ],
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 8, 31)),
        aujourdHui: aujourdHui,
      );

      expect(periodes.map((p) => p.date), [DateTime(2026, 9, 28), DateTime(2026, 10, 5)]);
    });

    test('moto suspendue : ses echeances de la pause (restees en attente) ne sont ni a payer ni dans le solde', () {
      final suspendue = moto(hebdo, DateTime.monday).copyWith(statut: AppConstants.motoSuspendue);
      final existants = [
        echeance(DateTime(2026, 9, 14), enRetard), // retard d'avant la pause : du
        echeance(DateTime(2026, 9, 21), enAttente), // pendant la pause
      ];

      expect(
          ScheduleService.periodesAPayer(existants: existants, moto: suspendue, aujourdHui: aujourdHui)
              .map((p) => p.date),
          [DateTime(2026, 9, 14)]);
      expect(ScheduleService.compte(suspendue, existants, aujourdHui), (retard: 50000.0, avance: 0.0));
    });

    test('jour change (lundi -> mercredi) : les semaines payees le lundi ne sont pas redemandees le mercredi', () {
      // Cas reel (TVs 125) : lundis jusqu'au 14/09, puis mercredis a partir du 16/09.
      final m = moto(hebdo, DateTime.wednesday, dateDebut: DateTime(2026, 8, 31));
      final existants = [
        echeance(DateTime(2026, 8, 31), paye),
        echeance(DateTime(2026, 9, 7), paye),
        echeance(DateTime(2026, 9, 14), enRetard),
        echeance(DateTime(2026, 9, 16), enRetard),
        echeance(DateTime(2026, 9, 30), enRetard),
        echeance(DateTime(2026, 10, 7), enAttente),
      ];
      final dues = ScheduleService.periodesAPayer(existants: existants, moto: m, aujourdHui: aujourdHui)
          .where((p) => p.date.isBefore(aujourdHui));

      expect(dues.map((p) => p.date), [DateTime(2026, 9, 14), DateTime(2026, 9, 16), DateTime(2026, 9, 30)]);
      // La relance (somme des periodes dues) et la fiche (solde) disent la meme chose.
      expect(ScheduleService.compte(m, existants, aujourdHui).retard, dues.fold<double>(0, (t, p) => t + p.reste));
    });

    test('solde : payee sans montant = payee en entier, dette exclue, partiel compte ce qui manque', () {
      final m = moto(hebdo, DateTime.monday);
      final existants = [
        echeance(DateTime(2026, 9, 7), paye), // ancien import, sans montant
        Versement(motoId: 1, dateEcheance: DateTime(2026, 9, 14), montantPrevu: 50000, montantPaye: 30000, statut: paye),
        echeance(DateTime(2026, 9, 21), AppConstants.versementEnDette),
        echeance(DateTime(2026, 9, 28), enRetard),
      ];

      expect(ScheduleService.compte(m, existants, aujourdHui), (retard: 70000.0, avance: 0.0));
      expect(
          ScheduleService.periodesAPayer(existants: existants, moto: m, aujourdHui: aujourdHui)
              .fold<double>(0, (t, p) => t + p.reste),
          70000);
    });
  });

  group('ajouter un versement (periodes choisies)', () {
    /// Lundis : retards les 14 et 21/09, paye le 28/09, 4 echeances a venir (05 au 26/10).
    final existants = [
      echeance(DateTime(2026, 9, 14), enRetard),
      echeance(DateTime(2026, 9, 21), enRetard),
      echeance(DateTime(2026, 9, 28), paye),
      echeance(DateTime(2026, 10, 5), enAttente),
      echeance(DateTime(2026, 10, 12), enAttente),
      echeance(DateTime(2026, 10, 19), enAttente),
      echeance(DateTime(2026, 10, 26), enAttente),
    ];
    final m = moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 9, 14));
    List<(DateTime, double)> affecter(double montant, {Set<DateTime>? choisies, List<ChangementMontant> changements = const []}) =>
        ScheduleService.affecterVersement(
          moto: m,
          existants: existants,
          changements: changements,
          aujourdHui: aujourdHui,
          montant: montant,
          choisies: choisies,
        ).map((a) => (a.date, a.montant)).toList();

    test('les periodes proposees suivent la frequence : dues, a venir, puis les suivantes', () {
      final periodes = ScheduleService.periodesChoisissables(
          moto: m, existants: existants, changements: const [], aujourdHui: aujourdHui, futures: 2);

      expect(periodes.map((p) => p.date), [
        DateTime(2026, 9, 14),
        DateTime(2026, 9, 21),
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 9),
      ]);
    });

    test('paie seulement les periodes choisies, meme une future pas encore creee', () {
      expect(affecter(100000, choisies: {DateTime(2026, 9, 21), DateTime(2026, 11, 2)}),
          [(DateTime(2026, 9, 21), 50000), (DateTime(2026, 11, 2), 50000)]);
    });

    test('un surplus passe aux periodes suivantes, jamais plus que son montant sur une echeance', () {
      expect(affecter(120000, choisies: {DateTime(2026, 9, 14)}),
          [(DateTime(2026, 9, 14), 50000), (DateTime(2026, 9, 21), 50000), (DateTime(2026, 10, 5), 20000)]);

      final avance = affecter(400000);
      expect(avance.map((a) => a.$1), [
        DateTime(2026, 9, 14),
        DateTime(2026, 9, 21),
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 9),
      ]);
      expect(avance.every((a) => a.$2 <= 50000), isTrue);
      expect(avance.fold<double>(0, (t, a) => t + a.$2), 400000);
    });

    test('une periode future prend le montant en vigueur a sa date', () {
      expect(
          affecter(60000,
              choisies: {DateTime(2026, 11, 2)}, changements: [(depuis: DateTime(2026, 11, 1), montant: 60000.0)]),
          [(DateTime(2026, 11, 2), 60000)]);
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

    test('transition : un seul versement par semaine (lundi deja du, passage au mercredi + date de debut)', () {
      // Cas reel (TVs 125) : la semaine du 14/09 a deja son versement (lundi 14/09) ;
      // le premier mercredi est celui de la semaine suivante, le 23/09, pas le 16/09.
      final plan = ScheduleService.replanifier(
        existants: [
          echeance(DateTime(2026, 8, 31), paye),
          echeance(DateTime(2026, 9, 7), paye),
          echeance(DateTime(2026, 9, 14), enRetard),
        ],
        moto: moto(hebdo, DateTime.wednesday, dateDebut: DateTime(2026, 8, 31)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      expect(plan.aCreer, [
        DateTime(2026, 9, 23),
        DateTime(2026, 9, 30),
        DateTime(2026, 10, 7),
        DateTime(2026, 10, 14),
        DateTime(2026, 10, 21),
        DateTime(2026, 10, 28),
      ]);
    });

    test('transition : mercredi -> lundi reprend la semaine suivante, sans jour offert', () {
      // Semaine du 28/09 : deja le mercredi 30/09 -> pas le lundi 28/09 ; le lundi 05/10 ouvre la semaine suivante.
      final plan = ScheduleService.replanifier(
        existants: [
          echeance(DateTime(2026, 9, 23), paye),
          echeance(DateTime(2026, 9, 30), enRetard),
          echeance(DateTime(2026, 10, 7), enAttente),
        ],
        moto: moto(hebdo, DateTime.monday, dateDebut: DateTime(2026, 9, 23)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      expect(plan.aCreer.first, DateTime(2026, 10, 5));
    });

    test('transition : lundi -> vendredi, le vendredi d\'une semaine deja payee est saute', () {
      final plan = ScheduleService.replanifier(
        existants: [
          echeance(DateTime(2026, 8, 31), paye),
          echeance(DateTime(2026, 9, 7), paye),
          echeance(DateTime(2026, 9, 14), enRetard),
        ],
        moto: moto(hebdo, DateTime.friday, dateDebut: DateTime(2026, 8, 31)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      // 04, 11 et 18/09 sont dans des semaines qui ont deja leur lundi.
      expect(plan.aCreer.first, DateTime(2026, 9, 25));
    });

    test('transition : hebdomadaire -> mensuel, un seul versement par mois', () {
      final plan = ScheduleService.replanifier(
        existants: [
          echeance(DateTime(2026, 8, 31), paye),
          echeance(DateTime(2026, 9, 7), paye),
          echeance(DateTime(2026, 9, 14), enRetard),
        ],
        moto: moto(mensuelle, 15, dateDebut: DateTime(2026, 8, 31)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      // Septembre a deja ses versements : le 15/09 est saute.
      expect(plan.aCreer.first, DateTime(2026, 10, 15));
    });

    test('transition : hebdomadaire -> tous les 10 jours, 10 jours au moins apres le dernier versement', () {
      final plan = ScheduleService.replanifier(
        existants: [
          echeance(DateTime(2026, 9, 21), paye),
          echeance(DateTime(2026, 9, 28), paye),
          echeance(DateTime(2026, 10, 5), enAttente),
        ],
        moto: moto(perso, 10, dateDebut: DateTime(2026, 9, 21)),
        depuisDateDebut: true,
        aujourdHui: aujourdHui,
      );

      expect(plan.aCreer.first, DateTime(2026, 10, 11)); // 21/09, 01/10 (trop pres du 28/09), 11/10
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
      // Mercredi 14/10 (semaine du 12/10), puis lundi 19/10 : semaine suivante.
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
