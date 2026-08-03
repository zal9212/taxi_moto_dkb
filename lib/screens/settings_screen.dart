import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/depense.dart';
import '../models/parametre.dart';
import '../models/versement.dart';
import '../services/database_service.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/pdf_service.dart';
import 'stats_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _db = DatabaseService.instance;
  Parametre? _parametres;
  bool _biometrieDisponible = false;
  bool _generationRapportEnCours = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final p = await _db.obtenirParametres();
    final bioDispo = await AuthService.biometrieDisponible();
    if (!mounted) return;
    setState(() {
      _parametres = p;
      _biometrieDisponible = bioDispo;
    });
  }

  Future<void> _majDevise() async {
    final ctrl = TextEditingController(text: _parametres!.deviseSymbole);
    final valeur = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Symbole de devise'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Ex: FG, FCFA, GNF')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Valider')),
        ],
      ),
    );
    if (valeur != null && valeur.isNotEmpty) {
      await _db.enregistrerParametres(_parametres!.copyWith(deviseSymbole: valeur));
      _charger();
    }
  }

  Future<void> _majDelaiNotification() async {
    final options = [1, 3, 6, 12, 24, 48];
    final choix = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Rappel avant echeance'),
        children: options
            .map((h) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, h),
                  child: Text(h < 24 ? '$h heure(s) avant' : '${h ~/ 24} jour(s) avant'),
                ))
            .toList(),
      ),
    );
    if (choix != null) {
      await _db.enregistrerParametres(_parametres!.copyWith(delaiNotificationHeures: choix));
      await NotificationService.reprogrammerTousLesRappels();
      _charger();
    }
  }

  Future<void> _changerPin() async {
    final controleur1 = TextEditingController();
    final controleur2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau code PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controleur1,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'Nouveau code (4 chiffres)'),
            ),
            TextField(
              controller: controleur2,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'Confirmer le code'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Valider')),
        ],
      ),
    );
    if (ok == true &&
        controleur1.text.length == 4 &&
        controleur1.text == controleur2.text) {
      await AuthService.definirPin(controleur1.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code PIN mis a jour')));
      }
    } else if (ok == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Les codes ne correspondent pas')));
      }
    }
  }

  Future<void> _genererRapportGeneral() async {
    setState(() => _generationRapportEnCours = true);
    try {
      final motos = await _db.listerMotos();
      final versementsParMoto = <int, List<Versement>>{};
      final depensesParMoto = <int, List<Depense>>{};
      for (final m in motos) {
        if (m.id == null) continue;
        versementsParMoto[m.id!] = await _db.listerVersementsParMoto(m.id!);
        depensesParMoto[m.id!] = await _db.listerDepensesParMoto(m.id!);
      }
      await PdfService.genererEtPartagerRapportGlobal(
        motos: motos,
        versementsParMoto: versementsParMoto,
        depensesParMoto: depensesParMoto,
        deviseSymbole: _parametres?.deviseSymbole ?? 'FG',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de la generation du rapport : $e')));
      }
    } finally {
      if (mounted) setState(() => _generationRapportEnCours = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_parametres == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final p = _parametres!;

    return Scaffold(
      appBar: AppBar(title: const Text('Reglages')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitre('General'),
          _carteReglage(
            titre: 'Devise',
            valeur: p.deviseSymbole,
            icone: Icons.attach_money,
            onTap: _majDevise,
          ),
          const SizedBox(height: 20),
          _sectionTitre('Rapports et statistiques'),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.bordure, width: 0.6),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bar_chart_outlined, size: 20),
                  title: const Text('Statistiques des versements', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Par semaine, mois ou annee', style: TextStyle(fontSize: 10)),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StatsScreen())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                  title: const Text('Rapport general (PDF)', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Toutes les motos - versements et depenses', style: TextStyle(fontSize: 10)),
                  trailing: _generationRapportEnCours
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _generationRapportEnCours ? null : _genererRapportGeneral,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitre('Notifications'),
          _carteReglage(
            titre: 'Rappel avant echeance',
            valeur: p.delaiNotificationHeures < 24
                ? '${p.delaiNotificationHeures}h avant'
                : '${p.delaiNotificationHeures ~/ 24}j avant',
            icone: Icons.notifications_outlined,
            onTap: _majDelaiNotification,
          ),
          const SizedBox(height: 20),
          _sectionTitre('Securite'),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.bordure, width: 0.6),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.pin_outlined, size: 20),
                  title: const Text('Modifier le code PIN', style: TextStyle(fontSize: 13)),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: _changerPin,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint, size: 20),
                  title: const Text('Empreinte / Face ID', style: TextStyle(fontSize: 13)),
                  subtitle: !_biometrieDisponible
                      ? const Text('Non disponible sur cet appareil', style: TextStyle(fontSize: 10))
                      : null,
                  value: p.biometrieActive,
                  activeColor: AppColors.accentLime,
                  onChanged: _biometrieDisponible
                      ? (v) async {
                          await AuthService.activerBiometrie(v);
                          _charger();
                        }
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitre('A propos'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Moto Taxi Douka - v1.0.0\nDonnees stockees localement sur cet appareil.',
                style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitre(String texte) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Text(texte, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteGris)),
    );
  }

  Widget _carteReglage({
    required String titre,
    required String valeur,
    required IconData icone,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.bordure, width: 0.6),
      ),
      child: ListTile(
        leading: Icon(icone, size: 20),
        title: Text(titre, style: const TextStyle(fontSize: 13)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(valeur, style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
