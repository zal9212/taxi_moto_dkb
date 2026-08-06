import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/theme.dart';
import 'services/auth_service.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'screens/lock_screen.dart';

/// Cle globale de navigation : permet de reverrouiller l'app depuis
/// [_MotoTaxiAppState.didChangeAppLifecycleState], en dehors du contexte
/// d'un ecran precis.
final navigatorKey = GlobalKey<NavigatorState>();

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

/// Reverrouille automatiquement l'app (comme une app bancaire) des qu'elle
/// revient au premier plan apres avoir ete mise en arriere-plan — pas
/// juste apres une boite de dialogue ou un partage/selecteur de fichier,
/// qui ne declenchent que l'etat "inactive", jamais "paused".
class MotoTaxiApp extends StatefulWidget {
  const MotoTaxiApp({super.key});

  @override
  State<MotoTaxiApp> createState() => _MotoTaxiAppState();
}

class _MotoTaxiAppState extends State<MotoTaxiApp> with WidgetsBindingObserver {
  bool _etaitEnArrierePlan = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      _etaitEnArrierePlan = true;
      return;
    }
    if (state == AppLifecycleState.resumed && _etaitEnArrierePlan) {
      _etaitEnArrierePlan = false;
      if (await AuthService.pinConfigure()) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const LockScreen(estReverrouillage: true)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Douka Moto',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const LockScreen(),
    );
  }
}
