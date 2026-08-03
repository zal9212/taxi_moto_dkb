import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import 'home_screen.dart';
import 'setup_pin_screen.dart';

/// Écran affiché au démarrage : tente d'abord la biométrie si activée,
/// sinon (ou en secours) propose la saisie du code PIN.
/// Si aucun PIN n'a encore été configuré, l'app passe directement à
/// l'accueil (protection optionnelle, activable depuis les Réglages).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final List<String> _saisie = [];
  bool _erreur = false;
  bool _verificationEnCours = true;
  bool _pinExiste = false;
  bool _biometrieActive = false;

  @override
  void initState() {
    super.initState();
    _initialiser();
  }

  Future<void> _initialiser() async {
    final pinConfigure = await AuthService.pinConfigure();
    final params = await DatabaseService.instance.obtenirParametres();

    if (!pinConfigure) {
      _allerVersAccueil();
      return;
    }

    setState(() {
      _pinExiste = true;
      _biometrieActive = params.biometrieActive;
      _verificationEnCours = false;
    });

    if (_biometrieActive) {
      _tenterBiometrie();
    }
  }

  Future<void> _tenterBiometrie() async {
    final disponible = await AuthService.biometrieDisponible();
    if (!disponible) return;
    final succes = await AuthService.authentifierParBiometrie();
    if (succes) _allerVersAccueil();
  }

  void _allerVersAccueil() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  Future<void> _ajouterChiffre(String chiffre) async {
    if (_saisie.length >= 4) return;
    setState(() {
      _saisie.add(chiffre);
      _erreur = false;
    });
    if (_saisie.length == 4) {
      final ok = await AuthService.verifierPin(_saisie.join());
      if (ok) {
        _allerVersAccueil();
      } else {
        setState(() => _erreur = true);
        await Future.delayed(const Duration(milliseconds: 400));
        setState(() => _saisie.clear());
      }
    }
  }

  void _effacer() {
    if (_saisie.isEmpty) return;
    setState(() => _saisie.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    if (_verificationEnCours) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_pinExiste) {
      // Sécurité non configurée : proposer la configuration au premier lancement
      return SetupPinScreen(onTermine: _allerVersAccueil);
    }

    return Scaffold(
      backgroundColor: AppColors.carteNoire,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const Icon(Icons.motorcycle, color: AppColors.accentLime, size: 48),
              const SizedBox(height: 16),
              const Text('Moto Taxi Douka',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                _erreur ? 'Code incorrect, reessayez' : 'Entrez votre code',
                style: TextStyle(
                  color: _erreur ? AppColors.danger : AppColors.texteGris,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final rempli = i < _saisie.length;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: rempli ? AppColors.accentLime : Colors.transparent,
                      border: Border.all(color: AppColors.accentLime, width: 1.4),
                    ),
                  );
                }),
              ),
              const Spacer(),
              if (_biometrieActive)
                TextButton.icon(
                  onPressed: _tenterBiometrie,
                  icon: const Icon(Icons.fingerprint, color: AppColors.accentLime),
                  label: const Text('Utiliser empreinte / Face ID',
                      style: TextStyle(color: AppColors.accentLime)),
                ),
              const SizedBox(height: 12),
              _clavierNumerique(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _clavierNumerique() {
    final touches = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', '<'];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.6,
      children: touches.map((t) {
        if (t.isEmpty) return const SizedBox.shrink();
        return TextButton(
          onPressed: () => t == '<' ? _effacer() : _ajouterChiffre(t),
          child: t == '<'
              ? const Icon(Icons.backspace_outlined, color: Colors.white, size: 20)
              : Text(t, style: const TextStyle(color: Colors.white, fontSize: 22)),
        );
      }).toList(),
    );
  }
}
