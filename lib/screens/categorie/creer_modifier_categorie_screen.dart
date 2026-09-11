import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_champ.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';

/// Creation ou modification d'une categorie d'activite : nom, devise,
/// couleur, et ses champs personnalises (niveau "entite" - ex: le
/// responsable d'une boutique - et niveau "transaction" - ex: le type de
/// depense - remplis respectivement une fois par entite ou a chaque
/// revenu/depense).
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

  List<CategorieChamp> _champsEntite = [];
  List<CategorieChamp> _champsTransaction = [];
  bool _chargement = true;
  bool _enregistrement = false;

  bool get _modeEdition => widget.categorieExistante != null;

  @override
  void initState() {
    super.initState();
    final c = widget.categorieExistante;
    _nomCtrl = TextEditingController(text: c?.nom ?? '');
    _deviseCtrl = TextEditingController(text: c?.deviseSymbole ?? '');
    if (c != null) _couleur = c.couleur;
    _charger();
  }

  Future<void> _charger() async {
    if (widget.categorieExistante?.id != null) {
      final entite = await _db.listerChampsCategorie(widget.categorieExistante!.id!,
          niveau: AppConstants.niveauChampEntite);
      final transaction = await _db.listerChampsCategorie(widget.categorieExistante!.id!,
          niveau: AppConstants.niveauChampTransaction);
      if (!mounted) return;
      setState(() {
        _champsEntite = entite;
        _champsTransaction = transaction;
        _chargement = false;
      });
    } else {
      setState(() => _chargement = false);
    }
  }

  Future<void> _ajouterChamp(String niveau) async {
    final champ = await showDialog<_ChampBrouillon>(
      context: context,
      builder: (context) => const _DialogueNouveauChamp(),
    );
    if (champ == null) return;
    setState(() {
      final nouveau = CategorieChamp(
        categorieId: widget.categorieExistante?.id ?? 0,
        niveau: niveau,
        nom: champ.nom,
        type: champ.type,
        options: champ.options,
        ordre: (niveau == AppConstants.niveauChampEntite ? _champsEntite.length : _champsTransaction.length),
      );
      if (niveau == AppConstants.niveauChampEntite) {
        _champsEntite = [..._champsEntite, nouveau];
      } else {
        _champsTransaction = [..._champsTransaction, nouveau];
      }
    });
  }

  Future<void> _supprimerChamp(CategorieChamp champ, String niveau) async {
    if (champ.id != null) {
      final confirme = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Retirer ce champ ?'),
          content: Text('Les valeurs deja saisies pour "${champ.nom}" seront perdues.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('Retirer'),
            ),
          ],
        ),
      );
      if (confirme != true) return;
      await _db.supprimerChampCategorie(champ.id!);
    }
    setState(() {
      if (niveau == AppConstants.niveauChampEntite) {
        _champsEntite = _champsEntite.where((c) => c != champ).toList();
      } else {
        _champsTransaction = _champsTransaction.where((c) => c != champ).toList();
      }
    });
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

      int categorieId;
      if (_modeEdition) {
        await _db.modifierCategorieActivite(categorie);
        categorieId = categorie.id!;
      } else {
        categorieId = await _db.insererCategorieActivite(categorie);
      }

      // N'insere que les champs qui n'ont pas encore d'id (nouveaux) ;
      // ceux avec un id existent deja tels quels en base.
      for (final champ in [..._champsEntite, ..._champsTransaction]) {
        if (champ.id == null) {
          await _db.insererChampCategorie(CategorieChamp(
            categorieId: categorieId,
            niveau: champ.niveau,
            nom: champ.nom,
            type: champ.type,
            options: champ.options,
            ordre: champ.ordre,
          ));
        }
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
    if (_chargement) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
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
              _sectionChamps(
                titre: 'Champs de la fiche (une fois par entite)',
                exemple: 'ex: Responsable, Adresse...',
                champs: _champsEntite,
                niveau: AppConstants.niveauChampEntite,
                couleurChoisie: couleurChoisie,
              ),
              const SizedBox(height: 20),
              _sectionChamps(
                titre: 'Champs des revenus/depenses (a chaque operation)',
                exemple: 'ex: Categorie de depense...',
                champs: _champsTransaction,
                niveau: AppConstants.niveauChampTransaction,
                couleurChoisie: couleurChoisie,
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

  Widget _sectionChamps({
    required String titre,
    required String exemple,
    required List<CategorieChamp> champs,
    required String niveau,
    required Color couleurChoisie,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.bordure, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titre, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          Text(exemple, style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
          const SizedBox(height: 10),
          if (champs.isEmpty)
            Text('Aucun champ ajoute pour l\'instant.', style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
          ...champs.map((c) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${c.nom} (${c.type})', style: const TextStyle(fontSize: 12)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => _supprimerChamp(c, niveau),
                    ),
                  ],
                ),
              )),
          TextButton.icon(
            onPressed: () => _ajouterChamp(niveau),
            icon: Icon(Icons.add, size: 16, color: couleurChoisie),
            label: Text('Ajouter un champ', style: TextStyle(color: couleurChoisie)),
          ),
        ],
      ),
    );
  }
}

class _ChampBrouillon {
  final String nom;
  final String type;
  final List<String>? options;
  _ChampBrouillon({required this.nom, required this.type, this.options});
}

class _DialogueNouveauChamp extends StatefulWidget {
  const _DialogueNouveauChamp();

  @override
  State<_DialogueNouveauChamp> createState() => _DialogueNouveauChampState();
}

class _DialogueNouveauChampState extends State<_DialogueNouveauChamp> {
  final _nomCtrl = TextEditingController();
  final _optionsCtrl = TextEditingController();
  String _type = AppConstants.typeChampTexte;

  static const _libellesType = {
    AppConstants.typeChampTexte: 'Texte',
    AppConstants.typeChampMontant: 'Montant',
    AppConstants.typeChampDate: 'Date',
    AppConstants.typeChampListe: 'Choix dans une liste',
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouveau champ'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(controller: _nomCtrl, decoration: const InputDecoration(labelText: 'Nom du champ')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: AppConstants.typesChampDisponibles
                .map((t) => DropdownMenuItem(value: t, child: Text(_libellesType[t] ?? t)))
                .toList(),
            onChanged: (v) => setState(() => _type = v ?? AppConstants.typeChampTexte),
          ),
          if (_type == AppConstants.typeChampListe) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _optionsCtrl,
              decoration: const InputDecoration(labelText: 'Choix, separes par des virgules'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        ElevatedButton(
          onPressed: () {
            final nom = _nomCtrl.text.trim();
            if (nom.isEmpty) return;
            final options = _type == AppConstants.typeChampListe
                ? _optionsCtrl.text.split(',').map((o) => o.trim()).where((o) => o.isNotEmpty).toList()
                : null;
            Navigator.pop(context, _ChampBrouillon(nom: nom, type: _type, options: options));
          },
          child: const Text('Ajouter'),
        ),
      ],
    );
  }
}
