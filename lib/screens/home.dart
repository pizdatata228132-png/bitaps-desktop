part of '../main.dart';

// ============================ HOME (статус / подключение) ============================
extension ShellHome on ShellState {
  // Честная подпись охвата защиты: на телефоне туннель забирает весь трафик устройства,
  // на десктопе поднимается системный прокси — под защитой браузеры и приложения, которые
  // его уважают. Обещать «весь трафик» там, где это неправда, нельзя.
  String _protectionScope() => TunnelEngine.kind() == EngineKind.desktopXray
      ? tr('под защитой — браузеры и приложения с системным прокси')
      : tr('под защитой');

  // ---------------- HOME ----------------
  Widget _home() {
    final connected = conn == 2;
    // Серия автопереподключения идёт: ждём паузу (conn == 0, тикает таймер) или прямо сейчас
    // подключаемся из серии (conn == 1 с номером попытки). Человек обязан это видеть — иначе
    // пауза между попытками выглядит мёртвым «Отключено».
    final reconnecting = conn == 1 ? _conn.reconnectAttempt > 0 : _conn.reconnecting;
    final attemptLine = appLang == 'en'
        ? 'reconnecting, attempt ${_conn.reconnectAttempt}'
        : 'переподключение, попытка ${_conn.reconnectAttempt}';
    // Автоперебор (режим «лучший сервер»): какой кандидат на пробе и который он по счёту.
    // Название сервера — через tr(): это страна из выдачи, она есть в словаре kCountryEn.
    final tryLine = appLang == 'en'
        ? 'trying ${tr(_conn.tryServer)}… (${_conn.tryAttempt})'
        : 'пробуем ${tr(_conn.tryServer)}… (${_conn.tryAttempt})';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        // Flexible+FittedBox: на узких телефонах (360px) логотип и пилюля статуса вместе не
        // помещались, и правый край пилюли обрезался. Теперь при нехватке места они ужимаются.
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _logo())),
          const SizedBox(width: 8),
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: _shieldPill(connected))),
        ]),
        const SizedBox(height: 10),
        Center(child: _powerButton()),
        const SizedBox(height: 4),
        Center(child: Text(
          // в демо (kRealTunnel=false) НЕ заявляем «Подключено/под защитой» — реального туннеля нет;
          // при сработавшем килл-свитче — не «Отключено» (это читалось бы как «интернет прямой»),
          // а факт блокировки: прокси нарочно не снят, трафик не идёт никуда (fail-closed)
          // «Подключение…» важнее «Трафик заблокирован»: при реконнекте ИЗ блокировки blocked
          // остаётся true всю попытку (см. toggle в connection.dart), и без этого приоритета
          // человек не видел бы, что подключение вообще идёт. «Переподключение…» в ожидании
          // таймера — тоже важнее блокировки: карточка килл-свитча при этом остаётся на месте.
          conn == 1 ? tr('Подключение…')
              : reconnecting ? tr('Переподключение…')
              : connBlocked ? tr('Трафик заблокирован')
              : conn == 0 ? tr('Отключено')
              : (gEngineReal ? tr('Подключено') : tr('Демо-режим')),
          style: disp(22, w: FontWeight.w700, c: connected ? C.accent : (conn == 1 || reconnecting || connBlocked ? C.warn : C.text)))),
        const SizedBox(height: 6),
        Center(child: Text(connected ? hms : '00:00:00',
          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 38, fontWeight: FontWeight.w700,
            color: connected ? C.accentSoft : C.muted, letterSpacing: 2))),
        const SizedBox(height: 4),
        Center(child: Text(
          conn == 1 ? (reconnecting ? attemptLine : (_conn.tryAttempt > 0 ? tryLine : tr('устанавливаем соединение…')))
              : reconnecting ? attemptLine
              : connBlocked ? tr('VPN отвалился — килл-свитч не пускает трафик напрямую')
              : conn == 0 ? tr('нажми на кнопку')
              : (gEngineReal ? _protectionScope() : tr('демо — без реального туннеля')),
          style: mono(12))),
        // Сработавший килл-свитч важнее обычной карточки причины: показываем его карточку —
        // с кнопкой «Снять блокировку» (единственный путь снять прокси без нового подключения).
        if (conn == 0 && connBlocked) ...[
          const SizedBox(height: 18),
          _killSwitchCard(),
        ] else if (conn == 0 && connFail != null) ...[
          // Причина неудачи живёт на экране до следующей попытки — вместе с кнопкой «что делать».
          // Раньше причина уходила с тостом за три секунды, и оставалось «нажал — ничего не произошло».
          const SizedBox(height: 18),
          _connFailCard(connFail!, connFix),
        ],
        const SizedBox(height: 20),
        Row(children: [
          for (int i = 0; i < 4; i++)
            Expanded(child: Padding(padding: EdgeInsets.only(right: i < 3 ? 8 : 0), child: _modeChip(modeLabels[i], i))),
        ]),
        const SizedBox(height: 10),
        Text(tr('Режим подбирает сервер: Авто/Игры — минимальный отклик, Стрим — наименьшая нагрузка, Прив. — самый быстрый узел.'), style: mono(12)),
        const SizedBox(height: 14),
        _card(child: Row(children: [
          Text(server.flag, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(server.id.isEmpty ? tr('сервер не выбран') : tr(server.city), style: disp(16, w: FontWeight.w700)),
            const SizedBox(height: 2),
            // Узлов ещё нет (id пуст) — рядом с прочерком стояло «Reality», и карточка читалась
            // как выбранный, но неисправный сервер. До замера отклика числа тоже нет: «0 ms»
            // читалось как «мгновенный сервер» — та же выдумка, что и вычищенные отсюда города.
            Text(server.id.isEmpty
                    ? tr('появится вместе с подпиской')
                    : pingOf(server) > 0 ? '${pingOf(server)} ms · ${server.proto}' : server.proto,
                style: mono(12)),
          ])),
          // Semantics: «сменить» — кнопка (лейбл читается из дочернего текста, merge — одним узлом)
          Semantics(
            button: true,
            child: MergeSemantics(child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _goTab(1),
              child: Row(children: [
                Icon(Icons.swap_horiz, size: 17, color: C.accent),
                const SizedBox(width: 5),
                Text(tr('сменить'), style: disp(13, w: FontWeight.w700, c: C.accent)),
              ]),
            )),
          ),
        ])),
        const SizedBox(height: 12),
        _card(padding: 13, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('↓', style: disp(15, c: C.muted)),
            const SizedBox(width: 5),
            Text(connected ? _fmtSpeed(down) : '—', style: mono(13, c: C.text, w: FontWeight.w600)),
            const SizedBox(width: 16),
            Text('↑', style: disp(15, c: C.muted)),
            const SizedBox(width: 5),
            Text(connected ? _fmtSpeed(up) : '—', style: mono(13, c: C.text, w: FontWeight.w600)),
            const Spacer(),
            Icon(Icons.language, size: 15, color: C.muted),
            const SizedBox(width: 6),
            // В боевом режиме (kRealTunnel) реального канала IP из движка нет → не показываем
            // выдуманный статичный адрес (иначе юзер увидел бы неверный IP без пометки «демо»).
            // Демо-IP светим только в демо-режиме, где рядом стоит дисклеймер. Отключённому
            // пользователю IP-строку не подписываем «IP скрыт» (это было бы ложью) — прочерк,
            // согласованный с плейсхолдерами скорости в этой же строке.
            Text(!connected ? '—' : (gEngineReal ? tr('IP скрыт') : '95.142.16.7'), style: mono(12)),
          ]),
          // Честно: без боевого туннеля скорость/трафик/IP — демонстрационные.
          if (connected && !gEngineReal) ...[
            const SizedBox(height: 8),
            Text(tr('Демо-режим — скорость и IP показаны для примера'), style: mono(10, c: C.muted)),
          ],
          // Пока не подключены — прочерки без пояснения непонятны: подсказываем, что цифры появятся после коннекта.
          if (!connected) ...[
            const SizedBox(height: 8),
            Text(tr('Скорость появится после подключения'), style: mono(10, c: C.muted)),
          ],
        ])),
        const SizedBox(height: 12),
        // Ползунок режима «лучший сервер»: подключение само берёт оптимальный под режим сервер
        // (toggle() в main.dart). Выбор конкретного сервера в списке выключает режим (_pickServer),
        // тап по чипу режима — включает обратно (_modeChip). Тап по всей плашке = тот же переключатель;
        // excludeFromSemantics — чтобы у скринридера не было второго безымянного tap-узла рядом
        // с merged-переключателем (сам паттерн MergeSemantics — как у _toggle в settings.dart).
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () => _setBestServer(!bestServer),
          child: _card(child: MergeSemantics(child: Row(children: [
            _gIcon(Icons.bolt),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Подключаться к лучшему серверу'), style: disp(15, w: FontWeight.w600)),
              const SizedBox(height: 2),
              // «оптимальный под режим», а не «быстрейший»: serverForMode для Стрим берёт минимальную
              // нагрузку, для Прив. — зарубежный; «быстрейший» в подписи противоречил бы карточке режимов
              Text(bestServer ? tr('при подключении сам возьму оптимальный под режим') : tr('выключено — сервер выбираешь ты'),
                style: mono(11)),
            ])),
            const SizedBox(width: 8),
            // activeTrackColor от текущего акцента: дефолтный трек красится colorScheme.primary,
            // который не пересобирается при смене акцента (ThemeData слушает только яркость).
            Switch(value: bestServer, activeThumbColor: C.accent, activeTrackColor: C.accent.withValues(alpha: 0.35), onChanged: _setBestServer),
          ]))),
        ),
        const SizedBox(height: 10),
        // «Авто-подключение» (30.08, владелец: вынесено из Настроек под автовыбор сервера):
        // один тумблер = держать VPN всегда включённым. Внутри себя включает авто-подключение
        // при запуске, авто-ПЕРЕподключение при обрыве и автостарт после перезагрузки устройства
        // (Android — BootReceiver, десктоп — запуск с системой).
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () => _setAlwaysOnHome(!alwaysOn),
          child: _card(child: MergeSemantics(child: Row(children: [
            _gIcon(Icons.all_inclusive),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Авто-подключение'), style: disp(15, w: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(alwaysOn
                  ? tr('VPN будет работать постоянно — даже после перезагрузки устройства')
                  : tr('выключено — подключать вручную'),
                style: mono(11)),
            ])),
            const SizedBox(width: 8),
            Switch(value: alwaysOn, activeThumbColor: C.accent, activeTrackColor: C.accent.withValues(alpha: 0.35), onChanged: _setAlwaysOnHome),
          ]))),
        ),
      ],
    );
  }

  // Карточка fail-closed: VPN отвалился при включённом килл-свитче, трафик заблокирован
  // (системный прокси нарочно не снят). Видна сразу на Главной — до неё не нужно идти в
  // Настройки. «Снять блокировку» — единственный путь вернуть прямой интернет без реконнекта;
  // повторное подключение большой кнопкой тоже снимает блокировку (см. toggle в connection.dart).
  // Геометрия — как у _connFailCard/_updateBanner (16/14, радиус 14, иконка 20, gap 12).
  Widget _killSwitchCard() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: C.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.danger.withValues(alpha: 0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.gpp_bad_outlined, size: 20, color: C.danger),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('VPN отвалился — трафик заблокирован'), style: disp(14, w: FontWeight.w700, c: C.danger)),
              const SizedBox(height: 3),
              Text(
                // причина обрыва от движка + пояснение, что блокировка — сработавший
                // килл-свитч, а не «сломался интернет». tr() к причине — как в _connFailCard.
                '${connFail != null && connFail!.isNotEmpty ? '${tr(connFail!)}\n' : ''}'
                '${tr('Килл-свитч держит прокси включённым: интернет не пойдёт мимо туннеля. Сними блокировку или подключись снова.')}',
                style: mono(11.5, c: C.muted)),
            ])),
          ]),
          const SizedBox(height: 12),
          _btn(tr('Снять блокировку'), kind: 1, icon: Icons.lock_open, onTap: () => _conn.unblock()),
        ]),
      );

  // Карточка «почему не подключилось»: причина + одно конкретное действие под неё.
  // Геометрия и цвета — как у _updateBanner/_expiryBanner (16/14, радиус 14, иконка 20, gap 12),
  // только предупреждающим цветом. Текст причины гоняем через tr(): часть строк прилетает
  // исключениями движка и сервиса выдачи, они переводятся в момент показа (как в _toast).
  Widget _connFailCard(String msg, ConnFix fix) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: C.warn.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.warn.withValues(alpha: 0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.error_outline, size: 20, color: C.warn),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Подключение не выполнено'), style: disp(14, w: FontWeight.w700, c: C.warn)),
              const SizedBox(height: 3),
              Text(tr(msg), style: mono(11.5, c: C.muted)),
            ])),
          ]),
          if (fix != ConnFix.none) ...[
            const SizedBox(height: 12),
            switch (fix) {
              // Движок этой платформы не тянет — Happ тянет: даём и импорт ключа, и страницу приложения
              ConnFix.happ => Row(children: [
                  Expanded(child: _btn(tr('Открыть в Happ'), kind: 1, icon: Icons.open_in_new, onTap: _openInHapp)),
                  const SizedBox(width: 12),
                  Expanded(child: _btn(tr('Скачать приложение'), kind: 2, icon: Icons.download,
                      onTap: () => _open(kDownloadUrl))),
                ]),
              ConnFix.refreshSub => _btn(tr('Обновить подписку'), kind: 1, icon: Icons.refresh,
                  onTap: _subVisibleLoading ? null : () => _refreshSub()),
              // Узел не пропустил трафик — ведём к списку, где уже видно, какие сервера рабочие
              ConnFix.pickOther => Row(children: [
                  Expanded(child: _btn(tr('Выбрать сервер'), kind: 1, icon: Icons.dns_outlined, onTap: () => _goTab(1))),
                  const SizedBox(width: 12),
                  Expanded(child: _btn(tr('Проверить серверы'), kind: 2, icon: Icons.network_ping,
                      onTap: _pinging ? null : _pingServers)),
                ]),
              // поддержка живёт в Кабинете — ведём туда, а не наружу в переписку с нуля
              _ => _btn(tr('Написать в поддержку'), kind: 1, icon: Icons.forum, onTap: () => _goTab(2)),
            },
          ],
        ]),
      );

  // Включение режима при выключенном туннеле сразу показывает оптимальный сервер в карточке
  // (при поднятом — не трогаем: конфиг живого коннекта менять нельзя, подхватится при следующем).
  void _setBestServer(bool v) {
    rebuild(() {
      bestServer = v;
      if (v && conn == 0) server = serverForMode(mode);
    });
    _save();
  }

  // Тумблер «Авто-подключение» на Главной (30.08): один выключатель на три механизма —
  // авто-подключение при запуске, авто-ПЕРЕподключение при обрыве и автостарт после
  // перезагрузки (BootReceiver/launch-at-startup). Юзеру не нужно знать про внутренности.
  void _setAlwaysOnHome(bool v) {
    rebuild(() {
      alwaysOn = v;
      autoConnect = v;
      autoReconnect = v;
    });
    if (v && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      rebuild(() => autoLaunch = true);
      try { launchAtStartup.enable(); } catch (_) {/* тост не нужен — флаг всё равно сохранён */}
    }
    _save();
  }

  // Скорость движка приходит в kbps: ≥1000 показываем как Mbps, иначе kbps.
  String _fmtSpeed(int kbps) =>
      kbps >= 1000 ? '${(kbps / 1000).toStringAsFixed(1)} Mbps' : '$kbps kbps';

  Widget _logo() => Row(children: [
        // Пасхалка «Фосфор»: 7 быстрых тапов по ₿-квадрату разблокируют секретную 6-ю палитру.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tapLogoForPhosphor,
          child: Container(width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(gradient: accentGrad, borderRadius: BorderRadius.circular(9),
              boxShadow: [BoxShadow(color: C.accent.withValues(alpha: 0.5), blurRadius: 12)]),
            child: Text('₿', style: disp(17, w: FontWeight.w900, c: C.bg))),
        ),
        const SizedBox(width: 9),
        Text('bit', style: disp(22, w: FontWeight.w800)),
        Text('aps', style: disp(22, w: FontWeight.w800, c: C.accent)),
      ]);

  // Считаем серию быстрых тапов (<1.2с между) по лого; на 7-м — разблокируем «Фосфор» и включаем её.
  void _tapLogoForPhosphor() {
    final now = DateTime.now();
    if (_lastLogoTap == null || now.difference(_lastLogoTap!).inMilliseconds > 1200) {
      _logoTaps = 0; // серия прервалась — начинаем заново
    }
    _lastLogoTap = now;
    _logoTaps++;
    if (phosphorUnlocked) return; // уже открыта — не спамим
    if (_logoTaps >= 7) {
      _logoTaps = 0;
      rebuild(() {
        phosphorUnlocked = true;
        accentIdx = kPhosphorAccent;
        C.accent = accentThemes[kPhosphorAccent].$2;
        C.accentSoft = accentThemes[kPhosphorAccent].$3;
        _applyThemeMode(); // включаем люминофорную палитру
      });
      _syncAnimations();
      _save();
      _toast(appLang == 'en' ? '☘ Phosphor theme unlocked' : '☘ Тема «Фосфор» разблокирована');
    }
  }

  // ---------------- PREMIUM POWER BUTTON ----------------
  Widget _powerButton() {
    final connected = conn == 2;
    final busy = conn == 1;
    final glow = connected ? 0.6 : busy ? 0.35 : 0.0;
    final col = busy ? C.accentSoft : C.accent;
    final showRings = connected || btnStyle == 3;
    // Semantics для скринридера: кнопка подключения. label — что делает (подключить/отключить),
    // value — текущее состояние. ExcludeSemantics на визуале, чтобы кольца/иконки не шумели.
    return Semantics(
      button: true,
      label: connected ? tr('Отключить') : tr('Подключиться'),
      // value повторяет видимый статус (строка 41), включая honesty-гейт: в демо скринридер
      // тоже слышит «Демо-режим», а не «Подключено»; при блокировке — «Трафик заблокирован».
      value: connBlocked ? tr('Трафик заблокирован') : conn == 0 ? tr('Отключено') : conn == 1 ? tr('Подключение…') : (gEngineReal ? tr('Подключено') : tr('Демо-режим')),
      onTap: toggle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: toggle,
        child: ExcludeSemantics(
          child: SizedBox(
            width: 270, height: 270,
            child: Stack(alignment: Alignment.center, children: [
              if (showRings)
                AnimatedBuilder(animation: _wave, builder: (_, __) {
                  return Stack(alignment: Alignment.center, children: [
                    for (int i = 0; i < 3; i++) _pulseRing((_wave.value + i / 3) % 1.0),
                  ]);
                }),
              AnimatedContainer(
                duration: const Duration(milliseconds: 450),
                width: 270, height: 270,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(
                  colors: [C.accent.withValues(alpha: glow), C.accent.withValues(alpha: 0)], stops: const [0.25, 1.0])),
              ),
              _powerInner(col),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _powerInner(Color col) {
    final on = conn == 2;
    switch (btnStyle) {
      case 1: // кольцо — толстое светящееся кольцо
        return Stack(alignment: Alignment.center, children: [
          Container(width: 214, height: 214,
            decoration: BoxDecoration(shape: BoxShape.circle,
              border: Border.all(color: col, width: 10),
              boxShadow: [BoxShadow(color: col.withValues(alpha: on ? 0.5 : 0.14), blurRadius: 22)])),
          Container(width: 150, height: 150,
            decoration: BoxDecoration(shape: BoxShape.circle, color: C.bg2, border: Border.all(color: C.line))),
          Icon(Icons.power_settings_new, size: 60, color: col),
        ]);
      case 2: // орб — наполненная светящаяся сфера; off-состояние тема-зависимое (тёмная сфера на светлом фоне выглядела чужой)
        return Container(width: 192, height: 192, alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle,
            gradient: RadialGradient(center: const Alignment(-0.4, -0.4),
              colors: on
                  ? [C.accentSoft, C.accent, C.accent.withValues(alpha: 0.55)]
                  : (C.light ? const [Color(0xFFFFFFFF), Color(0xFFDDE3EF)] : const [Color(0xFF1A1728), Color(0xFF12101C)])),
            boxShadow: [BoxShadow(color: col.withValues(alpha: on ? 0.55 : 0.14), blurRadius: 36)]),
          child: Icon(Icons.power_settings_new, size: 62, color: on ? Colors.black.withValues(alpha: 0.85) : col));
      case 3: // пульс — концентрические кольца от ядра
        return Stack(alignment: Alignment.center, children: [
          for (final r in const [220.0, 178.0, 136.0])
            Container(width: r, height: r,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: col.withValues(alpha: 0.22), width: 1.5))),
          Container(width: 96, height: 96, alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: C.bg2, border: Border.all(color: col, width: 2),
              boxShadow: [BoxShadow(color: col.withValues(alpha: on ? 0.5 : 0.1), blurRadius: 20)]),
            child: Icon(Icons.power_settings_new, size: 44, color: col)),
        ]);
      default: // шестерёнка
        return Stack(alignment: Alignment.center, children: [
          Container(width: 250, height: 250, decoration: BoxDecoration(shape: BoxShape.circle,
            gradient: RadialGradient(colors: [col.withValues(alpha: C.light ? 0.20 : 0.0), col.withValues(alpha: 0)]))),
          RotationTransition(turns: _spin, child: AnimatedOpacity(
            duration: const Duration(milliseconds: 350), opacity: conn == 0 ? 0.85 : 1,
            child: CustomPaint(size: const Size(212, 212), painter: GearPainter(col)))),
          Text('B', style: disp(60, w: FontWeight.w800, c: Colors.white)),
        ]);
    }
  }

  Widget _pulseRing(double v) {
    return Opacity(
      opacity: ((1 - v) * 0.45).clamp(0, 1),
      child: Container(
        width: 150 + v * 110, height: 150 + v * 110,
        decoration: BoxDecoration(shape: BoxShape.circle,
          border: Border.all(color: C.accent.withValues(alpha: 0.5), width: 2)),
      ),
    );
  }

  Widget _modeChip(String label, int i) {
    final sel = mode == i;
    // Semantics: чип — кнопка с признаком выбора (как _tabItem в main.dart), лейбл — из текста.
    return Semantics(
      button: true,
      selected: sel,
      child: GestureDetector(
      onTap: () {
        // Смена режима меняет и сервер → запрещаем не только при conn==2, но и при conn==1
        // (конфиг коннекта уже собран), иначе туннель и выбранный режим/сервер разъезжаются.
        if (conn != 0) { _toast(tr('Отключись, чтобы сменить режим')); return; }
        // Режим = просьба автоподбора → включаем bestServer обратно: иначе при выключенном
        // ползунке server молча заменился бы автоподбором, а плашка говорила бы «сервер выбираешь ты».
        rebuild(() { mode = i; bestServer = true; server = serverForMode(i); });
        _save();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 40, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? C.accent.withValues(alpha: 0.16) : C.fill,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: sel ? C.accent : C.line),
        ),
        child: Text(tr(label), style: disp(13, w: FontWeight.w700, c: sel ? C.accent : C.muted)),
      ),
    ));
  }

}
