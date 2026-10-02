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
      // 关闭按钮 = 隐藏到托盘，不是退出。
      await windowManager.setPreventClose(true);
      windowManager.addListener(_WindowEvents(this));
      _setupTray();
      _ready = true;
    } catch (e) {
      debugPrint('tray init failed: $e');
    }
  }

  void _setupTray() {
    final icon = TrayIcon.create();
    if (icon == null) {
      debugPrint('TrayIcon.create() returned null — 系统可能不支持托盘');
      return;
    }
    _icon = icon;
    // setIcon 在图片加载失败时会抛 ArgumentError（所有平台都是），
    // 所以这里必须给一个真实存在的资源。
    icon.icon = ImageAsset.fromAsset('assets/tray/tray_icon.png');
    icon.setTooltip('YPT — Yeolpumta');
    _trayListener = (event) {
      // Linux 不上报这些事件，面板自己弹菜单。
      if (Platform.isLinux) return;
      if (event is TrayIconClickedEvent) {
        _showWindow();
      }
    };
    icon.addListener(_trayListener!);
    _rebuildMenu();
    icon.setVisible(true);
  }

  /// 重建托盘菜单。
  ///
  /// 每次状态变化都要重建：MenuItem 的 label 虽然挂载后也能改，但增删
  /// 菜单项必须重新 setContextMenu。
  void _rebuildMenu() {
    final icon = _icon;
    if (icon == null) return;
    final menu = Menu.create();
    if (menu == null) return;

    final st = _app;

    // 状态行（禁用，仅显示）
    final statusLabel = st.studying
        ? '${st.activeSubject?.title ?? 'Studying'}  ${_hms(st.elapsed)}'
        : 'Not studying · today ${_hms(Duration(milliseconds: st.todayStudyMs))}';
    final statusItem = MenuItem.createWithLabelAndType(
      statusLabel,
      MenuItemType.normal,
    );
    if (statusItem != null) {
      // 注意：MenuItem 没有 disabled 属性，用 isEnabled。
      statusItem.isEnabled = false;
      menu.addItem(statusItem);
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

  /// AppState 变化时由外部调用，刷新菜单里的状态行。
  void sync() {
    if (!_ready) return;
    _rebuildMenu();
  }

  /// 窗口关闭被拦截时调用：隐藏到托盘。
  void onWindowCloseAttempt() {
    if (_quitting) return;
    windowManager.hide();
  }

  void dispose() {
    _trayListener = null;
    _menuListeners.clear();
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
