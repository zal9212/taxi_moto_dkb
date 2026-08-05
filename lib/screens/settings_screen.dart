import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/depense.dart';
import '../models/parametre.dart';
import '../models/versement.dart';
import '../services/backup_service.dart';
import '../services/database_service.dart';
import '../services/auth_service.dart';
import '../services/excel_service.dart';
import '../services/notification_service.dart';
import '../services/pdf_service.dart';
import 'lock_screen.dart';
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
  bool _sauvegardeEnCours = false;
  bool _restaurationEnCours = false;
  bool _exportExcelEnCours = false;
  bool _importExcelEnCours = false;

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

  Future<void> _exporterSauvegarde() async {
    setState(() => _sauvegardeEnCours = true);
    try {
      await BackupService.exporter();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de l\'export : $e')));
      }
    } finally {
      if (mounted) setState(() => _sauvegardeEnCours = false);
    }
  }

  Future<void> _restaurerSauvegarde() async {
    final chemin = await BackupService.choisirFichierSauvegarde();
    if (chemin == null || !mounted) return;

    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restaurer cette sauvegarde ?'),
        content: const Text(
            'Toutes les donnees actuelles (motos, versements, depenses) seront '
            'definitivement remplacees par celles de cette sauvegarde. Cette '
            'action est irreversible.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Restaurer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;

    setState(() => _restaurationEnCours = true);
    try {
      await BackupService.restaurer(chemin);
      if (!mounted) return;
      // Repart de l'ecran de verrouillage pour que tout l'etat de l'app
      // (motos, reglages...) soit recharge depuis la base restauree.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockScreen()),
        (route) => false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de la restauration : $e')));
      }
    } finally {
      if (mounted) setState(() => _restaurationEnCours = false);
    }
  }

  Future<void> _exporterExcel() async {
    setState(() => _exportExcelEnCours = true);
    try {
      await ExcelService.exporter();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de l\'export Excel : $e')));
      }
    } finally {
      if (mounted) setState(() => _exportExcelEnCours = false);
    }
  }

  Future<void> _importerExcel() async {
    final chemin = await ExcelService.choisirFichierExcel();
    if (chemin == null || !mounted) return;

    final mode = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mode d\'import'),
        content: const Text(
            'Ajouter/mettre a jour : cree les nouvelles lignes et met a jour '
            'celles qui ont un ID existant, sans rien effacer.\n\n'
            'Tout remplacer : efface toutes les donnees actuelles et les '
            'remplace par le contenu du fichier.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(context, 'fusion'),
            child: const Text('Ajouter / mettre a jour'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'remplacement'),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Tout remplacer'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    if (mode == 'remplacement') {
      final confirme = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Tout remplacer ?'),
          content: const Text(
              'Toutes les donnees actuelles (motos, versements, depenses) seront '
              'definitivement effacees et remplacees par celles du fichier Excel. '
              'Cette action est irreversible.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('Remplacer'),
            ),
          ],
        ),
      );
      if (confirme != true || !mounted) return;
    }

    setState(() => _importExcelEnCours = true);
    try {
      final rapport = await ExcelService.importer(chemin, remplacementComplet: mode == 'remplacement');
      if (!mounted) return;
      await _afficherRapportImportExcel(rapport);
      if (!mounted) return;
      // Repart de l'ecran de verrouillage pour que tout l'etat de l'app
      // (motos, reglages...) soit recharge depuis les donnees importees.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockScreen()),
        (route) => false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de l\'import Excel : $e')));
      }
    } finally {
      if (mounted) setState(() => _importExcelEnCours = false);
    }
  }

  Future<void> _afficherRapportImportExcel(RapportImportExcel rapport) async {
    final resume = <String>[
      if (rapport.motosCreees > 0) '${rapport.motosCreees} moto(s) creee(s)',
      if (rapport.motosMisesAJour > 0) '${rapport.motosMisesAJour} moto(s) mise(s) a jour',
      if (rapport.versementsCrees > 0) '${rapport.versementsCrees} versement(s) cree(s)',
      if (rapport.versementsMisAJour > 0) '${rapport.versementsMisAJour} versement(s) mis a jour',
      if (rapport.depensesCreees > 0) '${rapport.depensesCreees} depense(s) creee(s)',
      if (rapport.depensesMisesAJour > 0) '${rapport.depensesMisesAJour} depense(s) mise(s) a jour',
    ];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rapport.erreurs.isEmpty ? 'Import reussi' : 'Import termine avec des erreurs'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (resume.isEmpty)
                const Text('Aucune ligne importee.')
              else
                ...resume.map((s) => Text('- $s')),
              if (rapport.erreurs.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('${rapport.erreurs.length} ligne(s) ignoree(s) :',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                ...rapport.erreurs.take(10).map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('- $e', style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                    )),
                if (rapport.erreurs.length > 10) Text('... et ${rapport.erreurs.length - 10} autre(s).'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
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
          _sectionTitre('Sauvegarde et restauration'),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.bordure, width: 0.6),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined, size: 20),
                  title: const Text('Exporter mes donnees', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Sauvegarde complete : motos, versements, depenses',
                      style: TextStyle(fontSize: 10)),
                  trailing: _sauvegardeEnCours
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _sauvegardeEnCours ? null : _exporterSauvegarde,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.restore_outlined, size: 20),
                  title: const Text('Restaurer une sauvegarde', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Remplace toutes les donnees actuelles',
                      style: TextStyle(fontSize: 10)),
                  trailing: _restaurationEnCours
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _restaurationEnCours ? null : _restaurerSauvegarde,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitre('Export / import Excel'),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.bordure, width: 0.6),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.table_chart_outlined, size: 20),
                  title: const Text('Exporter en Excel', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Fichier .xlsx lisible et modifiable', style: TextStyle(fontSize: 10)),
                  trailing: _exportExcelEnCours
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _exportExcelEnCours ? null : _exporterExcel,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.upload_file_outlined, size: 20),
                  title: const Text('Importer depuis Excel', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Ajouter/mettre a jour, ou tout remplacer',
                      style: TextStyle(fontSize: 10)),
                  trailing: _importExcelEnCours
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _importExcelEnCours ? null : _importerExcel,
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
