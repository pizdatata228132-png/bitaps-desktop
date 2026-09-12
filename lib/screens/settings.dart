part of '../main.dart';

// ============================ SETTINGS ============================
extension ShellSettings on ShellState {
  Widget _accentSwatch(int i) {
    final th = accentThemes[i];
    final sel = accentIdx == i;
    return GestureDetector(
      onTap: () {
        rebuild(() {
          accentIdx = i;
          C.accent = th.$2;
          C.accentSoft = th.$3;
          // Вход/выход из «Фосфор» переключает всю палитру фона (люминофор ↔ обычная тема),
          // поэтому пере-применяем тему после смены акцента.
          _applyThemeMode();
        });
        _syncAnimations(); // starfield гасится в Фосфоре (тёмная спец-палитра) — сверить
        _save();
      },
      // Semantics: свотч — кнопка с именем акцента (Sunset/Neon/…) и признаком выбора,
      // иначе скринридер слышит 5 безымянных кружков.
      child: Semantics(
        button: true,
        selected: sel,
        label: th.$1,
        child: Container(
          margin: const EdgeInsets.only(right: 12),
          width: 44, height: 44, alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle,
            gradient: LinearGradient(colors: [th.$3, th.$2]),
            border: Border.all(color: sel ? (C.light ? Colors.black : Colors.white) : Colors.transparent, width: 3),
            boxShadow: [BoxShadow(color: th.$2.withValues(alpha: 0.5), blurRadius: sel ? 14 : 6)]),
          child: sel ? Icon(Icons.check, size: 18, color: C.light ? Colors.black : Colors.white) : null,
        ),
      ),
    );
  }

  Widget _styleChip(int i) {
    final sel = btnStyle == i;
    const previews = [Icons.settings, Icons.radio_button_unchecked, Icons.brightness_1, Icons.wifi_tethering];
    return GestureDetector(
      onTap: () { rebuild(() => btnStyle = i); _syncAnimations(); _save(); }, // стиль решает, крутить ли шестерёнку/кольца
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: sel ? C.accent.withValues(alpha: 0.16) : C.fill,
          borderRadius: BorderRadius.circular(11), border: Border.all(color: sel ? C.accent : C.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(previews[i], size: 15, color: sel ? C.accent : C.muted),
          const SizedBox(width: 7),
          Text(tr(btnStyleNames[i]), style: disp(13, w: FontWeight.w600, c: sel ? C.accent : C.muted)),
        ])),
    );
  }

  Widget _themeChip(int i) {
    const names = ['Тёмная', 'Светлая', 'Системная'];
    const icons = [Icons.dark_mode_outlined, Icons.light_mode_outlined, Icons.brightness_auto_outlined];
    final sel = themeMode == i;
    return GestureDetector(
      onTap: () { rebuild(() { themeMode = i; _applyThemeMode(); }); _syncAnimations(); _save(); }, // starfield только в тёмной
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: sel ? C.accent.withValues(alpha: 0.16) : C.fill,
          borderRadius: BorderRadius.circular(11), border: Border.all(color: sel ? C.accent : C.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icons[i], size: 15, color: sel ? C.accent : C.muted),
          const SizedBox(width: 7),
          Text(tr(names[i]), style: disp(13, w: FontWeight.w600, c: sel ? C.accent : C.muted)),
        ])),
    );
  }

  // переключатель языка RU/EN — по образцу _themeChip
  Widget _langChip(String code, String label) {
    final sel = appLang == code;
    return GestureDetector(
      onTap: () { rebuild(() { appLang = code; }); _save(); if (_trayReady) _updateTrayMenu(); }, // меню трея тоже на tr()
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(color: sel ? C.accent.withValues(alpha: 0.16) : C.fill,
          borderRadius: BorderRadius.circular(11), border: Border.all(color: sel ? C.accent : C.line)),
        child: Text(label, style: disp(13, w: FontWeight.w600, c: sel ? C.accent : C.muted)),
      ),
    );
  }

  // Честный лейбл протокола: выводим ФАКТИЧЕСКИЙ протокол текущего ключа (парсер умеет
  // vless/trojan/vmess/ss/hysteria2), а не захардкоженный «VLESS + Reality».
  String _protoLabel() {
    // Подписка несёт сразу несколько узлов разных протоколов — честнее показать это, чем
    // выводить «https» из схемы ссылки.
    if (isSubscriptionUrl(keyStr)) return tr('подписка bitaps');
    final scheme = keyStr.split(':').first.toLowerCase();
    switch (scheme) {
      case 'vless':
        final sec = Uri.tryParse(keyStr)?.queryParameters['security']?.toLowerCase();
        return sec == 'reality' ? 'VLESS + Reality' : 'VLESS';
      case 'trojan':
        return 'Trojan';
      case 'vmess':
        return 'VMess';
      case 'ss':
        return 'Shadowsocks';
      case 'hysteria2':
      case 'hy2':
        return 'Hysteria2';
      default:
        return tr('подбирается автоматически');
    }
  }

  void _showStats() {
    _dialog(tr('Статистика'),
        appLang == 'en'
            ? 'Sessions started: $sessions\nCurrent session: ${conn == 2 ? hms : "not connected"}\nServer: ${tr(server.city)}\nMode: ${tr(modeLabels[mode])}\nFavorite servers: ${favs.length}'
            : 'Сессий запущено: $sessions\nТекущая сессия: ${conn == 2 ? hms : "не подключено"}\nСервер: ${tr(server.city)}\nРежим: ${modeLabels[mode]}\nИзбранных серверов: ${favs.length}');
  }

  void _customConfig() {
    final ctrl = TextEditingController(text: customCfg ?? '');
    // Контроллер живёт, пока открыт диалог; освобождаем ПОСЛЕ закрытия маршрута (иначе TextField
    // ещё смонтирован → в debug «used after being disposed»). onPressed читает ctrl.text до pop.
    showDialog<void>(
      context: context,
      // Esc закрывает (barrierDismissible:false заодно глушил Esc; защита от клика-мимо иллюзорна —
      // «Отмена» теряет текст ровно так же, а ctrl.dispose висит на .then и отработает любой выход).
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Свой конфиг'), style: disp(18, w: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true, // фокус сразу в поле — Cmd+V вставляет ключ без предварительного клика
          style: mono(12, c: C.text),
          cursorColor: C.accent,
          // хинт перечисляет схемы честно: принимаются все kSupportedKeySchemes, не только vless
          decoration: InputDecoration(hintText: tr('Вставь ключ vless://, trojan://, ss://…'), hintMaxLines: 2, hintStyle: mono(12, c: C.muted)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'), style: mono(13, c: C.muted))),
          TextButton(
            onPressed: () async {
              final t = ctrl.text.trim();
              Navigator.pop(context);
              if (kSupportedKeySchemes.any((s) => t.toLowerCase().startsWith(s))) {
                // ТОТ ЖE trusted-host гейт, что и в _importKey: без него «вставь это в Свой конфиг»
                // обходил защиту и при kRealTunnel=true трафик молча ушёл бы на хост атакующего.
                // Принимаем ВСЕ схемы singbox_config (vless/trojan/vmess/ss/hysteria2), а не только
                // vless:// — и реально ПРИМЕНЯЕМ конфиг как ключ подключения (keyStr), а не мёртвый customCfg.
                final host = _hostOf(t);
                // Ключ самого bitaps — тем же путём, что _importKeyString (вход/рефреш аккаунта):
                // importedHost/customCfg НЕ выставляем, иначе авто-рефреш подписки навсегда
                // перестал бы обновлять этот ключ (см. гард importedHost==null в _applySub).
                if (host != null && _isTrustedHost(host)) { await _importKeyString(t); return; }
                final ok = await _confirmForeignHost(host ?? tr('неизвестный хост'));
                if (ok != true) return;
                if (!mounted) return;
                rebuild(() { keyStr = t; importedHost = host; customCfg = t; });
                _save();
                _toast(host != null
                    ? (appLang == 'en' ? 'Key replaced with $host ✓' : 'Ключ заменён на $host ✓')
                    : tr('Ключ заменён ✓'));
              } else if (t.isEmpty) {
                rebuild(() => customCfg = null);
                _save();
                _toast(tr('Конфиг очищен'));
              } else {
                // раньше любой текст «сохранялся» в customCfg с зелёным тостом, но customCfg нигде не
                // читается → фича была мёртвой. Не врём об успехе: честно отклоняем неподдержанный формат.
                _toast(appLang == 'en'
                    ? 'Need a vless:// key (or trojan/vmess/ss/hysteria2). Other formats are not supported.'
                    : 'Нужен ключ vless:// (или trojan/vmess/ss/hysteria2). Другой формат не поддерживается.');
              }
            },
            child: Text(tr('Сохранить'), style: mono(13, c: C.accent)),
          ),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  Widget _settings() => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(tr('Настройки'), style: disp(26, w: FontWeight.w800)),
          const SizedBox(height: 18),
          _kicker(tr('персонализация')),
          const SizedBox(height: 10),
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Цвет акцента'), style: disp(15, w: FontWeight.w600)),
            const SizedBox(height: 12),
            // Секретная «Phosphor» (kPhosphorAccent) в ряду только после разблокировки пасхалкой.
            // Wrap: 6-й свотч не влезал бы в Row на узком окне — переносим.
            Wrap(children: [
              for (int i = 0; i < accentThemes.length; i++)
                if (i != kPhosphorAccent || phosphorUnlocked) _accentSwatch(i)
            ]),
            const SizedBox(height: 18),
            Text(tr('Кнопка подключения'), style: disp(15, w: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [for (int i = 0; i < btnStyleNames.length; i++) _styleChip(i)]),
            const SizedBox(height: 18),
            Text(tr('Тема'), style: disp(15, w: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [for (int i = 0; i < 3; i++) _themeChip(i)]),
            const SizedBox(height: 18),
            Text(tr('Язык'), style: disp(15, w: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [_langChip('ru', 'RU'), _langChip('en', 'EN')]),
          ])),
          const SizedBox(height: 22),
          _kicker(tr('безопасность')),
          const SizedBox(height: 10),
          _card(child: Column(children: [
            _toggle(tr('Блокировка входа'), tr('Только экран: от доступа к устройству не защищает'), tgl1, (v) { if (v) { _enableLock(); } else { _pinFails = 0; _clearPinThrottle(); rebuild(() { tgl1 = false; appPin = null; }); _save(); } }),
            _divider(),
            _toggle(tr('Обрыв соединения'), tr('Уведомлять, если VPN отвалился'), tgl2, (v) { rebuild(() => tgl2 = v); _save(); }),
            _divider(),
            _toggle(tr('Килл-свитч'), _killSwitchSub(), killSwitch, _setKillSwitch),
            _divider(),
            _toggle(tr('Подписка истекает'), tr('Напомнить за пару дней'), tgl3, (v) { rebuild(() => tgl3 = v); _save(); }),
            _divider(),
            _toggle(tr('Лимит трафика'), tr('Сигнал при расходе от 5 ГБ за сессию'), tgl4, (v) { rebuild(() => tgl4 = v); _save(); }),
            // «Авто-подключение»/«Автопереподключение» здесь УБРАНЫ (30.08, владелец): единый
            // тумблер «Авто-подключение» живёт на Главной под автовыбором сервера и включает
            // сразу всё: подключение при запуске, переподключение при обрыве и автостарт
            // после перезагрузки. Дублировать здесь = два источника правды, которые расходятся.
          ])),
          // Автозапуск/хоткей — только десктоп (на мобильных нет launch_at_startup/глобальных хоткеев)
          if (_isDesktop) ...[
            const SizedBox(height: 22),
            _kicker(tr('система')),
            const SizedBox(height: 10),
            _card(child: Column(children: [
              _toggle(tr('Запускать при входе'), tr('Автостарт вместе с системой'), autoLaunch, _setAutoLaunch),
              _divider(),
              _toggle(tr('Старт свёрнутым'), tr('При автозапуске — сразу в трей'), startMinimized, _setStartMinimized),
              _divider(),
              _hotkeyRow(),
            ])),
          ],
          const SizedBox(height: 22),
          _kicker(tr('инструменты')),
          const SizedBox(height: 10),
          _card(padding: 6, child: Column(children: [
            _navRow(Icons.speed, tr('Тест скорости'), _speedTest),
            _divider(),
            _navRow(Icons.bar_chart, tr('Статистика'), _showStats),
            _divider(),
            _navRow(Icons.shield, tr('Проверка утечек'), _leakCheck),
            _divider(),
            _navRow(Icons.upload_file, customCfg == null ? tr('Свой конфиг') : tr('Свой конфиг ✓'), _customConfig),
            _divider(),
            // 🩺 самодиагностика — локальный чек аккаунта/подписки/ключа из app-sub (без сети)
            _navRow(Icons.health_and_safety_outlined, tr('Проверить мой доступ'), _selfDiagnose),
            _divider(),
            // 🆕 что нового — фетч changelog.json с сайта (fail-soft)
            _navRow(Icons.new_releases_outlined, tr('Что нового'), _showChangelog),
            _divider(),
            // повторный показ онбординга (3 карточки-знакомства)
            _navRow(Icons.auto_awesome, tr('Показать знакомство'), _replayOnboarding),
          ])),
          const SizedBox(height: 22),
          _kicker(tr('подключение')),
          const SizedBox(height: 10),
          // padding 6+8=14 — инсет строки как у _navRow-строк карточки «Инструменты» выше
          _card(padding: 6, child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(children: [
                Icon(Icons.bolt, size: 19, color: C.accent),
                const SizedBox(width: 12),
                Text(tr('Протокол'), style: disp(15, w: FontWeight.w500)),
                const Spacer(),
                Text(_protoLabel(), style: mono(13, c: C.muted)),
              ]),
            ),
            // Демо-сессия — только там, где туннель поднять нечем, и только по явной просьбе.
            // Где движок есть, тумблер бессмыслен, поэтому его там просто нет.
            if (_noEngine) ...[
              _divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _toggle(tr('Демо-режим'), tr('Показать интерфейс без реального туннеля'), demoMode,
                    (v) { rebuild(() => demoMode = v); _save(); }),
              ),
            ],
          ])),
          const SizedBox(height: 8),
          Text(tr('Протокол подбирается автоматически под твой ключ. Настраивать ничего не нужно.'),
              style: mono(11, c: C.muted)),
          const SizedBox(height: 22),
          _btn(tr('Выйти'), kind: 1, icon: Icons.logout, onTap: _logout),
          const SizedBox(height: 16),
          Center(child: Text('bitaps vpn · v1.0', style: mono(11, c: C.muted))),
        ],
      );

  Widget _navRow(IconData ic, String label, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(children: [
            Icon(ic, size: 19, color: C.accent),
            const SizedBox(width: 12),
            Text(label, style: disp(15, w: FontWeight.w500)),
            const Spacer(),
            Icon(Icons.chevron_right, size: 18, color: C.muted),
          ]),
        ),
      );

  Widget _toggle(String title, String sub, bool v, ValueChanged<bool> onCh) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        // MergeSemantics: скринридер зачитывает заголовок+подзаголовок+состояние переключателя как один элемент.
        child: MergeSemantics(child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: disp(15, w: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(sub, style: mono(11)),
          ])),
          // activeTrackColor от текущего акцента: дефолтный трек — colorScheme.primary, а он
          // не пересобирается при смене акцента (ThemeData слушает только смену яркости).
          Switch(value: v, onChanged: onCh, activeThumbColor: C.accent, activeTrackColor: C.accent.withValues(alpha: 0.35)),
        ])),
      );

  bool get _isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  // ---------------- КИЛЛ-СВИТЧ ----------------
  // Подпись-подсказка с платформенным примечанием. Честность важнее маркетинга:
  //   • Android: сам по себе тумблер НИЧЕГО не блокирует — после смерти VpnService маршруты
  //     удерживает только система («Постоянный VPN» + «Блокировать соединения без VPN»),
  //     см. диалог при первом включении (_setKillSwitch) и holdProxyOnDrop в connection.dart.
  //   • iOS: нативная сторона (NetworkExtension) ещё не собрана, поэтому «действует всегда»
  //     обещать нельзя — честно пишем «после выхода iOS-версии».
  // Строки собраны тернарником appLang, а не tr(): текст платформо-зависимый.
  String _killSwitchSub() {
    final base = appLang == 'en'
        ? 'if the VPN drops, traffic is blocked instead of going direct'
        : 'если VPN отвалится, интернет блокируется, а не идёт напрямую';
    if (Platform.isIOS) {
      return appLang == 'en'
          ? '$base · on iOS — built in once the iOS version ships'
          : '$base · на iOS — из коробки после выхода iOS-версии';
    }
    if (Platform.isAndroid) {
      return appLang == 'en'
          ? '$base · on Android the switch alone blocks nothing — enable the system “Always-on VPN” + “Block connections without VPN”'
          : '$base · на Android сам по себе не блокирует — включи системные «Постоянный VPN» и «Блокировать соединения без VPN»';
    }
    return base;
  }

  // Переключение килл-свитча. На Android при ПЕРВОМ включении — одноразовый диалог: системная
  // защита там сильнее приложения, потому что после смерти VpnService маршруты удерживает лишь
  // «Постоянный VPN» + «Блокировать соединения без VPN» в настройках ОС. Открыть системные
  // настройки VPN из приложения нельзя: ни flutter_v2ray_client, ни наш канал такого метода
  // не имеют, а android-модуля у сборки нет — поэтому диалог с инструкцией, без кнопки-перехода.
  void _setKillSwitch(bool v) {
    rebuild(() => killSwitch = v);
    _save();
    if (v && Platform.isAndroid) _showKillSwitchAndroidHintOnce();
  }

  Future<void> _showKillSwitchAndroidHintOnce() async {
    final p = await SharedPreferences.getInstance();
    if ((p.getBool('ksHintShown') ?? false) || !mounted) return; // показываем один раз
    await p.setBool('ksHintShown', true);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Килл-свитч на Android'), style: disp(18, w: FontWeight.w700)),
        content: SizedBox(width: 360, child: Text(
          appLang == 'en'
              ? 'Android protects this better at the system level: enable “Always-on VPN” and “Block connections without VPN” for bitaps in system settings (Network & internet → VPN → gear icon). Then traffic cannot bypass the tunnel even if the app dies.'
              : 'Системная защита Android надёжнее приложения: включи для bitaps «Постоянный VPN» и «Блокировать соединения без VPN» в настройках системы (Сеть и интернет → VPN → шестерёнка). Тогда трафик не пойдёт мимо туннеля, даже если приложение упадёт.',
          style: mono(13, c: C.text))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Понятно'), style: mono(13, c: C.accent)))],
      ),
    );
  }

  /// Туннель на этой системе поднять нечем (десктоп без бинаря xray рядом и т.п.).
  /// От этого зависят тумблер «Демо-режим» и честные формулировки в знакомстве/диагностике.
  bool get _noEngine => TunnelEngine.kind() == EngineKind.none;

  // ---------------- ГЛОБАЛЬНЫЙ ХОТКЕЙ (строка + рекордер) ----------------
  Widget _hotkeyRow() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Хоткей подключения'), style: disp(15, w: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(_recordingHotkey ? tr('Нажми сочетание клавиш…') : tr('Глобально включает/выключает VPN'), style: mono(11)),
          ])),
          const SizedBox(width: 10),
          // чип-рекордер: тап → ловим следующее сочетание (RawKeyboardListener внутри), долгий тап/× — сброс
          _hotkeyChip(),
        ]),
      );

  Widget _hotkeyChip() {
    final label = _recordingHotkey ? '…' : hotkeyLabel(hotkeyStr);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // Focus+KeyboardListener: пока идёт запись, ловим первое сочетание с модификатором
      Focus(
        autofocus: _recordingHotkey,
        onKeyEvent: (node, ev) {
          if (!_recordingHotkey) return KeyEventResult.ignored;
          if (ev is KeyDownEvent) {
            _recordHotkey(ev.logicalKey, ev.physicalKey,
                HardwareKeyboard.instance.logicalKeysPressed);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: () => rebuild(() => _recordingHotkey = !_recordingHotkey),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _recordingHotkey ? C.accent.withValues(alpha: 0.16) : C.fill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _recordingHotkey ? C.accent : C.line)),
            child: Text(label, style: mono(12, c: _recordingHotkey ? C.accent : C.text, w: FontWeight.w600)),
          ),
        ),
      ),
      IconButton(
        onPressed: _resetHotkey,
        iconSize: 16, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34), splashRadius: 18,
        tooltip: tr('Сбросить'), icon: Icon(Icons.restart_alt, color: C.muted)),
    ]);
  }

  // ---------------- 🩺 САМОДИАГНОСТИКА ----------------
  // Локальный чек аккаунта БЕЗ сети: собран из уже загруженного состояния (app-sub/app-login).
  // Каждая строка — факт с иконкой ✓/⚠; проблемные ведут к действию (войти/продлить/скопировать код).
  void _selfDiagnose() {
    final rows = <Widget>[];
    Widget row(bool ok, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ok ? Icons.check_circle : Icons.error_outline, size: 17, color: ok ? C.ok : C.warn),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: mono(12, c: C.text))),
      ]),
    );
    rows.add(row(loggedIn, loggedIn ? tr('Вход выполнен') : tr('Не вошёл — войди в Кабинете')));
    if (loggedIn) {
      final days = _daysLeft();
      final subOk = subActive && (days == null || days > 0);
      rows.add(row(subOk, subOk
          ? (days != null ? (appLang == 'en' ? 'Subscription active · $days days left' : 'Подписка активна · осталось $days ${_pluralDays(days)}') : tr('Подписка активна'))
          : tr('Подписка неактивна — продли в Кабинете')));
      final hasKey = keyStr.isNotEmpty && keyStr != kDemoKey;
      rows.add(row(hasKey, hasKey ? tr('Ключ доступа получен') : tr('Ключ ещё не подтянут — нажми «Обновить»')));
      final devOk = subLimit == null || devices.length <= subLimit!;
      rows.add(row(devOk, appLang == 'en'
          ? 'Devices: ${devices.length} / $_limitStr'
          : 'Устройств: ${devices.length} / $_limitStr'));
      rows.add(row(loginSecret != null, loginSecret != null
          ? tr('Код входа доступен (для входа без ключа)')
          : tr('Кода входа нет — получи в боте (/start → Код входа)')));
    }
    // честный дисклеймер: «всё зелёное» не должно читаться как «VPN сейчас защищает».
    // Сверяемся с фактическим движком, а не с const-флагом kRealTunnel: он всегда true, и
    // ветка про демо была мертва ровно на тех системах, где демо и происходит.
    showDialog<void>(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.bg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
      title: Text(tr('Проверка доступа'), style: disp(18, w: FontWeight.w700)),
      content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        ...rows,
        const SizedBox(height: 10),
        _divider(),
        const SizedBox(height: 8),
        Text(
          _noEngine ? tr('Подключение сейчас демонстрационное — реального туннеля нет.')
                    : tr('Диагностика проверяет доступ к аккаунту, не качество канала.'),
          style: mono(10.5, c: C.muted)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Ок'), style: mono(13, c: C.accent)))],
    ));
  }

  // ---------------- 🆕 ЧТО НОВОГО ----------------
  // Фетч changelog.json с сайта (fail-soft). Формат: {"entries":[{"build","date","ru":[],"en":[]}]}.
  void _showChangelog() {
    final fut = _fetchChangelog();
    showDialog<void>(context: context, builder: (ctx) => FutureBuilder<List<_ChangeEntry>>(
      future: fut,
      builder: (c, snap) {
        final done = snap.connectionState == ConnectionState.done;
        Widget body;
        if (!done) {
          body = Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent)),
            const SizedBox(width: 12), Text(tr('Минутку…'), style: mono(13, c: C.muted)),
          ]);
        } else if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
          body = Text(tr('Список изменений пока недоступен. Загляни позже.'), style: mono(13, c: C.muted));
        } else {
          body = SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final e in snap.data!) ...[
              Row(children: [
                Text(e.build > 0 ? (appLang == 'en' ? 'build ${e.build}' : 'сборка ${e.build}') : '', style: mono(12, c: C.accent, w: FontWeight.w700)),
                const Spacer(),
                Text(e.date, style: mono(11, c: C.muted)),
              ]),
              const SizedBox(height: 6),
              for (final line in (appLang == 'en' ? e.en : e.ru))
                Padding(padding: const EdgeInsets.only(bottom: 4),
                  child: Text('•  $line', style: mono(12, c: C.text))),
              const SizedBox(height: 12),
            ],
          ]));
        }
        return AlertDialog(
          backgroundColor: C.bg2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
          title: Text(tr('Что нового'), style: disp(18, w: FontWeight.w700)),
          content: SizedBox(width: 360, child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 380), child: body)),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Ок'), style: mono(13, c: C.accent)))],
        );
      },
    ));
  }

  Future<List<_ChangeEntry>> _fetchChangelog() async {
    final r = await http.get(Uri.parse(kChangelogUrl)).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('http ${r.statusCode}');
    final d = jsonDecode(r.body);
    final list = (d is Map && d['entries'] is List) ? d['entries'] as List : const [];
    return list.whereType<Map>().map((e) => _ChangeEntry(
      build: (e['build'] is num) ? (e['build'] as num).toInt() : 0,
      date: e['date']?.toString() ?? '',
      ru: (e['ru'] is List) ? (e['ru'] as List).map((x) => x.toString()).toList() : const [],
      en: (e['en'] is List) ? (e['en'] as List).map((x) => x.toString()).toList() : const [],
    )).toList();
  }
}

// Одна запись changelog (сборка/дата/строки RU+EN). Внутренняя модель экрана «Что нового».
class _ChangeEntry {
  final int build;
  final String date;
  final List<String> ru, en;
  _ChangeEntry({required this.build, required this.date, required this.ru, required this.en});
}
