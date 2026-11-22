import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/domains/live/data/stream/playback_manifest_probe.dart';

/// Behaviour of one fake manifest endpoint.
enum _Mode {
  /// Answers a complete playlist and closes.
  normal,

  /// Sends the playlist header and then holds the connection open forever.
  hangsAfterHeaders,

  /// Sends a complete playlist with bare children, then keeps the socket busy
  /// without ever finishing. A streaming read can classify this and return while
  /// the transfer is still open; a buffered read would wait for the deadline.
  completeThenHangs,

  /// Trickles one byte at a time, never finishing.
  trickles,

  /// Answers with far more than the byte limit.
  oversized,
}

final class _ManifestServer {
  _ManifestServer._(this._server, this._body, this._status, this._mode);

  static Future<_ManifestServer> start({required String body, int status = 200, _Mode mode = _Mode.normal}) async {
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    final _ManifestServer result = _ManifestServer._(server, body, status, mode);
    server.listen((HttpRequest request) async {
      result.requests++;
      final HttpResponse response = request.response;
      response.statusCode = result._status;
      response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      try {
        switch (result._mode) {
          case _Mode.normal:
          case _Mode.oversized:
            response.write(result._body);
            await response.close();
          case _Mode.hangsAfterHeaders:
            // Enough bytes to prove the read started, then silence. `flush` on
            // its own does not hand the bytes to the client in Dart, so the body
            // is chunked first and only then left open.
            response.bufferOutput = false;
            response.write('#EXTM3U\n');
            await response.flush();
          // Deliberately never closes; the probe must not wait for it.
          case _Mode.completeThenHangs:
            // A whole classifiable manifest, then the keep-alive is held. The
            // answer is already known at this point, so a streaming read returns
            // without waiting for the close.
            response.bufferOutput = false;
            for (final line in result._body.split('\n')) {
              response.write('$line\n');
              await response.flush();
            }
            // Keep the response object alive without closing it.
            await Future<void>.delayed(const Duration(seconds: 30));
          case _Mode.trickles:
            response.write('#EXTM3U\n');
            for (var i = 0; i < 200; i++) {
              response.add(<int>[0x23]); // '#'
              await response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            await response.close();
        }
      } catch (_) {
        // The probe tearing the socket down is the expected end of the hang and
        // trickle modes; nothing to report.
      }
    });
    return result;
  }

  final HttpServer _server;
  final String _body;
  final int _status;
  final _Mode _mode;
  int requests = 0;

  Uri get url =>
      Uri(scheme: 'http', host: InternetAddress.loopbackIPv4.address, port: _server.port, path: '/live/media.m3u8');

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Dio dio;

  setUp(() => dio = Dio());
  tearDown(() => dio.close(force: true));

  group('清单探测按需截断', () {
    test('清单已可分类就返回，不等连接关闭', () async {
      final server = await _ManifestServer.start(
        body: '#EXTM3U\n#EXTINF:2.0,\nmedia.95.mp4\n#EXT-X-ENDLIST\n',
        mode: _Mode.completeThenHangs,
      );
      addTearDown(server.close);

      // The endpoint never closes the body. A buffered read would sit here until
      // its deadline and then report "unreadable"; a streaming read has the
      // answer as soon as the playlist is on the wire.
      final stopwatch = Stopwatch()..start();
      final probe = await probePlaybackManifest(
        server.url.toString(),
        client: dio,
        timeout: const Duration(seconds: 10),
      );
      stopwatch.stop();

      expect(probe, isNotNull);
      expect(probe!.kind.requiresRewrite, isTrue);
      expect(probe.kind.relativeChildren, 1);
      // Bounded by the read, not by the 10 s deadline above.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('回传的正文是完整清单，不因为能分类就截断', () async {
      // The probe's body is handed to the loopback relay as the root playlist and
      // served verbatim, so a truncated body silently breaks playback: the relay
      // rewrites children it never saw. Twelve segments make a mid-playlist cut
      // obvious instead of accidentally complete.
      final segments = <String>[for (var i = 0; i < 12; i++) '#EXTINF:2.0,\nseg$i.ts'].join('\n');
      final body = '#EXTM3U\n$segments\n#EXT-X-ENDLIST\n';
      final server = await _ManifestServer.start(body: body);
      addTearDown(server.close);

      final probe = await probePlaybackManifest(server.url.toString(), client: dio);

      expect(probe, isNotNull);
      expect(probe!.body, body);
      expect(probe.kind.relativeChildren, 12);
    });

    test('未声明结束的清单读到最后一条子项', () async {
      // A live playlist has no #EXT-X-ENDLIST. Its body still has to arrive
      // complete before the relay can rewrite every child.
      final segments = <String>[for (var i = 0; i < 8; i++) '#EXTINF:2.0,\nmedia.$i.mp4'].join('\n');
      final body = '#EXTM3U\n$segments\n';
      final server = await _ManifestServer.start(body: body);
      addTearDown(server.close);

      final probe = await probePlaybackManifest(server.url.toString(), client: dio);

      expect(probe, isNotNull);
      expect(probe!.body, body);
      expect(probe.kind.relativeChildren, 8);
    });

    test('只收到头部、没有子清单时按截止时间放弃', () async {
      final server = await _ManifestServer.start(body: '', mode: _Mode.hangsAfterHeaders);
      addTearDown(server.close);

      final probe = await probePlaybackManifest(
        server.url.toString(),
        client: dio,
        timeout: const Duration(milliseconds: 300),
      );

      expect(probe, isNull);
    });

    test('完整清单在连接保持时仍按截止时间返回 null，不挂住调用方', () async {
      final server = await _ManifestServer.start(
        body: '#EXTM3U\n#EXTINF:2.0,\nmedia.95.mp4\n',
        mode: _Mode.hangsAfterHeaders,
      );
      addTearDown(server.close);

      final stopwatch = Stopwatch()..start();
      final probe = await probePlaybackManifest(
        server.url.toString(),
        client: dio,
        timeout: const Duration(milliseconds: 300),
      );
      stopwatch.stop();

      expect(probe, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('超过字节上限直接拒绝，不返回半份清单', () async {
      final server = await _ManifestServer.start(
        body: '#EXTM3U\n${'#EXTINF:2.0,\nseg.ts\n' * 5000}',
        mode: _Mode.oversized,
      );
      addTearDown(server.close);

      final probe = await probePlaybackManifest(server.url.toString(), client: dio, maximumBytes: 1024);

      // Half a playlist would misclassify the children, so the answer is "no
      // answer" rather than a partial one.
      expect(probe, isNull);
    });

    test('慢速涓流受截止时间约束', () async {
      final server = await _ManifestServer.start(body: '', mode: _Mode.trickles);
      addTearDown(server.close);

      final stopwatch = Stopwatch()..start();
      final probe = await probePlaybackManifest(
        server.url.toString(),
        client: dio,
        timeout: const Duration(milliseconds: 250),
      );
      stopwatch.stop();

      expect(probe, isNull);
      // A per-chunk receive timeout would keep resetting here; the deadline is
      // what has to end it.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('调用方取消后立刻返回 null', () async {
      final server = await _ManifestServer.start(body: '', mode: _Mode.trickles);
      addTearDown(server.close);

      final cancel = CancelToken();
      final future = probePlaybackManifest(
        server.url.toString(),
        client: dio,
        cancel: cancel,
        timeout: const Duration(seconds: 30),
      );
      Timer(const Duration(milliseconds: 80), () => cancel.cancel('room changed'));

      final stopwatch = Stopwatch()..start();
      expect(await future, isNull);
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('已取消的令牌不再发起请求', () async {
      final server = await _ManifestServer.start(body: '#EXTM3U\n');
      addTearDown(server.close);

      final cancel = CancelToken()..cancel('already gone');
      expect(await probePlaybackManifest(server.url.toString(), client: dio, cancel: cancel), isNull);
      expect(server.requests, 0);
    });
  });

  group('清单分类语义保持不变', () {
    test('裸名子清单仍标记为需要改写，且回传正文', () async {
      final server = await _ManifestServer.start(body: '#EXTM3U\n#EXTINF:2.0,\nmedia.95.mp4\n#EXT-X-ENDLIST\n');
      addTearDown(server.close);

      final probe = await probePlaybackManifest(server.url.toString(), client: dio);

      expect(probe, isNotNull);
      expect(probe!.kind.requiresRewrite, isTrue);
      expect(probe.kind.relativeChildren, 1);
      // The body is handed on so the relay does not read the manifest twice.
      expect(probe.body, startsWith('#EXTM3U'));
    });

    test('绝对子清单交给播放器直连', () async {
      final server = await _ManifestServer.start(
        body: '#EXTM3U\n#EXTINF:2.0,\nhttps://cdn.example.com/seg1.ts\n#EXT-X-ENDLIST\n',
      );
      addTearDown(server.close);

      final probe = await probePlaybackManifest(server.url.toString(), client: dio);

      expect(probe?.kind.requiresRewrite, isFalse);
      expect(probe?.kind.absoluteChildren, 1);
    });

    test('非清单正文不分类', () async {
      final server = await _ManifestServer.start(body: '<html>login required</html>');
      addTearDown(server.close);

      expect(await probePlaybackManifest(server.url.toString(), client: dio), isNull);
    });

    test('403 交给调用方回退', () async {
      final server = await _ManifestServer.start(body: 'no', status: HttpStatus.forbidden);
      addTearDown(server.close);

      expect(await probePlaybackManifest(server.url.toString(), client: dio), isNull);
    });

    test('不可达主机返回 null 而不是抛出', () async {
      expect(
        await probePlaybackManifest(
          'http://127.0.0.1:1/live/media.m3u8',
          client: dio,
          timeout: const Duration(milliseconds: 300),
        ),
        isNull,
      );
    });
  });
}
