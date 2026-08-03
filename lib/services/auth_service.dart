import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';

import 'database_service.dart';

/// Gère la protection d'accès à l'application : code PIN (stocké haché)
/// et déverrouillage biométrique (empreinte / Face ID) via local_auth.
/// Le PIN reste toujours disponible comme méthode de secours.
class AuthService {
  AuthService._();
  static final LocalAuthentication _localAuth = LocalAuthentication();

  static String _hacherPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  /// Vrai si un PIN a déjà été configuré.
  static Future<bool> pinConfigure() async {
    final params = await DatabaseService.instance.obtenirParametres();
    return params.pinCodeHash != null && params.pinCodeHash!.isNotEmpty;
  }

  static Future<void> definirPin(String pin) async {
    final params = await DatabaseService.instance.obtenirParametres();
    await DatabaseService.instance.enregistrerParametres(
      params.copyWith(pinCodeHash: _hacherPin(pin)),
    );
  }

  static Future<bool> verifierPin(String pin) async {
    final params = await DatabaseService.instance.obtenirParametres();
    if (params.pinCodeHash == null) return false;
    return params.pinCodeHash == _hacherPin(pin);
  }

  static Future<void> supprimerPin() async {
    final params = await DatabaseService.instance.obtenirParametres();
    await DatabaseService.instance.enregistrerParametres(
      params.copyWith(pinCodeHash: ''),
    );
  }

  /// Vérifie si l'appareil supporte la biométrie (matériel + capteurs enregistrés).
  static Future<bool> biometrieDisponible() async {
    try {
      final supporte = await _localAuth.isDeviceSupported();
      final peutVerifier = await _localAuth.canCheckBiometrics;
      return supporte && peutVerifier;
    } catch (_) {
      return false;
    }
  }

  static Future<void> activerBiometrie(bool actif) async {
    final params = await DatabaseService.instance.obtenirParametres();
    await DatabaseService.instance.enregistrerParametres(
      params.copyWith(biometrieActive: actif),
    );
  }

  /// Lance la demande de déverrouillage biométrique natif (empreinte / Face ID).
  static Future<bool> authentifierParBiometrie() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Deverrouillez pour acceder a vos motos',
        options: const AuthenticationOptions(
          biometricOnly: false, // autorise le fallback PIN/schéma natif du téléphone
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
