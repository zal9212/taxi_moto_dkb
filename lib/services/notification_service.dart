import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;

import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import 'database_service.dart';

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
    if (versement.id == null) return;
    final d = versement.dateEcheance;
    final montant = versement.montantPrevu.toStringAsFixed(0);

    await _programmer(
      versement.id!, // id unique = id du versement, permet d'annuler facilement
      'Versement a venir - ${moto.nom}',
      'Echeance de $montant prevue le ${_formaterDate(d)}',
      d.subtract(Duration(hours: delaiHeures)),
    );
    await _programmer(
      versement.id! + _decalageAlerteRetard,
      'Versement non recu - ${moto.nom}',
      '${moto.chauffeur} n\'a pas encore paye l\'echeance du ${_formaterDate(d)} ($montant). '
          'Pensez a relancer.',
      DateTime(d.year, d.month, d.day + 1, 9),
    );
  }

  static Future<void> _programmer(int id, String titre, String texte, DateTime quand) async {
    if (quand.isBefore(DateTime.now())) return; // déjà passé, on ignore
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
    );
  }

  static Future<void> annulerRappel(int versementId) async {
    await _plugin.cancel(versementId);
    await _plugin.cancel(versementId + _decalageAlerteRetard);
  }

  /// Synchronise les rappels d'une moto avec son statut actuel : programme
  /// les rappels de ses echeances non payees si elle est active, les
  /// annule sinon (suspendue/archivee = hors service, ne doit plus
  /// notifier tant qu'elle n'est pas reactivee).
  static Future<void> synchroniserRappelsMoto({
    required Moto moto,
    required List<Versement> versements,
    required int delaiHeures,
  }) async {
    // Une echeance passee en dette se suit dans Dettes : plus de rappel.
    final nonPayes = versements.where(
        (v) => v.statut != AppConstants.versementPaye && v.statut != AppConstants.versementEnDette);

    if (moto.statut != AppConstants.motoActive) {
      for (final v in nonPayes) {
        if (v.id != null) await annulerRappel(v.id!);
      }
      return;
    }

    for (final v in nonPayes) {
      await planifierRappel(versement: v, moto: moto, delaiHeures: delaiHeures);
    }
  }

  /// Complète les échéances d'une moto active (fenêtre glissante) et
  /// programme les rappels de celles qui viennent d'être créées — sans ça,
  /// les rappels s'arrêtaient après les premières échéances de la moto.
  static Future<void> assurerEcheancesEtRappels(Moto moto) async {
    final db = DatabaseService.instance;
    if (moto.id == null || await db.assurerEcheances(moto) == 0) return;
    // Le rappel est secondaire : un echec du plugin de notifications ne
    // doit pas bloquer le chargement des ecrans qui appellent ceci.
    try {
      final params = await db.obtenirParametres();
      await synchroniserRappelsMoto(
        moto: moto,
        versements: await db.listerVersementsParMoto(moto.id!),
        delaiHeures: params.delaiNotificationHeures,
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
      for (final v in versements) {
        if (v.statut != AppConstants.versementPaye && v.statut != AppConstants.versementEnDette) {
          await planifierRappel(
            versement: v,
            moto: moto,
            delaiHeures: params.delaiNotificationHeures,
          );
        }
      }
    }
  }

  static String _formaterDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
