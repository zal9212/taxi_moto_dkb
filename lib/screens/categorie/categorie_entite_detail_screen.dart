import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_champ.dart';
import '../../models/categorie_entite.dart';
import '../../models/categorie_transaction.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../../utils/formatters.dart';
import 'add_categorie_transaction_screen.dart';
import 'add_edit_categorie_entite_screen.dart';

/// Detail d'une entite generique (ex: une boutique precise) : ses champs
/// personnalises, son solde, l'historique de ses revenus/depenses.
/// Equivalent generique de MotoDetailScreen.
class CategorieEntiteDetailScreen extends StatefulWidget {
  final int entiteId;
  final CategorieActivite categorie;

  const CategorieEntiteDetailScreen({super.key, required this.entiteId, required this.categorie});

  @override
  State<CategorieEntiteDetailScreen> createState() => _CategorieEntiteDetailScreenState();
}

class _CategorieEntiteDetailScreenState extends State<CategorieEntiteDetailScreen> {
  final _db = DatabaseService.instance;
  CategorieEntite? _entite;
  List<CategorieTransaction> _transactions = [];
  List<CategorieChamp> _champsEntite = [];
  Map<int, String> _valeursEntite = {};
  double _solde = 0;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final entite = await _db.obtenirEntiteCategorie(widget.entiteId);
    if (entite == null) return;
    final transactions = await _db.listerTransactionsEntite(widget.entiteId);
    final champs = await _db.listerChampsCategorie(widget.categorie.id!, niveau: AppConstants.niveauChampEntite);
    final valeurs = await _db.obtenirValeursEntite(widget.entiteId);
    final solde = await _db.soldeEntiteCategorie(widget.entiteId);

    if (!mounted) return;
    setState(() {
      _entite = entite;
      _transactions = transactions;
      _champsEntite = champs;
      _valeursEntite = valeurs;
      _solde = solde;
      _chargement = false;
    });
  }

  Future<void> _supprimerTransaction(CategorieTransaction t) async {
    if (t.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette operation ?'),
        content: const Text('Cette action est irreversible.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    await _db.supprimerTransactionCategorie(t.id!);
    _charger();
  }

  Future<void> _supprimerEntite() async {
    if (_entite?.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette entite ?'),
        content: Text(
          '"${_entite!.nom}" et tout son historique seront definitivement supprimes. '
          'Cette action est irreversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    await _db.supprimerEntiteCategorie(_entite!.id!);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_chargement || _entite == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final entite = _entite!;
    final couleur = couleurDepuisHex(widget.categorie.couleur);
    final devise = widget.categorie.deviseSymbole;

    return Scaffold(
      appBar: AppBar(
        title: Text(entite.nom),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddEditCategorieEntiteScreen(categorie: widget.categorie, entiteExistante: entite),
                ),
              );
              _charger();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _supprimerEntite,
          ),
        ],
      ),
      body: RefreshIndicator(
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
                  Text('Solde', style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  const SizedBox(height: 4),
                  Text(formaterMontant(_solde, devise),
                      style: TextStyle(
                          color: _solde < 0 ? const Color(0xFFE2554A) : Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600)),
                  if (_champsEntite.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ..._champsEntite.where((c) => c.id != null && _valeursEntite[c.id!] != null).map(
                          (c) => Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text('${c.nom} : ${_valeursEntite[c.id!]}',
                                style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                          ),
                        ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: couleur, foregroundColor: Colors.white),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Ajouter un revenu / une depense'),
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AddCategorieTransactionScreen(categorie: widget.categorie, entite: entite),
                          ),
                        );
                        _charger();
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Historique', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (_transactions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('Aucune operation pour le moment.',
                      style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                ),
              )
            else
              ..._transactions.map((t) => _ligneTransaction(t, devise)),
          ],
        ),
      ),
    );
  }

  Widget _ligneTransaction(CategorieTransaction t, String devise) {
    final estRevenu = t.type == AppConstants.transactionRevenu;
    return Dismissible(
      key: ValueKey(t.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(color: AppColors.dangerFond, borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.delete_outline, color: AppColors.danger),
      ),
      onDismissed: (_) => _supprimerTransaction(t),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                  Text(formaterDate(t.date), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  if (t.description != null && t.description!.isNotEmpty)
                    Text(t.description!, style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            Text(
              '${estRevenu ? '+' : '-'}${formaterMontant(t.montant, devise)}',
              style: TextStyle(
                color: estRevenu ? AppColors.succes : AppColors.danger,
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
