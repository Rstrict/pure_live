import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/shared/platforms/douyu/douyu_site.dart';

void main() {
  setUp(DouyuSite.clearCdnFailureMemory);
  tearDown(DouyuSite.clearCdnFailureMemory);

  group('斗鱼线路排序', () {
    test('没有任何历史时，保持平台顺序并把 scdn 排在后面', () {
      expect(DouyuSite.orderCdns(<String>['scdncmcclinsy2', 'hw-h5', 'hs-h5']), <String>[
        'hw-h5',
        'hs-h5',
        'scdncmcclinsy2',
      ]);
    });

    test('房间自身线路（rtmp_cdn 插入到首位）优先于其它非 scdn 线路', () {
      // parseCdnCodes 会把 rtmp_cdn 插到最前，这里验证排序不会把它挪走。
      expect(DouyuSite.orderCdns(<String>['hw-h5', 'hs-h5', 'scdncmcclinsy2']), <String>[
        'hw-h5',
        'hs-h5',
        'scdncmcclinsy2',
      ]);
    });

    test('失败过的线路沉到所有未失败线路之后', () {
      DouyuSite.debugRecordCdnFailure('hw-h5');

      final ordered = DouyuSite.orderCdns(<String>['hw-h5', 'hs-h5', 'scdncmcclinsy2']);

      // hw-h5 刚失败过，即使它是 rtmp_cdn 也要让位。
      expect(ordered, <String>['hs-h5', 'scdncmcclinsy2', 'hw-h5']);
    });

    test('失败记录会过期，过期后恢复原有次序', () {
      final at = DateTime(2026, 11, 21, 12, 0, 0);
      DouyuSite.debugRecordCdnFailure('hw-h5', at: at);

      expect(DouyuSite.orderCdns(<String>['hw-h5', 'hs-h5'], now: at), <String>['hs-h5', 'hw-h5'], reason: '刚失败时应被降权');
      expect(
        DouyuSite.orderCdns(<String>[
          'hw-h5',
          'hs-h5',
        ], now: at.add(DouyuSite.cdnFailureMemory + const Duration(seconds: 1))),
        <String>['hw-h5', 'hs-h5'],
        reason: '超过记忆窗口后不应再影响次序',
      );
    });

    test('成功一次就清掉失败记录', () {
      DouyuSite.debugRecordCdnFailure('hs-h5');
      expect(DouyuSite.cdnRecentlyFailed('hs-h5'), isTrue);

      DouyuSite.debugRecordCdnSuccess('hs-h5');
      expect(DouyuSite.cdnRecentlyFailed('hs-h5'), isFalse);
    });

    test('空线路名不会被记录，也不会打乱次序', () {
      DouyuSite.debugRecordCdnFailure('   ');

      expect(DouyuSite.cdnRecentlyFailed(''), isFalse);
      expect(DouyuSite.orderCdns(<String>['', 'hw-h5']), <String>['', 'hw-h5']);
    });

    test('失败记录有上限，不会无限增长', () {
      for (var index = 0; index < 200; index++) {
        DouyuSite.debugRecordCdnFailure('cdn-$index');
      }

      // 最早写入的被挤出，最近的仍在。
      expect(DouyuSite.cdnRecentlyFailed('cdn-0'), isFalse);
      expect(DouyuSite.cdnRecentlyFailed('cdn-199'), isTrue);
    });

    test('排序是偏好而不是过滤：所有线路都保留', () {
      DouyuSite.debugRecordCdnFailure('hw-h5');
      final ordered = DouyuSite.orderCdns(<String>['hw-h5', 'hs-h5', 'scdncmcclinsy2']);

      expect(ordered.length, 3);
      expect(ordered.toSet(), <String>{'hw-h5', 'hs-h5', 'scdncmcclinsy2'});
    });
  });
}
