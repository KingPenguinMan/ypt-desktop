# YPT API 端点清单（RE 提取）

> 来源：`YPT - Yeolpumta 810.0.85`（XAPK，包名 `com.pallo.passiontimerscoped`）
> 提取源：`config.arm64_v8a.apk` → `lib/arm64-v8a/libapp.so`（40.4 MB，Dart AOT）
> 提取日期：2026-10-02
> 端点总数：**243**（含 `/group/*` 90+ 个）

## 提取方法

```python
import re
data = open('libapp.so','rb').read()
strs = re.findall(rb'[\x20-\x7e]{3,160}', data)      # 可打印 ASCII 段
paths = {s.decode() for s in strs
         if re.match(r'^/[a-zA-Z0-9/_.\-]+$', s.decode())}
```

**要点：**
- Dart AOT 把所有字符串常量放进一张符号表，**字符串本身完整保留**
- 但彼此偏移是随机交织的 —— **靠偏移取上下文无效**（提取出来全是无关噪声）
- `libapp.so` 里只有 i18n **key**，没有韩文/中文文案。文案在 Dart 侧被常量折叠或来自服务端，需要界面截图才能拿到
- `config.ko.apk` 里只有 `resources.arsc` + 一张图，无 l10n 文本

## 验证方法

服务端区分「路径不存在」和「需要鉴权」：

| 情况 | 状态码 | 响应体 |
|---|---|---|
| 不存在 | `404` | 空 |
| 存在但 token 无效 | `200` / `403` | `{"s":false,"c":"108"}` / HTML |

错误码 `108` = token 无效/缺失。

---

## 计时与休息

| 端点 | 用途 | 本客户端 |
|---|---|---|
| `POST /study/start` | 开始计时 | ✅ 已用 |
| `POST /study/stop` | 停止计时 | ✅ 已用 |
| `POST /study/app/start` | App 内开始（区别于 `/study/start`） | ❌ |
| `POST /study/app/stop` | App 内停止 | ❌ |
| `POST /study/sync-offline-data` | 离线记录补传 | ⚠️ 方法已备 |
| `POST /study/planner/finish` | 完成番茄钟 | ❌ |
| `POST /study/study-plan/rest` | 学习计划里的休息 | ❌ |
| `POST /study/study-plan/update-order` | 计划排序 | ❌ |
| `POST /rest/record` | **记录休息（"在做什么"）** | ⚠️ 路径已发现，协议未验证，当前不上传 |
| `POST /rest/add` | 补记休息 | ⚠️ 当前不上传 |
| `POST /rest/edit` | 修改休息 | ⚠️ 当前不上传 |
| `POST /rest/delete` | 删除休息 | ⚠️ 当前不上传 |
| `POST /rest/tags/edit` | 休息标签管理 | ⚠️ 当前不上传 |

### 休息记录字段（二进制确认）

```
tag        休息标签（可空）
startedAt  休息开始，epoch 毫秒
endedAt    休息结束，epoch 毫秒
minutes    休息时长，分钟  ← 注意与 /study 的毫秒不同
```

### 休息 UI 流程（i18n key 还原）

```
stop_study_enter
 └─ alert_stop_study_just_now_record      停止后立即询问
    └─ study_dialog_rest_title
       ├─ study_dialog_rest_record         记录
       │  └─ study_dialog_rest_edit_tag
       │     └─ study_break_tag_selection
       │        ├─ select_break_tag_msg
       │        └─ study_break_tag_not_exist_alert
       └─ study_dialog_rest_skip           跳过
```

标签是**用户可编辑的**（`/rest/tags/edit` + `study_rest_tag_title` 等 key +
`INFO_REST_TAGS` 常量），**预置枚举值未在二进制中找到**，应从服务端下发。

### 离线支持

`OFFLINE_POMODORO_START_LOG` / `OFFLINE_POMODORO_STOP_LOG` /
`OFFLINE_POMODORO_BREAK_TMP_MINUTES` / `OFFLINE_POMODORO_LAST_STATE` +
`/study/sync-offline-data` → 官方支持离线记账后补传。

---

## 日志与统计

| 端点 | 用途 | 本客户端 |
|---|---|---|
| `GET /logs/day?date=` | 单日日志 | ✅ 已用 |
| `GET /logs/v2/day?date=` | 遗留，服务端有但**官方客户端不用** | ⚠️ 兜底 |
| `GET /logs/range/days` | 期间范围（日历批量） | ✅ 已用 |
| `GET /logs/calendar/home` | 日历摘要 | ✅ 已用 |
| `GET /logs/calendar/todos` | 日历 + Todo | ❌ |
| `GET /logs/day/closing-log` | 结课日志 | ❌ |
| `GET /logs/category/member/ranks` | 分类排名 | ✅ 已用 |
| `GET /logs/my-category-rank` | 我的分类排名 | ✅ 已用 |
| `GET /logs/my-category-cam-rank` | 分类拍立得排名 | ❌ |
| `GET /logs/group/attendances` | 出勤 | ❌ |
| `GET /logs/group/member/ranks` | 组内排名 | ❌ |
| `GET /logs/group/members` | 组员（v1） | ❌ |
| `GET /logs/group/members/v2` | 组员（v2） | ✅ 已用 |
| `GET /logs/group/member/dialog/v3` | 组员对话框 | ❌ |
| `GET /logs/school/member/ranks` | 学校排名 | ❌ |
| `GET /logs/v70701/group/attendances` | 出勤（v70701） | ❌ |
| `GET /logs/v70701/group/challenge-ranks` | 挑战排名 | ❌ |

### `dl` 结构（第三方开源实现 `astroanax/JEEhadistBOT` 实证）

```python
rank["dl"]["is"]   # 是否正在计时中
rank["dl"]["st"]   # 本次会话开始时间，格式 "%Y-%m-%d %H:%M:%S.%f%z"（带时区）
rank["dl"]["sm"]   # 已学习毫秒
```

**⚠️ 时区要点**：`st` 带时区偏移，而 epoch 毫秒转日期时本客户端固定按 **KST(UTC+9)** 处理。1700000000000 在 UTC 是 11-14、KST 是 11-15 —— 用本地时区会错一天。

---

## 用户与认证

| 端点 | 用途 | 本客户端 |
|---|---|---|
| `POST /user/sign-in-jwt` | 邮箱登录 | ✅ 已用 |
| `POST /user/social/sign-up-jwt` | 社交登录/注册 | ✅ 已用 |
| `POST /user/v2/reload/info` | 资料/科目/今日日志 | ✅ 已用 |
| `POST /user/logout` | 登出 | ❌ |
| `POST /user/unregister` | **注销账号**（合规） | ❌ |
| `POST /user/splash-login` / `/user/v2/splash-login` | 启动登录 | ❌ |
| `POST /user/v2/cache` | 缓存 | ❌ |
| `POST /user/v2/create-email-account` | 注册 | ❌ |
| `POST /user/v2/reset-password` | 重置密码 | ❌ |
| `POST /user/v2/send-password-reset-code` | 发重置码 | ❌ |
| `POST /user/v2/send-signup-code` | 发注册码 | ❌ |
| `POST /user/v2/verify-code` | 验码 | ❌ |
| `POST /user/check-password` | 校验密码 | ❌ |
| `POST /user/find-email` | 找回邮箱 | ❌ |
| `POST /user/reset-password-jwt` | JWT 重置密码 | ❌ |
| `POST /user/exist-username` | 用户名存在性 | ❌ |
| `POST /user/detail` | 详情 | ❌ |
| `POST /user/nickname/change` | 改昵称 | ❌ |
| `POST /user/status-msg` / `/user/status_msg/change` | 状态消息 | ❌ |
| `POST /user/notifications` | 通知 | ❌ |
| `POST /user/push-token` | 推送 token | ❌ |
| `POST /user/read-notice` | 已读通知 | ❌ |
| `POST /user/schedule` / `DELETE` | 日程 | ❌ |
| `POST /user/shake/change` | 摇一摇设置 | ❌ |
| `POST /user/push-token` | 推送 | ❌ |
| `POST /user/callback/sign-in-with-apple` | Apple 登录回调 | ❌ |
| `POST /user/api-jwt-auth/` | API JWT 认证 | ❌ |
| `POST /user/firebase/custom-token` | Firebase token | ❌ |
| `POST /user/disconnect-naver` | 解绑 Naver | ❌ |
| `POST /user/d-day/create` | D-Day 创建 | ❌ |
| `POST /user/d-day/get` | D-Day 查询 | ❌ |
| `POST /user/d-day/edit` / `delete` | D-Day 改/删 | ❌ |
| `POST /user/subject/create` | 建科目 | ❌ |
| `POST /user/subject/edit` | 改科目 | ❌ |
| `POST /user/subject/order/change` | 科目排序 | ❌ |
| `POST /user/subject/archive/change` | 归档科目 | ❌ |
| `POST /user/subject/hard-delete` | 彻底删科目 | ❌ |

---

## 科目与 Todo

| 端点 | 用途 | 本客户端 |
|---|---|---|
| `POST /study/add` | 添加学习记录 | ❌ |
| `POST /study/edit` / `delete` | 改/删记录 | ❌ |
| `POST /study/task/make` | **创建 Todo** | ❌ |
| `POST /study/task/edit` / `delete` | 改/删 Todo | ❌ |
| `POST /study/todo/statistics/main` | Todo 统计 | ❌ |
| `POST /study/white-noise/all` | 白噪音列表 | ❌ |
| `POST /study/generator/add` / `edit` / `delete` | 生成器 | ❌ |
| `POST /study/cam-ms` | 拍立得毫秒 | ❌ |

---

## 小组（90+ 端点，PC 端只实现了 5 个）

**PC 端已用**：`/group/groups/v2`、`/group/list-new-2`、`/group/detail`(部分)

**未实现的重要部分**：

| 类别 | 端点 |
|---|---|
| 建组 | `/group/make`、`/group/make2`~`/group/make5`、`/group/make/v2`、`/group/make/title/validate` |
| 申请/审批 | `/group/join/step1`、`/group/join/step2`、`/group/join/v2`、`/group/join/info`、`/group/group-user/join/approve-or-reject`、`/group/group-user/join-info`、`/group/waiting/member`、`/group/waiting/member/reject/reason` |
| 退出/踢人 | `/group/leave`、`/group/kick-out` |
| 设置 | `/group/profile/setting`、`/group/join/type/setting`、`/group/question/setting`、`/group/user/notice/setup`、`/group/school-info/*` |
| 聊天 | `/group/chat`、`/group/message`、`/group/messages`、`/group/message/update`、`/group/groups/chat-badges` |
| 帖子 | `/group/post`、`/group/posts`、`/group/legacy/post`、`/group/post/vote`、`/group/post/vote/cam`、`/group/post/report` |
| 通知 | `/group/notice`、`/group/notice/read`、`/group/notification`、`/group/push/notice`、`/group/push/shake`、`/group/push/shake/all` |
| 挑战 | `/group/challenge/detail`、`/group/challenge/list`、`/group/challenge/make`、`/group/challenge/make/date/select`、`/group/challenge/make/type/list` |
| 任务 | `/group/mission`、`/group/mission/list`、`/group/mission/rank`、`/group/mission/past/rank`、`/group/mission/past/timebook`、`/group/mission/proof`、`/group/mission/range/proofs`、`/group/mission/user/proofs`、`/group/flashcardmission/*`、`/group/photomission/*` |
| 排行榜 | `/group/list-attendance-2`、`/group/list-cam-2`、`/group/list-mission-2`、`/group/list-owner-2`、`/group/list-time-2`、`/group/list/search-2` |
| 封禁 | `/group/black/add`、`/group/black/all`、`/group/black/delete`、`/group/warn`、`/group/warn/cancel` |
| Webtoon | `/group/webtoon/*`（join/leave/my-study/studies/users/cookie/promo） |
| 其它 | `/group/search`、`/group/search-info/v2`、`/group/meta`、`/group/user`、`/group/user/manage`、`/group/user/order`、`/group/order`、`/group/promote`、`/group/delete`、`/group/get-group`、`/group/sync-member-count`、`/group/quiz/push`、`/group/book-presigned-url`、`/group/cafe-presigned-url`、`/group/presigned-url`、`/group/info/edit`、`/group/check-password` |

---

## 计划器 / 日历（10 分钟计划器相关）

| 端点 | 用途 |
|---|---|
| `GET /planner/user/calendar/select` | 日历选择 |
| `GET /planner/user/calendar/settings` | 日历设置 |
| `GET /planner/subject/list` | 科目列表 |
| `GET /planner/timeline/editor` | 时间线编辑器 |
| `GET /planner/edit/logs` | 编辑日志 |
| `GET /planner/themes` / `planner/stuff` | 主题/素材 |
| `GET /planner/capture` / `planner/bookshelf` | 截图/书架 |
| `POST /planner/event/create` | 创建事件 |
| `GET /planner/school/event/hide/keywords` | 隐藏关键词 |
| `GET /planner/bookshelf` | 书架 |

i18n key：`planner_menu_study_log`、`planner_study_log_editor_*`、`planner_dialog_edit_record_title`、`timeline_between_log_rest_btn`

---

## 挑战 / 任务系统

| 端点 | 用途 |
|---|---|
| `GET /challenge`、`/challenge/detail`、`/challenge/ranking`、`/challenge/date-selection`、`/challenge/sleep`、`/challenge/user-detail`、`/challenge/fee` | 官方挑战 |
| `POST /challenge/submit-day-off`、`/challenge/submit-preview` | 提交休息日 |
| `GET /mission/challenges`、`/mission/challenges/ypt` | 挑战列表 |
| `GET /mission/challenge/user/logs`、`/mission/challenge/logs/rest`、`/mission/challenge/logs/sleep`、`/mission/challenge/ranking/*` | 挑战日志与排名 |
| `POST /mission/challenge/logs/update-batch`、`/logs/delete-batch` | 批量操作 |
| `GET /mission/challenge/v2/daily-planner/logs` | 日计划日志 |
| `POST /mission/push/remind`、`/mission/push/remind/all` | 提醒 |

---

## 报告 / 成绩

`/report/main`、`/report/examination`、`/report/examination/goal`、`/report/examination/goal/result/regit`、`/report/general/*`、`/report/grade/semester`、`/report/grade/subject`、`/report/mid/*`、`/report/nickname`、`/report/profile*`、`/report/univ/*`、`/report/group`、`/report/setting`、`/report/status-msg`、`/grade/activity-score`、`/grade/activity-scores`

---

## 认证与第三方

| 端点 | 用途 |
|---|---|
| `GET /auth/authorize` | 授权页 |
| `GET /music/comment/like` | 音乐评论点赞（推测为 BGM 功能） |

---

## 未确认项

| 待确认 | 原因 |
|---|---|
| 休息标签的服务端预置列表 | 二进制里没有，应由某个读取端点下发（未找到，可能在 `/user/v2/reload/info` 里） |
| `/rest/record` 完整响应结构 | 需有效 JWT |
| 各端点必需参数与类型 | 需有效 JWT 实测 |
| 韩文/中文显示文案 | 二进制与语言包均无，需界面截图 |
| 大量端点的 HTTP 方法 | 字符串表不含方法信息，同一路径可能是 GET/POST 二选一 |

## 风险提示

Firehound 事件（VX Underground / CovertLabs，TechRadar 报道）列出 YPT 涉及 200 万+ 用户数据泄露（聊天消息、AI tokens、用户 ID、用户 keys）。因此本客户端的存储安全应当收紧：

- `ypt_api.dart` 硬编码伪装成安卓机的设备指纹 `SM-S921N`
- JWT 明文存 `shared_preferences`
- 从 APK 提取的 OAuth `clientId` / `clientSecret` 曾硬编码在 `social_auth.dart`；
  现已移至 **`lib/social_credentials.dart`，该文件不纳入版本控制**（模板见
  `lib/social_credentials.example.dart`）。公开仓库中不含这些凭证。

建议后续迁移到 `flutter_secure_storage`（Windows DPAPI / macOS Keychain），密钥改由
构建期注入（`--dart-define`）而非源码常量。
