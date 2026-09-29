# SSH Pad Flutter

Pad 优先的 Flutter SSH / Telnet / SFTP / FTP 终端客户端。  
对齐 [ServerBox](https://github.com/lollipopkit/flutter_server_box) 架构思路（`dartssh2` + `xterm` + 会话生命周期 + Android 前台服务），重写现有 Kotlin 版 [ssh-pad](https://github.com/camilavivan/ssh-pad)。

> **许可**：本仓库建议 Apache-2.0 / MIT。不复制 ServerBox 源码（AGPLv3）；仅使用 pub.dev 公开包与自研代码。

## 产品目标

- **Pad 优先 UI**：宽屏（≥600dp）左栏节点/会话 + 可拖分割条 + 右栏终端/文件；窄屏 NavigationRail。
- **外接 / 蓝牙键盘**：`configChanges` 含 keyboard；Ctrl-C = SIGINT；resume 清 IME 组字；插拔/旋转 refit PTY。
- **首发协议**：SSH、SFTP、TELNET、FTP；主机档案含 `protocol` 字段。
- **保活是重中之重**：切应用/熄屏不断开；同进程 ForegroundService（`mediaPlayback|dataSync`）+ 默认弱音 AudioTrack + Wake/Wifi 锁 + 首次连接电池白名单 + OEM 引导；默认**不**无限静默自动重连。
- 延后：SERIAL / LOCAL / RLOGIN（选择器可见，标注「稍后」）。

完整计划见 [`docs/rewrite-plan.md`](docs/rewrite-plan.md)。

## 协议矩阵（MVP vs 延后）

| 协议 | 默认端口 | 首发 | 说明 |
|------|----------|------|------|
| SSH | 22 | ✅ MVP | `dartssh2` PTY |
| SFTP | 22 | ✅ MVP | `dartssh2` SftpClient |
| TELNET | 23 | ✅ MVP | `ctelnet` |
| FTP | 21 | ✅ MVP | `ftpconnect`（FTPS/FTPES + PASV） |
| SERIAL / LOCAL / RLOGIN | — | 隐藏 | 枚举保留；协议选择器不展示 |

## 技术栈

| 项 | 选型 |
|----|------|
| Flutter | stable（本机以 `flutter --version` 为准） |
| 状态 | Riverpod |
| SSH/SFTP | dartssh2（每主机共享一个 `SSHClient`；多终端=多 shell；Files=`client.sftp()`） |
| 终端 | xterm |
| Telnet | ctelnet |
| FTP | ftpconnect |
| 持久化 | shared_preferences |
| 唤醒 | wakelock_plus |
| 保活 | 自写 Android FGS（mediaPlayback\|dataSync）+ 弱音 + MethodChannel |

## 里程碑（保活提前）

1. **M0** — 脚手架 + HostProfile + 保活骨架（FGS stub）
2. **M1** — 最小 SSH 终端
3. **M1b** — **保活 FGS 完整接通（关键路径）**
4. **M2** — SFTP / TELNET / FTP
5. **M3** — Pad 布局 / 键盘打磨
6. **M5** — 发版打磨
7. **v0.5.3** — 连接共享（多 shell + SFTP 同会话）
8. **v0.5.4** — 主机卡片资源状态（CPU / MEM / NET / DISK，共享 SSH exec）
9. **v0.5.5** — 硬件 Esc 全局策略（永不作 Back；终端发 0x1b）
10. **v0.5.6** — Esc / 硬件键盘打磨版（overlay 优先、Ctrl+[、分栏无焦点）
11. **v0.5.7** — OEM Esc→BACK 重映射修复（OnePlus Pad Ace 2 Pro / ColorOS；scanCode 1/158）
12. **v0.5.8** — 软键盘可唤起 + 本地文件列表修复 ← 当前

## Pad 布局与键盘（M3）

- **≥600dp**：左栏主机卡片 / 会话列表，中间 14dp 拖拽分割条（宽度持久化），右栏终端或文件。
- **&lt;600dp**：`NavigationRail`（主机 / 终端 / 文件 / 设置），避免破坏手机布局。
- **安全区**：顶栏控件最小点击热区 **48dp**；OEM 状态栏 inset 为 0 时保底 40dp。
- **键盘**：
  - Manifest `configChanges` 已含 `keyboard|keyboardHidden|navigation`（插拔不重建 Activity）。
  - **Esc 全局策略**：整个 App 内硬件 Esc **绝不**当作 Flutter/Android Back；`DismissIntent` shortcut + action 双保险；仅可关闭 barrierDismissible 浮层（菜单优先于终端）；终端会话活跃且非文本框焦点时发 `0x1b` 到 PTY（含 Pad 分栏终端可见但未聚焦）；**Ctrl+[** → Esc（vi）；系统返回键/手势仍可导航。
  - **OEM Esc→BACK 重映射（v0.5.7）**：国行平板外接键盘常把物理 Esc 报成 `KEYCODE_BACK`。Android 侧 `MainActivity` 识别 Linux scanCode **1**（KEY_ESC，小米系）与 **158**（KEY_BACK，一加 Pad Ace / ColorOS 常见）+ `SOURCE_KEYBOARD` 非虚拟设备，改写为 `KEYCODE_ESCAPE` 并消费，避免 ColorOS `finish()` 退桌面并掐断 SSH。根路由另有 `PopScope(canPop: false)` 兜底，Back 不退出 Activity；嵌套路由仍可 pop。真·软键/手势 Back（scanCode 0）不受影响。调试：`adb logcat -s SshPadMain` 可见 `physical Esc rewrite …`。
  - `HardwareKeyboard`：**Ctrl-C → SIGINT**（非复制；复制为 Ctrl+Shift+C）。Esc / Ctrl+[ 由 `AppEscapePolicy` 单路径发送，避免与 TerminalView 双发。
  - Resume / 可见性：unfocus→`InputMethodManager.restartInput`→focus，清 IME 组字。
  - Metrics 变化：重建 fit 行列并触发 PTY `resize`。
  - 软键盘：`TextInputType.visiblePassword`（少联想 / 智能标点）。
  - **硬件键盘检测（v0.5.8）**：Android 用 `InputDevice` 枚举非虚拟 `SOURCE_KEYBOARD` + `KEYBOARD_TYPE_ALPHABETIC`，不再仅看 `Configuration.keyboard`（ColorOS / 一加平板常误报 QWERTY）。真·外接键盘时默认 `hardwareKeyboardOnly` 并收起 ExtraKeys 全键条。
  - **「键盘」手动唤起**：工具栏图标 / ExtraKeys「键盘」/ 菜单「键盘（软键盘）」可强制软 IME（`_forceSoftIme`）；即使 HW 误检也能弹出系统软键盘并显示 ExtraKeys。MethodChannel `showSoftInput` → `InputMethodManager.showSoftInput`。
  - 无外接键盘时 ExtraKeys 默认可见；有真·硬件键盘时仍保留紧凑「键盘」开关。


## 主机资源状态（v0.5.4）

已连接的 **SSH / SFTP** 主机卡片显示 ServerBox 风格紧凑条：

- **CPU %**（`/proc/stat` 两次采样差分）
- **MEM** used/total（`/proc/meminfo` MemTotal − MemAvailable）
- **NET** ↓rx ↑tx B/s（`/proc/net/dev` 差分）
- **DISK** `/` used/total（`df -Pk /`，可选）
- load average

采样：每 ~2.5s 对共享 `SshConnectionHub` 客户端 `exec` 一次（**不**另开 SSH）；应用进后台停表，保活不变；Telnet/FTP 不显示。

## 如何运行

```bash
# 依赖：Flutter stable、JDK 17、Android SDK（minSdk 26）
export PATH="/home/box/flutter/bin:$PATH"
flutter pub get
flutter analyze
flutter test
flutter run   # 需连接设备 / 模拟器
```

保活相关设置：左栏盾牌图标，或窄屏「设置」。

## 仓库说明

- 发布仓：`Ghostpanter/ssh-pad-flutter`（原 `camilavivan/ssh-pad-flutter` 不可达时的镜像）。
- Kotlin 对照仓：`camilavivan/ssh-pad` / `Ghostpanter/ssh-pad`（勿与本仓混淆）。
- 应用 id：`com.sshtab.ssh_pad_flutter`
- org：`com.sshtab`


## M5 打磨

- **TOFU 主机密钥**：SSH/SFTP 首次连接展示指纹并写入信任库；指纹变更时警告，可拒绝或替换。
- **安全密钥存储**：密码 / 私钥 / 口令经 `flutter_secure_storage` 保存；SharedPreferences 仅存主机元数据；启动时迁移旧明文。
- **双栏文件浏览器**：宽屏（≥600dp）左本地 / 右远程，支持上传、下载、远程 mkdir/删除；窄屏可切换显示本地栏。本地栏用 `stat`/`FileSystemEntity.type` 列举（不再依赖 `e is File`，避免 Android 上只见文件夹不见文件）；默认根目录为应用 `SSHPad` 文件夹；API≤32 可请求 `READ_EXTERNAL_STORAGE`；Android 13+ 受限路径请用应用目录或系统选取上传。
- **会话日志**：设置页可查看近期连接 / 密钥 / 文件操作事件。
- **安装**：从 [GitHub Releases](https://github.com/Ghostpanter/ssh-pad-flutter/releases) 下载 APK（`v0.5.8`）。

### 自行签名发版

```bash
# 生成上传密钥（勿提交）
mkdir -p /workspace/secrets
keytool -genkeypair -v -keystore /workspace/secrets/ssh-pad-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias ssh-pad \
  -storepass CHANGE_ME -keypass CHANGE_ME \
  -dname "CN=SSH Pad, OU=Dev, O=SSHTab, L=HK, ST=HK, C=HK"

# /workspace/secrets/key.properties:
# storePassword=CHANGE_ME
# keyPassword=CHANGE_ME
# keyAlias=ssh-pad
# storeFile=/workspace/secrets/ssh-pad-upload.jks

export PATH="/home/box/flutter/bin:$PATH"
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

若未配置 `key.properties`，release 仍可用 Android debug 签名构建（仅供内测）。用户可用自己的密钥重新签名后再分发。



## 软键盘自测（v0.5.8）

1. **无外接键盘**（拔掉蓝牙键盘）：打开终端 → 应自动可用系统软键盘；ExtraKeys（Esc/Tab/Ctrl…）可见。
2. 若软键盘未出：点工具栏键盘图标，或 ExtraKeys「键盘」，或菜单「键盘（软键盘）」→ 再点终端区域 → **系统软键盘应出现**；ExtraKeys 保持可见。
3. 接上真·蓝牙键盘：ExtraKeys 全键条可收起，但底部仍有「键盘」开关；点「键盘」可强制唤起软 IME（不依赖误检）。
4. 一加 Pad Ace 2 Pro / ColorOS：即使系统误报有硬件键盘，点「键盘」仍必须能弹出软键盘。

## 本地文件自测（v0.5.8）

1. 打开 SFTP/FTP 文件页：左栏本地默认在应用 `SSHPad` 目录。
2. 向该目录放入测试文件（或从远程下载一个文件）→ **刷新后应同时看到文件夹与文件**；文件行有上传按钮。
3. 进入子文件夹再返回：文件仍正常列出（不再「只能进目录、看不见文件」）。
4. 点「选择文件夹」浏览到 Downloads 等共享路径：API≤32 会请求存储权限；若 Android 13+ 仍只见目录，按提示改用应用 SSHPad 目录或远程栏「上传（选取文件）」系统选取器。

## 硬件 Esc 自测清单（v0.5.7 / OEM 重映射）

1. 外接 / 蓝牙键盘连接 SSH，打开 `vi` / `vim`，`i` 进插入模式 → **Esc** 退回正常模式，**不得**退出 App / 切走终端 / 断开会话。
2. **OnePlus Pad Ace 2 Pro（ColorOS）**：物理 Esc 不得退到桌面；PTY 应收到单个 `0x1b`。若仍异常，抓 `adb logcat -s SshPadMain` 看 `physical Esc rewrite keyCode=… scanCode=…`（预期 scanCode `1` 或 `158`）。
3. 同上，试 **Ctrl+[**：应等同 Esc（退插入模式），且只生效一次（无双 Esc）。
4. 主机列表 / 设置 / 文件页按 Esc：界面保持，不得 `Navigator.pop` / 退桌面。
5. 打开终端溢出菜单（⋯）按 Esc：仅关闭菜单，不离开终端、不杀会话。
6. TOFU 主机密钥对话框（不可点遮罩关闭）：Esc **不得**误关 / 误拒绝；需点按钮。
7. Pad 分栏：终端在右侧可见，焦点在左侧主机列表时按 Esc：应送到 PTY（vi 仍可退模式），不得 Back。
8. 主机编辑页（TextField 焦点）按 Esc：不得注入后台 PTY，也不得 pop 编辑页；系统 Back / 手势仍可 pop 编辑页。
9. 系统返回键或手势返回：嵌套路由可 pop；**根路由 Back 不得 finish Activity**（会话应仍活着；可用 Home 键正常回桌面）。
10. ExtraKeys 点 Esc：照常发 `0x1b`（软键路径与硬件策略独立）。

## 保活自测（v0.5.1+）

1. 安装 release APK，授予**通知权限**。
2. 连接一台 SSH 主机；应立刻看到「SSH Pad 会话保活」通知。
3. 按 Home / 切到其他应用，等待 **2–5 分钟**，再返回：会话应仍在，终端可继续输入。
4. `adb logcat -s SshPadFGS SshPadAudio SshPadMain` 应能看到 `startForeground mediaPlayback|dataSync ok` 与 `weak audio started`。

### 国行 OEM 建议（若仍被冻）

| 厂商 | 设置 |
|------|------|
| 小米/红米 | 自启动 = 允许；省电策略 = 无限制；锁屏清理白名单 |
| 华为/荣耀 | 启动管理 = 手动管理全开；后台活动 = 允许 |
| OPPO/一加/realme | 耗电管理 = 允许后台；自启动 = 允许 |
| vivo/iQOO | 后台高耗电 = 允许；自启动 = 允许 |
| 通用 | 忽略电池优化；可选开启悬浮窗 |

弱音保活默认开启（设置里可关）。关闭后多数国行会在切应用后很快冻死同进程 Dart SSH。
