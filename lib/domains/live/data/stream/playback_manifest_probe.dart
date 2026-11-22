import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:media_core_ingest/media_core_ingest.dart';
import 'package:pure_live/core/network/http_client.dart';

/// What one manifest read told us about a source.
typedef PlaybackManifestProbe = ({HlsManifestKind kind, String body});

/// Reads [url] once, bounded, so the playback input can be decided from what the
/// manifest actually contains instead of from a per-platform guess.
///
/// The manifest form is the only thing that matters: a manifest that already
/// writes absolute URLs is handed to the player untouched, while one whose
/// children are bare names (`media.95.mp4`) or absolute paths has to be rewritten
/// over loopback first, or a resolver that loses the manifest URL turns them
/// into local paths (`\tc.livehls\...\media.95.mp4`).
///
/// Returns null when the manifest cannot be read - the caller then falls back to
/// its declared needs and finally to a direct open. Live players re-read their
/// manifest every target duration, so one extra bounded read costs nothing that
/// changes the provider's behaviour.
///
/// The read is streamed rather than buffered whole. A playlist names its
/// children in its first `#EXT` lines, so the answer is known long before the
/// body ends; reading to completion meant a provider that keeps the connection
/// open (or answers with something enormous) held the source open for as long as
/// it liked, and the size limit only rejected the result after everything had
/// already arrived. The stream stops at the first of: an answer sufficient to
/// classify, [maximumBytes], the caller's [cancel], or [timeout].
Future<PlaybackManifestProbe?> probePlaybackManifest(
  String url, {
  Map<String, String> headers = const <String, String>{},
  Dio? client,
  CancelToken? cancel,
  Duration timeout = const Duration(seconds: 3),
  int maximumBytes = 512 * 1024,
}) async {
  if (cancel?.isCancelled == true) return null;
  final Dio dio = client ?? HttpClient.instance.dio;

  // One token for the whole read. It is what actually aborts the socket when the
  // deadline passes or the caller retires the room, instead of merely abandoning
  // the future while the connection keeps working in the background.
  final CancelToken token = CancelToken();
  if (cancel != null) {
    // `whenCancel` is a future, not a stream: link it by awaiting once.
    unawaited(
      cancel.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel('manifest probe cancelled');
      }),
    );
  }
  final Timer deadline = Timer(timeout, () {
    if (!token.isCancelled) token.cancel('manifest probe timed out');
  });

  Response<ResponseBody>? response;
  StreamSubscription<Uint8List>? subscription;
  try {
    response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        followRedirects: true,
        // The deadline owns the wall clock. A per-phase receive timeout restarts
        // with every chunk, so a provider that trickles bytes forever would never
        // trip it.
        receiveTimeout: null,
        sendTimeout: timeout,
        validateStatus: (int? status) => status == 200,
      ),
      cancelToken: token,
    );
    final ResponseBody? stream = response.data;
    if (stream == null) return null;

    final BytesBuilder buffer = BytesBuilder(copy: false);
    final Completer<bool> settled = Completer<bool>();
    // Classification can settle early, but the *body* cannot: the caller hands
    // this text to the loopback relay as the root playlist, which serves it to the
    // player verbatim instead of re-reading upstream. Stopping the read at the
    // first classifiable line would therefore deliver a truncated playlist and the
    // room would fail to play. The stream is drained to its end (or to the byte
    // budget / deadline) and only the premature-stop decision uses the prefixes.
    var overLimit = false;
    subscription = stream.stream.listen(
      (Uint8List chunk) {
        if (overLimit) return;
        buffer.add(chunk);
        if (buffer.length > maximumBytes) {
          // Over the limit is a refusal, not a partial answer: half a playlist
          // would misclassify the children and send the relay after segments this
          // read never saw.
          overLimit = true;
          if (!settled.isCompleted) settled.complete(false);
          return;
        }
        // A body that is not a playlist at all (an HTML login wall, a JSON error)
        // will never become one, so there is nothing left to wait for.
        if (!settled.isCompleted && _isNotPlaylist(buffer)) settled.complete(false);
        // A playlist that declares its own end is complete even if the provider
        // keeps the connection open; anything else keeps reading to EOF so the
        // relay gets the whole body to rewrite.
        if (!settled.isCompleted && _hasDeclaredEnd(buffer)) settled.complete(true);
      },
      onDone: () {
        if (!settled.isCompleted) settled.complete(true);
      },
      onError: (Object error, StackTrace stack) {
        if (!settled.isCompleted) settled.completeError(error, stack);
      },
      cancelOnError: true,
    );

    final bool completed = await Future.any<bool>(<Future<bool>>[settled.future, token.whenCancel.then((_) => false)]);
    if (!completed || token.isCancelled) return null;
    return _classify(buffer.takeBytes());
  } catch (_) {
    // An unreadable manifest is not an error here: the player may still open the
    // source directly, and a provider that rejects this read is exactly the case
    // where guessing would be wrong.
    return null;
  } finally {
    deadline.cancel();
    await subscription?.cancel();
  }
}

/// Whether the bytes read so far cannot become a playlist.
///
/// Only the very beginning can answer this: a body that does not open with `#EXT`
/// is an HTML login wall or a JSON error, and no later byte turns it into a
/// playlist.
bool _isNotPlaylist(BytesBuilder buffer) {
  if (buffer.length < 8) return false;
  final String text = latin1.decode(buffer.toBytes(), allowInvalid: true);
  return !text.startsWith('#EXT');
}

/// Whether the playlist declares its own end.
///
/// `#EXT-X-ENDLIST` is the one marker that makes the body complete by definition,
/// so a host that keeps the connection open after it cannot force the read to sit
/// until the deadline. A live playlist without it has no self-declared end and is
/// read to EOF.
bool _hasDeclaredEnd(BytesBuilder buffer) {
  if (buffer.length < 16) return false;
  final String text = latin1.decode(buffer.toBytes(), allowInvalid: true);
  return text.contains('#EXT-X-ENDLIST');
}

PlaybackManifestProbe? _classify(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final String body = _stripBom(utf8.decode(bytes, allowMalformed: true));
  if (!body.trimLeft().startsWith('#EXT')) return null;
  return (kind: classifyHlsManifest(body), body: body);
}

String _stripBom(String value) => value.startsWith('\uFEFF') ? value.substring(1) : value;
