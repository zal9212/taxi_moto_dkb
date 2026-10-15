import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../models/parametre.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/schedule_service.dart';
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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
  int _motosAJour = 0;
  List<_ActiviteRecente> _activites = [];
  List<_MotoAvecInfos> _infosMotos = [];
  bool _etaitEnArrierePlan = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _charger();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Recharge au retour au premier plan apres une vraie mise en arriere-plan
  /// (un nouveau jour a pu commencer : retards, nouvelles echeances). Pas
  /// apres un selecteur de fichier ou un partage, qui ne passent pas par
  /// "paused" — meme regle que le reverrouillage dans main.dart.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _etaitEnArrierePlan = true;
    if (state == AppLifecycleState.resumed && _etaitEnArrierePlan) {
      _etaitEnArrierePlan = false;
      _charger();
    }
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

  /// Chargement en cours, et s'il faut recharger une fois de plus a la fin
  /// (une demande arrivee pendant le chargement) : jamais deux a la fois.
  Future<void>? _chargementEnCours;
  bool _rechargerApres = false;

  Future<void> _charger() {
    if (_chargementEnCours != null) {
      _rechargerApres = true;
      return _chargementEnCours!;
    }
    return _chargementEnCours = () async {
      try {
        do {
          _rechargerApres = false;
          await _chargerUneFois();
        } while (_rechargerApres && mounted);
      } finally {
        _chargementEnCours = null;
      }
    }();
  }

  /// 1. Affichage immediat (quelques lectures) ; 2. entretien de fond juste
  /// apres, sans faire attendre l'ecran ; on ne rafraichit que s'il a change
  /// quelque chose (ex : la nouvelle echeance de la semaine).
  Future<void> _chargerUneFois() async {
    await _afficher();
    if (await _entretenir() && mounted) await _afficher();
  }

  /// Entretien des echeances : statuts en retard, fenetre d'echeances a
  /// venir, regles d'argent (normaliser), rappels. true si les echeances ont
  /// change. (Le retard affiche se calcule sur les dates : le statut "en
  /// retard" n'y change rien.)
  Future<bool> _entretenir() async {
    await _db.actualiserRetards();
    final params = await _db.obtenirParametres();
    final motos = await _db.listerMotos();
    var change = false;
    // Rappels deja programmes : lus une seule fois pour toutes les motos.
    final rappels = await NotificationService.rappelsEnAttente();
    for (final m in motos.where((m) => m.statut == AppConstants.motoActive)) {
      if (await NotificationService.assurerEcheancesEtRappels(m,
          enAttente: rappels, delaiHeures: params.delaiNotificationHeures)) {
        change = true;
      }
    }
    // Les motos hors service suivent les memes regles d'argent (doublons,
    // trop-payes) ; les actives le font dans assurerEcheances.
    for (final m in motos.where((m) => m.statut != AppConstants.motoActive && m.id != null)) {
      if (await _db.normaliser(m.id!)) change = true;
    }
    return change;
  }

  Future<void> _afficher() async {
    final bornes = _bornesPeriode;
    final params = await _db.obtenirParametres();
    final motos = await _db.listerMotos();
    final totalEncaisse = await _db.totalEncaisse(
      motoId: _motoFiltreId,
      debut: bornes.debut,
      fin: bornes.fin,
    );
    // Retard compte moto par moto : l'avance de l'une ne compense pas le
    // retard d'une autre ; une moto suspendue garde ses retards d'avant la pause.
    // Une seule passe pour toutes les motos (retard/avance, prochain, encaisse).
    final etats = await _db.etatsMotos();
    final comptes = {
      for (final e in etats.entries)
        if (_motoFiltreId == null || e.key == _motoFiltreId) e.key: e.value.compte,
    };

    final paiementsRecents = await _db.listerPaiementsRecents(
      motoId: _motoFiltreId,
      debut: bornes.debut,
      fin: bornes.fin,
      limite: 15,
    );
    final depensesRecentes = await _db.listerDepensesRecentes(
      motoId: _motoFiltreId,
      debut: bornes.debut,
      fin: bornes.fin,
      limite: 15,
    );
    final remboursementsRecents = await _db.listerRemboursementsMotos(
      motoId: _motoFiltreId,
      debut: bornes.debut,
      fin: bornes.fin,
      limite: 15,
    );
    final infosMotos = [
      for (final m in motos)
        if (m.id != null && etats[m.id] != null)
          _MotoAvecInfos(
              moto: m, totalVerse: etats[m.id]!.encaisse, compte: etats[m.id]!.compte, prochain: etats[m.id]!.prochain),
    ];

    final motosParId = {for (final m in motos) m.id: m};
    final categories = {for (final c in await _db.listerCategories()) c.id: c};

    final activites = <_ActiviteRecente>[
      ...paiementsRecents.map(
            (p) => _ActiviteRecente(
              titre: 'Versement - ${motosParId[p.motoId]?.nom ?? 'Moto'} - '
                  '${motosParId[p.motoId]?.chauffeur ?? ''}',
              date: p.date,
              montant: p.montant,
              estPositif: true,
              icone: Icons.check_circle_outline,
              motoId: p.motoId,
            ),
          ),
      ...depensesRecentes.map(
        (d) => _ActiviteRecente(
          titre: 'Depense - ${categories[d.categorieId]?.nom ?? 'Depense'} - '
              '${motosParId[d.motoId]?.nom ?? ''} - ${motosParId[d.motoId]?.chauffeur ?? ''}',
          date: d.date,
          montant: d.montant,
          estPositif: false,
          icone: Icons.build_outlined,
          motoId: d.motoId,
        ),
      ),
      // Encaisse dans la caisse de la moto liee (voir totalEncaisse).
      ...remboursementsRecents.map(
        (e) => _ActiviteRecente(
          titre: 'Remboursement dette - ${e.dette.nomPersonne} - ${motosParId[e.dette.lienId]?.nom ?? ''}',
          date: e.remboursement.date,
          montant: e.remboursement.montant,
          estPositif: true,
          icone: Icons.request_page_outlined,
          motoId: e.dette.lienId,
        ),
      ),
    ]..sort((a, b) => b.date.compareTo(a.date));

    if (!mounted) return;
    setState(() {
      _parametres = params;
      _motos = motos;
      _totalEncaisse = totalEncaisse;
      _totalEnRetard = comptes.values.fold(0.0, (total, c) => total + c.retard);
      // "A jour" : parmi les motos en service.
      _motosAJour = motos
          .where((m) => m.statut == AppConstants.motoActive && (comptes[m.id]?.retard ?? 0) == 0)
          .length;
      _activites = activites.take(10).toList();
      _infosMotos = infosMotos;
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
      // Spinner au tout premier chargement seulement : ensuite les donnees se
      // rafraichissent sous les yeux, sans detruire l'onglet ouvert.
      body: SafeArea(child: _parametres == null ? const Center(child: CircularProgressIndicator()) : pages[_ongletActif]),
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
          final venaitDAilleurs = _ongletActif > 1;
          setState(() => _ongletActif = i);
          // Accueil et Motos montrent les memes donnees : on ne recharge qu'en y
          // revenant depuis Depenses / Reglages (qui ont pu les changer).
          if (i <= 1 && venaitDAilleurs) _charger();
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
                  onTap: a.motoId == null
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => MotoDetailScreen(motoId: a.motoId!)),
                          );
                          _charger();
                        },
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
                child: _miniStat('A jour', '$_motosAJour moto(s)', AppColors.accentLime),
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

    // Infos calculees une fois dans _charger : la recherche et le tri ne
    // relancent plus de requetes a chaque lettre tapee.
    final toutesLesMotos = _infosMotos;
    final items = _filtrerEtTrierMotos(toutesLesMotos);

    return RefreshIndicator(
      onRefresh: _charger,
      child: toutesLesMotos.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 80),
                Center(
                  child: Text('Aucune moto pour le moment.\nAppuyez sur + pour en ajouter une.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.texteGris, fontSize: 13)),
                ),
              ],
            )
          : ListView(
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
                          compte: item.compte,
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
        // Les plus en retard d'abord (une avance ne compense pas un retard).
        items.sort((a, b) => b.compte.retard.compareTo(a.compte.retard));
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

}

class _ActiviteRecente {
  final String titre;
  final DateTime date;
  final double montant;
  final bool estPositif;
  final IconData icone;
  /// Permet de rendre la ligne cliquable vers le detail de la moto
  /// concernee (versement ou depense).
  final int? motoId;

  _ActiviteRecente({
    required this.titre,
    required this.date,
    required this.montant,
    required this.estPositif,
    required this.icone,
    this.motoId,
  });
}

class _MotoAvecInfos {
  final Moto moto;
  final double totalVerse;
  final CompteMoto compte;
  final ({DateTime date, String etat, double reste})? prochain;

  _MotoAvecInfos({
    required this.moto,
    required this.totalVerse,
    required this.compte,
    required this.prochain,
  });
}
