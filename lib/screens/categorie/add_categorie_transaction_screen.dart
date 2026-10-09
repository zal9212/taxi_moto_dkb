import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_entite.dart';
import '../../models/categorie_gerant.dart';
import '../../models/categorie_transaction.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../../utils/formatters.dart';
import '../../widgets/note_vocale.dart';

/// Ajoute un revenu ou une depense a une entite : montant, date,
/// description et/ou note vocale, et la personne concernee (proprietaire ou
/// gerant actif).
class AddCategorieTransactionScreen extends StatefulWidget {
  final CategorieActivite categorie;
  final CategorieEntite entite;

  /// Gerants actifs de l'entite (vide = pas de choix "Qui ?", tout va au
  /// proprietaire).
  final List<CategorieGerant> gerants;

  /// Personne preselectionnee (null = proprietaire).
  final int? gerantInitial;

  const AddCategorieTransactionScreen({
    super.key,
    required this.categorie,
    required this.entite,
    this.gerants = const [],
    this.gerantInitial,
  });

  @override
  State<AddCategorieTransactionScreen> createState() => _AddCategorieTransactionScreenState();
}

class _AddCategorieTransactionScreenState extends State<AddCategorieTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;
  final _montantCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  String _type = AppConstants.transactionRevenu;
  DateTime _date = DateTime.now();
  late int? _gerantId =
      widget.gerants.any((g) => g.id == widget.gerantInitial) ? widget.gerantInitial : null;
  bool _enregistrement = false;
  Uint8List? _audio;
  bool _noteEnCours = false;

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _enregistrement = true);
    try {
      await _db.insererTransactionCategorie(
        CategorieTransaction(
          entiteId: widget.entite.id!,
          type: _type,
          montant: lireMontant(_montantCtrl.text)!,
          date: _date,
          description: _descriptionCtrl.text.trim().isEmpty ? null : _descriptionCtrl.text.trim(),
          gerantId: _gerantId,
        ),
        audio: _audio,
      );

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
    final couleur = couleurDepuisHex(widget.categorie.couleur);
    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle operation')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _puceType('Revenu', AppConstants.transactionRevenu, AppColors.accentLime),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _puceType('Depense', AppConstants.transactionDepense, const Color(0xFFE2554A)),
                  ),
                ],
              ),
              if (widget.gerants.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<int?>(
                  initialValue: _gerantId,
                  decoration: const InputDecoration(labelText: 'Qui ?'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text(AppConstants.libelleProprietaire)),
                    for (final g in widget.gerants) DropdownMenuItem(value: g.id, child: Text(g.nom)),
                  ],
                  onChanged: (v) => setState(() => _gerantId = v),
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                controller: _montantCtrl,
                decoration: InputDecoration(labelText: 'Montant (${widget.categorie.deviseSymbole})'),
                keyboardType: TextInputType.number,
                validator: (v) => lireMontant(v) == null ? 'Montant invalide' : null,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date', style: TextStyle(fontSize: 13)),
                subtitle: Text('${_date.day}/${_date.month}/${_date.year}'),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                onTap: () async {
                  final choisie = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2100),
                  );
                  if (choisie != null) setState(() => _date = choisie);
                },
              ),
              const Divider(),
              const SizedBox(height: 8),
              TextFormField(
                controller: _descriptionCtrl,
                decoration: const InputDecoration(labelText: 'Description (optionnel)'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              EnregistreurNoteVocale(
                onChanged: (audio) => _audio = audio,
                onEnregistrement: (enCours) => setState(() => _noteEnCours = enCours),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: couleur, foregroundColor: Colors.white),
                // Pendant une note vocale : l'operation partirait sans elle.
                onPressed: _enregistrement || _noteEnCours ? null : _enregistrer,
                child: Text(_libelleEnregistrer),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _libelleEnregistrer {
    if (_noteEnCours) return 'Arretez d\'abord la note vocale';
    if (_enregistrement) return 'Enregistrement...';
    return 'Enregistrer';
  }

  Widget _puceType(String label, String valeur, Color couleur) {
    final actif = _type == valeur;
    return GestureDetector(
      onTap: () => setState(() => _type = valeur),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: actif ? couleur : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: actif ? couleur : AppColors.bordure),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: actif ? texteContrasteSur(couleur) : AppColors.texteGris,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}
