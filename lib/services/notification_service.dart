import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;

import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../utils/formatters.dart';
import 'database_service.dart';
import 'schedule_service.dart';

/// Planifie des rappels locaux avant chaque échéance de versement.
/// Le délai de rappel (en heures avant l'échéance) est configurable
/// dans les Réglages, jamais figé en dur.
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialiser() async {
    tzdata.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(settings);

    // Demande explicite des permissions (Android 13+ / iOS)
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// Decalage d'id de l'alerte de retard d'un versement (l'id du rappel est
  /// l'id du versement lui-meme) : les deux s'annulent ensemble.
  static const _decalageAlerteRetard = 1000000000;

  /// Programme, pour un versement : un rappel `delaiHeures` avant
  /// l'échéance, et une alerte le lendemain à 9 h s'il n'a pas été payé
  /// (c'est là qu'il passe en retard). Payer l'échéance annule les deux.
  static Future<void> planifierRappel({
    required Versement versement,
    required Moto moto,
    required int delaiHeures,
  }) async {
    for (final r in _rappelsDe(versement, moto, delaiHeures)) {
      await _programmer(r);
    }
  }

  /// Les rappels a venir d'une echeance (deja passes : aucun). Seule
  /// definition de leur texte et de leur heure.
  static List<({int id, String titre, String texte, DateTime quand, String payload})> _rappelsDe(
      Versement versement, Moto moto, int delaiHeures) {
    if (versement.id == null) return const [];
    final d = versement.dateEcheance;
    final montant = formaterNombre(ScheduleService.resteDu(versement)); // ce qui reste a payer
    final maintenant = DateTime.now();
    return [
      (
        id: versement.id!, // id unique = id du versement, permet d'annuler facilement
        titre: 'Versement a venir - ${moto.nom}',
        texte: 'Echeance de $montant prevue le ${formaterDate(d)}',
        quand: d.subtract(Duration(hours: delaiHeures)),
        payload: _payload(moto),
      ),
      (
        id: versement.id! + _decalageAlerteRetard,
        titre: 'Versement non recu - ${moto.nom}',
        texte: '${moto.chauffeur} n\'a pas encore paye l\'echeance du ${formaterDate(d)} ($montant). '
            'Pensez a relancer.',
        quand: DateTime(d.year, d.month, d.day + 1, 9),
        payload: _payload(moto),
      ),
    ].where((r) => !r.quand.isBefore(maintenant)).toList();
  }

  static Future<void> _programmer(({int id, String titre, String texte, DateTime quand, String payload}) r) async {
    final (:id, :titre, :texte, :quand, :payload) = r;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'rappels_versements',
        'Rappels de versement',
        channelDescription: 'Notifications de rappel des echeances de versement',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.zonedSchedule(
      id,
      titre,
      texte,
      tz.TZDateTime.from(quand, tz.local),
      details,
      // Mode inexact : ne necessite pas la permission "alarmes exactes"
      // (refusee par defaut sur Android 12+). Un rappel peut arriver avec
      // quelques minutes de decalage, ce qui est sans consequence ici.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  static Future<void> annulerRappel(int versementId) async {
    await _plugin.cancel(versementId);
    await _plugin.cancel(versementId + _decalageAlerteRetard);
  }

  /// Rappels actuellement programmes sur le telephone (une seule lecture,
  /// partagee par toutes les motos d'un chargement d'ecran).
  static Future<List<PendingNotificationRequest>> rappelsEnAttente() async {
    try {
      return await _plugin.pendingNotificationRequests();
    } catch (_) {
      return const [];
    }
  }

  /// Met les rappels d'une moto en accord avec ses echeances, en ne touchant
  /// QU'A ce qui a change : chaque appel au systeme de notifications est
  /// lent, tout annuler / reprogrammer a chaque ecran ralentissait l'app.
  /// Seule une echeance avec un reste a payer (hors dette, moto active) a des
  /// rappels : une semaine payee - meme par de l'argent deplace vers elle -,
  /// en dette, ou supprimee (doublon, avance regroupee) n'en a plus.
  static Future<void> synchroniserRappelsMoto({
    required Moto moto,
    required List<Versement> versements,
    required int delaiHeures,
    List<PendingNotificationRequest>? enAttente,
  }) async {
    final attendus = {
      if (moto.statut == AppConstants.motoActive)
        for (final v in versements)
          if (v.statut != AppConstants.versementEnDette && ScheduleService.resteDu(v) > 0)
            for (final r in _rappelsDe(v, moto, delaiHeures)) r.id: r,
    };
    // Rappels de cette moto deja programmes (anciens sans payload : par id).
    final idsEcheances = {for (final v in versements) if (v.id != null) v.id!};
    for (final p in enAttente ?? await rappelsEnAttente()) {
      final echeance = p.id >= _decalageAlerteRetard ? p.id - _decalageAlerteRetard : p.id;
      if (p.payload != _payload(moto) && !idsEcheances.contains(echeance)) continue;
      final attendu = attendus[p.id];
      if (attendu == null) {
        await _plugin.cancel(p.id); // plus rien a rappeler pour cette echeance
      } else if (attendu.titre == p.title && attendu.texte == p.body) {
        attendus.remove(p.id); // deja programme tel quel
      }
    }
    for (final r in attendus.values) {
      await _programmer(r); // nouveau, ou texte change (reste du) : remplace
    }
  }

  /// Rattache chaque rappel a sa moto (pour retrouver ceux d'echeances supprimees).
  static String _payload(Moto moto) => 'moto:${moto.id}';

  /// Complète les échéances d'une moto active (fenêtre glissante) et
  /// resynchronise ses rappels — à chaque fois : un paiement, une dette ou
  /// une normalisation (argent déplacé vers une semaine plus ancienne) change
  /// les échéances à rappeler, pas seulement leur création.
  /// [enAttente] / [delaiHeures] : lus une fois par l'ecran qui traite
  /// plusieurs motos (accueil), sinon lus ici.
  static Future<void> assurerEcheancesEtRappels(Moto moto,
      {List<PendingNotificationRequest>? enAttente, int? delaiHeures}) async {
    final db = DatabaseService.instance;
    if (moto.id == null) return;
    final versements = await db.assurerEcheancesEtLister(moto);
    // Le rappel est secondaire : un echec du plugin de notifications ne
    // doit pas bloquer le chargement des ecrans qui appellent ceci.
    try {
      await synchroniserRappelsMoto(
        moto: moto,
        versements: versements,
        delaiHeures: delaiHeures ?? (await db.obtenirParametres()).delaiNotificationHeures,
        enAttente: enAttente,
      );
    } catch (_) {}
  }

  /// Reprogramme tous les rappels en attente — utile après un changement
  /// de délai de notification dans les Réglages. Les motos suspendues ou
  /// archivées (hors service) sont ignorées : elles ne doivent plus
  /// notifier tant qu'elles ne sont pas réactivées.
  static Future<void> reprogrammerTousLesRappels() async {
    await _plugin.cancelAll();
    final params = await DatabaseService.instance.obtenirParametres();
    final motos = await DatabaseService.instance.listerMotos(statut: AppConstants.motoActive);
    for (final moto in motos) {
      if (moto.id == null) continue;
      final versements = await DatabaseService.instance.listerVersementsParMoto(moto.id!);
      // Meme regle que synchroniserRappelsMoto (pas d'annulation : cancelAll ci-dessus).
      await synchroniserRappelsMoto(
          moto: moto, versements: versements, delaiHeures: params.delaiNotificationHeures, enAttente: const []);
    }
  }
}
