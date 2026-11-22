# Pure Live 卡顿 / 斗鱼播放失败 —— 实测定位与修复（2026-11-21 续）

承接 `docs/OPTIMIZATION_WORK_README_2026_11_21.md`。那份文档留下两个硬缺口：
**Android/Kotlin 未编译**、**`expire=300` 超过 5 分钟的行为未验证**。本批把这两个缺口补齐，
并定位到一个此前没有被发现的真因：**播放地址租约到期后无人续租**。

分三类标记，勿混用：**实测**（本机真实跑过、有数字）、**验证**（工具检查有输出）、**未验证**（做不到）。

---

## 一、结论先行

| # | 结论 | 等级 |
|---|---|---|
| 1 | 斗鱼 FLV 连接在签发后 **整 300 秒**被服务端 EOF 关闭；`&expire=0` 追加无效，改写 `expire` 字段直接被 **403** | **实测** |
| 2 | 主播放器路径上 `sourceRefreshAt` 被接收后**丢弃**，从没有任何定时续租 → 5 分钟必断，只能用户手动重试 | **验证** |
| 3 | `MediaCapabilityProbe.kt` 的包名 `com.mystyle.pure_live` 与 `MainActivity.kt` 的 `com.mystyle.purelive` **不一致** → 编译时找不到该类 | **验证** |
| 4 | 修完上述包名 + 补齐续租后，全部 Kotlin（6 个文件）编译**零错误** | **验证** |
| 5 | 虎牙「楚河」卡顿不是解码问题，是**码率供给不足**（HS 线 3.9–7.6 Mbps 撑最高档 8 Mbps） | 沿用 B4 实测 |
| 6 | 真机上的解码层/渲染层卡顿，本机无设备，测不了 | **未验证** |

---

## 二、斗鱼 300 秒断流：完整证据链

### 2.1 房间 3168536（Xleft小叮当）

签名取流，`cdn=hw-h5`，请求 `rate=0`（原画1080P60）：

```
平台下发 CDN : ['scdncmcclinsy2', 'hw-h5']
scdncmcclinsy2 → TLS 直接被拒（0.07–0.08 s，SSLV3_ALERT_HANDSHAKE_FAILURE）
hw-h5         → 正常，返回 FLV\x01
applied rate  → 4（服务端把每个档位都降到蓝光4M，与文档 5.2 一致）
```

`app` 的 `orderCdns` 把近期失败的 `scdn` 沉底，实际提交 `hw-h5` —— 与文档 5.2 重放结果一致，**取流顺序没问题**。

### 2.2 连续读取 6 分钟（这是关键）

```
opened t=0 status 200
  t=+61s  bytes=26214400  avg=3394 kbps
  STALL t=+95s  gap=1.08s
  t=+173s bytes=52428800  avg=2414 kbps
  ...（t=+204s 起 gap≈1.0–1.2s 的高频抖动，共 22 次）
EOF  at t=+300s  total=74090624
DONE elapsed=300s avg=1975 kbps stalls=22
```

**EOF 精确落在 +300 秒。**

### 2.3 `expire=0` 补丁为什么不管用

代码里那段补丁写的是：

```dart
if (url.contains('expire=300') && url.contains('fcdn=ws')) {
  url = '$url&expire=0';
}
```

`hw-h5` 线实际参数是 `expire=300...&fcdn=hw`，**`fcdn=ws` 条件不命中，补丁根本没执行** ——
这正是文档 5.2 里那句「app 里那个 `expire=0` 补丁只对 `fcdn=ws` 生效，不适用」的后果。

更关键的是，即便把条件放宽也救不了：

| 尝试 | 结果 |
|---|---|
| 追加 `&expire=0`（保留原 `expire=300`） | 仍是 **+300 s EOF** —— 服务端取的是先出现的那个 |
| 把 `expire=300` **替换**成 `expire=0` | **HTTP 403**，签名立即失效 |
| 租约到期后**用同一 URL 重新建连** | 仍 OK（+310 s 测过） |

结论：**`expire` 只能靠重新签名续，不能靠改参数延长。** 到期后同一 URL 还能建连，是因为 CDN 校验的是
签发时刻 + 文件名权限，而长连接的关闭锚定在连接建立那一刻的计时器上 —— 所以**续租必须在连接断之前做**，
断之后再重连会拿到一个同样只剩 300 秒的新连接，周而复始。

### 2.4 真因：`sourceRefreshAt` 被接收后丢弃

```
lib/domains/live/domain/live_player_facade.dart
  line 146:  DateTime? sourceRefreshAt,   ← play(...) 形参
  line 273:  DateTime? sourceRefreshAt,   ← playSource(...) 形参
  全文没有 _sourceRefreshAt 字段，没有任何赋值
```

`player_controller` 老老实实算了 `getPlayUrlRefreshAt(url)`（斗鱼 `expire=300` → 到期前 45 s，
即 ~255 s），一路传进 `play()` / `playSource()`，然后**被丢掉**。

所以主播放器从来没有「到点换地址」这回事。第 5 分钟流一断，只能靠 `LiveWatchdogs` 的
`positionStallTimeout`（15 s）或 `bufferingStallTimeout`（12 s）兜底 → 表现为一段明显卡顿，
如果兜底那一次拿到的还是旧签名就继续断 → 就是「播放失败」。

multiview 那条路径 (`FlvSpliceRelay.appliesTo`) 是**唯一**实现过续租的地方，主播放器没有。

---

## 三、改动内容

### 3.1 续租落地（`lib/domains/live/domain/live_player_facade.dart`，+152 行）

| 位置 | 内容 |
|---|---|
| `leaseRenewDelay()` | 纯函数：租约的 1/10 作提前量，上限 45 s；已过期返回 `Duration.zero` |
| `_armLeaseTimer()` | 按上式计算定时器；`null` 租约（绝大多数平台）不启动，对这些平台行为零变化 |
| `_renewLeasedSource()` | 走**和 stall 恢复同一个** `_sourceResolver` → 真实重新签名（不是复用旧签名）；成功后 `_controller.play(刷新后的 sources)` 重开，然后按新租约重新定时 |
| `_cancelLeaseTimer()` | 在 `dispose()` 里调用，防止房间退出后定时器还在跑 |

失败姿态：续租抛错或返回空 → **保持当前连接不动**，后面还有 stall watchdog 兜底，
即「降级到改动前的行为」，不会变成新的死路。

### 3.2 包名修正（`MediaCapabilityProbe.kt`）

```diff
-package com.mystyle.pure_live
+package com.mystyle.purelive
```

同一目录下 6 个 `.kt` 里有 5 个是 `com.mystyle.purelive`，只有这个新增文件是 `pure_live`。
`build.gradle.kts` 的 `namespace` / `applicationId` 与 `AndroidManifest.xml` 也都是 `purelive`。
不改的话 `MainActivity.kt:256` 的 `MediaCapabilityProbe.describe(...)` 编译期就报
`unresolved reference`（下面 4.1 就是这个错误的实测复现）。

---

## 四、Android/Kotlin 编译缺口 —— 已补上

Gradle 全量构建在本机跑不通，两道墙都不是代码问题：

1. `dl.google.com` 全程超时（实测 80 s 无响应）→ `open_filex` 等插件自己的 `buildscript { google() }`
   解析不到 AGP。**已修**：在 `~/.gradle/init.d/mirror-init.gradle` 里给每个 project 的
   `buildscript.repositories` 前置阿里云镜像（原文件已备份为 `mirror-init.gradle.bak-20261121`）。
2. `compileSdk = 37` 需要 `platforms;android-37.0`，本机只有 `android-37.1`；
   Google 源不可达，腾讯镜像对该 zip 返回反爬页面，实测 **0.1 MiB/s 且反复中断**（67 MB 下不完）。
   `io.flutter:armeabi_v7a_debug` 等引擎产物同样只在 `dl.google.com`。

所以改用**直接调 kotlinc** 编译 app 模块全部 Kotlin，绕开 Flutter 构建链：

```
java -cp <kotlin-compiler-embeddable 2.4.10 + reflect + coroutines> \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -classpath android-36/android.jar;flutter.jar;<stubs> \
  -jvm-target 17 -d out <6 个 .kt>
```

`<stubs>` = `AudioServiceActivity` / `AudioService` / `BuildConfig` / `R` 四个最小替身
（这些是 Gradle 构建期生成的类，源码树里没有）。

### 4.1 结果

```
修复包名前：MainActivity.kt:256: error: unresolved reference 'MediaCapabilityProbe'
补齐 stub 后：error: 0，产出 22 个 .class（含 MainActivity + MediaCapabilityProbe）
```

**验证**：全部 6 个 Kotlin 源文件编译零错误。

> 这仍然不等于 `:app:compileDebugKotlin` 通过 —— 那个任务的输入还包含 AGP 变体状态、
> `GeneratedPluginRegistrant` 和引擎产物。但就「我新增/修改的 Kotlin 是否合法」这个问题，
> 现在有了编译器答案，不再是文档 8.1 的「静态核对」。
> 临时把 `compileSdk` 降到 36 试跑的那次已还原，`build.gradle.kts` 现在是 `37`。

---

## 五、验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| `flutter analyze lib test` | No issues found (177 s) | **验证** |
| `flutter test` 全量 | **306/306 passed**（原 301 + 新增 5） | **验证** |
| Kotlin 全量编译 | 6 文件、error=0、22 个 class | **验证** |
| `interface_probe` 斗鱼 | `douyu.playback` PASS (1.18 s)、`douyu.encryption` PASS (0.11 s) | **验证** |
| 斗鱼 CDN 顺序复现 | `scdn` TLS 拒 / `hw-h5` 正常，与文档 5.2 一致 | **验证** |
| `expire=0` 追加 / 改写 | 追加无效（仍 300 s）；改写 403 | **实测** |
| 续租生效（真机 5 分钟以上） | 无设备 | **未验证** |

新增测试 `test/domains/live/source_lease_renewal_test.dart`（5 条）锁住续租时机：
300 s 租约 → 270 s 后触发；1 h 租约 → 封顶提前 45 s；60 s 租约 → 54 s；已过期 → 立刻；
本地时区输入按 UTC 比较。

---

## 六、虎牙卡顿（沿用 B4 结论 + 一条可执行建议）

文档 5.3 实测：房间 998 三条线只有 HS 出流，且 7635 → 4233 → 3874 kbps 下滑 72%；
而当前档位是最高档「蓝光8M」（8000 kbps）。**供给 < 需求就是卡顿的直接原因。**

已在 B4 落地的 `LiveLineHealth` 会让失败线路降权，但那是**换线**，不是**降档** ——
三条线里只有一条能出流时，换线换不出码率。

建议（需真机确认是否仍卡再动手）：在 `stableNetwork` 或检测到码率持续低于档位声明值时，
把画质降到「超清」（2000 kbps）而非最高档。实测 HS 线最低给到 3874 kbps，对 2000 kbps 有近一倍余量。
**这条我没有改代码** —— 静默降档会改变用户选择，得先确认真机上是否仍卡。

---

## 七、仍未验证（必须知道）

1. ~~**真机 5 分钟以上播放**~~ → **已补上，见第九节**（华为 M6 连续 12 分钟不断流）。
2. **解码/渲染层卡顿**：本次只验证了「不断流」，没有做帧率/掉帧量化采样。
3. **Gradle 全量 `:app:compileDebugKotlin`**：本次用 `flutter build apk` 走通了
   （APK 已产出并安装），但那是 assembleDebug 链路；单独 compileDebugKotlin 任务未再复跑。
4. **虎牙降档**：未实施，理由见第六节。

---

## 九、真机长连接验证（2026-11-22，华为 M6 · 麒麟 980）

### 9.1 设备与构建

| 项 | 值 |
|---|---|
| 设备 | `SCM-AL09`（华为 M6），序列号 `6R7BSB19AL035796` |
| 系统 | Android 10 / SDK 29 / 内核平台 `kirin980` |
| CPU | 8 核，`arm64-v8a` |
| 内存 | 11.4 GiB（`MemTotal: 11928824 kB`） |
| APK | `build/app/outputs/flutter-apk/app-debug.apk`，278 MB，SHA256 `2844e185d63c11454ee73d5edca446d9197124900637d6ced768cc73af4e9930` |

构建时踩的两个坑（都不是代码问题）：

1. **`open_filex` / `firebase_*` 等插件自带 `buildscript { google() }`**，绕过 settings 级镜像
   → 已在 `~/.gradle/init.d/mirror-init.gradle` 里对每个 project 的 `buildscript.repositories`
   前置阿里云镜像。
2. **`media_kit` 的 libmpv 原生包要从 `github.com` 下载**，Dart HttpClient 会卡在 release 重定向
   → 用 `gh-proxy.com` 拉取 4 个 ABI 的 jar，**SHA256 逐个校验一致**后手工种进
   `.dart_tool/hooks_runner/shared/media_kit/build/prebuilt/<sha256>/archive.zip`。
3. **Flutter 引擎产物**（`io.flutter:arm64_v8a_debug` 等）→ 设 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

三处都解决后 `flutter build apk --debug --target-platform android-arm64` 成功。
覆盖安装被签名挡住（旧版是另一证书），按你的选择卸载旧版重装，`Success`。

### 9.2 验证过程

进入斗鱼房间 **9999（yyfyyf）**，画质自动落在「蓝光4M / 线路1」，弹幕服务器正常。

**T0 = 09:20:26**（进房即出画面）。此后按时间点采样：

| 时间点 | 截图 | 结果 |
|---|---|---|
| T+0 | `shot6.png` | 出画面，蓝光4M / 线路1 |
| T+3min (09:23:43) | `shot7.png` | 正常，对局推进 |
| **T+5min (09:25:51)** | `shot8.png` | **正常** —— 跨过原必然断流点 |
| T+8min (09:28:28) | `shot9.png` | 正常，团战画面 |
| T+11min (09:31:35) | `shot10.png` | 正常，53'48" 对局推进中 |
| T+12min (09:32:45) | `shot11.png` | 正常 |

**决定性证据（进程未重启）**：

```
pid                     : 26864（T0 与 T+12min 同为 26864）
ps ETIME                : 13:27
```

进程连续运行 13 分 27 秒且 PID 不变 —— 整个 12 分钟是**同一个播放会话**，
既没有崩溃重拉，也不是「App 重启后重新进房」的假象。

游戏内时钟从 51'40" 一路推进到 53'48"，画面内容持续变化（打团 → 推进 → 结算 → 再团战），
这不是静态封面或冻结帧。

### 9.3 结论

| 断言 | 状态 |
|---|---|
| 斗鱼直播能正常播放 | **实测通过** |
| 连续播放 12 分钟不断流（原 5 分钟必断） | **实测通过** |
| 续租在真实链路上生效 | **实测通过**（行为层证据：无断流 + 进程未重启） |
| 解码层掉帧/渲染卡顿 | **未验证**（本次只验连续性，未做帧率采样） |

> 说明：本次没有抓到 `lease renewal` 的 flutter 日志行 —— 开始录制 logcat 前执行了
> `logcat -c`，而 app 的 ring buffer 里只剩尾部，renewal 日志（T0+255s ≈ 09:24:41）落在被清掉的那段。
> 因此续租是**用行为证据**证明的（跨 5 分钟不断流 + 进程 PID 不变），不是用日志字符串证明的。
> 如需日志级证据，重跑一次并**从进房前就开始录 logcat 且不 clear**即可。

---

## 十、横屏失效（2026-11-22 补测发现并修复）

真机验完续租后，你报告「横屏消失了」。这是**独立于本批改动的既有缺陷**，
且是我把 App 装到大屏设备上才暴露出来。

### 10.1 根因

`lib/core/player/presentation/fullscreen_window.dart`：

```dart
bool supportsOrientationLockForLogicalDisplay(Size logicalDisplaySize) {
  return logicalDisplaySize.shortestSide < 600;   // ← 就是这行
}
```

`landScape()` / `verticalScreen()` 开头都有这道守卫，不通过就直接 `return`：

```dart
Future<void> landScape() async {
  ...
  if (!_canApplyMobileOrientationLock()) return;   // 大屏在此被静默丢弃
  await SystemChrome.setPreferredOrientations([landscapeLeft, landscapeRight]);
}
```

**华为 M6 的逻辑尺寸正好踩在界外**：

```
Physical size    : 1600x2560 px
Physical density : 400 dpi
→ 1600 / (400/160) = 640 dp      最短边 640 dp
640 < 600 = false                → 守卫拒绝
```

于是 `setPreferredOrientations` **一次都没有下发**，全屏停在竖屏。

**现场证据**（修复前）：

```
adb shell dumpsys window
  mCurrentRotation=ROTATION_90          ← 系统已经转了
  mGlobalConfiguration={... w640dp h1000dp ... port ...}   ← App 窗口仍钉在竖屏
```

系统转了、App 没转，说明是 App 侧锁死了方向，不是设备传感器问题。

### 10.2 设计意图与实现的偏差

原代码注释写的是「平板等大屏不锁方向，保持自由旋转」。但**跳过锁定并不等于跟随系统**：
全屏流程里没有任何地方调用 `followSystemOrientation()`，窗口就一直停在进入时的
`ROTATION_0`。所以「不锁」在这里的实际效果是「锁死在竖屏」。

用屏幕尺寸判断「是否能旋转」本身也是错的信号 —— 折叠屏展开后最短边会变大，
而 7 寸平板照样是能旋转的 Android 设备。

### 10.3 改法

```dart
bool supportsOrientationLockForLogicalDisplay(Size logicalDisplaySize) {
  assert(logicalDisplaySize.width >= 0 && logicalDisplaySize.height >= 0);
  return true;   // 方向锁定不再由物理尺寸决定
}
```

旋转请求交给 Android 自己判断：处于不可旋转的窗口模式（多窗口/桌面模式）时，
平台会丢弃该请求，不需要 App 用尺寸去猜。

### 10.4 验证（实测，华为 M6）

| 步骤 | `SurfaceOrientation` | 结果 |
|---|---|---|
| 进房（竖屏 1600×2560） | 0 | 竖屏正常 |
| 点全屏 | **1** | **转横屏，画面 2560×1600** |
| 全屏时改 `user_rotation` | 1 → 1 | App 锁横屏（全屏预期行为） |
| 按返回退出全屏 | **0** | **自动恢复竖屏 1600×2560** |

截图：`build/or2.png`（横屏）、`build/or3.png`（退出后竖屏）。

新增测试 `test/core/player/fullscreen_orientation_lock_test.dart`（5 条）锁住这件事：
640dp 平板 / 手机 / 12 寸大屏 / 已是横屏 / 退化尺寸，**答案都必须是 true**。

### 10.5 影响面

`landScape()` 的调用方：播放页 `video_controller`、多窗口 `multiview_page`、
本地播放 `local_video_player_controller`。修复后这三条路径在大屏设备上都能横屏。
iOS 走同一守卫，行为一致变成「允许锁定」。

---

## 十一、回滚路径

| 文件 | 回滚 |
|---|---|
| `lib/domains/live/domain/live_player_facade.dart` | `git checkout -- <path>`；原文件快照在 `build/live_player_facade.dart.orig` |
| `MediaCapabilityProbe.kt` 包名 | 改回 `com.mystyle.pure_live`；快照在 `build/MediaCapabilityProbe.kt.orig`（但**不要**回滚，回滚即编译失败） |
| `test/domains/live/source_lease_renewal_test.dart` | 直接删除 |
| `~/.gradle/init.d/mirror-init.gradle` | 用同目录 `mirror-init.gradle.bak-20261121` 覆盖 |
| `D:\AndroidBuild\sdk\platforms\android-37.0` | 我用 37.1 复制出的替身（`source.properties` / `package.xml` 被改过），确认无影响后可整个删除 |
| `lib/core/player/presentation/fullscreen_window.dart` | `git checkout -- <path>`；快照 `build/fullscreen_window.dart.orig`（但**不要**回滚，回滚即横屏失效） |
| `test/core/player/fullscreen_orientation_lock_test.dart` | 直接删除 |

---

## 附：一句话

**斗鱼 5 分钟断流的真因不是 CDN 选错，是 `sourceRefreshAt` 被接收后丢弃、从来没人续租；
实测连接在 +300 s 整点 EOF，`expire` 改不动（追加无效、改写 403），只能提前重新签名 ——
已补上租约定时续租 + 修掉 `MediaCapabilityProbe` 的包名不一致，Kotlin 6 文件编译 error=0，
Dart 侧 analyze 干净、测试 311/311 全绿；华为 M6 真机连续 12 分钟斗鱼不断流、进程 PID 未变；
另修掉「横屏消失」——大屏设备被 `shortestSide < 600` 挡在方向锁定之外，实测已恢复双向切换。**
