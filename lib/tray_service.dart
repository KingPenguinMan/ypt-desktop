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
///平台差异（来自 tray_manager 官方文档，务必留意）：
///  - Linux：托盘点击事件**完全不上报**（StatusNotifierItem 的点击由面板
///    自己处理并直接弹出菜单）。所以 Linux 上不能依赖 onTrayIconMouseDown
///    来显示窗口，只能靠菜单项。
///  - GNOME 默认不显示托盘图标，需要 AppIndicator 扩展。
///  - macOS 需要 10.15+。
class TrayService with TrayListener {
  TrayService(this._app);

  final AppState _app;

  TrayIcon? _icon;
  Menu? _menu;
  bool _ready = false;

  /// 主窗口隐藏时是否退出应用。false = 继续在托盘跑。
  bool _exitOnClose = false;

  void setExitOnClose(bool v) => _exitOnClose = v;

  bool get isSupported {
    if (kIsWeb) return false;
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) return true;
    return false;
  }

  /// 初始化托盘。必须在 windowManager.ensureInitialized() 之后调用。
  Future<void> init() async {
    if (!isSupported || _ready) return;
    try {
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(440, 840), center: true),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      );
      final opt = await windowManager.getOptions();
      opt.minSize = const Size(380, 600);
      await windowManager.setOptions(opt);
      // 关闭按钮 = 隐藏到托盘，不是退出。
      await windowManager.setPreventClose(true);
      windowManager.addListener(_onWindowListener);
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
    // 没有专用托盘图标资源时用 Flutter 自带的 material 图标转 bytes。
    // setIcon 在图片加载失败时会抛 ArgumentError，所以这里必须给可加载的值。
    icon.icon = ImageAsset.fromAsset('assets/tray/tray_icon.png');
    icon.setTooltip('YPT — Yeolpumta');
    icon.addListener(this);
    _rebuildMenu();
    icon.setVisible(true);
  }

  /// 重建托盘菜单。
  ///
  /// 每次状态变化都要重建：tray_manager 的 MenuItem 只能在挂载期间改
  /// label，增删项必须重新 setContextMenu。
  void _rebuildMenu() {
    final icon = _icon;
    if (icon == null) return;

    final menu = Menu.create();
    if (menu == null) return;
    _menu = menu;

    final st = _app;

    // 状态行（不可点，只显示）
    final statusLabel = st.studying
        ? '${st.activeSubject?.title ?? 'Studying'}  ${_hms(st.elapsed)}'
        : 'Not studying · today ${_hms(Duration(milliseconds: st.todayStudyMs))}';
    final statusItem = MenuItem.createWithLabelAndType(
      statusLabel,
      MenuItemType.normal,
    );
    if (statusItem != null) {
      statusItem.disabled = true;
      menu.addItem(statusItem);
      menu.addSeparator();
    }

    // 开始/停止
    if (st.studying) {
      final stop = MenuItem.createWithLabelAndType('Stop', MenuItemType.normal);
      if (stop != null) {
        stop.addListener((event) {
          if (event is MenuItemClickedEvent) {
            st.stopTimer();
          }
        });
        menu.addItem(stop);
      }
    } else {
      // 没在计时时列出科目，直接从托盘开始学习——这是托盘最省事的用法。
      final subjects = st.user?.subjects ?? const [];
      if (subjects.isNotEmpty) {
        final submenu = Menu.create();
        if (submenu != null) {
          for (final s in subjects.take(12)) {
            final item =
                MenuItem.createWithLabelAndType(s.title, MenuItemType.normal);
            if (item == null) continue;
            item.addListener((event) {
              if (event is MenuItemClickedEvent) {
                st.startTimer(s);
              }
            });
            submenu.addItem(item);
          }
          final startItem =
              MenuItem.createWithLabelAndType('Start…', MenuItemType.submenu);
          if (startItem != null) {
            startItem.submenu = submenu;
            menu.addItem(startItem);
          }
        }
      }
    }

    // 待补录的空档：托盘里给一个入口，避免用户离开电脑后回来完全忘记。
    if (st.hasPendingGap && st.pendingGap!.isOpen) {
      final gapItem = MenuItem.createWithLabelAndType(
        'Log untimed gap (${st.pendingGap!.duration.inMinutes}m)',
        MenuItemType.normal,
      );
      if (gapItem != null) {
        gapItem.addListener((event) {
          if (event is MenuItemClickedEvent) {
            _showWindow();
          }
        });
        menu.addItem(gapItem);
      }
    }

    menu.addSeparator();
    final showItem =
        MenuItem.createWithLabelAndType('Show window', MenuItemType.normal);
    if (showItem != null) {
      showItem.addListener((event) {
        if (event is MenuItemClickedEvent) {
          _showWindow();
        }
      });
      menu.addItem(showItem);
    }

    final quitItem =
        MenuItem.createWithLabelAndType('Quit YPT', MenuItemType.normal);
    if (quitItem != null) {
      quitItem.addListener((event) {
        if (event is MenuItemClickedEvent) {
          _exitOnClose = true;
          _quit();
        }
      });
      menu.addItem(quitItem);
    }

    icon.setContextMenu(menu);
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

  void _onWindowListener() {
    // 拦截关闭：隐藏到托盘。
    if (windowManager.isClosePrevented && _exitOnClose) {
      _quit();
      return;
    }
    if (windowManager.isClosePrevented) {
      windowManager.hide();
      // macOS 上隐藏后 Dock 图标还在，激活一下能真正收起。
      if (Platform.isMacOS) {
        windowManager.setPreventClose(false);
        windowManager.hide();
        windowManager.setPreventClose(true);
      }
    }
  }

  /// AppState 变化时调用，刷新菜单里的状态行。
  void sync() {
    if (!_ready) return;
    _rebuildMenu();
  }

  // ── TrayListener：注意 Linux 上这些事件都不会触发 ──

  @override
  void onTrayIconMouseDown(MouseDownEvent event) {
    // Linux 不支持；这里只用于 Windows/macOS 的左键快速点击。
    if (Platform.isLinux) return;
  }

  @override
  void onTrayIconRightMouseDown(MouseDownEvent event) {
    if (Platform.isLinux) return;
  }

  @override
  void onTrayIconMouseUp(MouseUpEvent event) {}

  @override
  void onTrayIconRightMouseUp(MouseUpEvent event) {}

  @override
  void onTrayIconClick(MouseClickEvent event) {
    // Linux 不上报点击，面板自己弹出菜单。那里不能靠点击切回窗口。
    if (Platform.isLinux) return;
    if (event.button == MouseButton.left) {
      _showWindow();
    }
  }

  @override
  void onTrayIconRightClick(MouseClickEvent event) {
    if (Platform.isLinux) return;
  }

  @override
  void onTrayIconDoubleClick(MouseDoubleClickEvent event) {
    if (Platform.isLinux) return;
  }

  @override
  void onTrayMenuItemClick(MenuItemClickEvent event) {}

  void dispose() {
    windowManager.removeListener(_onWindowListener);
    _icon?.dispose();
    _icon = null;
  }
}

String _hms(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}';
}
