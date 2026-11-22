import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/player/kernel/player_preset.dart';

/// What the native controller will actually honour as an explicit `vo`.
///
/// Mirrors `MediaKitLiveProperties.buildVideoControllerConfiguration`: with the
/// embedded render context only `libmpv` reaches the engine, and anything else is
/// dropped in favour of the default. Kept here so a preset cannot promise a `vo`
/// the engine will silently discard.
bool _voSurvivesToEngine(String? vo) => vo != null && vo.trim() == 'libmpv';

void main() {
  group('预设只声明真正生效的输出', () {
    test('没有任何预设声明会被丢弃的 vo', () {
      for (final id in PlayerPresetId.values) {
        final vo = id.outputOverride.vo;
        if (vo == null) continue;
        expect(
          _voSurvivesToEngine(vo),
          isTrue,
          reason:
              '${id.name} 声明了 vo=$vo，但视频控制器只放行 libmpv，'
              '这个值不会生效，设置页却仍会把它标成锁定。',
        );
      }
    });

    test('compat 用 hwdec 表达兼容解码，不再假装改写表面', () {
      final override = PlayerPresetId.compat.outputOverride;

      expect(override.hwdec, 'mediacodec');
      expect(override.vo, isNull);
      // 锁定项必须与真正写入的项一致，否则用户无法从设置页纠正黑屏。
      expect(PlayerPresetId.compat.lockedOutputKeys, <String>{'hwdec'});
    });

    test('锁定项始终是预设真正接管的输出项', () {
      for (final id in PlayerPresetId.values) {
        final override = id.outputOverride;
        final pinsVo = override.vo != null;
        final pinsHwdec = override.hwdec != null;
        final locked = id.lockedOutputKeys;

        expect(locked.contains('vo'), pinsVo, reason: '${id.name} 的 vo 锁定与写入不一致');
        expect(locked.contains('hwdec'), pinsHwdec, reason: '${id.name} 的 hwdec 锁定与写入不一致');
      }
    });

    test('lowEnd 不再擅自关闭硬解', () {
      // 弱机恰恰是硬解更重要的地方；预设调的是内存与线程，不是解码器选择。
      expect(PlayerPresetId.lowEnd.outputOverride.enableCodec, isNull);
      expect(PlayerPresetId.lowEnd.outputOverride.hwdec, isNull);
      expect(PlayerPresetId.lowEnd.outputOverride.vo, isNull);
    });
  });

  group('预设参数彼此自洽', () {
    test('stableNetwork 的缓存目标与字节上限不互相打架', () {
      final props = PlayerPresetId.stableNetwork.extraProperties;
      final cacheSeconds = int.parse(props['cache-secs']!);
      final maxBytes = int.parse(props['demuxer-max-bytes']!);

      // 8 Mb/s 是这份预设声称要覆盖的码率量级。缓存目标乘以码率不能超过
      // 字节上限，否则 mpv 会在字节墙前停下，cache-secs 成为一个从不生效的数。
      const int eightMegabitsPerSecond = 8 * 1000 * 1000;
      final neededBytes = eightMegabitsPerSecond * cacheSeconds ~/ 8;

      expect(
        maxBytes,
        greaterThanOrEqualTo(neededBytes),
        reason:
            'cache-secs=$cacheSeconds 在 8 Mb/s 下需要约 ${neededBytes ~/ (1024 * 1024)} MiB，'
            '但 demuxer-max-bytes 只有 ${maxBytes ~/ (1024 * 1024)} MiB。',
      );
    });

    test('stableNetwork 同时抬高回退上限，前向与后向预算不互相挤压', () {
      final props = PlayerPresetId.stableNetwork.extraProperties;

      expect(props.containsKey('demuxer-max-back-bytes'), isTrue);
      final forward = int.parse(props['demuxer-max-bytes']!);
      final back = int.parse(props['demuxer-max-back-bytes']!);
      expect(back, lessThan(forward));
    });

    test('lowLatency 与 stableNetwork 在缓存目标上确实相反', () {
      final lowLatency = PlayerPresetId.lowLatency.extraProperties;
      final stable = PlayerPresetId.stableNetwork.extraProperties;

      // lowLatency 关缓存；stableNetwork 显式要求更大目标。两者不能同值，
      // 否则界面上两个选项实际做同一件事。
      expect(lowLatency['cache'], 'no');
      expect(stable['cache-secs'], isNotNull);
      expect(int.parse(stable['cache-secs']!), greaterThan(0));
    });

    test('balanced 不加任何额外参数，保持引擎默认', () {
      expect(PlayerPresetId.balanced.extraProperties, isEmpty);
    });
  });
}
