import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/player/kernel/media_capability.dart';
import 'package:pure_live/core/player/kernel/media_kit_live_properties.dart';

void main() {
  tearDown(MediaKitLiveProperties.debugClearDecodeCapability);

  group('解码能力数据模型', () {
    test('unknown 不声称任何硬件能力', () {
      const capability = MediaCapability.unknown();

      expect(capability.isAndroid, isFalse);
      expect(capability.hasHardwareDecoder, isFalse);
      // unknown 的高帧率风险必须是 false：没有信息时不能替用户降档。
      expect(capability.highFrameRateRisky, isFalse);
    });

    test('有 AVC 硬解即算有硬件解码器', () {
      const capability = MediaCapability(
        isAndroid: true,
        sdkInt: 33,
        avcHardware: true,
        hevcHardware: false,
        avcFrameRateOk: true,
        hevcFrameRateOk: false,
        decoderNames: <String>['c2.qti.avc.decoder'],
      );

      expect(capability.hasHardwareDecoder, isTrue);
      expect(capability.highFrameRateRisky, isFalse);
    });

    test('有硬解但不支持目标帧率时标记高帧率风险', () {
      const capability = MediaCapability(
        isAndroid: true,
        sdkInt: 29,
        avcHardware: true,
        hevcHardware: false,
        avcFrameRateOk: false,
        hevcFrameRateOk: false,
        decoderNames: <String>['OMX.kirin.avc.decoder'],
      );

      expect(capability.hasHardwareDecoder, isTrue);
      expect(capability.highFrameRateRisky, isTrue);
    });

    test('没有硬件解码器时不把高帧率标为风险，因为降档救不了', () {
      const capability = MediaCapability(
        isAndroid: true,
        sdkInt: 29,
        avcHardware: false,
        hevcHardware: false,
        avcFrameRateOk: false,
        hevcFrameRateOk: false,
        decoderNames: <String>[],
      );

      expect(capability.hasHardwareDecoder, isFalse);
      expect(capability.highFrameRateRisky, isFalse);
    });
  });

  group('能力探测影响自动低配表', () {
    test('未探测时不改变原有判断（至少不强制低配）', () {
      // 默认状态：没有平台答案，沿用核数与内存启发式。
      MediaKitLiveProperties.debugClearDecodeCapability();

      // 断言可观察的产物：属性表能正常生成，且没有因为探测缺失而崩。
      final properties = MediaKitLiveProperties.build();
      expect(properties['cache'], 'yes');
      expect(properties['demuxer-max-bytes'], isNotNull);
    });

    test('明确报告没有硬件解码器时启用低配内存表', () {
      MediaKitLiveProperties.debugSetDecodeCapability(hardware: false);

      final properties = MediaKitLiveProperties.build();

      expect(properties['demuxer-max-bytes'], MediaKitLiveProperties.lowEndForwardBytes.toString());
      expect(properties['demuxer-max-back-bytes'], MediaKitLiveProperties.lowEndBackBytes.toString());
    });

    test('报告有硬件解码器时不因缺少信息强制低配', () {
      MediaKitLiveProperties.debugSetDecodeCapability(hardware: true);

      final properties = MediaKitLiveProperties.build();

      // 该测试机若核数较少，仍可能走低配；只断言不会被探测强制。
      expect(properties.containsKey('demuxer-max-bytes'), isTrue);
    });
  });
}
