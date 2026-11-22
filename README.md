
<div align="center">

<img src="assets/icons/icon.png" width="150" alt="Pure Live 图标"/>

# 纯粹直播（Pure Live）· Rstrict 维护分支

**基于 Flutter 的开源多平台直播聚合播放器**

A third-party live stream aggregator built with Flutter.

[![Platform](https://img.shields.io/badge/Android%20%7C%20TV%20%7C%20Windows%20%7C%20Linux%20%7C%20macOS%20%7C%20iOS-8A2BE2)](https://github.com/Rstrict/pure_live)
[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Upstream](https://img.shields.io/badge/upstream-liuchuancong%2Fpure__live-blue)](https://github.com/liuchuancong/pure_live)

<img src="assets/images/banner.png" width="720" alt="Pure Live 界面预览"/>

</div>

> **纯粹直播** 是一款开源的第三方多平台直播聚合播放器，使用 Flutter 构建，支持 Android、Android TV、Windows、Linux、macOS 和 iOS。一个应用看遍全网直播，支持多画面同看、弹幕、录制、定时关闭与数据同步。

> 本仓库是 [liuchuancong/pure_live](https://github.com/liuchuancong/pure_live) 的维护分支，集中修复直播播放链路与屏幕方向问题。上游功能与站点支持保持不变，差异见[本分支修复记录](#-本分支修复记录)。

---

## 🔧 本分支修复记录

基线 `de27883`。以下每一项都有真机或实测证据，未验证的会明确标注。

### 1. 斗鱼 5 分钟断流（核心修复）

**症状**：斗鱼直播播到第 5 分钟停止，必须手动重试才恢复。

**根因**：斗鱼 FLV 连接的签名 URL 带 `expire=300`，CDN 在签发后**整 300 秒**关闭连接。实测连续读取 6 分钟，在 `+300 s` 精确得到 EOF：

```
opened t=0  →  t=+300s  EOF  total=74090624   (avg 1975 kbps, 22 次 1.0–1.2s 抖动)
```

`expire` 改不动——追加 `&expire=0` 无效（服务端取先出现的），把 `expire=300` 改写成 `expire=0` 直接返回 **403**。唯一出路是**到期前重新签名**。

而 `LivePlayerFacade.play()` / `playSource()` 接收了 `sourceRefreshAt` 参数后**直接丢弃**——全文件没有对应字段，没有任何定时续租。多画面路径是唯一实现过续租的地方（`FlvSpliceRelay`），主播放器没有。

**修复**：`LivePlayerFacade` 按平台给的截止时间安排续租，通过**和 stall 恢复同一个** resolver 重新签名，再用新 URL 重开原生源。续租失败则保持当前连接不动，stall watchdog 仍在后面兜底——不会变成新的死路。

**真机验证**（华为 M6 / 麒麟 980 / Android 10）：

| 时间点 | 结果 |
| --- | --- |
| T+0 | 出画面，蓝光4M / 线路1 |
| T+3min | 正常 |
| **T+5min** | **正常——跨过原必然断流点** |
| T+8min | 正常，团战中 |
| T+11min | 正常，对局 53'48" |
| T+12min | 正常 |

决定性证据：进程 PID `26864` 从 T+0 到 T+12min **未变**，`ps ETIME` 13:27。整个 12 分钟是同一个播放会话。

### 2. 横屏在全屏时不生效

**症状**：大屏设备点全屏后画面仍是竖屏。

**根因**：`landScape()` 开头有一道尺寸守卫 `supportsOrientationLockForLogicalDisplay()`，条件是 `shortestSide < 600`。华为 M6 是 `1600 px @ 400 dpi = 640 × 1000 dp`，最短边 **640 ≥ 600**，守卫拒绝，`setPreferredOrientations` **一次都没下发**。

修复前的现场证据：

```
mCurrentRotation=ROTATION_90                              ← 系统转了
mGlobalConfiguration={... w640dp h1000dp ... port ...}     ← App 窗口仍钉在竖屏
```

而且「跳过锁定」从来不等于「跟随系统」——全屏流程里没有任何地方调用 `followSystemOrientation()`，窗口就停在进入时的方向。

**修复**：方向锁定不再由物理尺寸决定（折叠屏展开后最短边会变大，7 寸平板照样能转），交给平台判断；同时新增**三档方向设置**。

### 3. 新增：屏幕方向设置

`设置 → 视频 → 播放行为 → 屏幕方向`，三档：

| 选项 | 行为 |
| --- | --- |
| **保持横屏** | 全屏与播放页始终横屏，不受重力感应影响 |
| **保持竖屏** | 始终竖屏，全屏也不旋转 |
| **跟随系统** | 由系统自动旋转开关决定，App 不干预 |

三档共用 `OrientationLock` 单一入口，设置页、全屏切换、App 启动三处读同一个值——避免「设了但下次启动被重置」。

**真机验证**：进房竖屏 1600×2560 → 点全屏 `SurfaceOrientation: 1` 转 2560×1600 → 返回退出自动恢复 1600×2560。

### 4. 解码能力探测

`_lowEnd` 原来只看 CPU 核数，无法区分「能硬解 1080p60」和「悄悄退回软解掉帧」的设备。新增 `MediaCapabilityProbe`，直接查 Android 的 `MediaCodecList`。

**三态设计**：`null` = 平台没回答 → 保持原有启发式（不会被误判成低配）；只有平台**明确报告没有硬解**才强制降低配置表。

### 5. 顺带修复

| 项 | 说明 |
| --- | --- |
| `MediaCapabilityProbe` 包名 | 写成 `com.mystyle.pure_live`，与其余 5 个 Kotlin 文件、`namespace`、`applicationId` 的 `com.mystyle.purelive` 不一致，导致 `MainActivity` 找不到该类 |
| 斗鱼 CDN 解析 | 串行 `await` 改为有界并发 + 12s 墙钟预算，并按**平台原始顺序**排序（并发后完成先后会让备份线路占据 index 0） |
| 线路健康度 | 新增 `LiveLineHealth`：只记失败、成功即清除、10 分钟过期、**取消不算失败**、上限 32 条、不持久化。是**偏好不是过滤**，降权线路仍保留 |
| 7 个平台恢复契约 | bilibili / cc / douyin / kuaishou / soop / twitch / yy 补齐 `LivePlayRecoveryResolver`；新增 `matchRecoveredQuality`，平台不再提供该档位时返回 `null` 让上层提示，**不静默降档** |
| 清单探测流式化 | 改流式读取边读边计，但**正文必须完整**——截断的正文会被 relay 当成根清单，后半段子项没被改写就播放失败 |
| 预设一致性 | `compat` 撤掉实际不生效的 `vo`；`lowEnd` 不再无条件关硬解；`stableNetwork` 的缓存目标与 demuxer 预算自洽 |
| 构建门禁 | 补齐 6 个工作流文件、修正 3 处过期路径断言、`best_form_validator` 升到 1.4.2 |

### 6. 已知未验证

- **解码层掉帧/渲染卡顿**：只验证了连续性，没有做帧率量化采样。
- **`flutter build apk --release`**：本分支未产出正式签名的 release 包（见[下载安装](#-下载安装)）。
- **虎牙降档**：实测「楚河」三条线只有 HS 能出流且 7635 → 3874 kbps 下滑 72%，而当前档位是最高档 8000 kbps，供给不足就是卡顿直接原因。降档会改变用户选择，未擅自实施。

---

## 📺 支持站点

**34 个直播站点 + IPTV 自定义直播源，共 35 个适配器。** 各站分区、搜索、弹幕、人数口径与能力边界见[平台兼容性](docs/PLATFORM_COMPATIBILITY.md)。

### 🇨🇳 国内平台（18 站）

| | | |
| --- | --- | --- |
| <img src="assets/images/bilibili.png" width="26"/> **哔哩哔哩** | <img src="assets/images/douyu.png" width="26"/> **斗鱼** | <img src="assets/images/huya.png" width="26"/> **虎牙** |
| <img src="assets/images/douyin.png" width="26"/> **抖音** | <img src="assets/images/kuaishou.png" width="26"/> **快手** | <img src="assets/images/yy.png" width="26"/> **YY 直播** |
| <img src="assets/images/cc.png" width="26"/> **网易 CC** | <img src="assets/images/acfun.png" width="26"/> **AcFun** | <img src="assets/images/missevan.png" width="26"/> **猫耳 FM** |
| <img src="assets/images/inke.png" width="26"/> **映客** | <img src="assets/images/kilakila.png" width="26"/> **克拉克拉** | <img src="assets/images/xiaohongshu.png" width="26"/> **小红书** |
| <img src="assets/images/weibo.png" width="26"/> **微博直播** | <img src="assets/images/jd.png" width="26"/> **京东直播** | <img src="assets/images/kugou.png" width="26"/> **酷狗直播** |
| <img src="assets/images/baidu.png" width="26"/> **百度直播** | <img src="assets/images/sixroom.png" width="26"/> **六间房** | <img src="assets/images/look.png" width="26"/> **LOOK 直播** |

### 🌍 海外平台（16 站）

| | | |
| --- | --- | --- |
| <img src="assets/images/twitch.png" width="26"/> **Twitch** | <img src="assets/images/soop.png" width="26"/> **SOOP Live** | <img src="assets/images/youtube.png" width="26"/> **YouTube Live** |
| <img src="assets/images/tiktok.png" width="26"/> **TikTok LIVE** | <img src="assets/images/kick.png" width="26"/> **Kick** | <img src="assets/images/chzzk.png" width="26"/> **CHZZK** |
| <img src="assets/images/bigo.png" width="26"/> **Bigo Live** | <img src="assets/images/17live.png" width="26"/> **17LIVE** | <img src="assets/images/liveme.png" width="26"/> **LiveMe** |
| <img src="assets/images/showroom.png" width="26"/> **SHOWROOM** | <img src="assets/images/niconico.png" width="26"/> **niconico** | <img src="assets/images/picarto.png" width="26"/> **Picarto** |
| <img src="assets/images/twitcasting.png" width="26"/> **TwitCasting** | <img src="assets/images/fc2.png" width="26"/> **FC2 Live** | <img src="assets/images/steam.png" width="26"/> **Steam 直播** |
| <img src="assets/images/panda.png" width="26"/> **PandaTV** | | |

### 📡 IPTV / 自定义直播源

- 支持 **M3U / M3U8**、本地直播源、网络直播源导入
- 按分区、平台和频道管理，支持 EPG 节目单与订阅源同步

---

## 📥 下载安装

本分支目前**只产出 debug 构建**用于验证，不提供正式签名的 release APK。

原因：`android/app/build.gradle.kts` 的 release 签名读取 `android/key.properties`，要求 `storeFile` / `keyAlias` / `keyPassword` / `storePassword` 齐全。本机没有该文件，也没有仓库专用签名证书——**用临时证书签出的「release」包无法覆盖升级官方版本，签名不一致会安装失败**。这正是本次真机验证时需要先卸载旧版的原因。

需要正式包时：

```powershell
# 1. 准备签名（自建，需长期保管）
#    android/key.properties:
#      storeFile=../keystore/pure_live.jks
#      keyAlias=pure_live
#      keyPassword=******
#      storePassword=******

# 2. 构建
PowerShell -ExecutionPolicy Bypass -File .\tool\build_local_release.ps1 `
  -Target AndroidArm64 -Configuration Release -FullRegression -RequireReleaseSigning
```

官方安装包请到上游 [GitHub Releases](https://github.com/liuchuancong/pure_live/releases/latest) 获取，并用同一 Release 的 `SHA256SUMS.txt` 校验。

| 平台 | 安装包 | 系统要求 |
| --- | --- | --- |
| 📱 Android / Android TV | APK（arm64-v8a / armeabi-v7a / x86_64） | Android 8.0（API 26）及以上 |
| 🖥️ Windows | EXE 安装器 / 便携 ZIP | Windows 10 / 11 x64 |
| 🍎 macOS | Universal DMG / ZIP | Apple Silicon + Intel |
| 🐧 Linux | Portable tar.gz | x64 |
| 📲 iOS | TrollStore IPA / 未签名 ZIP | arm64 |

---

## ✨ 核心功能

### 🎬 多平台聚合

- 聚合 34 个直播平台，按平台与分区浏览、筛选和隐藏入口
- 跨平台搜索，支持综合 / 平台顺序 / 观众 / 粉丝等排序，直播 / 未开播筛选
- 各平台保持独立分页状态；「全部」搜索按平台完成顺序渐进显示，单平台超时不挡其他结果

### ▶️ 多播放器

Android / Android TV 支持在设置中切换播放器，出现黑屏、卡顿或硬解兼容问题时可随时更换：

- IJKPlayer
- EXOPlayer
- MPV Player

Windows、Linux、macOS 等桌面平台使用对应平台的播放器实现。

### 🖥️ 多画面同看

- 最多 4 路同时播放，支持布局切换与聚焦单路
- 每路独立画质与线路选择；多画面路径已内置签名 URL 续租（`FlvSpliceRelay`）

### 💬 弹幕系统

- 支持各平台原生弹幕协议，含表情、颜色、房管标识
- 弹幕开关、透明度、字号、速度、显示区域、关键词屏蔽

### 🪟 小窗弹幕

- 小窗/画中画状态下弹幕单独渲染，不随视频缩放糊掉
- 独立的速度与密度设置

### 📺 高刷新率

- 支持高刷屏输出，可指定刷新率档位
- 播放页与 UI 分离刷新策略

### 🎧 ASMR / 助眠模式

- 定时关闭，可设定分钟数或按时间点
- 后台播放与音频独占

### ⏺️ 直播录制

- FLV / HLS 分段录制，支持合并与重命名
- 录制中心统一管理，可后台继续

### 💾 数据管理

- 关注、历史、设置、IPTV 与录制集中保存
- WebDAV 同步、局域网设备间配置互传、导入导出

---

## 🛠️ 本地构建

固定 Flutter `3.47.5` / Dart `3.13.4`、Java 21、Android 字节码目标 Java/Kotlin 17，`compileSdk 37` / `minSdk 26`。资源档位与缓存规则见 [构建资源策略](BUILD_POLICY.md)。

```powershell
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'   # Flutter 引擎产物镜像
$env:JAVA_HOME  = 'D:\Study\Codex\.tools\jdk\jdk-21.0.2'
$env:ANDROID_HOME = 'D:\AndroidBuild\sdk'

flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

完整质量门禁：

```powershell
PowerShell -ExecutionPolicy Bypass -File .\tool\local_ci.ps1 -Scope Full
```

### 国内网络说明

首次构建在受限网络下会卡住，这几处已配置：

| 环节 | 出口 |
| --- | --- |
| Gradle 分发 | 腾讯镜像（`gradle-wrapper.properties`） |
| Maven 依赖 | 阿里云优先，官方源保留为 fallback（`settings.gradle.kts`） |
| 插件自带 `buildscript {}` | `~/.gradle/init.d/mirror-init.gradle` 覆盖（settings 级注入够不到） |
| Flutter 引擎产物 | `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| media_kit 的 libmpv | `gh-proxy.com` 拉取后按 SHA256 校验，放入 `.dart_tool/hooks_runner/shared/media_kit/build/prebuilt/<sha256>/` |

---

## 📚 文档

| 文档 | 内容 |
| --- | --- |
| [优化工作记录 PART1](docs/OPTIMIZATION_WORK_README_2026_11_21.md) | 第一批改动的动机、实测数据与未验证项 |
| [优化工作记录 PART2](docs/OPTIMIZATION_WORK_README_2026_11_21_PART2.md) | 300s EOF 实测、Kotlin 编译、12 分钟真机验证、横屏缺陷 |
| [文档索引](docs/README.md) | 当前入口、开发验证、产品参考与历史证据查找方式 |
| [维护范围与问题处置策略](MAINTENANCE_POLICY.md) | 平台支持边界、Issue 分流、来源判定与完成标准 |
| [构建与发布](docs/BUILD_AND_RELEASE.md) | 本机质量门禁、签名、打包和 Release 流程 |
| [平台接口与兼容性](docs/PLATFORM_COMPATIBILITY.md) | 分区、搜索、弹幕、观看指标和能力边界 |
| [高刷新率与性能验证](docs/PERFORMANCE.md) | Android / Windows 帧、CPU、GPU 与资源采样 |
| [依赖与接口审计](docs/DEPENDENCY_AUDIT.md) | 固定工具链、升级约束和接口探测范围 |
| [参与贡献](CONTRIBUTING.md) | 分支、提交、测试和 Pull Request 要求 |
| [安全策略](SECURITY.md) | 私密漏洞报告和签名材料管理 |

---

## 🧪 验证状态

| 检查 | 结果 |
| --- | --- |
| `flutter analyze lib test` | No issues found |
| `flutter test` 全量 | **318 / 318 passed** |
| Kotlin 全量编译（6 个源文件） | **error = 0** |
| 真机长连接（华为 M6） | 斗鱼 12 分钟不断流，PID 未变 |
| 真机横屏（华为 M6） | 全屏 2560×1600 ↔ 竖屏 1600×2560 双向正常 |

---

## 📌 维护说明

- 本分支重点维护 **Android**，改动集中在播放链路与屏幕方向。
- 上游同步、站点新增等请提交至 [上游仓库](https://github.com/liuchuancong/pure_live)。
- Issue 受理**可复现的维护型 Bug**，请附设备型号、系统版本与复现步骤。

---

## 🤝 贡献与致谢

**上游作者**：[@liuchuancong](https://github.com/liuchuancong)
**上游协助**：[@RebornQ](https://github.com/RebornQ) · [@wzgrx](https://github.com/wzgrx)

**代码参考**

- [dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)
- [pure_live (Jackiu1997)](https://github.com/Jackiu1997/pure_live)

---

## ⚖️ 免责声明

本项目仅供学习与技术研究，所有直播内容版权归原平台与主播所有。请勿用于商业用途，使用产生的任何后果由使用者自行承担。
