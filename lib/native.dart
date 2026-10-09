part of 'main.dart';

// ============================ NATIVE INTEGRATIONS (deep-link / автозапуск / хоткей) ============================
// Всё здесь fail-soft: на платформе без нативной стороны (или при любой ошибке плагина) фича
// молча отключается, приложение продолжает работать. Ничего из этого не влияет на честность
// демо-статуса — хоткей/трей переключают ту же демо-сессию, что и большая кнопка.
extension ShellNative on ShellState {
  // ---------------- DEEP-LINK (bitaps://) ----------------
  // Схемы: bitaps://import?key=<vless…>  → импорт ключа существующим _importKeyString (trusted-host гейт);
  //        bitaps://login?secret=<uuid>  → вход по «Коду входа» через _login.
  // Нативная регистрация схемы — на платформенной стороне (CI-патчи build.yml / .desktop+reg).
  Future<void> _initDeepLinks() async {
    try {
      final links = AppLinks();
      // холодный старт: приложение открыли ссылкой — обрабатываем начальный URI
      final initial = await links.getInitialLink();
      if (initial != null) _handleDeepLink(initial);
      // горячие ссылки: приложение уже запущено, кликнули ещё одну bitaps://…
      _linkSub = links.uriLinkStream.listen(_handleDeepLink, onError: (_) {/* тихо */});
    } catch (e) {
      debugPrint('deep-link init failed: $e'); // нет нативной стороны схемы — живём без deep-link
    }
  }

  void _handleDeepLink(Uri uri) {
    if (!mounted) return;
    if (uri.scheme.toLowerCase() != kUrlScheme) return;
    // Под замком ссылку не исполняем (вход/импорт поверх PIN-экрана недопустим), но и не
    // роняем: откладываем и разбираем сразу после разблокировки (_processPendingDeepLink).
    if (_locked) { _pendingDeepLink = uri; return; }
    // окно могло быть свёрнуто (старт свёрнутым/трей) — поднимаем на ссылку
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.setSkipTaskbar(false).catchError((_) {});
      windowManager.show().catchError((_) {});
      windowManager.focus().catchError((_) {});
    }
    final host = uri.host.toLowerCase();
    if (host == 'import') {
      final key = uri.queryParameters['key']?.trim();
      if (key != null && key.isNotEmpty) {
        _goTab(2);
        // Доверенный ключ/подписка по deep-link приводил бы к МОЛЧАЛИВОЙ подмене ключа —
        // подтверждение ВСЕГДА (и у гостя, и у залогиненного: чужая ссылка подменяет выдачу
        // на ноды атакующего — аудит A10). Отказ = не импортируем вовсе.
        final h = isSubscriptionUrl(key) ? '' : (_hostOf(key) ?? '');
        if (isSubscriptionUrl(key) || (h.isNotEmpty && _isTrustedHost(h))) {
          _confirmDeepLinkAction(() => _importKeyString(key));
          return;
        }
        _importKeyString(key);
        return;
      }
    }
    if (host == 'login') {
      final secret = uri.queryParameters['secret']?.trim();
      if (secret != null && secret.isNotEmpty) {
        _goTab(2);
        if (!loggedIn) { _confirmDeepLinkAction(() => _login(secret)); } else { _toast(tr('Ты уже вошёл')); }
        return;
      }
    }
    _toast(tr('Не удалось разобрать ссылку'));
  }

  // Действие, приводящее ко ВХОДУ, по deep-link — только с явным подтверждением человека:
  // ссылку может открыть кто угодно (чат/письмо/QR), а bitaps:// раньше логинил молча.
  // Диалог по образцу _confirmForeignHost.
  void _confirmDeepLinkAction(Future<void> Function() run) {
    showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Вход по ссылке'), style: disp(18, w: FontWeight.w700)),
        content: Text(tr('Войти в аккаунт по ссылке?'), style: mono(13, c: C.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: Text(tr('Отмена'), style: mono(13, c: C.muted))),
          TextButton(onPressed: () { Navigator.pop(dctx); run(); }, child: Text(tr('Войти'), style: mono(13, c: C.accent))),
        ],
      ),
    );
  }

  // Ссылка, пришедшая под замком: разбираем после разблокировки (зеркало _maybeAutoConnect).
  void _processPendingDeepLink() {
    final u = _pendingDeepLink;
    _pendingDeepLink = null;
    if (u != null && mounted && !_locked) _handleDeepLink(u);
  }

  // ---------------- РЕГИСТРАЦИЯ СХЕМЫ bitaps:// (Windows/Linux при первом запуске) ----------------
  // macOS/iOS/Android регистрируют схему декларативно (Info.plist CFBundleURLTypes / intent-filter
  // — CI-патчи build.yml и локальный macOS-скрипт). На Windows/Linux схему надо прописать в реестр/
  // xdg при первом запуске. Делаем один раз (флаг в prefs), fail-soft.
  Future<void> _registerUrlScheme() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool('urlSchemeRegistered') == true) return;
      final exe = Platform.resolvedExecutable;
      if (Platform.isWindows) {
        // HKCU\Software\Classes\bitaps — не требует прав администратора
        const base = r'HKCU\Software\Classes\bitaps';
        await Process.run('reg', ['add', base, '/ve', '/d', 'URL:bitaps', '/f']);
        await Process.run('reg', ['add', base, '/v', 'URL Protocol', '/d', '', '/f']);
        await Process.run('reg', ['add', '$base\\shell\\open\\command', '/ve', '/d', '"$exe" "%1"', '/f']);
      } else if (Platform.isLinux) {
        // .desktop с x-scheme-handler/bitaps + xdg-mime default
        final home = Platform.environment['HOME'] ?? '';
        if (home.isEmpty) return;
        final appsDir = Directory('$home/.local/share/applications');
        if (!appsDir.existsSync()) appsDir.createSync(recursive: true);
        final desktop = File('${appsDir.path}/bitaps-vpn.desktop');
        desktop.writeAsStringSync(
          '[Desktop Entry]\n'
          'Name=bitaps VPN\n'
          'Exec=$exe %u\n'
          'Type=Application\n'
          'Terminal=false\n'
          'Categories=Network;\n'
          'MimeType=x-scheme-handler/bitaps;\n');
        await Process.run('xdg-mime', ['default', 'bitaps-vpn.desktop', 'x-scheme-handler/bitaps']);
      }
      await p.setBool('urlSchemeRegistered', true);
    } catch (e) {
      debugPrint('registerUrlScheme failed: $e'); // не критично — deep-link просто не будет ловиться
    }
  }

  // ---------------- АВТОЗАПУСК ПРИ ВХОДЕ ----------------
  Future<void> _initNativeDesktop() async {
    await _registerUrlScheme();
    // launch_at_startup: настраиваем appName/appPath из package_info; args несёт «старт свёрнутым».
    try {
      final info = await PackageInfo.fromPlatform();
      launchAtStartup.setup(
        appName: info.appName.isNotEmpty ? info.appName : 'bitaps VPN',
        appPath: Platform.resolvedExecutable,
        args: startMinimized ? ['--minimized'] : const [],
      );
      // сверяем сохранённое желание с фактическим состоянием ОС (юзер мог снять автозапуск сам)
      final enabled = await launchAtStartup.isEnabled();
      if (enabled != autoLaunch && mounted) rebuild(() => autoLaunch = enabled);
    } catch (e) {
      debugPrint('launch_at_startup init failed: $e');
    }
    // регистрируем глобальный хоткей подключения
    await _registerHotkey();
  }

  // Тумблер «Запускать при входе». enable/disable + переустановка args при смене «старт свёрнутым».
  Future<void> _setAutoLaunch(bool v) async {
    rebuild(() => autoLaunch = v);
    _save();
    try {
      if (v) { await launchAtStartup.enable(); } else { await launchAtStartup.disable(); }
    } catch (e) {
      debugPrint('setAutoLaunch failed: $e');
      _toast(tr('Не удалось изменить автозапуск'));
    }
  }

  // Тумблер «Старт свёрнутым»: меняет args автозапуска (нужно переустановить setup+enable).
  Future<void> _setStartMinimized(bool v) async {
    rebuild(() => startMinimized = v);
    _save();
    // переустанавливаем автозапуск с новыми args, только если он включён
    if (!autoLaunch) return;
    try {
      final info = await PackageInfo.fromPlatform();
      launchAtStartup.setup(
        appName: info.appName.isNotEmpty ? info.appName : 'bitaps VPN',
        appPath: Platform.resolvedExecutable,
        args: v ? ['--minimized'] : const [],
      );
      await launchAtStartup.enable(); // перезаписывает запись с обновлёнными args
    } catch (e) {
      debugPrint('setStartMinimized re-register failed: $e');
    }
  }

  // ---------------- ГЛОБАЛЬНЫЙ ХОТКЕЙ ----------------
  // Сериализация: "mod+shift+keyB" — «mod» = Cmd на macOS, Ctrl иначе. Разбираем в HotKey.
  HotKey? _parseHotkey(String s) {
    final parts = s.toLowerCase().split('+').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final mods = <HotKeyModifier>[];
    PhysicalKeyboardKey? key;
    for (final p in parts) {
      switch (p) {
        case 'mod': mods.add(Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control); break;
        case 'ctrl': case 'control': mods.add(HotKeyModifier.control); break;
        case 'shift': mods.add(HotKeyModifier.shift); break;
        case 'alt': case 'option': mods.add(HotKeyModifier.alt); break;
        case 'meta': case 'cmd': case 'super': mods.add(HotKeyModifier.meta); break;
        default:
          // остаток — физическая клавиша по её debugName (keyB, keyG, digit1, space…)
          key = _physicalByName(p);
      }
    }
    if (key == null) return null;
    return HotKey(key: key, modifiers: mods, scope: HotKeyScope.system);
  }

  // Ищем PhysicalKeyboardKey по имени вида "keyB"/"digit1" (сериализованному из debugName).
  PhysicalKeyboardKey? _physicalByName(String name) {
    for (final k in PhysicalKeyboardKey.knownPhysicalKeys) {
      final dn = k.debugName?.toLowerCase().replaceAll(' ', '');
      if (dn == name) return k;
    }
    return null;
  }

  // Человекочитаемая метка хоткея для UI: «⌘⇧B» на macOS, «Ctrl+Shift+B» иначе.
  String hotkeyLabel(String s) {
    final parts = s.toLowerCase().split('+').where((e) => e.trim().isNotEmpty).toList();
    final mac = Platform.isMacOS;
    final out = <String>[];
    for (final p in parts) {
      switch (p) {
        case 'mod': out.add(mac ? '⌘' : 'Ctrl'); break;
        case 'ctrl': case 'control': out.add(mac ? '⌃' : 'Ctrl'); break;
        case 'shift': out.add(mac ? '⇧' : 'Shift'); break;
        case 'alt': case 'option': out.add(mac ? '⌥' : 'Alt'); break;
        case 'meta': case 'cmd': case 'super': out.add(mac ? '⌘' : 'Win'); break;
        default:
          // keyB → B, digit1 → 1
          var k = p;
          if (k.startsWith('key')) { k = k.substring(3); } else if (k.startsWith('digit')) { k = k.substring(5); }
          out.add(k.toUpperCase());
      }
    }
    return out.join(mac ? '' : '+');
  }

  Future<void> _registerHotkey() async {
    try {
      final hk = _parseHotkey(hotkeyStr);
      if (hk == null) return;
      if (_registeredHotkey != null) {
        try { await hotKeyManager.unregister(_registeredHotkey!); } catch (_) {}
      }
      await hotKeyManager.register(hk, keyDownHandler: (_) {
        if (!mounted) return;
        // Направление читаем ДО toggle: conn==2/1 — «размыкаем», иначе «подключаем».
        // Раньше стояло наоборот (conn==0 → «Отключаю…») + с пре-замером toggle асинхронен,
        // и чтение conn после него врёт в обоих дефолтных путях (аудит UX 09.10).
        final wasActive = conn != 0 || preProbing;
        toggle(); // тот же ConnectionController.toggle, что у большой кнопки
        _toast(wasActive
            ? tr('Отключаю…')
            : (gEngineReal || TunnelEngine.kind() != EngineKind.none ? tr('Подключаю…') : tr('Демо-подключение…')));
      });
      _registeredHotkey = hk;
    } catch (e) {
      // Linux/Wayland глобальные хоткеи часто недоступны — не шумим, просто без хоткея
      debugPrint('registerHotkey failed: $e');
    }
  }

  Future<void> _disposeHotkey() async {
    if (_registeredHotkey == null) return;
    try { await hotKeyManager.unregister(_registeredHotkey!); } catch (_) {}
    _registeredHotkey = null;
  }

  // Рекордер хоткея (Настройки): ловим следующее нажатие с модификаторами, сериализуем, регистрируем.
  Future<void> _recordHotkey(LogicalKeyboardKey logical, PhysicalKeyboardKey physical,
      Set<LogicalKeyboardKey> pressed) async {
    // требуем хотя бы один модификатор — иначе одиночная буква ловила бы весь ввод в системе
    final mods = <String>[];
    bool has(LogicalKeyboardKey a, LogicalKeyboardKey b) => pressed.contains(a) || pressed.contains(b);
    if (has(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight)) mods.add('meta');
    if (has(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight)) mods.add('ctrl');
    if (has(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight)) mods.add('shift');
    if (has(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight)) mods.add('alt');
    // сам модификатор без основной клавиши — игнорируем (ждём буквы/цифры)
    final isModKey = {
      LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
      LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
    }.contains(logical);
    if (isModKey) return;
    if (mods.isEmpty) { _toast(tr('Добавь модификатор (Cmd/Ctrl/Shift)')); return; }
    final keyName = physical.debugName?.toLowerCase().replaceAll(' ', '');
    if (keyName == null || keyName.isEmpty) return;
    final serialized = '${mods.join('+')}+$keyName';
    rebuild(() { hotkeyStr = serialized; _recordingHotkey = false; });
    _save();
    await _registerHotkey();
    _toast(appLang == 'en' ? 'Hotkey set: ${hotkeyLabel(serialized)}' : 'Хоткей: ${hotkeyLabel(serialized)}');
  }

  // Сброс к дефолту Cmd/Ctrl+Shift+B.
  Future<void> _resetHotkey() async {
    rebuild(() { hotkeyStr = kDefaultHotkey; _recordingHotkey = false; });
    _save();
    await _registerHotkey();
  }
}
