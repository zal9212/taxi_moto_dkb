import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/theme.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'screens/lock_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR', null);
  await NotificationService.initialiser();
  // Recalcule les retards dès l'ouverture de l'app
  await DatabaseService.instance.actualiserRetards();
  runApp(const MotoTaxiApp());
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
