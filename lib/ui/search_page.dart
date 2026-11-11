import 'package:flutter/material.dart';

import 'geocoder.dart';

/// Что выбрал пользователь на экране поиска.
class SearchResult {
  final Place? place;
  final bool myLocation, demo;
  const SearchResult.place(Place this.place)
      : myLocation = false,
        demo = false;
  const SearchResult.myLocation()
      : place = null,
        myLocation = true,
        demo = false;
  const SearchResult.demo()
      : place = null,
        myLocation = false,
        demo = true;
}

/// Полноэкранный поиск адреса, как в Google Картах.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.geocoder, required this.hint, this.forStart = false, this.initial = ''});
  final Geocoder geocoder;
  final String hint, initial;
  final bool forStart;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _ctl = TextEditingController(text: widget.initial);
  List<Place> _results = const [];
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final r = await widget.geocoder.search(q);
      if (!mounted) return;
      setState(() {
        _results = r;
        _message = r.isEmpty ? 'Ничего не найдено в странах Евросоюза' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _message = 'Поиск недоступен: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(28),
              color: scheme.surface,
              child: Row(children: [
                IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(hintText: widget.hint, border: InputBorder.none),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ]),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: ListView(children: [
              if (widget.forStart)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.my_location)),
                  title: const Text('Моё местоположение'),
                  onTap: () => Navigator.pop(context, const SearchResult.myLocation()),
                ),
              for (final p in _results)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.place_outlined)),
                  title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, SearchResult.place(p)),
                ),
              if (_message != null) Padding(padding: const EdgeInsets.all(16), child: Text(_message!)),
              if (_results.isEmpty && !widget.forStart) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Введите адрес или координаты и нажмите на лупу. Навигация работает по странам Евросоюза.'),
                ),
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.route)),
                  title: const Text('Демо-маршрут'),
                  subtitle: const Text('Работает без интернета'),
                  onTap: () => Navigator.pop(context, const SearchResult.demo()),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
