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


---

## 构建陷阱：MSVC 源代码编码（C2220 / C4819）

### 症状

```
windows/runner/social_webview.h(1,1): error C2220: 警告被视为错误
windows/runner/social_webview.h(1,1): warning C4819:
    该文件包含不能在当前代码页(936)中表示的字符
```

构建跑了一百多秒、`cnativeapi` 都编译成功了，最后倒在这里 —— 容易被误判成
"工具链没装好"。

### 根因链

```
原作者的 .h/.cpp 是 UTF-8 无 BOM，含韩文注释
        ↓
MSVC 未指定 /utf-8 时按【系统代码页】解析源文件
        ↓
中文 Windows = CP936(GBK)，很多 UTF-8 字节序列在 GBK 下非法
        ↓
warning C4819
        ↓
windows/CMakeLists.txt:42 有 /W4 /WX —— 警告视为错误
        ↓
error C2220
```

### 为什么原作者和 CI 都没事

**CP1252（英文/西文 locale）几乎定义了 0x80–0xFF 的全部字节值。**
同样的 UTF-8 韩文在 CP1252 下只会被解析成乱码，**不触发 C4819**。
英文 region 的机器和 GitHub Actions runner 都是 CP1252，
所以作者的构建一直正常；换到中文 Windows（CP936）就必然失败。

**这不是本项目引入的问题，是原仓库的既有缺陷。**

### 修法

`windows/runner/CMakeLists.txt`：

```cmake
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")
```

**加在这里而不是 `apply_standard_settings()`**：那个函数被
`flutter_wrapper_plugin` 和 `flutter_wrapper_app` 共用，且它自身的注释
明确写着"不要为插件改这个函数"。

### 安全性核实

判断 `/utf-8` 会不会改变行为，关键看非 ASCII 出现在哪：

| 位置 | /utf-8 的影响 |
|---|---|
| 注释 | 无影响（只是正确解码） |
| 字符串字面量 | **会改变**（执行字符集也变成 UTF-8） |

本项目实测：

```
windows/runner/social_webview.h    非 ASCII 4 行，全在注释
windows/runner/social_webview.cpp  非 ASCII 6 行，全在注释
   字符串字面量里的非 ASCII：0 处
```

**零个字符串字面量含非 ASCII ⇒ `/utf-8` 只改变读取方式，行为不变。**

### 自查命令

```bash
python -c "
import os,re,io
exts=('.cpp','.h','.cc','.c','.rc')
for root,_,fs in os.walk('windows'):
    for fn in fs:
        if not fn.endswith(exts): continue
        p=os.path.join(root,fn); d=open(p,'rb').read()
        n=sum(1 for b in d if b>127)
        if n: print(f'{n:>5} 非ASCII  BOM={d[:3]==bytes([0xEF,0xBB,0xBF])}  {p}')"
```

若新增的源文件带非 ASCII 且不在注释里，要么去掉，要么确认 `/utf-8`
对执行字符集的影响可接受。

### 另一种修法（未采用）

给源文件加 UTF-8 BOM。MSVC 用 BOM 自动识别编码，不必改 CMake。
没选它是因为要改动原作者的两个源文件，而改 CMake 不动源码。
