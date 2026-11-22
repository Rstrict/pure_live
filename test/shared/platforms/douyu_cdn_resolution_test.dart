import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/models/live_play_quality.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/shared/platforms/douyu/douyu_site.dart';

/// One H5 play answer as [_requestPlayData] returns it.
///
/// The test seam replaces the whole request, so this is what
/// [DouyuSite.parsePlayResponse] would have handed back once the envelope was
/// unwrapped: the `data` map itself, not the `{error, data}` wrapper.
///
/// `rate` is the acknowledgement the platform reports back; `cdn` only decides
/// which signed line the fake answered for, so the same response shape covers
/// the source-quality and the downgraded cohorts.
Map<String, dynamic> _playResponse({required int rate, required String cdn}) => <String, dynamic>{
  'rate': rate,
  'rtmp_url': 'https://$cdn.douyucdn.cn/live',
  'rtmp_live': 'room.flv?wsAuth=token',
};

LiveRoom _room({String roomId = '288016'}) => LiveRoom(platform: 'douyu', roomId: roomId);

LivePlayQuality _quality({int rate = 0, List<String> cdns = const ['hw', 'qd', 'ws']}) =>
    LivePlayQuality(quality: '原画', id: rate, data: DouyuPlayData(rate, cdns));

/// Records every line that was actually signed and how many ran at once.
class _Recorder {
  _Recorder(this.answer);

  final Future<Map<String, dynamic>> Function(String cdn, CancelToken? cancel) answer;
  final List<String> started = <String>[];
  final List<String> finished = <String>[];
  int inFlight = 0;
  int peakInFlight = 0;

  Future<Map<String, dynamic>> fetch(String roomId, int rate, String cdn, CancelToken? cancel) async {
    started.add(cdn);
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    try {
      return await answer(cdn, cancel);
    } finally {
      inFlight--;
      finished.add(cdn);
    }
  }
}

void main() {
  tearDown(() {
    DouyuSite.debugPlayDataFetcher = null;
    DouyuSite.debugResolutionBudget = null;
  });

  group('斗鱼多线路取流', () {
    test('三条线路并行取，不再逐条串行等待', () async {
      final gates = <String, Completer<void>>{};
      final recorder = _Recorder((cdn, _) {
        gates[cdn] = Completer<void>();
        return gates[cdn]!.future.then((_) => _playResponse(rate: 0, cdn: cdn));
      });
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      final future = DouyuSite().resolvePlayUrlsRaw(liveroom: _room(), quality: _quality());
      // Two workers are allowed at a time, so two lines are already in flight
      // before any of them answers.
      await Future<void>.delayed(Duration.zero);
      expect(recorder.started.length, DouyuSite.cdnConcurrency);
      expect(recorder.peakInFlight, DouyuSite.cdnConcurrency);

      // Releasing one lets the next line start without waiting for the last.
      gates['hw']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(recorder.started.length, 3);

      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      final resolution = await future;

      expect(resolution.urls.length, 3);
      expect(resolution.appliedQualityData, 0);
      expect(resolution.qualityUnconfirmed, isFalse);
      // The room's own line is first among equals: it is the one the room
      // already streams from, and the UI commits index 0.
      expect(resolution.urls.first, contains('hw.douyucdn.cn'));
    });

    test('后完成的后备线路不会挤掉房间自身线路的位置', () async {
      // The room's own CDN answers last; a backup line answers first. Completion
      // order must not decide the line order, or the default playback line would
      // silently become a backup CDN.
      final recorder = _Recorder(
        (cdn, _) => cdn == 'hw'
            ? Future<Map<String, dynamic>>.delayed(
                const Duration(milliseconds: 40),
                () => _playResponse(rate: 0, cdn: cdn),
              )
            : Future<Map<String, dynamic>>.delayed(
                const Duration(milliseconds: 5),
                () => _playResponse(rate: 0, cdn: cdn),
              ),
      );
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      final resolution = await DouyuSite().resolvePlayUrlsRaw(liveroom: _room(), quality: _quality());

      expect(resolution.urls.length, 3);
      expect(resolution.urls.first, contains('hw.douyucdn.cn'));
      expect(resolution.urls.map((url) => Uri.parse(url).host).toList(), <String>[
        'hw.douyucdn.cn',
        'qd.douyucdn.cn',
        'ws.douyucdn.cn',
      ]);
    });

    test('慢线路被总期限截断，已答线路照常返回', () async {
      DouyuSite.debugResolutionBudget = const Duration(milliseconds: 120);
      final recorder = _Recorder((cdn, _) {
        if (cdn == 'hw') {
          return Future<Map<String, dynamic>>.delayed(
            const Duration(milliseconds: 10),
            () => _playResponse(rate: 0, cdn: cdn),
          );
        }
        // A line that ignores cancellation entirely: the pass still has to end
        // on its own wall clock rather than on this future.
        return Completer<Map<String, dynamic>>().future;
      });
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      final stopwatch = Stopwatch()..start();
      final resolution = await DouyuSite().resolvePlayUrlsRaw(liveroom: _room(), quality: _quality());
      stopwatch.stop();

      expect(resolution.urls, hasLength(1));
      expect(resolution.urls.single, contains('hw.douyucdn.cn'));
      expect(resolution.appliedQualityData, 0);
      // The budget, not the hung request, decided when this returned.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('调用方取消后不再发起新线路，并抛出取消', () async {
      final cancel = CancelToken();
      final recorder = _Recorder((cdn, token) {
        // The first line answers immediately; the unfinished ones hang forever
        // so only the cancellation can end the pass.
        if (cdn == 'hw') return Future.value(_playResponse(rate: 0, cdn: cdn));
        return Completer<Map<String, dynamic>>().future;
      });
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      final future = DouyuSite().resolvePlayUrlsRawCancellable(liveroom: _room(), quality: _quality(), cancel: cancel);
      await Future<void>.delayed(Duration.zero);

      // Snapshot after the pool has settled into its two workers: what matters
      // is that cancellation stops *further* lines from starting, not that no
      // worker was ever handed a line before it.
      final startedBeforeCancel = recorder.started.length;
      cancel.cancel('room changed');
      await expectLater(future, throwsA(predicate((error) => error is DioException && CancelToken.isCancel(error))));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(recorder.started.length, startedBeforeCancel);
      expect(recorder.started.length, lessThanOrEqualTo(DouyuSite.cdnConcurrency + 1));
    });

    test('服务端降档时报告实际档位，不冒充请求档位', () async {
      final recorder = _Recorder((cdn, _) => Future.value(_playResponse(rate: cdn == 'hw' ? 2 : 0, cdn: cdn)));
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      final resolution = await DouyuSite().resolvePlayUrlsRaw(liveroom: _room(), quality: _quality(rate: 0));

      // The requested rate was acknowledged by two lines, so that cohort wins
      // and the downgraded line is not mixed into the same label.
      expect(resolution.appliedQualityData, 0);
      expect(resolution.urls.every((url) => !url.contains('hw.douyucdn.cn')), isTrue);
    });

    test('全部线路失败时抛出平台的原始错误，而不是伪造一个成功', () async {
      final recorder = _Recorder((cdn, _) => Future.error(const DouyuPlayApiException('H5 play API error 102')));
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      await expectLater(
        DouyuSite().resolvePlayUrlsRaw(liveroom: _room(), quality: _quality()),
        throwsA(isA<DouyuPlayApiException>()),
      );
    });

    test('房间号为空时不发请求', () async {
      final recorder = _Recorder((cdn, _) => Future.value(_playResponse(rate: 0, cdn: cdn)));
      DouyuSite.debugPlayDataFetcher = recorder.fetch;

      final resolution = await DouyuSite().resolvePlayUrlsRaw(
        liveroom: _room(roomId: '  '),
        quality: _quality(),
      );

      expect(resolution.urls, isEmpty);
      expect(recorder.started, isEmpty);
    });
  });
}
