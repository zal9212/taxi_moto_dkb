import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'database_service.dart';

/// Gère la protection d'accès à l'application : code PIN et déverrouillage
/// biométrique (empreinte / Face ID) via local_auth. Le PIN reste toujours
/// disponible comme méthode de secours.
///
/// Stockage : le hash du PIN (sel + hachage étiré) est conservé dans le
/// stockage sécurisé du système (Android Keystore / iOS Keychain, via
/// flutter_secure_storage) — jamais dans la base SQLite normale, qui peut
/// être extraite plus facilement (sauvegarde, débogage USB...).
///
/// Anti-brute-force : après plusieurs codes erronés, l'app impose un délai
/// croissant avant de pouvoir retenter (voir [secondesAvantDeblocage]).
class AuthService {
  AuthService._();
  static final LocalAuthentication _localAuth = LocalAuthentication();
  static const _storage = FlutterSecureStorage();

  static const _clePinHash = 'pin_hash';
  static const _cleSel = 'pin_salt';
  static const _cleEchecs = 'pin_echecs';
  static const _cleVerrouJusqua = 'pin_verrou_jusqua';

  static const int _iterations = 20000;
  static const int _seuilEchecs = 5;
  static const Duration _delaiVerrouBase = Duration(seconds: 30);

  static String _genererSel() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Hachage étiré (sel + N rounds de SHA-256) pour ralentir une éventuelle
  /// attaque hors-ligne sur un hash extrait.
  static String _hacher(String pin, String sel) {
    List<int> resultat = utf8.encode('$sel:$pin');
    for (var i = 0; i < _iterations; i++) {
      resultat = sha256.convert(resultat).bytes;
    }
    return base64Url.encode(resultat);
  }

  /// Vrai si un PIN a déjà été configuré.
  static Future<bool> pinConfigure() async {
    final hash = await _storage.read(key: _clePinHash);
    return hash != null && hash.isNotEmpty;
  }

  static Future<void> definirPin(String pin) async {
    final sel = _genererSel();
    final hash = _hacher(pin, sel);
    await _storage.write(key: _cleSel, value: sel);
    await _storage.write(key: _clePinHash, value: hash);
    await _reinitialiserEchecs();
  }

  /// Secondes restantes avant de pouvoir retenter un code (0 = pas de
  /// verrouillage actif). Le délai augmente à chaque nouvel échec au-delà
  /// du seuil, ce qui rend un brute-force automatisé du code impraticable.
  static Future<int> secondesAvantDeblocage() async {
    final valeur = await _storage.read(key: _cleVerrouJusqua);
    if (valeur == null) return 0;
    final jusqua = DateTime.tryParse(valeur);
    if (jusqua == null) return 0;
    final restant = jusqua.difference(DateTime.now()).inSeconds;
    return restant > 0 ? restant : 0;
  }

  static Future<bool> verifierPin(String pin) async {
    if (await secondesAvantDeblocage() > 0) return false;

    final sel = await _storage.read(key: _cleSel);
    final hash = await _storage.read(key: _clePinHash);
    if (sel == null || hash == null) return false;

    final correct = _hacher(pin, sel) == hash;
    if (correct) {
      await _reinitialiserEchecs();
    } else {
      await _enregistrerEchec();
    }
    return correct;
  }

  static Future<void> _reinitialiserEchecs() async {
    await _storage.delete(key: _cleEchecs);
    await _storage.delete(key: _cleVerrouJusqua);
  }

  static Future<void> _enregistrerEchec() async {
    final actuel = int.tryParse(await _storage.read(key: _cleEchecs) ?? '0') ?? 0;
    final nouveau = actuel + 1;
    await _storage.write(key: _cleEchecs, value: nouveau.toString());
    if (nouveau >= _seuilEchecs) {
      final multiplicateur = 1 << (nouveau - _seuilEchecs); // 1, 2, 4, 8...
      final jusqua = DateTime.now().add(_delaiVerrouBase * multiplicateur);
      await _storage.write(key: _cleVerrouJusqua, value: jusqua.toIso8601String());
    }
  }

  static Future<void> supprimerPin() async {
    await _storage.delete(key: _clePinHash);
    await _storage.delete(key: _cleSel);
    await _reinitialiserEchecs();
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

  /// Le flag d'activation (booleen non sensible) reste en base normale ;
  /// seul le PIN lui-même (secret) vit dans le stockage sécurisé ci-dessus.
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
