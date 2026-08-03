import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';

/// Configuration initiale du code PIN (obligatoire une fois) puis
/// proposition d'activer la biométrie si le téléphone la supporte.
class SetupPinScreen extends StatefulWidget {
  final VoidCallback onTermine;
  const SetupPinScreen({super.key, required this.onTermine});

  @override
  State<SetupPinScreen> createState() => _SetupPinScreenState();
}

class _SetupPinScreenState extends State<SetupPinScreen> {
  final List<String> _premierPin = [];
  final List<String> _confirmation = [];
  bool _etapeConfirmation = false;
  bool _erreur = false;

  Future<void> _ajouterChiffre(String chiffre) async {
    final liste = _etapeConfirmation ? _confirmation : _premierPin;
    if (liste.length >= 4) return;
    setState(() {
      liste.add(chiffre);
      _erreur = false;
    });

    if (liste.length == 4) {
      if (!_etapeConfirmation) {
        setState(() => _etapeConfirmation = true);
      } else {
        if (_premierPin.join() == _confirmation.join()) {
          await AuthService.definirPin(_premierPin.join());
          _proposerBiometrie();
        } else {
          setState(() {
            _erreur = true;
            _confirmation.clear();
          });
        }
      }
    }
  }

  void _effacer() {
    final liste = _etapeConfirmation ? _confirmation : _premierPin;
    if (liste.isEmpty) return;
    setState(() => liste.removeLast());
  }

  Future<void> _proposerBiometrie() async {
    final disponible = await AuthService.biometrieDisponible();
    if (!mounted) return;
    if (!disponible) {
      widget.onTermine();
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Empreinte / Face ID'),
        content: const Text(
            'Voulez-vous activer le deverrouillage par empreinte ou Face ID en plus du code PIN ?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onTermine();
            },
            child: const Text('Non merci'),
          ),
          ElevatedButton(
            onPressed: () async {
              await AuthService.activerBiometrie(true);
              if (context.mounted) Navigator.pop(context);
              widget.onTermine();
            },
            child: const Text('Activer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saisie = _etapeConfirmation ? _confirmation : _premierPin;

    return Scaffold(
      backgroundColor: AppColors.carteNoire,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const Icon(Icons.lock_outline, color: AppColors.accentLime, size: 40),
              const SizedBox(height: 16),
              Text(
                _etapeConfirmation ? 'Confirmez votre code' : 'Creez un code PIN',
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                _erreur ? 'Les codes ne correspondent pas' : 'Pour proteger l\'acces a l\'application',
                style: TextStyle(color: _erreur ? AppColors.danger : AppColors.texteGris, fontSize: 13),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final rempli = i < saisie.length;
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
