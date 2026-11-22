import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/models/live_play_quality.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/shared/platforms/live_quality_recovery.dart';
import 'package:pure_live/shared/platforms/live_site.dart';

/// A site whose recovery path is observable, so the contract test can assert
/// that recovery actually reacquires rather than replaying a cached list.
class _RecordingSite extends LiveSite implements LivePlayRecoveryResolver, LivePlayUrlResolver {
  _RecordingSite({required this.fresh}) {
    id = 'fake';
    name = 'Fake';
  }

  final List<LivePlayQuality> fresh;
  int resolveCalls = 0;
  int recoveryCalls = 0;

  @override
  Future<List<LivePlayQuality>> getPlayQualites({required LiveRoom liveroom}) async => fresh;

  @override
  Future<List<String>> getPlayUrls({required LiveRoom liveroom, required LivePlayQuality quality}) async {
    final data = quality.data;
    return data is List ? data.cast<String>() : const <String>[];
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsRaw({
    required LiveRoom liveroom,
    required LivePlayQuality quality,
  }) async {
    resolveCalls++;
    return LivePlayUrlResolution(
      urls: await getPlayUrls(liveroom: liveroom, quality: quality),
      appliedQualityData: quality.selectionId,
    );
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecoveryRaw({
    required LiveRoom liveroom,
    required LivePlayQuality quality,
  }) async {
    recoveryCalls++;
    final recovered = matchRecoveredQuality(fresh, requestedSelectionId: quality.selectionId);
    if (recovered == null) return const LivePlayUrlResolution(urls: <String>[]);
    return LivePlayUrlResolution(
      urls: await getPlayUrls(liveroom: liveroom, quality: recovered),
      appliedQualityData: recovered.selectionId,
    );
  }
}

void main() {
  final room = LiveRoom(platform: 'fake', roomId: '1');
  final committed = LivePlayQuality(quality: '原画', id: 'source', data: const <String>['https://old/expired.flv']);

  group('恢复契约', () {
    test('声明恢复能力的平台走恢复入口，返回新地址而不是旧列表', () async {
      final site = _RecordingSite(
        fresh: <LivePlayQuality>[
          LivePlayQuality(quality: '原画', id: 'source', data: const <String>['https://new/fresh.flv']),
        ],
      );

      final resolution = await site.resolvePlayUrlsForRecovery(liveroom: room, quality: committed);

      expect(site.recoveryCalls, 1);
      expect(site.resolveCalls, 0);
      expect(resolution.urls, <String>['https://new/fresh.flv']);
      expect(resolution.urls, isNot(contains('https://old/expired.flv')));
    });

    test('未声明恢复能力的平台退回普通解析，不报错', () async {
      final plain = _PlainSite();

      final resolution = await plain.resolvePlayUrlsForRecovery(liveroom: room, quality: committed);

      expect(plain.resolveCalls, 1);
      expect(resolution.urls, isNotEmpty);
    });

    test('平台已不提供该档位时空列表，调用方可据此提示而不是静默降级', () async {
      final site = _RecordingSite(
        fresh: <LivePlayQuality>[
          LivePlayQuality(quality: '高清', id: 'hd', data: const <String>['https://new/hd.flv']),
        ],
      );

      final resolution = await site.resolvePlayUrlsForRecovery(liveroom: room, quality: committed);

      expect(resolution.urls, isEmpty);
      expect(resolution.hasSources, isFalse);
    });
  });
}

/// A site with no recovery capability at all.
class _PlainSite extends LiveSite implements LivePlayUrlResolver {
  _PlainSite() {
    id = 'plain';
    name = 'Plain';
  }

  int resolveCalls = 0;

  @override
  Future<List<LivePlayQuality>> getPlayQualites({required LiveRoom liveroom}) async => const <LivePlayQuality>[];

  @override
  Future<List<String>> getPlayUrls({required LiveRoom liveroom, required LivePlayQuality quality}) async =>
      const <String>['https://plain/live.flv'];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsRaw({
    required LiveRoom liveroom,
    required LivePlayQuality quality,
  }) async {
    resolveCalls++;
    return LivePlayUrlResolution(
      urls: await getPlayUrls(liveroom: liveroom, quality: quality),
      appliedQualityData: quality.selectionId,
    );
  }
}
