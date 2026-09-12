# Moto Taxi Douka — Gestion des versements

Application Flutter locale (SQLite) pour suivre les versements de motos-taxis,
leur historique complet, et les dépenses associées (huile, réparations...).

## 1. Installation

Ce zip contient uniquement le code source Dart (`lib/`) et `pubspec.yaml`.
Les dossiers natifs `android/` et `ios/` ne sont **pas inclus** — Flutter les
génère automatiquement. Étapes :

```bash
# 1. Dézippez, puis dans le dossier du projet :
flutter create . --project-name moto_taxi_douka --org com.doukabusiness

# Attention : cette commande génère android/ ios/ etc. mais ne touche pas
# à votre dossier lib/ existant. Si un fichier lib/main.dart par défaut
# est créé, remplacez-le par celui fourni dans ce zip (déjà le cas normalement).

# 2. Installer les dépendances
flutter pub get

# 3. Lancer l'application
flutter run
```

## 2. Configuration native obligatoire

### Android (`android/app/src/main/AndroidManifest.xml`)

Ajoutez ces permissions au-dessus de la balise `<application>` :

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

Dans `android/app/src/main/kotlin/.../MainActivity.kt`, la biométrie
(`local_auth`) nécessite que l'activité étende `FlutterFragmentActivity`
au lieu de `FlutterActivity` :

```kotlin
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity: FlutterFragmentActivity()
```

Vérifiez aussi que `minSdkVersion` est au moins `23` dans
`android/app/build.gradle`.

### iOS (`ios/Runner/Info.plist`)

Ajoutez la clé suivante (texte affiché lors de la demande Face ID) :

```xml
<key>NSFaceIDUsageDescription</key>
<string>Utilisé pour déverrouiller l'application rapidement</string>
```

### Signature Android release (important, a faire une seule fois)

Sans cle de signature stable, chaque APK release est signe avec une cle
debug generee au hasard sur la machine qui build (y compris a chaque run
GitHub Actions). Android refuse alors d'installer une "mise a jour" signee
differemment de l'app deja installee : il faut desinstaller l'ancienne
version avant, ce qui efface toutes les donnees locales.

Pour eviter ca, genere une cle **une seule fois** et reutilise-la pour
toujours :

```bash
keytool -genkeypair -v -keystore android/app/upload-keystore.jks \
  -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 \
  -alias douka_moto_upload
```

Puis copie `android/key.properties.example` en `android/key.properties` et
renseigne les mots de passe choisis a la generation (ce fichier est ignore
par git, ne le commite jamais). Pour que le build GitHub Actions signe lui
aussi avec cette meme cle, ajoute 4 secrets dans Settings > Secrets and
variables > Actions du repo : `KEYSTORE_BASE64` (le fichier `.jks` encode en
base64), `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD`.

**Sauvegarde ce fichier `.jks` et ses mots de passe ailleurs que dans ce
depot** (gestionnaire de mots de passe, stockage cloud personnel...) : les
perdre signifie ne plus jamais pouvoir publier de mise a jour sous la meme
identite d'app.

A partir de la mise en place de cette cle, une seule desinstallation
manuelle sera encore necessaire (le temps de passer d'une ancienne signature
debug a celle-ci) ; toutes les installations suivantes se feront ensuite
comme des mises a jour normales, sans perte de donnees.

Le numero de build (le `+N` a la fin de `version:` dans `pubspec.yaml`) doit
lui aussi strictement augmenter a chaque publication, sinon Android refuse la
mise a jour meme avec la bonne signature. C'est automatise : le workflow
GitHub Actions (`.github/workflows/build-apk.yml`) le remplace a chaque build
par le numero de run GitHub (`--build-number=${{ github.run_number }}`), qui
augmente tout seul — rien a modifier a la main dans `pubspec.yaml` pour ça.
Le nom de version (`1.0.1` avant le `+`) reste sous ton controle, a changer
seulement quand tu veux marquer une vraie nouvelle version.

## 3. Structure du projet

```
lib/
  core/              constantes globales + thème visuel
  models/            Moto, Versement, Depense, CategorieDepense, Parametre
  services/
    database_service.dart     tout l'accès SQLite (CRUD complet)
    schedule_service.dart     génère le calendrier des échéances
    auth_service.dart         PIN + biométrie (empreinte / Face ID)
    notification_service.dart rappels locaux avant chaque échéance
    pdf_service.dart          génération et partage des relevés PDF
  screens/           tous les écrans de l'app
  widgets/           composants réutilisables (cartes, lignes d'activité)
  utils/             formatage montants / dates
```

## 4. Fonctionnalités incluses

- Gestion illimitée de motos, chacune avec sa propre fréquence de versement
  (hebdomadaire à jour configurable, mensuelle à jour configurable, ou
  intervalle personnalisé en jours) — rien n'est figé en dur.
- Génération automatique du calendrier de versements à la création d'une moto.
- Validation d'un versement en un clic, avec montant modifiable
  (paiement partiel ou différent du montant prévu).
- Passage automatique au statut "en retard" pour les échéances dépassées.
- Notifications locales de rappel avant chaque échéance (délai configurable).
- Suivi des dépenses (huile, réparation, carburant, assurance, autre —
  catégories entièrement personnalisables).
- Accueil avec total encaissé, filtres par moto/mois/année, et activité
  récente (versements + dépenses mélangés, triés par date).
- Export PDF du relevé complet d'une moto (versements + dépenses + solde),
  partageable directement depuis le téléphone.
- Protection d'accès par code PIN et/ou empreinte digitale / Face ID.
- Devise, délai de notification, et toutes les catégories sont modifiables
  depuis les Réglages sans jamais toucher au code.

## 5. Base de données

SQLite local (fichier créé automatiquement au premier lancement), 5 tables :
`motos`, `versements`, `depenses`, `categories_depenses`, `parametres`.
Le détail du schéma est commenté dans `database_service.dart`.

Les données restent uniquement sur l'appareil — aucune synchronisation
serveur n'est incluse dans cette version.
