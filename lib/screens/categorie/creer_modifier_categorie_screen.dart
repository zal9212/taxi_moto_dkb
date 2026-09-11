import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';

/// Creation ou modification d'une categorie d'activite (ex: Boutiques) :
/// nom, devise propre (jamais melangee avec une autre categorie), et
/// couleur d'accent propre. Chaque entite (ex: une boutique precise) suit
/// ensuite ses revenus et depenses (montant, date, description).
class CreerModifierCategorieScreen extends StatefulWidget {
  final CategorieActivite? categorieExistante;
  const CreerModifierCategorieScreen({super.key, this.categorieExistante});

  @override
  State<CreerModifierCategorieScreen> createState() => _CreerModifierCategorieScreenState();
}

class _CreerModifierCategorieScreenState extends State<CreerModifierCategorieScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;
  late final TextEditingController _nomCtrl;
  late final TextEditingController _deviseCtrl;
  String _couleur = AppConstants.couleursCategorieDisponibles.first;
  bool _enregistrement = false;

  bool get _modeEdition => widget.categorieExistante != null;

  @override
  void initState() {
    super.initState();
    final c = widget.categorieExistante;
    _nomCtrl = TextEditingController(text: c?.nom ?? '');
    _deviseCtrl = TextEditingController(text: c?.deviseSymbole ?? '');
    if (c != null) _couleur = c.couleur;
  }

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _enregistrement = true);
    try {
      final categorie = CategorieActivite(
        id: widget.categorieExistante?.id,
        nom: _nomCtrl.text.trim(),
        couleur: _couleur,
        deviseSymbole: _deviseCtrl.text.trim(),
        dateCreation: widget.categorieExistante?.dateCreation,
      );

      if (_modeEdition) {
        await _db.modifierCategorieActivite(categorie);
      } else {
        await _db.insererCategorieActivite(categorie);
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enregistrement = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur lors de l\'enregistrement : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final couleurChoisie = couleurDepuisHex(_couleur);

    return Scaffold(
      appBar: AppBar(title: Text(_modeEdition ? 'Modifier la categorie' : 'Nouvelle categorie')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _nomCtrl,
                decoration: const InputDecoration(labelText: 'Nom de la categorie (ex: Boutiques)'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _deviseCtrl,
                decoration: const InputDecoration(labelText: 'Devise (ex: FCFA, XOF, EUR)'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 16),
              const Text('Couleur', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: AppConstants.couleursCategorieDisponibles.map((hex) {
                  final c = couleurDepuisHex(hex);
                  final selectionnee = hex == _couleur;
                  return Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: InkWell(
                      onTap: () => setState(() => _couleur = hex),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: selectionnee ? Border.all(color: AppColors.texteNoir, width: 2) : null,
                        ),
                        child: selectionnee ? Icon(Icons.check, size: 16, color: texteContrasteSur(c)) : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: couleurChoisie,
                  foregroundColor: texteContrasteSur(couleurChoisie),
                ),
                onPressed: _enregistrement ? null : _enregistrer,
                child: Text(_enregistrement ? 'Enregistrement...' : 'Enregistrer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
