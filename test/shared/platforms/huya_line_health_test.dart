import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/shared/platforms/huya/huya_site.dart';
import 'package:pure_live/shared/platforms/live_line_health.dart';

HuyaLineModel _line(String cdn, {HuyaLineType type = HuyaLineType.flv}) => HuyaLineModel(
  line: 'http://$cdn.flv.huya.com/src',
  lineType: type,
  flvAntiCode: 'a=1',
  hlsAntiCode: 'b=2',
  streamName: '998-998-1-1',
  cdnType: cdn,
  presenterUid: 998,
);

void main() {
  setUp(HuyaSite.lineHealth.clear);
  tearDown(HuyaSite.lineHealth.clear);

  group('虎牙线路降权', () {
    test('没有历史时保持服务端给出的顺序', () {
      final lines = <HuyaLineModel>[_line('AL'), _line('TX'), _line('HS')];

      final ordered = HuyaSite.lineHealth.order(lines, key: (line) => line.cdnType);

      expect(ordered.map((line) => line.cdnType).toList(), <String>['AL', 'TX', 'HS']);
    });

    test('拿不到地址的线路沉到最后，可用的线路顶上来', () {
      // 实测：AL 与 TX 一条字节都拿不到，HS 才是能出流的线路。
      HuyaSite.lineHealth.recordFailure('AL');
      HuyaSite.lineHealth.recordFailure('TX');

      final ordered = HuyaSite.lineHealth.order(<HuyaLineModel>[
        _line('AL'),
        _line('TX'),
        _line('HS'),
      ], key: (line) => line.cdnType);

      expect(ordered.first.cdnType, 'HS');
      expect(ordered.map((line) => line.cdnType).toList(), <String>['HS', 'AL', 'TX']);
    });

    test('成功一次就清掉失败记录，线路回到原来的位置', () {
      HuyaSite.lineHealth.recordFailure('AL');
      expect(HuyaSite.lineHealth.recentlyFailed('AL'), isTrue);

      HuyaSite.lineHealth.recordSuccess('AL');

      expect(HuyaSite.lineHealth.recentlyFailed('AL'), isFalse);
      expect(
        HuyaSite.lineHealth
            .order(<HuyaLineModel>[_line('AL'), _line('HS')], key: (line) => line.cdnType)
            .map((line) => line.cdnType)
            .toList(),
        <String>['AL', 'HS'],
      );
    });

    test('失败记录会过期，过期的线路不再被降权', () {
      final at = DateTime(2026, 11, 21, 20, 0, 0);
      HuyaSite.lineHealth.recordFailure('AL', at: at);

      final fresh = HuyaSite.lineHealth.order(
        <HuyaLineModel>[_line('AL'), _line('HS')],
        key: (line) => line.cdnType,
        now: at,
      );
      expect(fresh.map((line) => line.cdnType).toList(), <String>['HS', 'AL']);

      final later = HuyaSite.lineHealth.order(
        <HuyaLineModel>[_line('AL'), _line('HS')],
        key: (line) => line.cdnType,
        now: at.add(HuyaSite.lineHealth.memory + const Duration(seconds: 1)),
      );
      expect(later.map((line) => line.cdnType).toList(), <String>['AL', 'HS']);
    });

    test('同健康度内保持服务端优先级，不同协议线路互不干扰', () {
      final lines = <HuyaLineModel>[_line('AL'), _line('AL', type: HuyaLineType.hls), _line('HS')];

      final ordered = HuyaSite.lineHealth.order(lines, key: (line) => line.cdnType);

      // AL 的两条线并列在前且保持原顺序，HS 在后。
      expect(ordered.map((line) => line.cdnType).toList(), <String>['AL', 'AL', 'HS']);
      expect(ordered[0].lineType, HuyaLineType.flv);
      expect(ordered[1].lineType, HuyaLineType.hls);
    });

    test('排序是偏好而不是过滤：失败线路仍然保留', () {
      HuyaSite.lineHealth.recordFailure('AL');

      final ordered = HuyaSite.lineHealth.order(<HuyaLineModel>[
        _line('AL'),
        _line('TX'),
        _line('HS'),
      ], key: (line) => line.cdnType);

      expect(ordered.length, 3);
      expect(ordered.map((line) => line.cdnType).toSet(), <String>{'AL', 'TX', 'HS'});
    });
  });

  group('线路健康记录', () {
    test('大小写与空白不影响同一线路的判定', () {
      final health = LiveLineHealth();
      health.recordFailure('  al ');

      expect(health.recentlyFailed('AL'), isTrue);
      expect(health.recentlyFailed('al'), isTrue);
    });

    test('空标识不会被记录', () {
      final health = LiveLineHealth();
      health.recordFailure('   ');

      expect(health.recentlyFailed(''), isFalse);
    });

    test('记录数量有上限，最早写入的被挤出', () {
      final health = LiveLineHealth(maxEntries: 4);
      for (var index = 0; index < 10; index++) {
        health.recordFailure('cdn-$index');
      }

      expect(health.recentlyFailed('cdn-0'), isFalse);
      expect(health.recentlyFailed('cdn-9'), isTrue);
    });
  });
}
