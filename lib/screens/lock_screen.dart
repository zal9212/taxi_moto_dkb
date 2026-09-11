import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import 'categorie/categorie_home_screen.dart';
import 'home_screen.dart';
import 'setup_pin_screen.dart';

/// Écran affiché au démarrage : tente d'abord la biométrie si activée,
/// sinon (ou en secours) propose la saisie du code PIN.
/// Si aucun PIN n'a encore été configuré, l'app passe directement à
/// l'accueil (protection optionnelle, activable depuis les Réglages).
class LockScreen extends StatefulWidget {
  /// true quand cet ecran est affiche par-dessus l'app (deja lancee) pour
  /// la reverrouiller au retour au premier plan : un deverrouillage reussi
  /// doit alors simplement reveler l'ecran precedent (pop), pas repartir
  /// sur un nouvel accueil.
  final bool estReverrouillage;

  const LockScreen({super.key, this.estReverrouillage = false});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final List<String> _saisie = [];
  bool _erreur = false;
  bool _verificationEnCours = true;
  bool _pinExiste = false;
  bool _biometrieActive = false;
  int? _categorieActiveId;

  int _secondesVerrou = 0;
  Timer? _minuteur;

  @override
  void initState() {
    super.initState();
    _initialiser();
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    super.dispose();
  }

  Future<void> _initialiser() async {
    final pinConfigure = await AuthService.pinConfigure();
    final params = await DatabaseService.instance.obtenirParametres();
    _categorieActiveId = params.categorieActiveId;

    if (!pinConfigure) {
      _allerVersAccueil();
      return;
    }

    final secondesVerrou = await AuthService.secondesAvantDeblocage();

    setState(() {
      _pinExiste = true;
      _biometrieActive = params.biometrieActive;
      _verificationEnCours = false;
      _secondesVerrou = secondesVerrou;
    });

    if (secondesVerrou > 0) {
      _demarrerCompteARebours();
    } else if (_biometrieActive) {
      _tenterBiometrie();
    }
  }

  void _demarrerCompteARebours() {
    _minuteur?.cancel();
    _minuteur = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final restant = await AuthService.secondesAvantDeblocage();
      if (!mounted) return;
      setState(() => _secondesVerrou = restant);
      if (restant <= 0) timer.cancel();
    });
  }

  Future<void> _tenterBiometrie() async {
    if (_secondesVerrou > 0) return;
    final disponible = await AuthService.biometrieDisponible();
    if (!disponible) return;
    final succes = await AuthService.authentifierParBiometrie();
    if (succes) _allerVersAccueil();
  }

  void _allerVersAccueil() {
    if (!mounted) return;
    if (widget.estReverrouillage) {
      Navigator.of(context).pop();
      return;
    }
    final categorieId = _categorieActiveId;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            categorieId != null ? CategorieHomeScreen(categorieId: categorieId) : const HomeScreen(),
      ),
    );
  }

  Future<void> _ajouterChiffre(String chiffre) async {
    if (_secondesVerrou > 0 || _saisie.length >= 4) return;
    setState(() {
      _saisie.add(chiffre);
      _erreur = false;
    });
    if (_saisie.length == 4) {
      final ok = await AuthService.verifierPin(_saisie.join());
      if (ok) {
        _allerVersAccueil();
        return;
      }

      final secondesVerrou = await AuthService.secondesAvantDeblocage();
      if (!mounted) return;
      setState(() {
        _erreur = true;
        _secondesVerrou = secondesVerrou;
      });
      if (secondesVerrou > 0) _demarrerCompteARebours();
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      setState(() => _saisie.clear());
    }
  }

  void _effacer() {
    if (_secondesVerrou > 0 || _saisie.isEmpty) return;
    setState(() => _saisie.removeLast());
  }

  String _libelleMessage() {
    if (_secondesVerrou > 0) {
      final minutes = _secondesVerrou ~/ 60;
      final secondes = _secondesVerrou % 60;
      final duree = minutes > 0 ? '${minutes}min ${secondes}s' : '${secondes}s';
      return 'Trop de tentatives. Reessayez dans $duree';
    }
    return _erreur ? 'Code incorrect, reessayez' : 'Entrez votre code';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Reverrouillage : le bouton/geste retour ne doit pas permettre de
      // contourner l'ecran et reveler l'app sans authentification.
      canPop: !widget.estReverrouillage,
      child: _construireContenu(context),
    );
  }

  Widget _construireContenu(BuildContext context) {
    if (_verificationEnCours) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_pinExiste) {
      // Sécurité non configurée : proposer la configuration au premier lancement
      return SetupPinScreen(onTermine: _allerVersAccueil);
    }

    final verrouille = _secondesVerrou > 0;

    return Scaffold(
      backgroundColor: AppColors.carteNoire,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      const Spacer(),
                      Icon(
                        verrouille ? Icons.lock_clock_outlined : Icons.motorcycle,
                        color: AppColors.accentLime,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      const Text('Douka Moto',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          _libelleMessage(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: (_erreur || verrouille) ? AppColors.danger : AppColors.texteGris,
                            fontSize: 13,
                          ),
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
                      if (_biometrieActive && !verrouille)
                        TextButton.icon(
                          onPressed: _tenterBiometrie,
                          icon: const Icon(Icons.fingerprint, color: AppColors.accentLime),
                          label: const Text('Utiliser empreinte / Face ID',
                              style: TextStyle(color: AppColors.accentLime)),
                        ),
                      const SizedBox(height: 12),
                      Opacity(
                        opacity: verrouille ? 0.3 : 1,
                        child: IgnorePointer(ignoring: verrouille, child: _clavierNumerique()),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            );
          },
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
