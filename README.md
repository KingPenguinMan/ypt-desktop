# YPT 桌面客户端（非官方）

YPT / 열품타 的非官方桌面客户端。使用 Flutter 编写，支持 Windows / Linux /
macOS 桌面端，另附一个 Flutter Web 演示页和一个 Next.js 落地页。

> [Korean README（上游原始文档）](README_ko.md)

![界面截图](landing/public/hero-dashboard.png)

---

## 关于本仓库

本仓库基于 **[deveworld/ypt_client](https://github.com/deveworld/ypt_client)** 开发。

**原作者：Gi Hyeon Sim（GitHub [@deveworld](https://github.com/deveworld)）**
原始客户端、API 逆向层与落地页均出自其手，版权归原作者所有。

本仓库是面向日常桌面使用而做的分支（fork），在原作者成果之上补充了若干功能，
详见下方「相对上游的增补」。**如果你只需要上游的原始客户端，请直接使用
[上游仓库](https://github.com/deveworld/ypt_client)。**

许可证沿用上游的 MIT，且完整保留了原始版权声明 —— 见 [LICENSE](LICENSE)。

---

## 免责声明

- 本项目**非官方**，与 YPT、Pallo Inc. 及相关权利方无任何隶属、赞助或认可关系。
- **仅供个人账号互通使用。** 不用于操作他人账号、滥用自动化或伪造学习时长。
- 客户端访问 YPT 未公开的 HTTPS 接口（`pi.tgclab.com`）。**该接口随时可能变更
  导致功能失效，且使用方式可能与服务条款冲突。** 风险自负。
- 登录使用邮箱与密码换取 JWT，JWT 通过 `shared_preferences` 明文存储在本地。
- 上游项目曾借助 Codex（GPT 5.5）撰写文档，并在 APK 逆向过程中参考过 Claude 的建议。

---

## 相对上游的增补

| 方面 | 本 fork 增加的内容 |
|---|---|
| **计时状态持久化** | 正在进行的计时会落盘。杀死进程或崩溃后重新打开，计时状态会恢复并可正常停止 —— 修复前服务端会继续累计时长，而客户端已经忘了这个会话。 |
| **系统托盘常驻** | 托盘图标带实时状态行（`数学 1:23:45` / `未在计时 · 今日 4h 9m`），可从托盘开始/停止、按科目展开子菜单、点关闭按钮隐藏到托盘；「退出」会先停掉服务端会话再退出。 |
| **历史视图** | 日历热力图（每日学习时长分档）＋ 科目占比环形图。圆环与图例均支持悬停聚焦，点击可固定选中。 |
| **空档记录** | 停止计时后再次开始时，可记录中间这段时间在做什么。**不足 15 秒或超过 3 小时的空档直接忽略**，记录只保存在本机；已有记录可在历史页补填。 |
| **Windows 构建流水线** | `build_and_test.bat`：静态分析 → 静态自检 → 逻辑自检 → 发布构建 → 打包，并带 C++ 工具链与「实例是否在运行」的前置检查。 |
| **静态自检工具** | `tool/staticcheck.dart` 检查同类内重复成员声明与未使用的 import。本环境无法运行 `dart analyze`（需要派生子进程），故自建。 |
| **诊断日志** | 发布版没有控制台，托盘/窗口/空档的关键事件写入 `%LOCALAPPDATA%\ypt_client\ypt.log`，运行 `open_log.bat` 可直接打开。 |
| **Windows 构建修复** | MSVC 默认按系统代码页读取源文件，而 runner 下若干源文件是带非 ASCII 注释的 UTF-8，在中文 Windows 上会报 `C2220`/`C4819`。已为 runner 目标加上 `/utf-8`。 |
| **接口与依赖文档** | `docs/API_ENDPOINTS.md`（接口表）、`docs/DEPENDENCY_API_NOTES.md`（逐符号核对过的三方包 API，含若干踩坑记录）。 |

---

## 凭证不在本仓库

上游把 OAuth 的 `clientId` / `clientSecret` 硬编码在 `lib/social_auth.dart` 里。
这些是**第三方服务的凭证**，不宜再分发，因此本仓库不再包含它们。

实现方式是**构建期注入**：`lib/social_credentials.dart` 里只有
`String.fromEnvironment(...)`，本身不含任何值。这样既不会泄露，
代码也始终能编译 —— 干净克隆直接可构建，无需先准备配置文件。

填值的方式（三者其一）：

```bash
# 1) 行内传参
flutter build linux --release \
  --dart-define=KAKAO_CLIENT_ID=xxx \
  --dart-define=NAVER_CLIENT_ID=xxx \
  --dart-define=NAVER_CLIENT_SECRET=xxx

# 2) Windows：用 build_and_test.bat，它会自动读取
#    social_credentials.local.bat（该文件不入库，模板见
#    social_credentials.local.bat.example）

# 3) 不填 —— 应用照常构建和运行，只是社交登录提示「未配置」
```

> 需要说明：这些凭证在上游仓库中仍然公开存在，本仓库只是不再继续分发它们。

---

## 从源码构建

### 1. 凭证（可选）

社交登录需要三个值，通过构建参数注入，仓库里不存它们 —— 见上一节。
**跳过这一步项目照样能构建**，只是社交登录会提示「未配置」。

### 2. Linux 开发构建

```bash
flutter doctor
flutter pub get
flutter run -d linux
```

本地发布构建：

```bash
flutter build linux --release
```

产物位于 `build/linux/x64/release/bundle/`。

### 3. Windows

```bat
build_and_test.bat
```

该脚本依次执行静态分析、静态自检、逻辑自检、发布构建与打包。

**前置要求**：需要 Visual Studio 的「使用 C++ 的桌面开发」工作负载 ——
`tray_manager` 依赖的 `cnativeapi` 会在构建时现场编译 C++。

**排错**：发布版没有控制台输出，运行期诊断写入
`%LOCALAPPDATA%\ypt_client\ypt.log`，用 `open_log.bat` 打开。
构建失败时脚本会按错误信息分类给出提示。

### 4. 其他平台

桌面产物应在对应宿主系统上构建。需要跨平台的发布产物时，使用下文的
GitHub Actions 工作流。

---

## 运行检查

两个自检套件和静态自检都是纯 Dart 脚本，**不需要 Flutter SDK 或设备**：

```bash
dart run tool/selftest.dart        # 逻辑断言
dart run tool/calendartest.dart    # 日期解析与热力图分档
dart run tool/staticcheck.dart     # 重复成员声明、未使用的 import
```

在 Windows 上可用 `build_and_test.bat` 一次跑完全部检查与发布构建。

---

## 项目结构

```text
lib/                       Flutter 应用源码
  app_state.dart           登录 / 计时 / 统计 / 群组的状态管理
  ypt_api.dart             YPT 接口客户端
  models.dart              接口响应模型
  screens/                 登录、主页、计时、统计、群组等界面
  history_models.dart      历史视图模型（热力图分档、环形图切片）
  timer_persistence.dart   进行中计时的本地快照
  gap_log.dart             空档记录（见「相对上游的增补」）
  tray_service.dart        托盘图标、菜单、窗口关闭行为
  app_log.dart             文件日志（发布版无控制台）
  social_credentials.dart  第三方凭证 —— 仅读构建参数，文件本身无值

tool/                      独立 Dart 脚本（不依赖 Flutter）
  selftest.dart            逻辑断言
  calendartest.dart        日期与热力图解析断言
  staticcheck.dart         重复成员声明、未使用的 import

docs/                      接口逆向与依赖核对笔记
assets/tray/               托盘图标（白色沙漏，透明底）
build_and_test.bat         Windows：检查 + 构建 + 打包
open_log.bat               Windows：打开运行期日志

linux/  macos/  windows/   各平台桌面目标
web/                       Flutter Web 演示
landing/                   Next.js 静态落地页
.github/workflows/         网页部署与桌面发布工作流
```

---

## 与上游同步

本仓库把上游保留为 `upstream` 远程：

```bash
git remote -v
# origin    https://github.com/KingPenguinMan/ypt-desktop.git
# upstream  https://github.com/deveworld/ypt_client.git

git fetch upstream
git merge upstream/main      # 或 git rebase upstream/main
```

注意：本仓库的历史经过改写（移除了凭证、调整了初始提交），因此与上游的提交
SHA 并不一一对应，合并时可能需要手工处理冲突。

---

## 许可证

[MIT](LICENSE) —— 原始版权归 deveworld（Gi Hyeon Sim）所有，本分支的改动
同样以 MIT 发布。
