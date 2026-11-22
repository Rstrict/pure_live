import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:media_core/media_core.dart';
import 'package:media_core_fullscreen/media_core_fullscreen.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/core/platform/orientation_lock.dart';
import 'package:pure_live/core/platform/orientation_preference.dart';
import 'package:pure_live/core/player/kernel/player_kernel_service.dart';

@visibleForTesting
bool supportsOrientationLockForLogicalDisplay(Size logicalDisplaySize) {
  // The lock used to be refused on any display whose shortest side reached
  // 600 dp, on the theory that a large screen must be a tablet and tablets do
  // not need rotating. That test is a screen size, and it says nothing about
  // whether the device can rotate: a Huawei M6 reports 640 x 1000 dp in
  // portrait (1600 px at 400 dpi), so the shortest side is 640 — one dp-group
  // past the cutoff — and `landScape()` returned without ever asking the
  // platform for a landscape orientation. The visible effect was that
  // fullscreen simply stayed portrait on that device.
  //
  // Size is the wrong signal in both directions: a folded phone can report a
  // large shortest side, and a 7" tablet is still a rotating Android device.
  // What the guard needs to exclude is an unfolded large-screen window, and
  // Android already reports that as a multi-window/desktop mode rather than
  // through a physical size. Orientation locking is therefore always allowed
  // here; the platform drops the request when the activity is in a windowing
  // mode that cannot rotate.
  assert(logicalDisplaySize.width >= 0 && logicalDisplaySize.height >= 0);
  return true;
}

@visibleForTesting
Future<void> enterDesktopFullscreen({
  required bool isWindows,
  required Future<void> Function() prepareWindowsFullscreen,
  required Future<void> Function(bool fullscreen) setFullScreen,
}) async {
  // window_manager 0.5.2 marks a hidden-title-bar window as frameless while
  // initializing it on Windows. Its native SetFullScreen implementation skips
  // every style and bounds update while that flag is set, although it still
  // reports fullscreen=true. Reapplying the same title-bar style clears the
  // stale native guard before the actual transition.
  if (isWindows) {
    await prepareWindowsFullscreen();
  }
  await setFullScreen(true);
}

final class PureLiveFullscreenWindow implements FullscreenWindow {
  const PureLiveFullscreenWindow();

  @override
  Future<bool> get isFullscreen => windowManager.isFullScreen();

  @override
  Future<Rect> captureBounds() => windowManager.getBounds();

  @override
  Future<void> setFullscreen(bool value, {Rect? restoreBounds}) async {
    if (value) {
      await enterDesktopFullscreen(
        isWindows: Platform.isWindows,
        prepareWindowsFullscreen: () => windowManager.setTitleBarStyle(TitleBarStyle.hidden),
        setFullScreen: windowManager.setFullScreen,
      );
      return;
    }
    await windowManager.setFullScreen(false);
    if (restoreBounds != null) {
      await windowManager.setBounds(restoreBounds);
    }
  }
}

final FullscreenDriver fullscreenDriver = FullscreenDriver(
  // Restoring the pre-fullscreen bounds is load-bearing beyond fullscreen
  // itself: entering picture-in-picture releases fullscreen first, and the
  // PiP backend captures the window state at that moment. Without the
  // restore, that state is the screen-sized window, and both the PiP exit
  // and the next fullscreen exit bring the window back screen-sized.
  config: const FullscreenConfig(restorePreviousBounds: true),
  desktopWindow: const PureLiveFullscreenWindow(),
);

class WindowService {
  static final WindowService _instance = WindowService._internal();
  factory WindowService() => _instance;
  WindowService._internal();

  bool _canApplyMobileOrientationLock() {
    if (!Platform.isAndroid) return true;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return true;
    final display = views.first.display;
    final logicalSize = Size(
      display.size.width / display.devicePixelRatio,
      display.size.height / display.devicePixelRatio,
    );
    return supportsOrientationLockForLogicalDisplay(logicalSize);
  }

  /// The orientation the viewer asked the app to keep.
  ///
  /// Read through the settings service so the fullscreen transition and the
  /// settings page cannot disagree about which way the screen should be.
  OrientationPreference get _orientationPreference =>
      SettingsService.to.app.orientationPreference;

  Future<void> landScape() async {
    dynamic document;
    try {
      if (kIsWeb) {
        await document.documentElement?.requestFullscreen();
      } else if (Platform.isAndroid || Platform.isIOS) {
        if (!_canApplyMobileOrientationLock()) return;
        // A viewer who pinned portrait keeps it: fullscreen must respect the
        // explicit setting instead of overriding it with a guess about how a
        // video "ought" to be shown.
        if (_orientationPreference == OrientationPreference.portrait) return;
        await OrientationLock.apply(OrientationPreference.landscape);
      } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        await doEnterFullScreen();
      }
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
    }
  }

  Future<void> verticalScreen() async {
    if (!_canApplyMobileOrientationLock()) return;
    // Leaving fullscreen restores the *preference*, not an unconditional
    // portrait: a viewer who pinned landscape should not be spun upright every
    // time they close the player.
    await OrientationLock.apply(_orientationPreference);
  }

  Future<void> followSystemOrientation() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    await OrientationLock.apply(OrientationPreference.system);
  }

  Future<void> doEnterFullScreen() async {
    if (kIsWeb) return;
    // One driver request serves both platform families: the driver performs
    // the desktop window transition (through PureLiveFullscreenWindow, with
    // its frameless guard) and the mobile immersive switch itself.
    await fullscreenDriver.initialize();
    await _applyPresentation(PresentationRequest.fullscreen());
  }

  Future<void> doExitFullScreen() async {
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        // Host-owned policy on mobile: the status bar styling and the
        // orientation restore are this app's theming and orientation rules.
        // The system UI mode itself is restored by the driver below.
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(statusBarIconBrightness: Brightness.dark, statusBarBrightness: Brightness.light),
        );
        // 手机退全屏回竖屏:iOS 只解除限制(空数组 = 跟随系统)并不会主动把
        // 已经横着的界面转回来,设备会一直停在横屏。平板等大屏不锁方向
        // (verticalScreen 内部守卫直接跳过),保持自由旋转。
        await verticalScreen();
      }
      await fullscreenDriver.initialize();
      await _applyPresentation(PresentationRequest.normal());
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
    }
  }

  /// Routes a mode request through the kernel presentation chain.
  ///
  /// The chain is the only owner of "the previous mode leaves first"
  /// (`PresentationDriverChain._active`). Driving [fullscreenDriver] directly —
  /// which is what the two transitions below used to do — left that bookkeeping
  /// empty, so the chain never released fullscreen when picture-in-picture was
  /// requested: the window stayed system-fullscreen while the small window
  /// applied its own size and picture fit on top of it (cropped picture, the
  /// fullscreen controls inside the small window), and leaving the small window
  /// restored fullscreen geometry. The comment on [fullscreenDriver]'s config
  /// has always described the intended release; this is what makes it happen.
  ///
  /// A host whose kernel is not attached yet still gets the direct call.
  Future<void> _applyPresentation(PresentationRequest request) async {
    final driver = PlayerKernelService.instance.kernel.presentationDriver;
    if (driver != null) {
      await driver.apply(PlayerId('pure-live'), request);
      return;
    }
    await fullscreenDriver.apply(PlayerId('pure-live'), request);
  }
}
