import '../core/constants.dart';

/// Réglages globaux de l'application. Une seule ligne en base (id fixe = 1).
/// Rien n'est figé en dur dans le code : la devise, le délai de rappel,
/// et l'activation biométrie se modifient depuis l'écran Réglages.
class Parametre {
  final int id;
  final String? pinCodeHash;
  final bool biometrieActive;
  final String deviseSymbole;
  final int delaiNotificationHeures;

  Parametre({
    this.id = 1,
    this.pinCodeHash,
    this.biometrieActive = AppConstants.biometrieActiveParDefaut,
    this.deviseSymbole = AppConstants.devisePardDefaut,
    this.delaiNotificationHeures = AppConstants.delaiNotificationHeuresParDefaut,
  });

  Parametre copyWith({
    String? pinCodeHash,
    bool? biometrieActive,
    String? deviseSymbole,
    int? delaiNotificationHeures,
  }) {
    return Parametre(
      id: id,
      pinCodeHash: pinCodeHash ?? this.pinCodeHash,
      biometrieActive: biometrieActive ?? this.biometrieActive,
      deviseSymbole: deviseSymbole ?? this.deviseSymbole,
      delaiNotificationHeures: delaiNotificationHeures ?? this.delaiNotificationHeures,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'pin_code_hash': pinCodeHash,
      'biometrie_active': biometrieActive ? 1 : 0,
      'devise_symbole': deviseSymbole,
      'delai_notification_heures': delaiNotificationHeures,
    };
  }

  factory Parametre.fromMap(Map<String, dynamic> map) {
    return Parametre(
      id: map['id'] as int,
      pinCodeHash: map['pin_code_hash'] as String?,
      biometrieActive: (map['biometrie_active'] as int) == 1,
      deviseSymbole: map['devise_symbole'] as String,
      delaiNotificationHeures: map['delai_notification_heures'] as int,
    );
  }
}
