import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Size;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';

/// 托盘常驻服务。
///
/// 存在的理由不是"桌面端应该有托盘"，而是解决一个具体问题：
/// 计时开始后用户如果直接关窗口，服务端的 /study/stop 就发不出去
/// （startedAt 虽然现在已落盘，但用户看不到界面就无从知晓自己在计时）。
/// 托盘常驻让计时状态始终可见可控。
///
/// ── API 说明（2026-10-02 逐符号核对 nativeapi 0.3.0 / tray_manager 0.7.0）──
/// tray_manager 0.6+ 换成了 nativeapi 底层，`trayManager` 单例与
/// `TrayListener` mixin 都已废弃，只存在于 `legacy.dart`。
/// 本文件用新 API：
///   TrayIcon.create()                → TrayIcon?
///   icon.icon = ImageAsset.fromAsset(path)   （ImageAsset 是 Image 的扩展）
///   icon.setTooltip(String?) / setContextMenu(Menu?) / setVisible(bool)
///   icon.addListener(void Function(TrayIconEvent))  → ListenerId
///   Menu.create() / menu.addItem / menu.addSeparator
///   MenuItem.createWithLabelAndType(label, type)  → MenuItem?
///   item.addListener(void Function(MenuEvent))    → ListenerId
///
/// 注意 MenuItem 没有 `disabled` 属性，只有 `isEnabled`。
///
/// 平台差异（官方文档明确）：
///  - Linux：托盘点击事件**不上报**，StatusNotifierItem 的点击由桌面面板
///    自己处理并直接弹出菜单。所以不能靠点击图标切回窗口，只能用菜单项。
///  - GNOME 默认不显示托盘图标，需要 AppIndicator 扩展。
///  - macOS 需要 10.15+。
class TrayService {
  TrayService(this._app);

  final AppState _app;

  TrayIcon? _icon;
  bool _ready = false;
  bool _quitting = false;

  /// 状态行菜单项。保留引用是为了秒级刷新时只改它的 label，
  /// 而不是重建整棵菜单。
  MenuItem? _statusItem;

  /// 上一次构建菜单时的结构签名。相同则跳过重建。
  String? _menuSignature;

  /// 挂到 nativeapi 事件循环上的回调必须保持引用，否则会被 GC 掉，
  /// 表现为"点了托盘没反应"。
  void Function(TrayIconEvent)? _trayListener;
  final List<void Function(MenuEvent)> _menuListeners = [];

  void setQuitting(bool v) => _quitting = v;

  bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  }

  Future<void> init() async {
    if (!isSupported || _ready) return;
    try {
      // window_manager 没有 getOptions/setOptions——设置项是逐个方法
      // （setSize / setMinimumSize / setTitle ...），窗口选项只在
      // waitUntilReadyToShow 的参数里生效。所以最小尺寸用 setMinimumSize。
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(440, 840), center: true),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      );
      // 太小会让日历热力图和扇形图挤坏。
      await windowManager.setMinimumSize(const Size(400, 620));

      // 先建托盘，**再**决定是否拦截关闭。
      //
      // 顺序很重要：如果先 setPreventClose(true) 而托盘创建失败
      // （系统不支持 / TrayIcon.create() 返回 null），用户就既关不掉窗口、
      // 又没有任何托盘入口可用 —— 只能杀进程。所以拦截关闭必须以
      // "托盘确实可用" 为前提。
      _setupTray();
      if (_icon != null) {
        await windowManager.setPreventClose(true);
        windowManager.addListener(_WindowEvents(this));
      } else {
        // 退化：关闭按钮就是退出。计时快照已落盘，下次启动会恢复。
        debugPrint(
          'tray unavailable — window close will quit the app normally',
        );
      }
      _ready = true;
    } catch (e) {
      debugPrint('tray init failed: $e');
    }
  }

  /// 建立托盘图标。
  ///
  /// 成功时 [_icon] 非空；失败时保持为 null。
  /// **所有可能抛异常的操作都在赋值 [_icon] 之前完成** —— 否则 setIcon
  /// 失败会留下"非空但不可用"的 _icon，让调用方误以为托盘正常。
  void _setupTray() {
    TrayIcon? icon;
    try {
      icon = TrayIcon.create();
      if (icon == null) {
        debugPrint('TrayIcon.create() returned null — 系统可能不支持托盘');
        return;
      }
      // setIcon 在图片加载失败时会抛 ArgumentError（所有平台都是），
      // 所以这里必须给一个真实存在的资源。该资源已随
      // data/flutter_assets/assets/tray/tray_icon.png 打包。
      icon.icon = ImageAsset.fromAsset('assets/tray/tray_icon.png');
      icon.setTooltip('YPT - Yeolpumta');
      _trayListener = (event) {
        // Linux 不上报这些事件，面板自己弹菜单。
        if (Platform.isLinux) return;
        if (event is TrayIconClickedEvent) {
          _showWindow();
        }
      };
      icon.addListener(_trayListener!);
    } catch (e) {
      // 失败就把 native handle 还回去，并保持 _icon 为 null。
      debugPrint('tray setup failed: $e');
      try {
        icon?.dispose();
      } catch (_) {}
      return;
    }
    // 到这里说明前面所有易失败步骤都通过了，可以正式认领。
    _icon = icon;
    _rebuildMenu(); // 先挂菜单
    icon.setVisible(true); // 再显示
  }

  /// 菜单结构签名。结构没变就不重建整棵菜单。
  ///
  /// 只包含**影响菜单项集合**的字段——正在计时与否、科目列表、是否有待补录
  /// 空档。状态行里的计时数字不参与，它走 [_updateStatusLabel] 单独更新。
  String _structureSignature() {
    final st = _app;
    final subjects = (st.user?.subjects ?? const [])
        .take(12)
        .map((s) => '${s.id}:${s.title}')
        .join(',');
    return '${st.studying}|$subjects|${st.hasPendingGap && st.pendingGap!.isOpen}';
  }

  String _statusLabel() {
    final st = _app;
    if (st.studying) {
      return '${st.activeSubject?.title ?? 'Studying'}  ${_hms(st.elapsed)}';
    }
    final today = Duration(milliseconds: st.todayStudyMs);
    return 'Not studying · today ${_hms(today)}';
  }

  /// 秒级刷新：只改状态行文字，不动菜单结构。
  ///
  /// 之前只有 [sync]，而 sync 挂在 ChangeNotifier 上——计时数字的秒级
  /// 通知已经从 ChangeNotifier 拆到 tick 通道了，所以托盘上的时间会静止
  /// 不动。这里补上 tick 侧的刷新。
  ///
  /// 只赋 label 而不重建菜单：MenuItem.label 在挂载后可直接改，重建整棵
  /// 菜单每秒会创建大量 native 对象。
  void tickSync() {
    if (!_ready) return;
    _updateStatusLabel();
  }

  void _updateStatusLabel() {
    final item = _statusItem;
    if (item == null) return;
    final label = _statusLabel();
    if (item.label != label) item.label = label;
  }

  /// AppState 变化时调用，按需刷新菜单。
  void sync() {
    if (!_ready) return;
    final sig = _structureSignature();
    if (sig == _menuSignature) {
      // 结构没变，但状态文字可能变了（比如刚停止计时）。
      _updateStatusLabel();
      return;
    }
    _menuSignature = sig;
    _rebuildMenu();
  }

  /// 重建托盘菜单。
  ///
  /// 只在结构变化时调用（见 [sync]）。重建时旧菜单被整体替换，
  /// 因此旧的回调闭包可以一并丢弃——这正是 [_menuListeners] 要先清空的
  /// 原因：不清就会每次重建都追加，无限增长。
  void _rebuildMenu() {
    final icon = _icon;
    if (icon == null) return;
    final menu = Menu.create();
    if (menu == null) return;

    // 旧菜单即将被替换，它对应的闭包不再需要。
    _menuListeners.clear();
    _statusItem = null;

    final st = _app;

    // 状态行（禁用，仅显示）。保留引用供秒级刷新。
    final statusItem = MenuItem.createWithLabelAndType(
      _statusLabel(),
      MenuItemType.normal,
    );
    if (statusItem != null) {
      // 注意：MenuItem 没有 disabled 属性，用 isEnabled。
      statusItem.isEnabled = false;
      menu.addItem(statusItem);
      _statusItem = statusItem;
      menu.addSeparator();
    }

    if (st.studying) {
      final stop = MenuItem.createWithLabelAndType('Stop', MenuItemType.normal);
      if (stop != null) {
        _bindMenu(stop, () => st.stopTimer());
        menu.addItem(stop);
      }
    } else {
      // 没在计时时列出科目，从托盘直接开始——这是托盘最省事的用法。
      final subjects = st.user?.subjects ?? const [];
      if (subjects.isNotEmpty) {
        final submenu = Menu.create();
        if (submenu != null) {
          for (final s in subjects.take(12)) {
            final item =
                MenuItem.createWithLabelAndType(s.title, MenuItemType.normal);
            if (item == null) continue;
            _bindMenu(item, () => st.startTimer(s));
            submenu.addItem(item);
          }
          final startItem = MenuItem.createWithLabelAndType(
            'Start…',
            MenuItemType.submenu,
          );
          if (startItem != null) {
            startItem.submenu = submenu;
            menu.addItem(startItem);
          }
        }
      }
    }

    // 待补录的空档：给一个入口，避免用户离开电脑后完全忘记。
    if (st.hasPendingGap && st.pendingGap!.isOpen) {
      final gapItem = MenuItem.createWithLabelAndType(
        'Log untimed gap (${st.pendingGap!.duration.inMinutes}m)',
        MenuItemType.normal,
      );
      if (gapItem != null) {
        _bindMenu(gapItem, _showWindow);
        menu.addItem(gapItem);
      }
    }

    menu.addSeparator();
    final showItem =
        MenuItem.createWithLabelAndType('Show window', MenuItemType.normal);
    if (showItem != null) {
      _bindMenu(showItem, _showWindow);
      menu.addItem(showItem);
    }

    final quitItem =
        MenuItem.createWithLabelAndType('Quit YPT', MenuItemType.normal);
    if (quitItem != null) {
      _bindMenu(quitItem, () {
        _quitting = true;
        _quit();
      });
      menu.addItem(quitItem);
    }

    icon.setContextMenu(menu);
  }

  void _bindMenu(MenuItem item, void Function() action) {
    // 这里用局部函数而非 `void Function(MenuEvent) listener = ...`：
    // 声明为局部函数语义相同（都产生一个闭包），但避免了
    // prefer_function_declarations_over_variables 这条 lint。
    //
    // 闭包必须被持有 —— 存在 _menuListeners 里，否则会被 GC，
    // 表现为"点了菜单没反应"。
    void listener(MenuEvent event) {
      if (event is MenuItemClickedEvent) {
        action();
      }
    }

    item.addListener(listener);
    _menuListeners.add(listener);
  }

  void _showWindow() {
    windowManager.show();
    windowManager.focus();
  }

  Future<void> _quit() async {
    // 退出前必须停掉服务端会话，否则用户账号会一直累计时长。
    try {
      await _app.stopTimer(silent: true);
    } catch (e) {
      debugPrint('stop before quit failed: $e');
    }
    await windowManager.destroy();
  }

  /// 窗口关闭被拦截时调用：隐藏到托盘。
  void onWindowCloseAttempt() {
    if (_quitting) return;
    windowManager.hide();
  }

  void dispose() {
    _trayListener = null;
    _menuListeners.clear();
    _statusItem = null;
    _menuSignature = null;
    _icon?.dispose();
    _icon = null;
    _ready = false;
  }
}

/// 窗口事件桥接。
///
/// 单独一个类而不是闭包/ mixin：window_manager 的 [addListener] 要求的是
/// `WindowListener` 抽象类实例，传入函数会类型不匹配。
class _WindowEvents extends WindowListener {
  _WindowEvents(this._tray);

  final TrayService _tray;

  @override
  void onWindowClose() {
    _tray.onWindowCloseAttempt();
  }
}

String _hms(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}';
}
