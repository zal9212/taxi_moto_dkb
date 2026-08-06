import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../models/depense.dart';
import '../services/database_service.dart';
import '../utils/formatters.dart';
import 'add_expense_screen.dart';

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final _db = DatabaseService.instance;
  List<Moto> _motos = [];
  List<Depense> _depenses = [];
  Map<int?, CategorieDepense> _categories = {};
  Map<int?, Moto> _motosParId = {};
  int? _filtreMotoId;
  String _devise = AppConstants.devisePardDefaut;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final motos = await _db.listerMotos();
    final depenses = await _db.listerDepensesRecentes(motoId: _filtreMotoId, limite: 200);
    final categories = await _db.listerCategories();
    final params = await _db.obtenirParametres();

    if (!mounted) return;
    setState(() {
      _motos = motos;
      _depenses = depenses;
      _categories = {for (final c in categories) c.id: c};
      _motosParId = {for (final m in motos) m.id: m};
      _devise = params.deviseSymbole;
      _chargement = false;
    });
  }

  double get _totalAffiche => _depenses.fold(0, (s, d) => s + d.montant);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Depenses'),
        actions: [
          IconButton(
            icon: const Icon(Icons.category_outlined),
            tooltip: 'Gerer les categories',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const _CategoriesScreen()));
              _charger();
            },
          ),
        ],
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _charger,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _puce('Toutes les motos', _filtreMotoId == null, () {
                          setState(() => _filtreMotoId = null);
                          _charger();
                        }),
                        const SizedBox(width: 8),
                        ..._motos.map((m) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _puce('${m.nom} - ${m.chauffeur}', _filtreMotoId == m.id, () {
                                setState(() => _filtreMotoId = m.id);
                                _charger();
                              }),
                            )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration:
                        BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Total des depenses', style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                        Text(formaterMontant(_totalAffiche, _devise),
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_depenses.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: Center(
                        child: Text('Aucune depense enregistree',
                            style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                      ),
                    )
                  else
                    ..._depenses.map((d) => _ligneDepense(d)),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.carteNoire,
        child: const Icon(Icons.add, color: AppColors.accentLime),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddExpenseScreen()));
          _charger();
        },
      ),
    );
  }

  Widget _puce(String label, bool actif, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: actif ? AppColors.carteNoire : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: actif ? AppColors.carteNoire : AppColors.bordure),
        ),
        child: Text(label, style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 11)),
      ),
    );
  }

  Widget _ligneDepense(Depense d) {
    final cat = _categories[d.categorieId];
    final moto = _motosParId[d.motoId];
    return Dismissible(
      key: ValueKey(d.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(color: AppColors.dangerFond, borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.delete_outline, color: AppColors.danger),
      ),
      onDismissed: (_) async {
        if (d.id != null) await _db.supprimerDepense(d.id!);
        _charger();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(color: AppColors.dangerFond, shape: BoxShape.circle),
              child: const Icon(Icons.build_outlined, color: AppColors.danger, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${cat?.nom ?? 'Depense'} - ${moto?.nom ?? ''}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  Text(formaterDate(d.date), style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  if (d.description != null && d.description!.isNotEmpty)
                    Text(d.description!, style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            Text('-${formaterMontant(d.montant, _devise)}',
                style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Gestion des catégories de dépenses — entièrement dynamique, l'utilisateur
/// peut ajouter ou supprimer des catégories au-delà de celles par défaut.
class _CategoriesScreen extends StatefulWidget {
  const _CategoriesScreen();

  @override
  State<_CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<_CategoriesScreen> {
  final _db = DatabaseService.instance;
  List<CategorieDepense> _categories = [];

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final cats = await _db.listerCategories();
    if (!mounted) return;
    setState(() => _categories = cats);
  }

  Future<void> _ajouter() async {
    final ctrl = TextEditingController();
    final nom = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouvelle categorie'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Nom')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
    if (nom != null && nom.isNotEmpty) {
      await _db.insererCategorie(CategorieDepense(nom: nom, icone: 'dots'));
      _charger();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories de depenses')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _categories.length,
        itemBuilder: (context, i) {
          final c = _categories[i];
          return ListTile(
            title: Text(c.nom),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              onPressed: () async {
                if (c.id != null) await _db.supprimerCategorie(c.id!);
                _charger();
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.carteNoire,
        child: const Icon(Icons.add, color: AppColors.accentLime),
        onPressed: _ajouter,
      ),
    );
  }
}
