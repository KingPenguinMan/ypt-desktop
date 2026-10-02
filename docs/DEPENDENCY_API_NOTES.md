# 依赖 API 核对表

> 核对日期：2026-10-02（含 analyze 实测后的修订）
> 方法：从 pub.dev 下载各包 tarball，**读真实源码**确认签名，不依赖文档描述或记忆。

---

## ⚠️ 最重要的一条：官方示例故意用废弃 API

`tray_manager` 仓库里 `example/lib/tray_controller.dart` 的开头写着：

```dart
// The example shows the deprecated 0.5.x compatible API on purpose.
// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package
...
import 'package:tray_manager/legacy.dart';
```

而 `README.md` 第 93 行给的是：

```dart
import 'package:tray_manager/tray_manager.dart';   // ← 新 API
```

**两个 import 是两套完全不同的 API。** README 里那段"完整示例"（`trayIcon.icon = ImageAsset.fromAsset(...)`）说的是新 API，
但仓库里唯一能运行的示例用的是 legacy API。

**本项目用新 API**（`tray_manager.dart`），因为 legacy 已标记 `@Deprecated`，
且官方明确说"will be removed in a later release"。

---

## 一个容易误判的现象：托盘插件没被注册

`flutter pub get` 后，`windows/flutter/generated_plugin_registrant.cc` 里
**只有 `window_manager`，没有 `tray_manager`**。

**这是正常的，不是 bug。** 核实过程：

```
tray_manager 0.7.0 的 pubspec.yaml
  → 没有 flutter: plugin: 段
  → 整个包只有 lib/ + example/，无 windows/ linux/ macos/ 目录
  → 它是纯 Dart + FFI 库，不走 Flutter 插件注册

真正的原生代码在：tray_manager → nativeapi → cnativeapi
  → cnativeapi 才有 windows/ linux/ macos/ + cxx_impl/（C++ 源码）
```

所以生成的注册文件里没有 `tray_manager` 是预期行为。真正需要 C++ 工具链的是
`cnativeapi`。

---

## 版本链

```
tray_manager 0.7.0        （纯 Dart + FFI，无平台插件目录）
  └─ nativeapi ^0.3.0     ← 实际装 0.3.x，不是最新的 0.4.0
       ├─ cnativeapi ^0.3.0  ← ★ 真正含 C++ 源码，需要 VS 工具链
       │    ├─ cxx_impl/{src,include,cmake,tests}
       │    ├─ windows/ linux/ macos/ android/ ios/
       │    └─ ffiPlugin: true（五个平台）
       └─ nativeapi_flutter  ← ImageAsset 扩展在这里

window_manager 0.5.2         （标准 Flutter 插件，会被注册）
  └─ path ^1.8.2, screen_retriever ^0.2.2
```

**SDK 约束核对**（`pub get` 若报版本错，先看这里）：

| 包 | SDK | Flutter |
|---|---|---|
| tray_manager 0.7.0 | `^3.13.0` | `>=3.47.0` |
| nativeapi 0.3.0 | `^3.13.0` | `>=3.47.0` |
| window_manager 0.5.2 | `>=3.0.0 <4.0.0` | `>=3.3.0` |
| 本项目 pubspec | `>=3.13.0 <4.0.0` | `>=3.47.0` |

实测已装 **Flutter 3.47.6 / Dart 3.13.5**，全部满足。`pub get` 成功。

---

## window_manager 0.5.2 真实 API（实测踩坑记录）

**没有 `getOptions()` / `setOptions()`。** 设置项是逐个方法：

```dart
await windowManager.ensureInitialized();
await windowManager.waitUntilReadyToShow(WindowOptions(...), callback);
await windowManager.setSize(Size size, {bool animate = false});
await windowManager.setMinimumSize(Size size);
await windowManager.setMaximumSize(Size size);
await windowManager.setTitle(String title);
await windowManager.setPreventClose(bool isPreventClose);
Future<bool> isPreventClose();     // ← 是方法，不是 getter
Future<bool> isMinimized();
Future<Size> getSize();
Future<void> show({bool inactive = false});
await windowManager.hide();
await windowManager.focus();
await windowManager.destroy();
void addListener(WindowListener);  // ← 要抽象类实例
```

窗口选项（`WindowOptions`）只在 `waitUntilReadyToShow` 的参数里生效，
之后要改具体项得用上面的 setter。

### WindowListener 是 `abstract mixin class`

```dart
abstract mixin class WindowListener {
  void onWindowClose() {}
  void onWindowFocus() {}
  void onWindowBlur() {}
  void onWindowMaximize() {}
  void onWindowMinimize() {}
  void onWindowRestore() {}
  void onWindowResize() {}
  void onWindowMove() {}
}
```

**因为是 mixin class，可以 `extends`**。传闭包会类型不匹配——
本项目用私有类 `_WindowEvents extends WindowListener` 桥接。

---

## tray_manager / nativeapi 真实 API（新 API）

`import 'package:tray_manager/tray_manager.dart';` 导出：

```
ContextMenuTrigger, Image, ImageAsset, KeyboardAccelerator, ListenerId,
Menu, MenuBackend, MenuClosedEvent, MenuEvent, MenuId, MenuItem,
MenuItemClickedEvent, MenuItemId, MenuItemState, MenuItemSubmenuClosedEvent,
MenuItemSubmenuOpenedEvent, MenuItemType, MenuOpenedEvent, Placement,
PositioningStrategy, TrayIcon, TrayIconClickedEvent,
TrayIconDoubleClickedEvent, TrayIconEvent, TrayIconId, TrayIconPosition
```

### TrayIcon

| 成员 | 签名 | 备注 |
|---|---|---|
| 创建 | `static TrayIcon? create()` | 返回 null 表示系统不支持 |
| 图标 | `set icon(Image? value)` | 用 `ImageAsset.fromAsset(path)` |
| 提示 | `void setTooltip(String? tooltip)` | 传 null 清除 |
| 标题 | `void setTitle(String? title)` | 传 null 清除 |
| 菜单 | `void setContextMenu(Menu? menu)` | 增删菜单项后需重调 |
| 可见 | `bool setVisible(bool visible)` | **返回 bool** |
| 事件 | `ListenerId addListener(void Function(TrayIconEvent) cb)` | **单参数** |
| 释放 | `void dispose()` | 释放 native handle |

### 事件类型（全部继承 `TrayIconEvent`）

```dart
TrayIconClickedEvent({required int trayIconId})
TrayIconRightClickedEvent({required int trayIconId})
TrayIconDoubleClickedEvent({required int trayIconId})
```

### Menu / MenuItem

| 成员 | 签名 | 备注 |
|---|---|---|
| Menu 创建 | `static Menu? create()` | |
| 加项 | `void addItem(MenuItem? item)` | |
| 分隔线 | `void addSeparator()` | |
| MenuItem 创建 | `static MenuItem? createWithLabelAndType(String label, MenuItemType type)` | |
| 标签 | `set label(String? value)` | 挂载后可改 |
| 启用 | `set isEnabled(bool value)` | **没有 `disabled` 属性** |
| 提示 | `set tooltip(String? value)` | |
| 状态 | `set state(MenuItemState value)` | checkbox/radio 用 |
| 子菜单 | `set submenu(Menu? value)` | |
| 事件 | `ListenerId addListener(void Function(MenuEvent) cb)` | **单参数** |

### MenuItemType

```dart
normal(0), checkbox(1), radio(2), separator(3), submenu(4)
```

### MenuEvent

```dart
MenuItemClickedEvent({required MenuItemId itemId})
MenuItemSubmenuOpenedEvent({required MenuItemId itemId})
MenuItemSubmenuClosedEvent({required MenuItemId itemId})
MenuClosedEvent / MenuOpenedEvent
```

### ImageAsset

**是 `Image` 的扩展方法**（在 `nativeapi/lib/src/widgets/image_asset.dart`），不是独立类：

```dart
extension ImageAsset on Image {
  static Image? fromAsset(String assetPath) { ... }
}
```

用法：`icon.icon = ImageAsset.fromAsset('assets/tray/tray_icon.png')`

⚠️ 图片加载失败时 `setIcon` 会在**所有平台**抛 `ArgumentError`，路径必须真实存在。

---

## 已废弃：legacy.dart

以下符号**只存在于 `package:tray_manager/legacy.dart`**，且都带 `@Deprecated`：

```dart
@Deprecated class TrayManager { static final instance; ... }
@Deprecated mixin class TrayListener {
  void onTrayIconMouseDown() {}      // ← 零参数
  void onTrayIconMouseUp() {}
  void onTrayIconRightMouseDown() {}
  void onTrayIconRightMouseUp() {}
  void onTrayMenuItemClick(MenuItem menuItem) {}
}
@Deprecated enum TrayIconPosition { left, right }
@Deprecated class MenuItem { MenuItem({required String key, required String label}); }
```

**legacy 版回调是零参数，nativeapi 版是单参数** —— 混用直接编译失败。

---

## 本项目已修正的错误汇总

| # | 错误 | 修正 |
|---|---|---|
| 1 | `with TrayListener` | `TrayIcon.addListener(void Function(TrayIconEvent))` |
| 2 | 覆写 `onTrayIconMouseDown(MouseDownEvent)` | 这些类型不存在，改为单参数事件回调 |
| 3 | `item.disabled = true` | `MenuItem` 没有 `disabled`，只有 `isEnabled` |
| 4 | `windowManager.addListener(闭包)` | `_WindowEvents extends WindowListener` |
| 5 | `windowManager.getOptions()/setOptions()` | 不存在，改用 `setMinimumSize(Size)` |
| 6 | `statusItem.addListener((event) { if (event is MenuItemClickedEvent) ...})` | 这个**是对的**，保留 |

---

## 剩余风险

### 1. cnativeapi 需要 C++ 工具链

```
cnativeapi/cxx_impl/   ← 完整 C++ 源码
cnativeapi/pubspec     ← ffiPlugin: true，无 build hook，无预编译产物
```

**构建时会现场编译 C++。** Windows 上需 VS 2022「使用 C++ 的桌面开发」工作负载。
`build_and_test.bat` 步骤 `[1b/7]` 会调 `flutter doctor` 检查。

已实测 `flutter doctor` 检测到 **Visual Studio Community 2022 17.9.34622.214 @ D:\IT\VS**，
工具链应该就位。但 VS 2022 17.9 是否含足够的 C++ 组件仍需 build 实测确认。

### 2. 三个平台行为差异

| 平台 | 状态 |
|---|---|
| Windows | 应该可用（待 build 实测） |
| Linux | 托盘点击事件**不上报**（官方文档明确），只能用菜单项；GNOME 需 AppIndicator 扩展 |
| macOS | 需 10.15+；托盘点击同样不上报 |

---

## 排错顺序

1. `analyze` 报错 → 看本文件"已修正的错误汇总"表
2. `cnativeapi` 编译失败 → 装 VS C++ 工作负载
3. 托盘图标不出现 → 检查系统是否支持托盘（`TrayIcon.create()` 返回 null）
4. 点了托盘没反应 → 检查闭包是否被 GC（本项目用 `_menuListeners` 持有引用）
5. 托盘菜单不刷新 → 每次增删菜单项后必须重调 `setContextMenu`

