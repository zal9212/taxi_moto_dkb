import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;

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

  /// Programme un rappel pour un versement donné, `delaiHeures` avant
  /// la date d'échéance.
  static Future<void> planifierRappel({
    required Versement versement,
    required Moto moto,
    required int delaiHeures,
  }) async {
    if (versement.id == null) return;

    final dateRappel =
        versement.dateEcheance.subtract(Duration(hours: delaiHeures));
    if (dateRappel.isBefore(DateTime.now())) return; // déjà passé, on ignore

    const androidDetails = AndroidNotificationDetails(
      'rappels_versements',
      'Rappels de versement',
      channelDescription: 'Notifications de rappel des echeances de versement',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      versement.id!, // id unique = id du versement, permet d'annuler facilement
      'Versement a venir - ${moto.nom}',
      'Echeance de ${versement.montantPrevu.toStringAsFixed(0)} prevue le '
          '${_formaterDate(versement.dateEcheance)}',
      tz.TZDateTime.from(dateRappel, tz.local),
      details,
      // Mode inexact : ne necessite pas la permission "alarmes exactes"
      // (refusee par defaut sur Android 12+). Un rappel peut arriver avec
      // quelques minutes de decalage, ce qui est sans consequence ici.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> annulerRappel(int versementId) async {
    await _plugin.cancel(versementId);
  }

  /// Reprogramme tous les rappels en attente — utile après un changement
  /// de délai de notification dans les Réglages.
  static Future<void> reprogrammerTousLesRappels() async {
    await _plugin.cancelAll();
    final params = await DatabaseService.instance.obtenirParametres();
    final motos = await DatabaseService.instance.listerMotos();
    for (final moto in motos) {
      if (moto.id == null) continue;
      final versements = await DatabaseService.instance.listerVersementsParMoto(moto.id!);
      for (final v in versements) {
        if (v.statut != 'paye') {
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
