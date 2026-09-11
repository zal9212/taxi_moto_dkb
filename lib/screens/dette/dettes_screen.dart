import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/dette.dart';
import '../../services/database_service.dart';
import '../../services/excel_service.dart';
import '../../utils/formatters.dart';
import 'add_edit_dette_screen.dart';
import 'dette_detail_screen.dart';

/// Liste globale des dettes ("quelqu'un me doit de l'argent"), avec le
/// total restant du. Suivi independant du systeme de categories generique.
class DettesScreen extends StatefulWidget {
  const DettesScreen({super.key});

  @override
  State<DettesScreen> createState() => _DettesScreenState();
}

class _DettesScreenState extends State<DettesScreen> {
  final _db = DatabaseService.instance;
  List<Dette> _dettes = [];
  final Map<int, double> _soldes = {};
  String _devise = AppConstants.devisePardDefaut;
  bool _chargement = true;
  bool _exportEnCours = false;
  bool _importEnCours = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final dettes = await _db.listerDettes();
    final params = await _db.obtenirParametres();
    _soldes.clear();
    for (final d in dettes) {
      if (d.id != null) _soldes[d.id!] = await _db.soldeDette(d.id!);
    }
    if (!mounted) return;
    setState(() {
      _dettes = dettes;
      _devise = params.deviseSymbole;
      _chargement = false;
    });
  }

  double get _totalEnCours => _soldes.values.where((s) => s > 0).fold(0.0, (a, b) => a + b);

  Future<void> _exporter() async {
    setState(() => _exportEnCours = true);
    try {
      await ExcelService.exporterDettes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur lors de l\'export Excel : $e')));
      }
    } finally {
      if (mounted) setState(() => _exportEnCours = false);
    }
  }

  Future<void> _importer() async {
    final chemin = await ExcelService.choisirFichierExcel();
    if (chemin == null || !mounted) return;

    final mode = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mode d\'import'),
        content: const Text(
            'Ajouter/mettre a jour : cree les nouvelles dettes/remboursements et '
            'met a jour ceux qui ont un ID existant, sans rien effacer.\n\n'
            'Tout remplacer : efface toutes les dettes actuelles et les remplace '
            'par le contenu du fichier.'),
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
              'Toutes les dettes actuelles seront definitivement effacees et '
              'remplacees par celles du fichier Excel. Cette action est irreversible.'),
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

    setState(() => _importEnCours = true);
    try {
      final rapport = await ExcelService.importerDettes(chemin, remplacementComplet: mode == 'remplacement');
      if (!mounted) return;
      await _afficherRapportImport(rapport);
      _charger();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur lors de l\'import Excel : $e')));
      }
    } finally {
      if (mounted) setState(() => _importEnCours = false);
    }
  }

  Future<void> _afficherRapportImport(RapportImportDettes rapport) async {
    final resume = <String>[
      if (rapport.dettesCreees > 0) '${rapport.dettesCreees} dette(s) creee(s)',
      if (rapport.dettesMisesAJour > 0) '${rapport.dettesMisesAJour} dette(s) mise(s) a jour',
      if (rapport.remboursementsCrees > 0) '${rapport.remboursementsCrees} remboursement(s) cree(s)',
      if (rapport.remboursementsMisAJour > 0) '${rapport.remboursementsMisAJour} remboursement(s) mis a jour',
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
              if (resume.isEmpty) const Text('Aucune ligne importee.') else ...resume.map((s) => Text('- $s')),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dettes'),
        actions: [
          if (_exportEnCours || _importEnCours)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'exporter') _exporter();
                if (v == 'importer') _importer();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'exporter', child: Text('Exporter Excel')),
                PopupMenuItem(value: 'importer', child: Text('Importer Excel')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddEditDetteScreen()));
          _charger();
        },
        child: const Icon(Icons.add),
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _charger,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Total en cours', style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                        const SizedBox(height: 4),
                        Text(formaterMontant(_totalEnCours, _devise),
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_dettes.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 60),
                      child: Center(
                        child: Text('Aucune dette pour le moment.',
                            style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                      ),
                    )
                  else
                    ..._dettes.map((d) => _ligneDette(d)),
                ],
              ),
            ),
    );
  }

  Widget _ligneDette(Dette d) {
    final solde = _soldes[d.id] ?? d.montantInitial;
    final soldee = solde <= 0;
    return InkWell(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => DetteDetailScreen(detteId: d.id!)));
        _charger();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.nomPersonne, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(formaterDate(d.date), style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            Text(
              soldee ? 'Soldee' : formaterMontant(solde, _devise),
              style: TextStyle(
                color: soldee ? AppColors.succes : AppColors.danger,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
