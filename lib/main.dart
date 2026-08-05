import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/theme.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'screens/lock_screen.dart';

/// Duree minimale d'affichage de l'ecran de demarrage, meme si
/// l'initialisation est plus rapide que cela.
const _dureeMinSplash = Duration(milliseconds: 400);

void main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  final debut = DateTime.now();
  await initializeDateFormatting('fr_FR', null);
  await NotificationService.initialiser();
  // Recalcule les retards dès l'ouverture de l'app
  await DatabaseService.instance.actualiserRetards();

  final restant = _dureeMinSplash - DateTime.now().difference(debut);
  if (restant > Duration.zero) {
    await Future.delayed(restant);
  }

  runApp(const MotoTaxiApp());
  FlutterNativeSplash.remove();
}

class MotoTaxiApp extends StatelessWidget {
  const MotoTaxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moto Taxi Douka',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const LockScreen(),
    );
  }
}
