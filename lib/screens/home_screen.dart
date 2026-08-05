import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../models/parametre.dart';
import '../services/database_service.dart';
import '../utils/formatters.dart';
import '../widgets/moto_card.dart';
import '../widgets/activity_tile.dart';
import 'moto_detail_screen.dart';
import 'add_edit_moto_screen.dart';
import 'expenses_screen.dart';
import 'settings_screen.dart';

enum _FiltrePeriode { tout, ceMois, cetteAnnee }
enum _TriMoto { recentes, nom, retard }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = DatabaseService.instance;

  int _ongletActif = 0;
  _FiltrePeriode _filtrePeriode = _FiltrePeriode.tout;
  int? _motoFiltreId; // null = toutes les motos
  String _rechercheMotos = '';
  _TriMoto _triMotos = _TriMoto.recentes;

  Parametre? _parametres;
  List<Moto> _motos = [];
  double _totalEncaisse = 0;
  double _totalEnRetard = 0;
  List<_ActiviteRecente> _activites = [];

  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  ({DateTime? debut, DateTime? fin}) get _bornesPeriode {
    final maintenant = DateTime.now();
    switch (_filtrePeriode) {
      case _FiltrePeriode.ceMois:
        return (debut: DateTime(maintenant.year, maintenant.month, 1), fin: maintenant);
      case _FiltrePeriode.cetteAnnee:
        return (debut: DateTime(maintenant.year, 1, 1), fin: maintenant);
      case _FiltrePeriode.tout:
        return (debut: null, fin: null);
    }
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    await _db.actualiserRetards();

    final bornes = _bornesPeriode;
    final params = await _db.obtenirParametres();
    final motos = await _db.listerMotos();

    // Garde la fenetre d'echeances a venir pleine pour chaque moto active
    // (versement recurrent et indefini) - toute modification (montant,
    // frequence...) se repercute donc immediatement sur tout le reste.
    for (final m in motos.where((m) => m.statut == AppConstants.motoActive)) {
      await _db.assurerEcheances(m);
    }
    final totalEncaisse = await _db.totalEncaisse(
      motoId: _motoFiltreId,
      debut: bornes.debut,
      fin: bornes.fin,
    );
    final solde = await _db.soldeNet(motoId: _motoFiltreId);
    final totalEnRetard = solde < 0 ? -solde : 0.0;

    final versementsRecents = await _db.listerVersementsRecents(
      motoId: _motoFiltreId,
      debut: bornes.debut,
      fin: bornes.fin,
      limite: 15,
    );
    final depensesRecentes = await _db.listerDepensesRecentes(motoId: _motoFiltreId, limite: 15);

    final motosParId = {for (final m in motos) m.id: m};
    final categories = {for (final c in await _db.listerCategories()) c.id: c};

    final activites = <_ActiviteRecente>[
      ...versementsRecents.where((v) => v.statut == AppConstants.versementPaye).map(
            (v) => _ActiviteRecente(
              titre: '${motosParId[v.motoId]?.nom ?? 'Moto'} - versement',
              date: v.dateValidation ?? v.dateEcheance,
              montant: v.montantPaye ?? v.montantPrevu,
              estPositif: true,
              icone: Icons.check_circle_outline,
            ),
          ),
      ...depensesRecentes.map(
        (d) => _ActiviteRecente(
          titre: '${categories[d.categorieId]?.nom ?? 'Depense'} - ${motosParId[d.motoId]?.nom ?? ''}',
          date: d.date,
          montant: d.montant,
          estPositif: false,
          icone: Icons.build_outlined,
        ),
      ),
    ]..sort((a, b) => b.date.compareTo(a.date));

    if (!mounted) return;
    setState(() {
      _parametres = params;
      _motos = motos;
      _totalEncaisse = totalEncaisse;
      _totalEnRetard = totalEnRetard;
      _activites = activites.take(10).toList();
      _chargement = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _pageAccueil(),
      _pageMotos(),
      const ExpensesScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: SafeArea(child: _chargement ? const Center(child: CircularProgressIndicator()) : pages[_ongletActif]),
      floatingActionButton: _ongletActif == 1
          ? FloatingActionButton(
              backgroundColor: AppColors.carteNoire,
              child: const Icon(Icons.add, color: AppColors.accentLime),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddEditMotoScreen()),
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
        indicatorColor: AppColors.succesFond,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Accueil'),
          NavigationDestination(icon: Icon(Icons.two_wheeler_outlined), selectedIcon: Icon(Icons.two_wheeler), label: 'Motos'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Depenses'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Reglages'),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // PAGE ACCUEIL
  // -----------------------------------------------------------------------

  Widget _pageAccueil() {
    final devise = _parametres?.deviseSymbole ?? AppConstants.devisePardDefaut;

    return RefreshIndicator(
      onRefresh: _charger,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _carteTotal(devise),
          const SizedBox(height: 16),
          _barreFiltres(),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Activite recente', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              TextButton(
                onPressed: () => setState(() => _ongletActif = 1),
                child: const Text('Voir tout', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (_activites.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('Aucune activite pour le moment',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
              ),
            )
          else
            ..._activites.map((a) => ActivityTile(
                  icone: a.icone,
                  titre: a.titre,
                  date: a.date,
                  montant: a.montant,
                  estPositif: a.estPositif,
                  devise: devise,
                )),
        ],
      ),
    );
  }

  Widget _carteTotal(String devise) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Total encaisse', style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            formaterMontant(_totalEncaisse, devise),
            style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _miniStat('A jour', formaterMontant(_totalEncaisse, devise), AppColors.accentLime),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _miniStat('En retard', formaterMontant(_totalEnRetard, devise), const Color(0xFFE2554A)),
              ),
            ],
          ),
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
          Text(label, style: TextStyle(color: AppColors.texteGris, fontSize: 9)),
          const SizedBox(height: 2),
          Text(valeur, style: TextStyle(color: couleur, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _barreFiltres() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _puceFiltre('Tout', _filtrePeriode == _FiltrePeriode.tout && _motoFiltreId == null, () {
            setState(() {
              _filtrePeriode = _FiltrePeriode.tout;
              _motoFiltreId = null;
            });
            _charger();
          }),
          const SizedBox(width: 8),
          _puceFiltreMoto(),
          const SizedBox(width: 8),
          _puceFiltre('Ce mois', _filtrePeriode == _FiltrePeriode.ceMois, () {
            setState(() => _filtrePeriode = _FiltrePeriode.ceMois);
            _charger();
          }),
          const SizedBox(width: 8),
          _puceFiltre('Cette annee', _filtrePeriode == _FiltrePeriode.cetteAnnee, () {
            setState(() => _filtrePeriode = _FiltrePeriode.cetteAnnee);
            _charger();
          }),
        ],
      ),
    );
  }

  Widget _puceFiltre(String label, bool actif, VoidCallback onTap) {
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
        child: Text(label,
            style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 11)),
      ),
    );
  }

  Widget _puceFiltreMoto() {
    return PopupMenuButton<int?>(
      onSelected: (id) {
        setState(() => _motoFiltreId = id);
        _charger();
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: null, child: Text('Toutes les motos')),
        ..._motos.map((m) => PopupMenuItem(value: m.id, child: Text('${m.nom} - ${m.chauffeur}'))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: _motoFiltreId != null ? AppColors.carteNoire : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _motoFiltreId != null ? AppColors.carteNoire : AppColors.bordure),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _motoFiltreId != null
                  ? (_motos.where((m) => m.id == _motoFiltreId).isNotEmpty
                      ? '${_motos.firstWhere((m) => m.id == _motoFiltreId).nom} - '
                          '${_motos.firstWhere((m) => m.id == _motoFiltreId).chauffeur}'
                      : 'Moto')
                  : 'Moto',
              style: TextStyle(
                  color: _motoFiltreId != null ? Colors.white : AppColors.texteGris, fontSize: 11),
            ),
            Icon(Icons.expand_more,
                size: 14, color: _motoFiltreId != null ? Colors.white : AppColors.texteGris),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // PAGE LISTE DES MOTOS
  // -----------------------------------------------------------------------

  Widget _pageMotos() {
    final devise = _parametres?.deviseSymbole ?? AppConstants.devisePardDefaut;

    return RefreshIndicator(
      onRefresh: _charger,
      child: FutureBuilder<List<_MotoAvecInfos>>(
        future: _chargerInfosMotos(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final toutesLesMotos = snapshot.data!;
          final items = _filtrerEtTrierMotos(toutesLesMotos);

          if (toutesLesMotos.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 80),
                Center(
                  child: Text('Aucune moto pour le moment.\nAppuyez sur + pour en ajouter une.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.texteGris, fontSize: 13)),
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            children: [
              _barreRechercheEtTriMotos(),
              const SizedBox(height: 12),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text('Aucun resultat pour cette recherche.',
                        style: TextStyle(color: AppColors.texteGris, fontSize: 13)),
                  ),
                )
              else
                ...items.map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: MotoCard(
                        moto: item.moto,
                        totalVerse: item.totalVerse,
                        solde: item.solde,
                        prochainVersement: item.prochain,
                        devise: devise,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => MotoDetailScreen(motoId: item.moto.id!)),
                          );
                          _charger();
                        },
                      ),
                    )),
            ],
          );
        },
      ),
    );
  }

  List<_MotoAvecInfos> _filtrerEtTrierMotos(List<_MotoAvecInfos> source) {
    var items = source;

    final q = _rechercheMotos.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items
          .where((it) =>
              it.moto.nom.toLowerCase().contains(q) || it.moto.chauffeur.toLowerCase().contains(q))
          .toList();
    }

    items = [...items];
    switch (_triMotos) {
      case _TriMoto.nom:
        items.sort((a, b) => a.moto.nom.toLowerCase().compareTo(b.moto.nom.toLowerCase()));
        break;
      case _TriMoto.retard:
        // Solde le plus negatif (plus grosse dette) en premier.
        items.sort((a, b) => a.solde.compareTo(b.solde));
        break;
      case _TriMoto.recentes:
        break; // ordre deja fourni par listerMotos (date_creation DESC)
    }
    return items;
  }

  Widget _barreRechercheEtTriMotos() {
    Widget puceTri(String label, _TriMoto valeur) {
      final actif = _triMotos == valeur;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _triMotos = valeur),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: actif ? AppColors.carteNoire : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: actif ? AppColors.carteNoire : AppColors.bordure),
            ),
            child: Text(label,
                style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 11)),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          onChanged: (v) => setState(() => _rechercheMotos = v),
          decoration: const InputDecoration(
            hintText: 'Rechercher une moto ou un chauffeur',
            prefixIcon: Icon(Icons.search, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              puceTri('Recentes', _TriMoto.recentes),
              puceTri('Nom (A-Z)', _TriMoto.nom),
              puceTri('Retard d\'abord', _TriMoto.retard),
            ],
          ),
        ),
      ],
    );
  }

  Future<List<_MotoAvecInfos>> _chargerInfosMotos() async {
    final resultats = <_MotoAvecInfos>[];
    for (final moto in _motos) {
      if (moto.id == null) continue;
      final totalVerse = await _db.totalEncaisse(motoId: moto.id!);
      final solde = await _db.soldeNet(motoId: moto.id!);
      final prochain = await _db.prochainVersement(moto.id!);
      resultats.add(_MotoAvecInfos(moto: moto, totalVerse: totalVerse, solde: solde, prochain: prochain));
    }
    return resultats;
  }
}

class _ActiviteRecente {
  final String titre;
  final DateTime date;
  final double montant;
  final bool estPositif;
  final IconData icone;

  _ActiviteRecente({
    required this.titre,
    required this.date,
    required this.montant,
    required this.estPositif,
    required this.icone,
  });
}

class _MotoAvecInfos {
  final Moto moto;
  final double totalVerse;
  final double solde;
  final Versement? prochain;

  _MotoAvecInfos({
    required this.moto,
    required this.totalVerse,
    required this.solde,
    required this.prochain,
  });
}
