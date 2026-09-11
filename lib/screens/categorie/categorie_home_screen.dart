import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_entite.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../../utils/formatters.dart';
import 'add_edit_categorie_entite_screen.dart';
import 'categorie_entite_detail_screen.dart';
import 'categories_screen.dart';

/// Ecran "accueil" generique affiche quand une categorie d'activite (ex:
/// Boutiques) est active, a la place de HomeScreen (Motos). Meme esprit
/// (tableau de bord + liste, bascule via la barre du bas) mais generique :
/// les entites et leurs champs sont definis par l'utilisateur.
class CategorieHomeScreen extends StatefulWidget {
  final int categorieId;
  const CategorieHomeScreen({super.key, required this.categorieId});

  @override
  State<CategorieHomeScreen> createState() => _CategorieHomeScreenState();
}

class _CategorieHomeScreenState extends State<CategorieHomeScreen> {
  final _db = DatabaseService.instance;
  int _ongletActif = 0;

  CategorieActivite? _categorie;
  List<CategorieEntite> _entites = [];
  final Map<int, double> _soldeParEntite = {};
  double _totalRevenus = 0;
  double _totalDepenses = 0;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final categorie = await _db.obtenirCategorieActivite(widget.categorieId);
    if (categorie == null) {
      // Categorie supprimee entre-temps : repli sur le selecteur.
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const CategoriesScreen()),
          (route) => false,
        );
      }
      return;
    }
    final entites = await _db.listerEntitesCategorie(widget.categorieId);
    final totaux = await _db.totauxCategorie(widget.categorieId);
    _soldeParEntite.clear();
    for (final e in entites) {
      if (e.id != null) {
        _soldeParEntite[e.id!] = await _db.soldeEntiteCategorie(e.id!);
      }
    }
    if (!mounted) return;
    setState(() {
      _categorie = categorie;
      _entites = entites;
      _totalRevenus = totaux.revenus;
      _totalDepenses = totaux.depenses;
      _chargement = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_chargement || _categorie == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final couleur = couleurDepuisHex(_categorie!.couleur);
    final devise = _categorie!.deviseSymbole;

    final pages = [
      _pageAccueil(couleur, devise),
      CategoriesScreen(key: ValueKey('reglages-${widget.categorieId}')),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_ongletActif]),
      floatingActionButton: _ongletActif == 0
          ? FloatingActionButton(
              backgroundColor: AppColors.carteNoire,
              foregroundColor: couleur,
              child: const Icon(Icons.add),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AddEditCategorieEntiteScreen(categorie: _categorie!)),
                );
                _charger();
              },
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _ongletActif,
        onDestinationSelected: (i) {
          setState(() => _ongletActif = i);
          _charger();
        },
        backgroundColor: Colors.white,
        indicatorColor: couleur.withValues(alpha: 0.25),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Accueil'),
          const NavigationDestination(icon: Icon(Icons.category_outlined), label: 'Categories'),
        ],
      ),
    );
  }

  Widget _pageAccueil(Color couleur, String devise) {
    final solde = _totalRevenus - _totalDepenses;
    return RefreshIndicator(
      onRefresh: _charger,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_categorie!.nom, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              Container(width: 12, height: 12, decoration: BoxDecoration(color: couleur, shape: BoxShape.circle)),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Solde global', style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                const SizedBox(height: 4),
                Text(formaterMontant(solde, devise),
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _miniStat('Revenus', formaterMontant(_totalRevenus, devise), AppColors.accentLime),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _miniStat('Depenses', formaterMontant(_totalDepenses, devise), const Color(0xFFE2554A)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('Entites', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_entites.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('Aucune entite pour le moment.\nAppuyez sur + pour en ajouter une.',
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.texteGris, fontSize: 13)),
              ),
            )
          else
            ..._entites.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _carteEntite(e, couleur, devise),
                )),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String valeur, Color couleur) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.carteNoireClaire, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
          const SizedBox(height: 2),
          Text(valeur, style: TextStyle(color: couleur, fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _carteEntite(CategorieEntite e, Color couleur, String devise) {
    final solde = _soldeParEntite[e.id] ?? 0;
    final estInactive = e.statut != AppConstants.motoActive;
    return InkWell(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => CategorieEntiteDetailScreen(entiteId: e.id!, categorie: _categorie!)),
        );
        _charger();
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.nom, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (estInactive)
                    Text(e.statut == AppConstants.motoSuspendue ? 'Suspendue' : 'Archivee',
                        style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            Text(formaterMontant(solde, devise),
                style: TextStyle(
                  color: solde < 0 ? AppColors.danger : couleur,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                )),
          ],
        ),
      ),
    );
  }
}
