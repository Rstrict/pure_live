import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/models/live_play_quality.dart';
import 'package:pure_live/shared/platforms/live_quality_recovery.dart';

LivePlayQuality _q({required String label, Object? id, Object? data}) =>
    LivePlayQuality(quality: label, id: id, data: data);

void main() {
  group('恢复时按稳定标识挑回原画质', () {
    test('同一 selectionId 命中，即使顺序变了', () {
      final fresh = <LivePlayQuality>[_q(label: '低清', id: 'ld', data: 'a'), _q(label: '原画', id: 'source', data: 'b')];

      final recovered = matchRecoveredQuality(fresh, requestedSelectionId: 'source');

      expect(recovered, isNotNull);
      expect(recovered!.selectionId, 'source');
      expect(recovered.data, 'b');
    });

    test('平台不再提供该档位时返回 null，不擅自降级', () {
      final fresh = <LivePlayQuality>[_q(label: '高清', id: 'hd', data: 'a'), _q(label: '标清', id: 'sd', data: 'b')];

      expect(matchRecoveredQuality(fresh, requestedSelectionId: 'source'), isNull);
    });

    test('空表返回 null', () {
      expect(matchRecoveredQuality(const <LivePlayQuality>[], requestedSelectionId: 'source'), isNull);
    });

    test('数字 id 与字符串 selectionId 能对齐', () {
      // 斗鱼/YY 的 rate、gear 是数字，调用方传进来的可能是字符串形式。
      final fresh = <LivePlayQuality>[_q(label: '原画', id: 0, data: 'a')];
      expect(matchRecoveredQuality(fresh, requestedSelectionId: '0')?.id, 0);
    });

    test('默认不按标签回退：有 id 的档位不会因同名被错配', () {
      // 两个不同 id 共用标签时，按标签匹配会挑到错误的流。
      final fresh = <LivePlayQuality>[
        _q(label: '原画', id: 'a', data: 'stream-a'),
        _q(label: '原画', id: 'b', data: 'stream-b'),
      ];

      expect(matchRecoveredQuality(fresh, requestedSelectionId: '原画'), isNull);
    });

    test('无 id 的档位按标签精确匹配', () {
      // `selectionId` 在没有 id 时就是标签本身，因此这类适配器天然按标签命中。
      final fresh = <LivePlayQuality>[
        _q(label: '原画', id: 'source-hd', data: 'stream-a'),
        _q(label: '高清', data: 'stream-b'),
      ];

      expect(matchRecoveredQuality(fresh, requestedSelectionId: '高清')?.data, 'stream-b');
    });

    test('带 id 的同名档位不会被冒认', () {
      final fresh = <LivePlayQuality>[_q(label: '原画', id: 'source-hd', data: 'stream-a')];

      // 请求方持有一个已经失效的 id，唯一同名档位带自己的 id：不能认它。
      expect(matchRecoveredQuality(fresh, requestedSelectionId: '原画'), isNull);
      expect(matchRecoveredQuality(fresh, requestedSelectionId: 'expired-id'), isNull);
    });
  });
}
