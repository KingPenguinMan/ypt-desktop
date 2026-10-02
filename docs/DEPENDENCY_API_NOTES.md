# 依赖 API 核对表

> 核对日期：2026-10-02
> 方法：从 pub.dev 下载各包 tarball，**读真实源码**确认签名，不依赖文档描述或记忆。

---

## 为什么有这张表

`tray_manager` 0.7.0 的官方 README 里有一段"兼容示例"，用的是
`trayManager` 单例 + `TrayListener` mixin（`onTrayIconMouseDown(MouseDownEvent)`）。
**那段代码对应的是 `legacy.dart`，不是 `tray_manager.dart`。**
我最初照 README 写，因此引入了一整批不存在的符号。

本表逐个核对实际 API，作为 `flutter analyze` 报错的对照依据。

---

## 版本链

```
tray_manager 0.7.0
  └─ nativeapi ^0.3.0        ← 实际会装 0.3.x，不是最新的 0.4.0
       ├─ cnativeapi        ← FFI 层
       └─ nativeapi_flutter ← widgets 扩展（ImageAsset 在这里）

window_manager 0.5.2         ← 独立包，不依赖 nativeapi
  └─ path ^1.8.2, screen_retriever ^0.2.2
```

**SDK 约束核对**（`pub get` 若报版本错，先看这里）：

| 包 | SDK | Flutter |
|---|---|---|
| tray_manager 0.7.0 | `^3.13.0` | `>=3.47.0` |
| nativeapi 0.3.0 | `^3.13.0` | `>=3.47.0` |
| window_manager 0.5.2 | `>=3.0.0 <4.0.0` | `>=3.3.0` |
| 本项目 pubspec | `>=3.13.0 <4.0.0` | `>=3.47.0` |

本项目已安装 **Flutter 3.47.6 / Dart 3.13.5**，满足全部约束。

---

## tray_manager / nativeapi 真实 API

`import 'package:tray_manager/tray_manager.dart';` 导出的类：

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

### Menu

| 成员 | 签名 |
|---|---|
| 创建 | `static Menu? create()` |
| 加项 | `void addItem(MenuItem? item)` |
| 分隔线 | `void addSeparator()` |
| 清空 | `void clear()` |

### MenuItem

| 成员 | 签名 | 备注 |
|---|---|---|
| 创建 | `static MenuItem? createWithLabelAndType(String label, MenuItemType type)` | |
| 标签 | `set label(String? value)` / `String? get label` | 挂载后可改 |
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
MenuClosedEvent({...})
MenuOpenedEvent({...})
```

### ImageAsset

**是 `Image` 的扩展方法**（在 `nativeapi/lib/src/widgets/image_asset.dart`），不是独立类：

```dart
extension ImageAsset on Image {
  static Image? fromAsset(String assetPath) { ... }
}
```

所以用法是 `icon.icon = ImageAsset.fromAsset('assets/...')`。

⚠️ 图片加载失败时 `setIcon` 会在**所有平台**抛 `ArgumentError`，路径必须真实存在。

---

## 已废弃：legacy.dart

以下符号**只存在于 `package:tray_manager/legacy.dart`**，且都带 `@Deprecated`：

```dart
@Deprecated class TrayManager { static final instance; ... }
@Deprecated mixin class TrayListener {
  void onTrayIconMouseDown() {}
  void onTrayIconMouseUp() {}
  void onTrayIconRightMouseDown() {}
  void onTrayIconRightMouseUp() {}
  void onTrayMenuItemClick(MenuItem menuItem) {}
}
@Deprecated enum TrayIconPosition { left, right }
```

注意 legacy 版 `TrayListener` 的回调是**零参数**（旧 MethodChannel 实现），
而 nativeapi 版是**单参数**（`TrayIconEvent`）。混用会直接编译失败。

---

## window_manager 真实 API

```dart
await windowManager.waitUntilReadyToShow(WindowOptions, callback);
await windowManager.show();
await windowManager.hide();
await windowManager.focus();
await windowManager.destroy();
await windowManager.close();
await windowManager.setPreventClose(bool);
await windowManager.setOptions(WindowOptions);
Future<WindowOptions> getOptions();
bool isClosePrevented();          // getter
Future<bool> isMinimized();
void addListener(WindowListener); // ← 要的是抽象类实例，不是闭包
void removeListener(WindowListener);
```

### WindowListener 是 `abstract mixin class`

```dart
abstract mixin class WindowListener {
  void onWindowClose() {}
  void onWindowFocus() {}
  void onWindowBlur() {}
  void onWindowMaximize() {}
  void onWindowUnmaximize() {}
  void onWindowMinimize() {}
  void onWindowRestore() {}
  void onWindowResize() {}
  void onWindowResized() {}
  void onWindowMove() {}
  // ...
}
```

**因为是 mixin class，可以 `extends`**。传闭包会类型不匹配——
本项目用一个私有类 `_WindowEvents extends WindowListener` 桥接。

### WindowOptions 字段

```dart
Size? size, bool? center, Size? minimumSize, bool? alwaysOnTop,
bool? skipTaskbar, String? title, TitleBarStyle? titleBarStyle
```

---

## 本项目已修正的错误

| # | 错误 | 修正 |
|---|---|---|
| 1 | `with TrayListener` | 改用 `TrayIcon.addListener(void Function(TrayIconEvent))` |
| 2 | 覆写 `onTrayIconMouseDown(MouseDownEvent)` 等 | 这些类型不存在，改为单个事件回调 + `is TrayIconClickedEvent` 判断 |
| 3 | `item.disabled = true` | 改为 `item.isEnabled = false` |
| 4 | `windowManager.addListener(闭包)` | 改为 `_WindowEvents extends WindowListener` |
| 5 | `statusItem.addListener((event) { if (event is MenuItemClickedEvent) ... })` | 这个写法**是对的**，保留 |
| 6 | `icon.setVisible(true)` 忽略 bool 返回值 | 合法，保留 |

---

## 已知构建风险：cnativeapi 需要 C++ 工具链

`tray_manager → nativeapi → cnativeapi`，而 `cnativeapi 0.3.0` 的实际情况是：

```
cnativeapi/
├── cxx_impl/          ← 完整 C++ 源码（src/ include/ cmake/ tests/）
├── lib/src/
├── windows/ linux/ macos/ android/ ios/
└── pubspec.yaml       ← ffiPlugin: true（五个平台都是）
```

**关键点：**

- 声明为 `ffiPlugin`，但**没有 build hook**（`hook/build.dart` 不存在）
- **没有任何预编译产物**（`.dll` / `.so` / `.a` / `.lib` 全部缺失）
- 因此构建时需要**现场编译 C++ 源码**

**这意味着 Windows 上必须装 Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载**，
否则 `flutter build windows` 会在编译 `cnativeapi` 时失败。

`build_and_test.bat` 的步骤 `[1b/7]` 会调 `flutter doctor -v` 检查并给出提示。

### 如果构建在 cnativeapi 上失败

按可能性排序：

| 方案 | 说明 |
|---|---|
| 1. 装 VS C++ 工作负载 | 最直接的解法。控制面板 → 程序 → Visual Studio → 修改 → 勾选「使用 C++ 的桌面开发」 |
| 2. 降级到 `tray_manager 0.5.x` | 旧版基于 `menu_base`，纯 Dart 实现，无 C++ 依赖。但 API 是旧的（`trayManager` 单例 + `TrayListener`），且 0.5.x 要求 Flutter 3.3+，与新版不兼容 |
| 3. 暂时移除托盘 | 注释掉 `main.dart` 里 `TrayService` 的创建，其余功能不受影响（托盘是独立模块） |
| 4. 只做 Linux 构建 | Linux 下 GCC 工具链通常更简单，`apt-get install libgtk-3-dev libx11-dev libxi-dev` 后可能直接能编 |

**方案 3 的代价最小**——托盘是独立文件，其余四项功能（计时持久化、扇形图、
日历热力图、空档询问）都不依赖它。

---

## 如果 analyze 还是报错

按这个顺序查：

1. **`nativeapi` 没装上** → 检查 `pubspec.lock` 里有没有 `nativeapi 0.3.x`
2. **`ImageAsset` 找不到** → 确认 import 的是 `tray_manager.dart` 不是 `legacy.dart`
3. **`ListenerId` / `MenuId` 类型不匹配** → 这些是 opaque handle，别当 int 用
4. **`cnativeapi` 编译失败** → 见上一节，需要 C++ 工具链
