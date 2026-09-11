import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../home_screen.dart';
import 'categorie_home_screen.dart';
import 'creer_modifier_categorie_screen.dart';

/// Liste des "espaces" de l'app : Motos (systeme specialise, toujours en
/// premier) puis les categories d'activite creees par l'utilisateur (ex:
/// Boutiques). Taper sur une ligne bascule tout l'app sur cet espace ;
/// le menu d'une categorie permet de la modifier ou de la supprimer.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _db = DatabaseService.instance;
  List<CategorieActivite> _categories = [];
  int? _categorieActiveId;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final categories = await _db.listerCategoriesActivite();
    final params = await _db.obtenirParametres();
    if (!mounted) return;
    setState(() {
      _categories = categories;
      _categorieActiveId = params.categorieActiveId;
      _chargement = false;
    });
  }

  Future<void> _activerMotos() async {
    await _db.definirCategorieActive(null);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  Future<void> _activerCategorie(CategorieActivite c) async {
    if (c.id == null) return;
    await _db.definirCategorieActive(c.id);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => CategorieHomeScreen(categorieId: c.id!)),
      (route) => false,
    );
  }

  Future<void> _supprimerCategorie(CategorieActivite c) async {
    if (c.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette categorie ?'),
        content: Text(
          '"${c.nom}" et tout son contenu (entites, revenus, depenses) '
          'seront definitivement supprimes. Cette action est irreversible.',
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
    await _db.supprimerCategorieActivite(c.id!);
    _charger();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Chaque categorie a sa propre devise, sa propre couleur, et ses '
                    'propres champs. Basculer d\'une categorie a l\'autre change tout '
                    'l\'app pour n\'afficher que ses donnees.',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                const SizedBox(height: 16),
                _ligneEspace(
                  nom: 'Motos',
                  sousTitre: 'Systeme specialise (versements recurrents)',
                  couleur: AppColors.accentLime,
                  active: _categorieActiveId == null,
                  onTap: _activerMotos,
                ),
                const SizedBox(height: 8),
                ..._categories.map((c) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ligneEspace(
                        nom: c.nom,
                        sousTitre: 'Devise : ${c.deviseSymbole}',
                        couleur: couleurDepuisHex(c.couleur),
                        active: _categorieActiveId == c.id,
                        onTap: () => _activerCategorie(c),
                        onModifier: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => CreerModifierCategorieScreen(categorieExistante: c)),
                          );
                          _charger();
                        },
                        onSupprimer: () => _supprimerCategorie(c),
                      ),
                    )),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.carteNoire,
        foregroundColor: AppColors.accentLime,
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle categorie'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreerModifierCategorieScreen()));
          _charger();
        },
      ),
    );
  }

  Widget _ligneEspace({
    required String nom,
    required String sousTitre,
    required Color couleur,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onModifier,
    VoidCallback? onSupprimer,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? couleur : AppColors.bordure, width: active ? 1.4 : 0.6),
        ),
        child: Row(
          children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: couleur, shape: BoxShape.circle)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(nom, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(sousTitre, style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                ],
              ),
            ),
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppColors.succesFond, borderRadius: BorderRadius.circular(6)),
                child: Text('Active', style: TextStyle(color: AppColors.succes, fontSize: 9, fontWeight: FontWeight.w600)),
              ),
            if (onModifier != null || onSupprimer != null)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'modifier') onModifier?.call();
                  if (v == 'supprimer') onSupprimer?.call();
                },
                itemBuilder: (context) => [
                  if (onModifier != null) const PopupMenuItem(value: 'modifier', child: Text('Modifier')),
                  if (onSupprimer != null)
                    PopupMenuItem(
                      value: 'supprimer',
                      child: Text('Supprimer', style: TextStyle(color: AppColors.danger)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
