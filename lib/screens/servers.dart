part of '../main.dart';

// ============================ SERVERS ============================
extension ShellServers on ShellState {
  Widget _servers() {
    // Честные цифры из реальных данных (models.dart), а не выдуманные «32 / 12 / 99.9%»:
    // считаем реально доступные серверы и их локации (города). Зарубежные (available:false) не в счёт.
    final avail = fleet.where((s) => s.available).toList();
    final locations = avail.map((s) => s.city).toSet().length;
    // Пока туннель поднимается (conn==1) или идёт горячая смена, выбор сервера закрыт —
    // показываем тонкий inline-хинт и приглушаем некликабельные-сейчас строки (текущий сервер
    // остаётся читаемым). При ЖИВОМ туннеле на десктопе смена идёт без разрыва (hot-switch) —
    // строки кликабельны, подсказываем это явно.
    final locked = conn == 1 || hotSwitching;
    return RefreshIndicator(
      color: C.accent,
      backgroundColor: C.bg2,
      // pull-to-refresh: свежие узлы подписки без перелогина (новые серверы появляются сами)
      onRefresh: _loadNodes,
      child: ListView(
        // AlwaysScrollable: pull-to-refresh обязан работать и на коротком списке
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(tr('Серверы'), style: disp(26, w: FontWeight.w800)),
          const SizedBox(height: 18),
          // IntrinsicHeight + stretch: плитки одной высоты (тексты в 1 и 2 строки давали рваные края)
          IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _infoTile('${avail.length}', appLang == 'en'
                ? (avail.length == 1 ? 'server\navailable' : 'servers\navailable')
                : '${_ruPlural(avail.length, 'сервер', 'сервера', 'серверов')}\nдоступно')),
            const SizedBox(width: 12),
            Expanded(child: _infoTile('$locations', appLang == 'en'
                ? (locations == 1 ? 'location' : 'locations')
                : _ruPlural(locations, 'локация', 'локации', 'локаций'))),
          ])),
          const SizedBox(height: 16),
          // Кнопка «Пинг»: живой замер отклика по всем доступным серверам (_pingServers в api.dart).
          // Работает и при поднятом туннеле — тогда замер идёт сквозь него (с фолбэком на живые
          // пинги observatory); приговоры «пропускает ли узел трафик напрямую» при этом не пишутся.
          // Semantics: во время замера кнопка неактивна — сообщаем это и скринридеру.
          Semantics(
            button: true,
            enabled: !_pinging,
            label: tr('Проверить серверы'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pinging ? null : _pingServers,
              child: _card(strong: true, child: Row(children: [
                _gIcon(Icons.network_ping),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Проверить серверы'), style: disp(16, w: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(_pinging
                          ? (pingTotal > 0
                              ? (appLang == 'en' ? 'checked $pingDone of $pingTotal…' : 'готово $pingDone из $pingTotal…')
                              : tr('проверяю, где идёт трафик…'))
                          : conn != 0
                              ? tr('замер сквозь активный туннель')
                              : tr('проверить, через какие серверы реально идёт трафик'),
                      style: mono(12)),
                ])),
                _pinging
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
                    : Icon(Icons.play_arrow, color: C.accent),
              ])),
            ),
          ),
          // Список поднят из кэша (выдача недоступна — сеть в режиме «белых списков»):
          // пометка обязана быть на экране, молча показывать старый список как свежий нельзя.
          if (subCacheAt != null && fleet.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.cloud_off_outlined, size: 14, color: C.muted),
              const SizedBox(width: 6),
              Flexible(child: Text(
                appLang == 'en'
                    ? 'Server list is from cache (${_cacheDate(subCacheAt!)}) — the network is restricted, will refresh as soon as the service is reachable'
                    : 'Список серверов из кэша от ${_cacheDate(subCacheAt!)} — сеть ограничена, обновлю, как только выдача станет доступна',
                style: mono(12, c: C.muted))),
            ]),
          ],
          if (locked) ...[
            const SizedBox(height: 16),
            Row(children: [
              Icon(hotSwitching ? Icons.swap_calls : Icons.lock_outline, size: 14, color: C.muted),
              const SizedBox(width: 6),
              Flexible(child: Text(
                hotSwitching
                    ? (appLang == 'en'
                        ? 'Switching to ${tr(hotSwitchTarget)}…'
                        : 'Переключаюсь на ${tr(hotSwitchTarget)}…')
                    : tr('Отключись, чтобы сменить сервер'),
                style: mono(12))),
            ]),
          ] else if (conn == 2 && TunnelEngine.kind() == EngineKind.desktopXray) ...[
            const SizedBox(height: 16),
            Row(children: [
              Icon(Icons.swap_calls, size: 14, color: C.muted),
              const SizedBox(width: 6),
              Flexible(child: Text(tr('нажми на сервер — переключусь без разрыва'), style: mono(12))),
            ]),
          ],
          const SizedBox(height: 22),
          ..._serverSections(locked),
          const SizedBox(height: 22),
          _nodeStatsBlock(),
        ],
      ),
    );
  }

  // ── «Доступность за 48 часов»: публичная статистика нод (node_stats.dart) ──
  Widget _nodeStatsBlock() {
    final rep = nodeStats;
    // Сбой сети (под «белыми списками» origin мёртв — это норма) — честная строка,
    // страница не ломается; при первой загрузке — нейтральный «Минутку…».
    if (rep == null || rep.nodes.isEmpty) {
      return _card(child: Row(children: [
        Icon(Icons.show_chart, size: 15, color: C.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(
          '${appLang == 'en' ? 'Availability · 48h' : 'Доступность за 48 часов'} · '
          '${nodeStatsFailed ? tr('данные недоступны') : tr('Минутку…')}',
          style: mono(12, c: C.muted))),
      ]));
    }
    var age = DateTime.now().difference(rep.generatedAt.toLocal());
    if (age.isNegative) age = Duration.zero; // часы на устройстве спешат — не показываем «будущее»
    final m = age.inMinutes;
    final ago = m < 1
        ? tr('только что')
        : appLang == 'en'
            ? '$m min ago'
            : '${_ruPlural(m, 'минуту', 'минуты', 'минут')} назад';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _kicker(appLang == 'en'
          ? 'availability · 48h · updated $ago'
          : 'доступность за 48 часов · обновлено $ago'),
      const SizedBox(height: 10),
      for (final n in rep.nodes) _nodeStatRow(n),
    ]);
  }

  Widget _nodeStatRow(NodeStat n) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final points = sparkPoints(n.series,
        buckets: kSparkHours, fromSec: nowSec - kSparkHours * 3600, toSec: nowSec);
    // Линия — акцент АКТИВНОЙ темы (неоново-оранжевый в Sunset), на светлой — затемнённый по
    // правилу accentSoftInk; при смене темы/палитры перекрашивается пересборкой (цвет не
    // кэшируется — считается на каждый build). Статус ноды — только точка у имени (ok/danger).
    final color = sparkColor(C.accent, light: C.light);
    // Имя как у узла подписки («🇫🇮 Финляндия» / «🛡️ … · LTE»): флаг отделяем, хвост рельсы
    // убираем — иначе название не находится в словаре стран (как в serverFromSubNode).
    final parts = n.name.trim().split(' ');
    final flag = parts.isNotEmpty ? parts.first : '🌐';
    var title = parts.length > 1 ? parts.sublist(1).join(' ') : n.name;
    title = title.replaceFirst(RegExp(r'\s*·\s*(LTE|БС|CDN)\s*$', caseSensitive: false), '');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: C.fill, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.line)),
      child: Row(children: [
        Text(flag, style: const TextStyle(fontSize: 15)),
        const SizedBox(width: 8),
        Container(width: 7, height: 7,
            decoration: BoxDecoration(color: n.ok ? C.ok : C.danger, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(tr(title), style: disp(13, w: FontWeight.w600),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        Text(n.rttNow != null ? '${n.rttNow} ms' : '—', style: mono(11, c: C.muted)),
        const SizedBox(width: 10),
        SizedBox(width: 96, height: 26,
            child: CustomPaint(painter: SparklinePainter(points, color))),
      ]),
    );
  }

  // Русские склонения для счётчиков плиток: 1 сервер / 2-4 сервера / 5+ серверов
  // (тот же алгоритм, что _pluralDays в account.dart).
  String _ruPlural(int n, String one, String few, String many) {
    final n10 = n % 10, n100 = n % 100;
    if (n10 == 1 && n100 != 11) return one;
    if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few;
    return many;
  }

  // Дата кэша выдачи для пометки «список из кэша от …» — локальное время, dd.mm.yyyy hh:mm.
  String _cacheDate(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = at.toLocal();
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  // Секция сортируется общим компаратором compareServers (как «лучший сервер» на Главной):
  // рабочие впереди непроверенных, незамеренные (пинг 0) — в конец, а не в топ списка;
  // во время замера «Пинг» строки пересортировываются на лету (rebuild в _pingServers).
  List<Server> _byPing(Iterable<Server> src) {
    final l = src.toList();
    l.sort(_betterServer);
    return l;
  }

  List<Widget> _serverSections(bool locked) {
    final all = fleet;
    final favList = _byPing(all.where((s) => favs.contains(s.id)));
    // Узлы «белого списка» (через CDN) показываем отдельной группой: они нужны, когда прямые
    // адреса недоступны, но обычно медленнее — пользователю честнее видеть это разделение.
    final direct = _byPing(all.where((s) => !s.proto.startsWith('LTE')));
    final bs = _byPing(all.where((s) => s.proto.startsWith('LTE')));
    return [
      if (favList.isNotEmpty) ...[
        _kicker(tr('⭐ избранное')),
        const SizedBox(height: 10),
        for (final s in favList) _serverRow(s, locked),
        const SizedBox(height: 22),
      ],
      if (direct.isNotEmpty) ...[
        _kicker(tr('прямые серверы')),
        const SizedBox(height: 10),
        for (final s in direct) _serverRow(s, locked),
      ],
      if (bs.isNotEmpty) ...[
        const SizedBox(height: 22),
        _kicker(tr('анти-глушилка · CDN')),
        const SizedBox(height: 10),
        for (final s in bs) _serverRow(s, locked),
      ],
      // Пустой список объясняем: чаще всего это занятый лимит устройств или истёкшая подписка,
      // и человек должен видеть причину прямо здесь, а не гадать.
      if (all.isEmpty) _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Текст от сервиса выдачи приходит по-русски — прогоняем через tr(), иначе в английском
        // интерфейсе он остался бы русским.
        Text(tr(subNotice ?? 'Войди в аккаунт — здесь появятся твои серверы'),
            style: disp(15, w: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          !loggedIn
              ? tr('Список серверов приходит вместе с подпиской.')
              // сверяем с РУССКИМ оригиналом: сервис отвечает на русском независимо от языка приложения
              : (subNotice ?? '').contains('Лимит')
                  ? tr('Отключи лишнее устройство в «Кабинете» или расширь лимит — и серверы появятся.')
                  : tr('Проверь подписку в «Кабинете» и обнови список.'),
          style: mono(12.5, c: C.muted)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _btn(tr('Обновить'), kind: 1, icon: Icons.refresh,
              onTap: _subVisibleLoading ? null : () => _refreshSub())),
          const SizedBox(width: 12),
          Expanded(child: _btn(tr('Кабинет'), kind: 0, icon: Icons.person_outline, onTap: () => _goTab(2))),
        ]),
      ])),
    ];
  }

  Widget _serverRow(Server s, bool locked) {
    final sel = s.id == server.id;
    final ping = pingOf(s);
    final st = stateOf(s.id);
    // Число показываем только за честный замер: сквозная проверка узла (приговор «работает»),
    // а при поднятом туннеле — ещё замер кнопкой сквозь туннель и живой пинг observatory
    // (pingOf уже подмешал его узлам без ручного замера). Раньше здесь стоял TCP-коннект до
    // адреса: при глушении интернета он проходит, а трафик — нет, и человек видел зелёный
    // отклик у сервера, через который ничего не грузится.
    final measured = st == NodeState.works ? ping > 0 : (conn == 2 && ping > 0);
    final pingCol = st == NodeState.blocked
        ? C.danger
        : !measured ? C.muted : ping < 60 ? C.ok : ping < 120 ? C.warn : C.danger;
    final pingLabel = switch (st) {
      NodeState.blocked => tr('через этот сервер трафик не идёт'),
      // «не проверен» — только без единого числа; живой пинг observatory оцениваем как обычный
      _ when !measured => tr('не проверен'),
      _ => ping < 60 ? tr('быстрый отклик') : ping < 120 ? tr('средний отклик') : tr('медленный отклик'),
    };
    // При locked (conn!=0) все строки кроме текущего сервера некликабельны-сейчас → приглушаем их,
    // чтобы список не выглядел обманчиво активным. Текущий сервер (sel) оставляем читаемым.
    final dimmed = (locked && !sel) || !s.available;
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      // Semantics: строка — кнопка выбора сервера с признаком выбора (как кнопка «Пинг» выше);
      // лейбл (город/страна/пинг) собирается из дочерних текстов автоматически.
      child: Semantics(
        button: true,
        selected: sel,
        enabled: s.available,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Недоступную строку раньше глушил IgnorePointer — тап проваливался в тишину. Тап
          // отдаём всегда: _pickServer сам объяснит и «сервер пока недоступен», и «сначала отключись».
          onTap: () => _pickServer(s),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(color: C.fill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sel ? C.accent.withValues(alpha: 0.5) : C.line)),
            child: Row(children: [
              Container(width: 40, height: 40, alignment: Alignment.center,
                decoration: BoxDecoration(color: C.fill, borderRadius: BorderRadius.circular(12)),
                child: Text(s.flag, style: const TextStyle(fontSize: 20))),
              const SizedBox(width: 12),
              // Город — отдельной строкой (на окне 390px бейджи в одной строке с городом
              // схлопывали его до «А…»), бейджи — к строке страны: PRO и «скоро» для строк,
              // которые выбрать пока нельзя (без бейджа приглушённая строка выглядела просто
              // блёклой, и человек жал её впустую).
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(s.city), style: disp(15, w: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(children: [
                  // У узлов подписки поля «страна» нет (название узла — уже страна), и строка
                  // оставалась пустой. Пишем рельсу: в «⭐ избранном» прямые узлы и узлы через
                  // CDN лежат вперемешку без заголовков групп, и отличить их иначе нечем.
                  Flexible(child: Text(
                    s.country.isNotEmpty ? tr(s.country)
                      : tr(s.proto.startsWith('LTE') ? 'через CDN' : 'прямой узел'),
                    style: mono(12), overflow: TextOverflow.ellipsis)),
                  if (s.premium) ...[const SizedBox(width: 6), _badge('PRO', accentSoftInk)],
                  if (st == NodeState.blocked) ...[const SizedBox(width: 6), _badge(tr('не работает'), C.danger)]
                  else if (!s.available) ...[const SizedBox(width: 6), _badge(tr('скоро'), C.muted)],
                ]),
              ])),
              Tooltip(message: measured ? '$pingLabel · $ping ms' : pingLabel,
                child: Text(st == NodeState.blocked ? '✕' : measured ? '$ping ms' : '—',
                    style: mono(13, c: pingCol, w: FontWeight.w600))),
              // Нагрузку узла подписка не сообщает — «0 %» с пустой полоской читались как
              // «сервер совершенно свободен». Показываем колонку, только когда число настоящее.
              if (s.load > 0) ...[
                const SizedBox(width: 10),
                Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${s.load}%', style: mono(10, c: C.muted)),
                  const SizedBox(height: 3),
                  SizedBox(width: 42, child: _loadBar(s.load)),
                ]),
              ],
              const SizedBox(width: 2),
              // Тап-таргет звезды ≥40px (было 18px — слишком мелко для касания)
              IconButton(
                onPressed: () { rebuild(() => favs.contains(s.id) ? favs.remove(s.id) : favs.add(s.id)); _save(); },
                iconSize: 19,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                splashRadius: 22,
                tooltip: tr('избранное'),
                icon: Icon(favs.contains(s.id) ? Icons.star : Icons.star_border,
                  color: favs.contains(s.id) ? accentSoftInk : C.muted)),
              const SizedBox(width: 2),
              Icon(sel ? Icons.check_circle : Icons.circle_outlined, size: 20, color: sel ? C.accent : C.muted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Спарклайн доступности ноды за 48 часов: линия по нормализованным точкам (sparkPoints),
/// мёртвые промежутки (null) — разрыв, под линией заливка тем же цветом с альфой ~16%.
/// Цвет приходит снаружи (акцент активной темы — см. sparkColor), painter тупой и ничего
/// не кэширует: смена темы перекрашивает график ближайшей пересборкой.
class SparklinePainter extends CustomPainter {
  SparklinePainter(this.points, this.color);
  final List<double?> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final alive = points.whereType<double>().toList();
    if (alive.isEmpty || size.width <= 0 || size.height <= 0) return;
    final lo = alive.reduce(math.min);
    final hi = alive.reduce(math.max);
    final span = (hi - lo) < 1 ? 1.0 : (hi - lo); // почти ровная линия — не растягиваем шум
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..style = PaintingStyle.fill;
    final n = points.length;
    double x(int i) => n == 1 ? size.width / 2 : size.width * i / (n - 1);
    double y(double v) => size.height - 2 - (v - lo) / span * (size.height - 4);
    // Разрывы делят линию на сегменты: заливка и штрих рисуются посегментно, чтобы мёртвые
    // промежутки оставались честными пустотами, а не «провисшими» соединениями.
    final line = Path();
    var pen = false; // false → следующая живая точка начинает новый сегмент (разрыв)
    var segStart = 0;
    void closeSegment(int endExclusive) {
      if (!pen) return;
      // заливка сегмента: вниз к нижней кромке и назад
      final f = Path()
        ..moveTo(x(segStart), y(points[segStart]!));
      for (var j = segStart + 1; j < endExclusive; j++) {
        f.lineTo(x(j), y(points[j]!));
      }
      f
        ..lineTo(x(endExclusive - 1), size.height)
        ..lineTo(x(segStart), size.height)
        ..close();
      canvas.drawPath(f, fill);
    }
    for (var i = 0; i < n; i++) {
      final v = points[i];
      if (v == null) {
        closeSegment(i);
        pen = false;
        continue;
      }
      if (!pen) {
        line.moveTo(x(i), y(v));
        segStart = i;
        pen = true;
      } else {
        line.lineTo(x(i), y(v));
      }
    }
    closeSegment(n);
    canvas.drawPath(line, stroke);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.points != points || old.color != color;
}
