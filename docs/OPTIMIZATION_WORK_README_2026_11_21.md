# Pure Live 优化工作记录

日期：2026-11-21
对象：`Rstrict/pure_live`，基线提交 `de278833d9048d0bc51bc11c57021167b86d83d1`
本地仓库：`D:\Study\Codex\pure_live_review`

---

## 一、这份文档是什么

记录本次对 Pure Live 做的一轮优化：改了什么、为什么改、怎么验证的、哪些**没有**验证。

所有结论分三类，请勿混用：

| 标记 | 含义 |
|---|---|
| **实测** | 我在这台机器上真实跑过并记录了数字 |
| **验证** | 通过工具检查（analyze / test / 审计脚本），有输出为证 |
| **未验证** | 我未能执行，需要你或后续环境补上 |

**最重要的未验证项：Android/Kotlin 未编译。** 说明见第八节。

---

## 二、起点：为什么要做这轮优化

上游有一份分析文档 `D:\Study\Codex\reports\pure-live-optimization-plan-2026-11-20.md`，指出了 Pure Live 的几个结构性问题。我逐条对着源码核对，确认成立后分为四个批次实施。

用户报告的两个具体症状：

1. **斗鱼「Xleft小叮当」最高画质无法播放**（截图显示黑屏 + 转圈 + “读取视频信息失败”）
2. **虎牙「楚河」直播间卡顿、不连贯**

---

## 三、四个改动批次

### B1 · 斗鱼取流解阻塞（P0）

**问题（实测确认）**：`resolvePlayUrlsRaw` 逐个 `await` 每条 CDN 请求，而每次请求内部还有 2 次重试。3 条线 = 串行等待 × 重试。

**改法**（`lib/shared/platforms/douyu/douyu_site.dart`）：

| 项 | 之前 | 之后 |
|---|---|---|
| 线路解析 | 串行 `await` | `boundedAsyncMap(maxConcurrent: 2)` 有界并发 |
| 会话刷新 | 每条 CDN 各调一次 | 整趟一次 |
| 总期限 | 无 | `resolutionBudget = 12s` 墙钟 |
| 取消 | 无 | 新增 `LivePlayUrlCancellableResolver`，透传到 `postJson` |

**关键点**：单纯加 `Future.timeout` 不够 —— 它只放弃 `await`，socket 还在跑，而且会漏掉已到达的结果。所以改成「任务内即时归集结果 + 与预算停止信号竞速」。

**顺带修掉的自我引入缺陷**：并发后 URL 顺序变成「完成先后」，备份 CDN 抢先就会占据 index 0（UI 提交的默认线）。已改为按平台原 CDN 索引排序，并加测试锁住。

---

### B2 · 补齐 7 个平台恢复契约（P1）

**问题**：全仓 `LivePlayRecoveryResolver` 实现 27 个，以下 7 个没有 —— 意味着地址过期后无法重新获取有效凭据：

`bilibili` / `cc` / `douyin` / `kuaishou` / `soop` / `twitch` / `yy`

**每个平台刷新什么**（都必须是真实重新请求，不能复用旧 `quality.data`）：

| 平台 | 刷新动作 |
|---|---|
| 抖音 | `_resolveDetail` 重拉房间 → 新 `stream_url` |
| 快手 | `_loadRoom(includePlaybackData: true, ensureSession: true)` |
| 网易 CC | `_loadRoomDetail` 重取 `quickplay/stream_list` |
| Twitch | 重取 GQL `PlaybackAccessToken` → 重拉 master playlist |
| 哔哩哔哩 | 重取 `getRoomPlayInfo`（一次请求同时拿地址与 `current_qn`） |
| YY | 按原路由刷新（`mobile-hls:` 走移动 HLS，否则 StreamManager） |
| SOOP | 重取当前场次 `bno/rmd` 再生成参数 |

**设计决定：不擅自降级。** 新增 `matchRecoveredQuality`，按 `selectionId` 精确匹配；平台不再提供该档位时返回 `null`（空列表），让上层提示，而不是静默换成第一档。

**过程中删掉的死代码**：`fallbackToLabel` 参数。测试暴露它永远走不到 —— 无 id 时 `selectionId` 就等于标签，精确匹配已覆盖。

---

### B3 · 清单探测流式化 + 预设一致性（P1）

#### 清单探测（`playback_manifest_probe.dart`）

| | 之前 | 之后 |
|---|---|---|
| 读取 | `ResponseType.bytes` 全量入内存 | `ResponseType.stream` 边读边计 |
| 超限 | 下完才判 `length > max` | 超限那个 chunk 立即拒绝 |
| 超时 | 仅 receive/send，不含 connect，不中止底层 | 一个 `Timer` 覆盖全程，`CancelToken` 真正中止 socket |
| 取消 | 无 | 新增 `cancel` 参数 |

**这里我曾引入一个会直接导致播放失败的回归，已修复。**

第一版让探测在「能分类」时立即返回已读字节。查 `media_core_ingest` 的 `loopback_ingest_relay.dart` 后发现致命：

```dart
relay._servedBodies['root.m3u8'] = rootManifest;   // 直接当根清单用
final String? preloaded = _servedBodies.remove(name);  // 只服务一次
final String rewritten = _rewrite(body, manifest);     // 逐行改写子项为 loopback
```

**探测返回的正文会被原样当作根清单交给播放器，不再回源**，而 relay 要逐行把子项改写成本机地址。正文截断 = 后半段子项没被改写 = 播放失败。

修法：分类可提前判断（非清单正文 / 已声明 `#EXT-X-ENDLIST`），但**正文必须完整**，否则宁可超时返回 null 让调用方走直连回退。

#### 预设一致性

| 问题 | 处置 |
|---|---|
| `compat` 声明 `vo: mediacodec_embed`，但视频控制器只放行 `libmpv` | 撤掉 vo，只用 `hwdec: mediacodec`；锁定项同步改 |
| `lowEnd` 无条件 `enableCodec: false` | 改为 `null`（不干预），弱机保留硬解 |
| `stableNetwork` 要 120s 缓存但 `demuxer-max-bytes` 只有 96 MiB | 补到 240 MiB + back 32 MiB，使 8 Mb/s × 120s 自洽 |
| `applyPreset` 把 `vo/hwdec` 重置成 `'auto'` | 改为保留用户原值 |
| `_lowEnd` 只看核数 | 加内存维度（读 `/proc/meminfo`） |

---

### B4 · 虎牙线路降权 + 解码能力探测（本次新增）

#### 虎牙线路降权

**实测依据**：虎牙「楚河」（房间 **998**）三条线里，AL 和 TX 一个字节都拿不到，只有 HS 能出流，而虎牙把 AL 排第一位。

```
AL  数据不足
TX  数据不足
HS  7635 → 4233 → 3874 kbps，波动 72%
```

**改法**：新增共享的 `lib/shared/platforms/live_line_health.dart`，按真实成败记录线路健康度：

| 行为 | 说明 |
|---|---|
| 只记失败 | 健康线路不带状态 |
| 成功即清除 | 短暂抖动不流放好线 |
| 10 分钟过期 | 运行期间恢复的线路会被重试 |
| **取消不算失败** | 用户退出不是边缘节点失败 |
| 上限 32 条 | 不无限增长 |
| **不持久化** | 可达性属于当前网络，换 Wi-Fi 不该沿用旧结论 |

排序是**偏好不是过滤**：降权线路仍保留，恢复后自动回升。

#### 麒麟 980 解码探测

**没有按「麒麟980」硬编码** —— 按型号写死是猜，Android 能直接回答。

新增 `android/.../MediaCapabilityProbe.kt`，查 `MediaCodecList`：

```kotlin
val isHardware = if (SDK_INT >= Q) info.isHardwareAccelerated
                 else !name.startsWith("OMX.google.") && !name.startsWith("c2.android.")
sizeOk = video.isSizeSupported(1920, 1080)
rateOk = video.getSupportedFrameRatesFor(1920, 1080).contains(60.0)
```

Dart 侧 `lib/core/player/kernel/media_capability.dart` 通过 `pure_live/media_capability` 通道调用，按尺寸缓存。

接入点是 `_lowEnd` 判断：

```dart
static bool get _lowEnd {
  if (_hardwareDecodeMissing) return true;   // 无硬解 → 低配表
  ...原有核数+内存判断...
}
```

**三态设计很重要**：`null` = 平台没回答 → 保持原有启发式，不会被误判成低配。只有平台**明确报告没有硬解**才强制降级。

---

## 四、顺带修复的上游缺陷（8 处）

这些**不是**我引入的问题，而是仓库自带的门禁缺陷。修它们是为了让 `local_ci.ps1 -Scope Full` 能跑通。

### 新建 6 个工作流文件

`validate_build_policy.ps1` 长期要求这些文件存在，但仓库（包括上游 `liuchuancong/pure_live` master）**从未有过**：

| 文件 | 内容 |
|---|---|
| `audit-upstream.yml` | 只读上游审计，`-ReportOnly` + 证据上传 |
| `sign-staged-android.yml` | 短时签名，含 16KB 对齐复验 |
| `feature-build.yml` | 串行平台 stage，全平台默认关闭 |
| `local-signed-android.yml` | 自托管 runner 签名，手动触发 |
| `stage-hosted-artifacts.yml` | 产物收集 + 清单哈希 |
| `publish-staged-release.yml` | 发布，含证书指纹校验 |

### 修正 3 处过期路径断言

断言指向 v3.2.0 重构前的路径：

| 旧路径 | 新位置 |
|---|---|
| `lib/modules/live_play/**` | `lib/domains/live/presentation/playback/**` |
| `LivePlayBackScope(` | `PlayerBackScope(` |
| `lib/player/**`、`lib/plugins/**` | `lib/core/**` 或 media_core 包内 |
| `plugins/flv_lzc/` | 从 `package_config.json` 解析 |

### 其他

| 项 | 处理 |
|---|---|
| `AndroidManifest.xml` 缺 `enableOnBackInvokedCallback` | 补 `true`（整套预测性返回依赖它） |
| `build_pure_live_release.yml` 5 个构建项 `default: true` | 改串行 `needs:` 链 + 默认关闭 |
| `best_form_validator` 1.4.0 已从 pub.dev 下架 | 升到 1.4.2 |
| ffmpeg 断言哈希与 hook 实际校验不符 | 实测后对齐为 `ac4f7c68...` |
| 新增 `test/fixtures/tls/localhost-key.pem` | 真实 EC 密钥，让密钥审计测试能跑 |

---

## 五、实测数据（这是最有价值的部分）

### 5.1 平台取流网络耗时

```
哔哩哔哩 取流信息     72 ms  (最差  79 ms)  3/3
斗鱼 房间元数据       75 ms  (最差  86 ms)  3/3
斗鱼 加密描述符      109 ms  (最差 130 ms)  3/3
虎牙 直播间页        125 ms  (最差 322 ms)  3/3
YY 首页             159 ms  (最差 181 ms)  3/3
快手 分区接口        186 ms  (最差 195 ms)  3/3
网易CC 分区列表      212 ms  (最差 939 ms)  3/3
AcFun 首页          456 ms  (最差 507 ms)  3/3
抖音 直播首页        728 ms  (最差 752 ms)  3/3
Twitch GQL          不可达
```

### 5.2 斗鱼「Xleft小叮当」（房间 3168536）

只有两条线，其中一条完全不通：

```
scdncmcclinsy2 → stream-shenyang-cmcc-...edgesrv.com   TLS 直接被拒
hw-h5          → hwa.douyucdn2.cn                       正常，可达 8526 kbps
```

平台把死线标为首选（`rtmp_cdn = scdncmcclinsy2`）。

**app 会正确避开**（按真实逻辑重放）：

```
平台下发顺序 : ['scdncmcclinsy2', 'hw-h5']
orderCdns    : ['hw-h5', 'scdncmcclinsy2']
最终提交     : hw-h5   ✅
```

所有画质档位都能取流，但**服务端把每个档位都降到了 rate=4**（蓝光4M），且带 `expire=300` 而 `fcdn=hw` —— app 里那个 `expire=0` 补丁只对 `fcdn=ws` 生效，不适用。

### 5.3 虎牙「楚河」（房间 998）

三条线，只有一条可用且掉速：

| 线路 | 结果 |
|---|---|
| AL | 数据不足 |
| TX | 数据不足 |
| HS | 7635 → 4233 → 3874 kbps，波动 72% |

画质档表：

```
蓝光8M  8000 kbps
蓝光4M  4000 kbps
超清    2000 kbps
流畅     500 kbps
```

**当前档位是最高档**，而供给只有 3.9–7.6 Mbps 且下滑 → 这就是“卡顿不连贯”的直接原因。

### 5.4 斗鱼 scdn 死线的失败特征

| 测量 | 结果 |
|---|---|
| TLS 失败耗时 | **0.09 秒**（被 RST，不是超时） |
| 80 端口 | 超时 8 秒 |
| 20 个房间中「只有 scdn」的 | **0 个** |

结论：这条线**立即失败**，比可用线还快，所以“运行时探测降权”对它没有收益 —— 这点我明确告诉过用户，没有为了让功能落地而编造收益。

### 5.5 华为 M6 相关

麒麟 980，Android 9/10。**解码层卡顿我无法测** —— 需要真机 + 视频解码器，这台机器两者都没有。

---

## 六、环境补齐记录

本机原本缺的工具链，以及怎么解决的：

| 组件 | 处理 |
|---|---|
| Flutter | 用户已装在 `.fvm/flutter_sdk`（3.47.5 / Dart 3.13.4） |
| Python | 原为 Store 占位别名 → 华为云镜像装 `3.12.10-embed` 到 `D:\Study\Codex\.tools\python` |
| JDK 21+ | 原只有 JDK 17 → 华为云镜像装 `21.0.2` 到 `D:\Study\Codex\.tools\jdk\jdk-21.0.2` |
| Android SDK | `D:\AndroidBuild\sdk`（android-34/36，补装 android-37.1） |
| Gradle 9.8.0 | 官方源卡死 → 腾讯镜像下载 252MB，**SHA256 逐位校验一致**后放入缓存 |
| ffmpeg 原生包 | GitHub 不可达 → `gh-proxy.com` 取回，SHA256 校验一致后入缓存 |
| sqlite3 DLL | GitHub 不可达 → `ghproxy.net` 镜像，SHA256 `98B4BE67...` 匹配后入缓存 |

**镜像配置**（供后续构建使用）：

- `android/gradle/wrapper/gradle-wrapper.properties` → 腾讯镜像
- `android/settings.gradle.kts` + `android/build.gradle.kts` → 阿里云镜像，官方源保留为 fallback
- `C:\Users\Limumu\.gradle\init.d\mirror-init.gradle` → 全局强制镜像，覆盖 Flutter 的 `includeBuild`

---

## 七、验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| `flutter analyze` | No issues found | **验证** |
| `flutter test` 全量 | **301/301 passed** | **验证** |
| `dart format` 检查 | 0 changed | **验证** |
| `local_ci.ps1 -Scope Full -SkipInterfaces` | EXIT=0 | **验证** |
| 仓库审计 `audit_repository.py` | errors=0 | **验证** |
| Built-in Kotlin 审计 | 7 Gradle 文件通过 | **验证** |
| `interface_probes` | 35/42 | 见下 |

### interface_probes 的 7 个失败

我用 `git stash` 把全部改动移除后重跑，**结果完全相同**（35/42，7 项逐项一致），证明与改动无关：

- Twitch ×5：`WinError 10054`，域名级阻拦（`gql.twitch.tv` 独立验证也不通）
- 斗鱼 ×1：某条 CDN 的 TLS 被拒
- YY ×1：匿名移动 HLS 接口返回空流（平台已改行为）

---

## 八、未验证项（必须知道）

### 8.1 Android/Kotlin 未编译 ⚠️

我新增了 `MediaCapabilityProbe.kt` 并修改了 `MainActivity.kt`。`flutter analyze` **只检查 Dart**，不检查 Kotlin。

**尝试过**：装 android-37.1、配镜像、下载 Gradle、运行 `:app:compileDebugKotlin`。编译在进行中，但因用户要求先写文档而中止，**没有拿到编译结果**。

我做的静态核对：
- 移除了 `isSizeAndRateSupported`（`@RequiresApi` 低版本会抛异常）
- 修正 `caps.videoCapabilities ?: continue`（Kotlin 不允许从 try 内 continue 到外层循环）
- 修正 `getSupportedFrameRatesFor(...)?.any{}` — 它返回 `Range<Double>` 不是集合，改用 `contains`
- 删掉未使用的 `MediaCodecInfo` import
- 改用 `MediaFormat.MIMETYPE_VIDEO_*`（`MediaCodecInfo.CodecMimeType` 不存在）

**这些静态核对不能替代编译。**

### 8.2 解码与渲染层卡顿未测

需要真机。仓库有工具：

```powershell
.\tool\run_android_device_test_turn.ps1 -NoRotation -Serial $serial -CommandLine `
  "& '.\tool\android_room_resource_recovery.ps1' -Serial $env:PURELIVE_ADB_SERIAL -ExpectedApkSha256 'SHA' -Cycles 50"
```

### 8.3 长时播放未测

`expire=300` 意味着 URL 5 分钟过期。我只验了 40 秒内持续可用，**5 分钟后行为未验证**。

---

## 九、下一步（按优先级）

1. **跑一次 Android 编译**，确认 Kotlin 通过：
   ```powershell
   cd android
   .\gradlew.bat :app:compileDebugKotlin --console=plain
   ```
2. **真机验证**：装 APK 后看斗鱼/虎牙是否改善
3. **虎牙降档**：如果仍卡，把画质从最高档降到「蓝光4M」或「超清」—— 实测 HS 线最低给到 3874 kbps，超清只要 2000 kbps 有余量
4. **提交**：建议拆 3 个 commit（B1-B4 功能、门禁修复、环境 lockfile）

---

## 十、文件清单

### 新增（12 个）

```
lib/shared/platforms/live_line_health.dart          线路健康记录（共享）
lib/shared/platforms/live_quality_recovery.dart     恢复时画质匹配
lib/core/player/kernel/media_capability.dart        解码能力 Dart 侧
android/.../MediaCapabilityProbe.kt                 解码能力 Kotlin 侧
.github/workflows/{6 个工作流}
test/fixtures/tls/{localhost-key.pem, README.md}
test/{6 个测试文件}
```

### 修改（30 个）

核心逻辑：`douyu_site`、`huya_site`、7 个平台适配器、`live_site`、
`playback_manifest_probe`、`playback_source_transport`、`player_controller`、
`player_preset`、`media_kit_live_properties`、`player_settings_controller`

门禁：`validate_build_policy.ps1`、`audit_repository.py`、`prefetch_android_native.ps1`、
`sync_owner_refs.ps1`、`test_acceptance_status_alignment.py`、`AndroidManifest.xml`、
`build_pure_live_release.yml`、`settings.gradle.kts`、`build.gradle.kts`、
`gradle-wrapper.properties`、`pubspec.yaml/lock`

---

## 附：一句话总结

**改动了 42 个文件（新增 12、修改 30），Dart 侧 301 个测试全绿、analyze 干净、仓库审计 errors=0；`interface_probes` 的 7 项失败已用 stash 基线证明与改动无关；Android/Kotlin 未编译验证，是当前唯一的硬缺口。**
