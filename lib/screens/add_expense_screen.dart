import 'package:flutter/material.dart';

import '../models/moto.dart';
import '../models/depense.dart';
import '../services/database_service.dart';

class AddExpenseScreen extends StatefulWidget {
  const AddExpenseScreen({super.key});

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;
  final _montantCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();

  List<Moto> _motos = [];
  List<CategorieDepense> _categories = [];
  int? _motoId;
  int? _categorieId;
  DateTime _date = DateTime.now();
  bool _enregistrement = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final motos = await _db.listerMotos();
    final categories = await _db.listerCategories();
    if (!mounted) return;
    setState(() {
      _motos = motos;
      _categories = categories;
      _motoId = motos.isNotEmpty ? motos.first.id : null;
      _categorieId = categories.isNotEmpty ? categories.first.id : null;
    });
  }

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate() || _motoId == null || _categorieId == null) return;
    setState(() => _enregistrement = true);

    try {
      await _db.insererDepense(Depense(
        motoId: _motoId!,
        categorieId: _categorieId!,
        montant: double.parse(_montantCtrl.text.replaceAll(' ', '')),
        date: _date,
        description: _descriptionCtrl.text.trim().isEmpty ? null : _descriptionCtrl.text.trim(),
      ));

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
    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle depense')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<int>(
              initialValue: _motoId,
              decoration: const InputDecoration(labelText: 'Moto concernee'),
              items: _motos.map((m) => DropdownMenuItem(value: m.id, child: Text(m.nom))).toList(),
              onChanged: (v) => setState(() => _motoId = v),
              validator: (v) => v == null ? 'Selectionnez une moto' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _categorieId,
              decoration: const InputDecoration(labelText: 'Categorie'),
              items: _categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.nom))).toList(),
              onChanged: (v) => setState(() => _categorieId = v),
              validator: (v) => v == null ? 'Selectionnez une categorie' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _montantCtrl,
              decoration: const InputDecoration(labelText: 'Montant'),
              keyboardType: TextInputType.number,
              validator: (v) => (double.tryParse(v ?? '') == null) ? 'Montant invalide' : null,
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
                  firstDate: DateTime(2020),
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
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _enregistrement ? null : _enregistrer,
              child: Text(_enregistrement ? 'Enregistrement...' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }
}
