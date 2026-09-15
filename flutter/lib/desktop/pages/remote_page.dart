import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:flutter_hbb/models/state_model.dart';

import '../../consts.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/remote_input.dart';
import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/toolbar.dart';
import '../../models/model.dart';
import '../../models/input_model.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';
import '../../utils/image.dart';
import '../widgets/remote_toolbar.dart';
import '../widgets/kb_layout_type_chooser.dart';
import '../widgets/tabbar_widget.dart';
import 'macos_full_screen_focus_recovery.dart';

import 'package:flutter_hbb/native/custom_cursor.dart'
    if (dart.library.html) 'package:flutter_hbb/web/custom_cursor.dart';

final SimpleWrapper<bool> _firstEnterImage = SimpleWrapper(false);

// Used to skip session close if "move to new window" is clicked.
final Map<String, bool> closeSessionOnDispose = {};

class RemotePage extends StatefulWidget {
  RemotePage({
    Key? key,
    required this.id,
    required this.toolbarState,
    this.sessionId,
    this.tabWindowId,
    this.password,
    this.display,
    this.displays,
    this.tabController,
    this.switchUuid,
    this.forceRelay,
    this.isSharedPassword,
  }) : super(key: key) {
    initSharedStates(id);
  }

  final String id;
  final SessionID? sessionId;
  final int? tabWindowId;
  final int? display;
  final List<int>? displays;
  final String? password;
  final ToolbarState toolbarState;
  final String? switchUuid;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final SimpleWrapper<State<RemotePage>?> _lastState = SimpleWrapper(null);
  final DesktopTabController? tabController;

  FFI get ffi => (_lastState.value! as _RemotePageState)._ffi;

  void releaseMacOSInputForTabTransfer() {
    if (!isMacOS) return;
    (_lastState.value! as _RemotePageState)._releaseMacOSRemoteInput();
  }

  @override
  State<RemotePage> createState() {
    final state = _RemotePageState(id);
    _lastState.value = state;
    return state;
  }
}

class _RemotePageState extends State<RemotePage>
    with
        AutomaticKeepAliveClientMixin,
        MultiWindowListener,
        WidgetsBindingObserver,
        TickerProviderStateMixin {
  Timer? _timer;
  // PATCH_DATASYSTEM_TITLE
  Timer? _aliasTimer;
  bool _settingTitle = false;
  String keyboardMode = "legacy";
  bool _isWindowBlur = false;
  AppLifecycleState? _macOSLifecycleState;
  bool _macOSLocalFocusLost = false;
  bool _macOSInputActive = false;
  bool _macOSInputSuppressed = false;
  final _macOSFullScreenFocusRecovery = MacOSFullScreenFocusRecovery();
  bool _macOSExplicitFocusRequestPending = false;
  StreamSubscription<DesktopTabState>? _tabStateSubscription;
  final _cursorOverImage = false.obs;
  late RxBool _showRemoteCursor;
  late RxBool _zoomCursor;
  late RxBool _remoteCursorMoved;
  late RxBool _keyboardEnabled;
  final _uniqueKey = UniqueKey();

  var _blockableOverlayState = BlockableOverlayState();

  final FocusNode _rawKeyFocusNode = FocusNode(debugLabel: "rawkeyFocusNode");

  Timer? _pointerLockCenterDebounceTimer;

  int? _instanceIdOnEnterOrLeaveImage4Toolbar;
  Function(bool)? _onEnterOrLeaveImage4Toolbar;

  late FFI _ffi;
  Worker? _waylandKeyboardModeWorker;
  bool _waylandKeyboardModeNormalized = false;
  bool _waylandKeyboardModeNormalizing = false;

  SessionID get sessionId => _ffi.sessionId;

  _RemotePageState(String id) {
    _initStates(id);
  }

  void _initStates(String id) {
    _zoomCursor = PeerBoolOption.find(id, kOptionZoomCursor);
    _showRemoteCursor = ShowRemoteCursorState.find(id);
    _keyboardEnabled = KeyboardEnabledState.find(id);
    _remoteCursorMoved = RemoteCursorMovedState.find(id);
  }

  // PATCH_DATASYSTEM_TITLE
  // Aplica o alias do peer como titulo da janela. Roda uma vez imediatamente
  // e depois se reagenda indefinidamente para impedir que o RustDesk sobrescreva.
  Future<void> _applyAliasTitle() async {
    // Aguarda a janela existir antes de tentar renomear
    for (int i = 0; i < 5; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final ok = await _setAliasTitleOnce();
      if (ok) break;
    }
    if (!mounted) return;
    _scheduleNextAliasTitle();
  }

  // PATCH_DATASYSTEM_TITLE
  // Reagenda a proxima aplicacao apos a atual terminar (evita sobreposicao).
  void _scheduleNextAliasTitle() {
    _aliasTimer?.cancel();
    _aliasTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted) return;
      await _setAliasTitleOnce();
      if (!mounted) return;
      _scheduleNextAliasTitle();
    });
  }

  // PATCH_DATASYSTEM_TITLE
  // Retorna true se conseguiu definir o titulo (alias nao vazio e setTitle ok).
  Future<bool> _setAliasTitleOnce() async {
    if (_settingTitle) return false;
    _settingTitle = true;
    try {
      if (widget.tabWindowId == null) return false;

      String alias = '';
      try {
        final peer = gFFI.abModel.find(widget.id);
        alias = peer?.alias ?? '';
      } catch (_) {
        return false;
      }
      if (alias.isEmpty) return false;

      final wc = await WindowController.fromWindowId(widget.tabWindowId!);
      await wc.setTitle(alias);
      return true;
    } catch (e) {
      debugPrint('PATCH_DATASYSTEM_TITLE erro: $e');
      return false;
    } finally {
      _settingTitle = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _ffi = FFI(widget.sessionId);
    if (isMacOS) {
      _macOSLifecycleState = SchedulerBinding.instance.lifecycleState;
      WidgetsBinding.instance.addObserver(this);
      _tabStateSubscription =
          widget.tabController?.state.listen(_onMacOSTabStateChanged);
    }
    Get.put<FFI>(_ffi, tag: widget.id);
    _ffi.imageModel.addCallbackOnFirstImage((String peerId) {
      _ffi.canvasModel.activateLocalCursor();
      showKBLayoutTypeChooserIfNeeded(
          _ffi.ffiModel.pi.platform, _ffi.dialogManager);
      _ffi.recordingModel
          .updateStatus(bind.sessionGetIsRecording(sessionId: _ffi.sessionId));
    });
    _ffi.canvasModel.initializeEdgeScrollFallback(this);
    _ffi.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      switchUuid: widget.switchUuid,
      forceRelay: widget.forceRelay,
      tabWindowId: widget.tabWindowId,
      display: widget.display,
      displays: widget.displays,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    WakelockManager.enable(_uniqueKey);

    _ffi.ffiModel.updateEventListener(sessionId, widget.id);
    _ffi.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    _ffi.dialogManager.loadMobileActionsOverlayVisible();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showRemoteCursor.value = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'show-remote-cursor');
      _zoomCursor.value = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: kOptionZoomCursor);
    });
    DesktopMultiWindow.addListener(this);

    _blockableOverlayState.applyFfi(_ffi);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });

    _ffi.inputModel.onRelativeMouseModeDisabled =
        _cancelPointerLockCenterDebounceTimer;

    _waylandKeyboardModeWorker = ever(_ffi.ffiModel.pi.isSet, (bool isSet) {
      if (isSet) {
        unawaited(_normalizeWaylandKeyboardModeIfNeeded());
      }
    });
    if (_ffi.ffiModel.pi.isSet.value) {
      unawaited(_normalizeWaylandKeyboardModeIfNeeded());
    }

    // PATCH_DATASYSTEM_TITLE - aplica o alias como titulo da janela
    unawaited(_applyAliasTitle());
  }

  Future<void> _normalizeWaylandKeyboardModeIfNeeded() async {
    if (!mounted ||
        _waylandKeyboardModeNormalized ||
        _waylandKeyboardModeNormalizing) {
      return;
    }
    _waylandKeyboardModeNormalizing = true;
    try {
      final pi = _ffi.ffiModel.pi;
      if (pi.platform != kPeerPlatformLinux || !pi.isWayland) return;
      final mapSupported = bind.sessionIsKeyboardModeSupported(
          sessionId: sessionId, mode: kKeyMapMode);
      if (!mapSupported) return;
      final current = await bind.sessionGetKeyboardMode(sessionId: sessionId);
      if (!mounted) return;
      if (current == kKeyMapMode) {
        _waylandKeyboardModeNormalized = true;
        return;
      }
      await bind.sessionSetKeyboardMode(
          sessionId: sessionId, value: kKeyMapMode);
      if (!mounted) return;
      await _ffi.inputModel.updateKeyboardMode();
      if (!mounted) return;
      _waylandKeyboardModeNormalized = true;
    } catch (e, st) {
      debugPrint('Failed to normalize Wayland keyboard mode: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      _waylandKeyboardModeNormalizing = false;
    }
  }

  void _cancelPointerLockCenterDebounceTimer() {
    _pointerLockCenterDebounceTimer?.cancel();
    _pointerLockCenterDebounceTimer = null;
  }

  bool get _isSelectedTab {
    final controller = widget.tabController;
    if (controller == null) return true;
    final tabState = controller.state.value;
    final selected = tabState.selected;
    return selected >= 0 &&
        selected < tabState.tabs.length &&
        tabState.tabs[selected].key == widget.id;
  }

  bool get _windowsCanFocusRemoteInput =>
      _isSelectedTab && _blockableOverlayState.middleBlocked.isFalse;

  bool get _isMacOSKeyboardContextActive {
    return stateGlobal.isFocused.value && !_isWindowBlur && _isSelectedTab;
  }

  void _onMacOSTabStateChanged(DesktopTabState _) {
    if (!_isSelectedTab) {
      _macOSFullScreenFocusRecovery.cancel();
      _syncMacOSKeyboardGrab();
      return;
    }
    scheduleMicrotask(() {
      if (mounted) {
        _syncMacOSKeyboardGrab(reassert: true);
      }
    });
  }

  void _releaseMacOSRemoteInput() {
    _macOSFullScreenFocusRecovery.cancel();
    _macOSExplicitFocusRequestPending = false;
    _macOSInputSuppressed = true;
    _macOSLocalFocusLost = true;
    _ffi.inputModel.enterOrLeave(false);
    _macOSInputActive = false;
    _rawKeyFocusNode.unfocus();
  }

  void _onMacOSFocusChange() {
    if (_rawKeyFocusNode.hasPrimaryFocus) {
      final explicitRequest = _macOSExplicitFocusRequestPending;
      _macOSExplicitFocusRequestPending = false;
      if (explicitRequest && _isMacOSKeyboardContextActive) {
        _macOSLocalFocusLost = false;
      }
      _syncMacOSKeyboardGrab(allowInactiveLifecycle: explicitRequest);
    } else {
      if (_macOSInputActive) {
        _ffi.inputModel.enterOrLeave(false);
        _macOSInputActive = false;
      }
      if (_isMacOSKeyboardContextActive) {
        _macOSLocalFocusLost = true;
      }
    }
  }

  void _syncMacOSKeyboardGrab({
    bool reassert = false,
    bool allowInactiveLifecycle = false,
  }) {
    if (!isMacOS) return;
    final lifecycleAllowsInput = allowInactiveLifecycle ||
        _macOSLifecycleState == null ||
        _macOSLifecycleState == AppLifecycleState.resumed;
    final shouldFocus = lifecycleAllowsInput &&
        _isMacOSKeyboardContextActive &&
        !_macOSInputSuppressed &&
        _blockableOverlayState.middleBlocked.isFalse &&
        _cursorOverImage.value &&
        !_macOSLocalFocusLost;
    final hasFocus = _rawKeyFocusNode.hasPrimaryFocus;
    final shouldActivateInput = shouldFocus && hasFocus;

    if (shouldActivateInput != _macOSInputActive ||
        (shouldActivateInput && reassert)) {
      _ffi.inputModel.enterOrLeave(shouldActivateInput);
    }
    _macOSInputActive = shouldActivateInput;

    if (!shouldFocus) {
      _macOSExplicitFocusRequestPending = false;
      if (hasFocus) _rawKeyFocusNode.unfocus();
    } else if (!hasFocus) {
      _macOSExplicitFocusRequestPending = allowInactiveLifecycle;
      _rawKeyFocusNode.requestFocus();
    } else {
      _macOSExplicitFocusRequestPending = false;
    }
  }

  void _restoreMacOSKeyboardAfterFullScreen({
    required int generation,
    bool allowHiddenLifecycle = false,
  }) {
    if (!_macOSFullScreenFocusRecovery.isCurrent(generation) ||
        (!allowHiddenLifecycle &&
            _macOSLifecycleState == AppLifecycleState.hidden)) {
      return;
    }
    final contextActive =
        stateGlobal.isFocused.value && !_isWindowBlur && _isSelectedTab;
    final shouldInferPointerInside = !_cursorOverImage.value &&
        allowHiddenLifecycle &&
        stateGlobal.fullscreen.isTrue &&
        contextActive;
    final canRestore = contextActive &&
        _blockableOverlayState.middleBlocked.isFalse &&
        (_cursorOverImage.value || shouldInferPointerInside);
    if (!_macOSFullScreenFocusRecovery.consume(generation)) return;
    if (!canRestore) {
      return;
    }
    if (shouldInferPointerInside) {
      _cursorOverImage.value = true;
    }
    _macOSLocalFocusLost = false;
    stateGlobal.getInputSource(force: true);
    _syncMacOSKeyboardGrab(reassert: true, allowInactiveLifecycle: true);
  }

  void _scheduleMacOSKeyboardAfterFullScreen({
    required int generation,
    bool allowHiddenLifecycle = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer.run(() {
        if (mounted) {
          _restoreMacOSKeyboardAfterFullScreen(
            generation: generation,
            allowHiddenLifecycle: allowHiddenLifecycle,
          );
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _queueMacOSKeyboardAfterFullScreen({
    bool allowHiddenLifecycle = false,
  }) {
    final generation = _macOSFullScreenFocusRecovery.queue();
    if (_macOSLifecycleState == AppLifecycleState.paused ||
        _macOSLifecycleState == AppLifecycleState.detached) {
      _macOSFullScreenFocusRecovery.cancel();
      return;
    }
    _scheduleMacOSKeyboardAfterFullScreen(
      generation: generation,
      allowHiddenLifecycle: allowHiddenLifecycle,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!isMacOS || _macOSLifecycleState == state) return;
    _macOSLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _syncMacOSKeyboardGrab(reassert: true);
    } else if (_macOSInputActive) {
      _ffi.inputModel.enterOrLeave(false);
      _macOSInputActive = false;
    }

    final generation = _macOSFullScreenFocusRecovery.pendingGeneration;
    if (generation == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.resumed) {
      _scheduleMacOSKeyboardAfterFullScreen(generation: generation);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _macOSFullScreenFocusRecovery.cancel();
    }
  }

  @override
  void onWindowBlur() {
    super.onWindowBlur();
    if (isWindows || isMacOS) {
      _isWindowBlur = true;
    }
    if (isMacOS) {
      _macOSFullScreenFocusRecovery.cancel();
      _macOSLocalFocusLost = true;
    }
    if (isWindows) {
      _rawKeyFocusNode.unfocus();
    }
    stateGlobal.isFocused.value = false;
    _syncMacOSKeyboardGrab();

    if (_ffi.inputModel.relativeMouseMode.value) {
      _ffi.inputModel.onWindowBlur();
    }
  }

  @override
  void onWindowFocus() {
    super.onWindowFocus();
    if (isWindows || isMacOS) {
      _isWindowBlur = false;
    }
    if (isMacOS) stateGlobal.getInputSource(force: true);
    stateGlobal.isFocused.value = true;

    if (isMacOS &&
        stateGlobal.fullscreen.isTrue &&
        !_ffi.inputModel.relativeMouseMode.value) {
      _queueMacOSKeyboardAfterFullScreen(allowHiddenLifecycle: true);
    }

    if (isWindows &&
        _cursorOverImage.value &&
        _windowsCanFocusRemoteInput &&
        !_rawKeyFocusNode.hasFocus) {
      _rawKeyFocusNode.requestFocus();
    }

    if (_ffi.inputModel.relativeMouseMode.value) {
      if (isMacOS) {
        if (_blockableOverlayState.middleBlocked.isFalse) {
          _cursorOverImage.value = true;
          _macOSLocalFocusLost = false;
        }
      } else if (!isWindows || _windowsCanFocusRemoteInput) {
        _rawKeyFocusNode.requestFocus();
      }
      _ffi.inputModel.onWindowFocus();
    }
    _syncMacOSKeyboardGrab(reassert: true, allowInactiveLifecycle: true);
  }

  @override
  void onWindowRestore() {
    super.onWindowRestore();
    if (isWindows) {
      _isWindowBlur = false;
    }
    WakelockManager.enable(_uniqueKey);
    _updatePointerLockCenterIfNeeded();
  }

  @override
  void onWindowMaximize() {
    super.onWindowMaximize();
    WakelockManager.enable(_uniqueKey);
    _updatePointerLockCenterIfNeeded();
  }

  @override
  void onWindowResize() {
    super.onWindowResize();
    _updatePointerLockCenterIfNeeded();
  }

  @override
  void onWindowMove() {
    super.onWindowMove();
    _updatePointerLockCenterIfNeeded();
  }

  void _updatePointerLockCenterIfNeeded() {
    if (!_ffi.inputModel.relativeMouseMode.value) return;

    _pointerLockCenterDebounceTimer?.cancel();
    _pointerLockCenterDebounceTimer = Timer(
      const Duration(milliseconds: kDefaultPointerLockCenterThrottleMs),
      () {
        if (!mounted) return;
        if (_ffi.inputModel.relativeMouseMode.value) {
          _ffi.inputModel.updatePointerLockCenter();
        }
      },
    );
  }

  @override
  void onWindowMinimize() {
    super.onWindowMinimize();
    WakelockManager.disable(_uniqueKey);
    if (isMacOS) {
      _macOSFullScreenFocusRecovery.cancel();
      _isWindowBlur = true;
      _cursorOverImage.value = false;
      stateGlobal.isFocused.value = false;
      _syncMacOSKeyboardGrab();
    }
    if (_ffi.inputModel.relativeMouseMode.value) {
      _ffi.inputModel.onWindowBlur();
    }
  }

  @override
  void onWindowEnterFullScreen() {
    super.onWindowEnterFullScreen();
    if (isMacOS) {
      stateGlobal.setFullscreen(true);
      _queueMacOSKeyboardAfterFullScreen();
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    super.onWindowLeaveFullScreen();
    if (isMacOS) {
      stateGlobal.setFullscreen(false);
      _queueMacOSKeyboardAfterFullScreen();
    }
  }

  @override
  Future<void> dispose() async {
    final closeSession = closeSessionOnDispose.remove(widget.id) ?? true;

    // PATCH_DATASYSTEM_TITLE - cancela o timer de alias
    _aliasTimer?.cancel();
    _aliasTimer = null;
    _settingTitle = false;

    if (isMacOS) {
      if (closeSession) {
        _releaseMacOSRemoteInput();
      }
      _tabStateSubscription?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
    debugPrint("REMOTE PAGE dispose session $sessionId ${widget.id}");

    if (!isWeb) bind.hostStopSystemKeyPropagate(stopped: true);

    _pointerLockCenterDebounceTimer?.cancel();
    _pointerLockCenterDebounceTimer = null;
    _waylandKeyboardModeWorker?.dispose();
    _ffi.inputModel.onRelativeMouseModeDisabled = null;
    _ffi.textureModel.onRemotePageDispose(closeSession);
    if (closeSession && !isMacOS) {
      _ffi.inputModel.enterOrLeave(false);
    }
    DesktopMultiWindow.removeListener(this);
    _ffi.dialogManager.hideMobileActionsOverlay();
    _ffi.imageModel.disposeImage();
    _ffi.cursorModel.disposeImages();
    _rawKeyFocusNode.dispose();
    if (closeSession) {
      clearWaylandKeyboardPromptSuppressedForConnection(sessionId.toString());
    }
    await _ffi.close(closeSession: closeSession);
    _timer?.cancel();
    _ffi.dialogManager.dismissAll();
    if (closeSession) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
    }
    WakelockManager.disable(_uniqueKey);
    await Get.delete<FFI>(tag: widget.id);
    removeSharedStates(widget.id);
  }

  Widget emptyOverlay() => BlockableOverlay(
        state: _blockableOverlayState,
        underlying: Container(
          color: Colors.transparent,
        ),
      );

  Widget buildBody(BuildContext context) {
    remoteToolbar(BuildContext context) => RemoteToolbar(
          id: widget.id,
          ffi: _ffi,
          state: widget.toolbarState,
          onEnterOrLeaveImageSetter: (id, func) {
            _instanceIdOnEnterOrLeaveImage4Toolbar = id;
            _onEnterOrLeaveImage4Toolbar = func;
          },
          onEnterOrLeaveImageCleaner: (id) {
            if (_instanceIdOnEnterOrLeaveImage4Toolbar == id) {
              _instanceIdOnEnterOrLeaveImage4Toolbar = null;
              _onEnterOrLeaveImage4Toolbar = null;
            }
          },
          setRemoteState: setState,
        );

    bodyWidget() {
      return Stack(
        children: [
          Container(
              color: kColorCanvas,
              child: RawKeyFocusScope(
                  focusNode: _rawKeyFocusNode,
                  onFocusChange: (bool imageFocused) {
                    debugPrint(
                        "onFocusChange(window active:${!_isWindowBlur}) $imageFocused");
                    if (isWindows) {
                      if (_isWindowBlur) {
                        imageFocused = false;
                        Future.delayed(Duration.zero, () {
                          _rawKeyFocusNode.unfocus();
                        });
                      }
                      if (imageFocused) {
                        _ffi.inputModel.enterOrLeave(true);
                      } else {
                        _ffi.inputModel.enterOrLeave(false);
                      }
                    } else if (isMacOS) {
                      _onMacOSFocusChange();
                    }
                  },
                  inputModel: _ffi.inputModel,
                  child: getBodyForDesktop(context))),
          Stack(
            children: [
              _ffi.ffiModel.pi.isSet.isTrue &&
                      _ffi.ffiModel.waitForFirstImage.isTrue
                  ? emptyOverlay()
                  : () {
                      if (!_ffi.ffiModel.isPeerAndroid) {
                        return Offstage();
                      } else {
                        return Obx(() => Offstage(
                              offstage: _ffi.dialogManager
                                  .mobileActionsOverlayVisible.isFalse,
                              child: Overlay(initialEntries: [
                                makeMobileActionsOverlayEntry(
                                  () => _ffi.dialogManager
                                      .setMobileActionsOverlayVisible(false),
                                  ffi: _ffi,
                                )
                              ]),
                            ));
                      }
                    }(),
              Obx(() => _ffi.inputModel.relativeMouseMode.value
                  ? const Offstage()
                  : _ffi.ffiModel.pi.isSet.isTrue
                      ? Overlay(initialEntries: [
                          OverlayEntry(builder: remoteToolbar)
                        ])
                      : remoteToolbar(context)),
              _ffi.ffiModel.pi.isSet.isFalse ? emptyOverlay() : Offstage(),
            ],
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Obx(() {
        final imageReady = _ffi.ffiModel.pi.isSet.isTrue &&
            _ffi.ffiModel.waitForFirstImage.isFalse;
        if (imageReady) {
          if (DateTime.now().difference(togglePrivacyModeTime) >
              const Duration(milliseconds: 3000)) {
            _ffi.dialogManager.dismissAll();
            _blockableOverlayState = BlockableOverlayState();
            _blockableOverlayState.applyFfi(_ffi);
          }
          return BlockableOverlay(
            underlying: bodyWidget(),
            state: _blockableOverlayState,
          );
        } else {
          return bodyWidget();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return WillPopScope(
        onWillPop: () async {
          clientClose(sessionId, _ffi);
          return false;
        },
        child: MultiProvider(providers: [
          ChangeNotifierProvider.value(value: _ffi.ffiModel),
          ChangeNotifierProvider.value(value: _ffi.imageModel),
          ChangeNotifierProvider.value(value: _ffi.cursorModel),
          ChangeNotifierProvider.value(value: _ffi.canvasModel),
          ChangeNotifierProvider.value(value: _ffi.recordingModel),
        ], child: buildBody(context)));
  }

  void enterView(PointerEnterEvent evt) {
    _ffi.canvasModel.rearmEdgeScroll();

    _cursorOverImage.value = true;
    _firstEnterImage.value = true;
    if (_onEnterOrLeaveImage4Toolbar != null) {
      try {
        _onEnterOrLeaveImage4Toolbar!(true);
      } catch (e) {
        //
      }
    }

    if (isMacOS) {
      _macOSLocalFocusLost = false;
      stateGlobal.getInputSource(force: true);
      _syncMacOSKeyboardGrab(reassert: true, allowInactiveLifecycle: true);
    } else if (isWindows) {
      if (!_isWindowBlur &&
          _windowsCanFocusRemoteInput &&
          !_rawKeyFocusNode.hasFocus) {
        _rawKeyFocusNode.requestFocus();
      }
    } else {
      if (!_rawKeyFocusNode.hasFocus) {
        _rawKeyFocusNode.requestFocus();
      }
      _ffi.inputModel.enterOrLeave(true);
    }
  }

  void leaveView(PointerExitEvent evt) {
    _ffi.canvasModel.disableEdgeScroll();

    if (_ffi.ffiModel.keyboard) {
      _ffi.inputModel.tryMoveEdgeOnExit(evt.position);
    }

    _cursorOverImage.value = false;
    _firstEnterImage.value = false;
    if (_onEnterOrLeaveImage4Toolbar != null) {
      try {
        _onEnterOrLeaveImage4Toolbar!(false);
      } catch (e) {
        //
      }
    }

    if (isMacOS) {
      _syncMacOSKeyboardGrab();
    } else if (!isWindows) {
      _ffi.inputModel.enterOrLeave(false);
    }
  }

  Widget _buildRawTouchAndPointerRegion(
    Widget child,
    PointerEnterEventListener? onEnter,
    PointerExitEventListener? onExit,
  ) {
    return RawTouchGestureDetectorRegion(
      child: _buildRawPointerMouseRegion(child, onEnter, onExit),
      ffi: _ffi,
    );
  }

  Widget _buildRawPointerMouseRegion(
    Widget child,
    PointerEnterEventListener? onEnter,
    PointerExitEventListener? onExit,
  ) {
    return RawPointerMouseRegion(
      onEnter: onEnter,
      onExit: onExit,
      onPointerDown: (event) {
        if ((isWindows || isMacOS) && _isWindowBlur) {
          debugPrint(
              "Unexpected status: onPointerDown is triggered while the remote window is in blur status");
          _isWindowBlur = false;
        }
        if (isMacOS) {
          if (onEnter == null || onExit == null) return;
          if (!stateGlobal.isFocused.value) {
            stateGlobal.isFocused.value = true;
          }
          _cursorOverImage.value = true;
          _macOSLocalFocusLost = false;
          stateGlobal.getInputSource(force: true);
          _syncMacOSKeyboardGrab(
              reassert: !isInputSourceFlutter, allowInactiveLifecycle: true);
        } else if (!_rawKeyFocusNode.hasFocus) {
          _rawKeyFocusNode.requestFocus();
        }
      },
      inputModel: _ffi.inputModel,
      child: child,
    );
  }

  Widget getBodyForDesktop(BuildContext context) {
    var paints = <Widget>[
      MouseRegion(
        onEnter: (evt) {
          if (!isWeb) bind.hostStopSystemKeyPropagate(stopped: false);
        },
        onExit: (evt) {
          if (!isWeb) bind.hostStopSystemKeyPropagate(stopped: true);
        },
        child: _ViewStyleUpdater(
          canvasModel: _ffi.canvasModel,
          inputModel: _ffi.inputModel,
          child: Builder(builder: (context) {
            final peerDisplay = CurrentDisplayState.find(widget.id);
            return Obx(
              () => _ffi.ffiModel.pi.isSet.isFalse
                  ? Container(color: Colors.transparent)
                  : Obx(() {
                      _ffi.textureModel.updateCurrentDisplay(peerDisplay.value);
                      return ImagePaint(
                        id: widget.id,
                        zoomCursor: _zoomCursor,
                        cursorOverImage: _cursorOverImage,
                        keyboardEnabled: _keyboardEnabled,
                        remoteCursorMoved: _remoteCursorMoved,
                        listenerBuilder: (child) =>
                            _buildRawTouchAndPointerRegion(
                                child, enterView, leaveView),
                        ffi: _ffi,
                      );
                    }),
            );
          }),
        ),
      )
    ];

    if (!_ffi.canvasModel.cursorEmbedded) {
      paints
          .add(Obx(() => _showRemoteCursor.isFalse || _remoteCursorMoved.isFalse
              ? Offstage()
              : CursorPaint(
                  id: widget.id,
                  zoomCursor: _zoomCursor,
                )));
    }
    paints.add(
      Positioned(
        top: 10,
        right: 10,
        child: _buildRawTouchAndPointerRegion(
            QualityMonitor(_ffi.qualityMonitorModel), null, null),
      ),
    );
    return Stack(
      children: paints,
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _ViewStyleUpdater extends StatefulWidget {
  final CanvasModel canvasModel;
  final InputModel inputModel;
  final Widget child;

  const _ViewStyleUpdater({
    Key? key,
    required this.canvasModel,
    required this.inputModel,
    required this.child,
  }) : super(key: key);

  @override
  State<_ViewStyleUpdater> createState() => _ViewStyleUpdaterState();
}

class _ViewStyleUpdaterState extends State<_ViewStyleUpdater> {
  Size? _lastSize;
  bool _callbackScheduled = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        if (!maxWidth.isFinite || !maxHeight.isFinite) {
          return widget.child;
        }
        final newSize = Size(maxWidth, maxHeight);
        if (_lastSize != newSize) {
          _lastSize = newSize;
          if (!_callbackScheduled) {
            _callbackScheduled = true;
            SchedulerBinding.instance.addPostFrameCallback((_) {
              _callbackScheduled = false;
              final currentSize = _lastSize;
              if (mounted && currentSize != null) {
                widget.canvasModel.updateViewStyle();
                widget.inputModel.updateImageWidgetSize(currentSize);
              }
            });
          }
        }
        return widget.child;
      },
    );
  }
}

class ImagePaint extends StatefulWidget {
  final FFI ffi;
  final String id;
  final RxBool zoomCursor;
  final RxBool cursorOverImage;
  final RxBool keyboardEnabled;
  final RxBool remoteCursorMoved;
  final Widget Function(Widget)? listenerBuilder;

  ImagePaint(
      {Key? key,
      required this.ffi,
      required this.id,
      required this.zoomCursor,
      required this.cursorOverImage,
      required this.keyboardEnabled,
      required this.remoteCursorMoved,
      this.listenerBuilder})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _ImagePaintState();
}

class _ImagePaintState extends State<ImagePaint> {
  bool _lastRemoteCursorMoved = false;

  String get id => widget.id;
  RxBool get zoomCursor => widget.zoomCursor;
  RxBool get cursorOverImage => widget.cursorOverImage;
  RxBool get keyboardEnabled => widget.keyboardEnabled;
  RxBool get remoteCursorMoved => widget.remoteCursorMoved;
  Widget Function(Widget)? get listenerBuilder => widget.listenerBuilder;

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    var c = Provider.of<CanvasModel>(context);
    final s = c.scale;

    bool isViewAdaptive() => c.viewStyle.style == kRemoteViewStyleAdaptive;
    bool isViewOriginal() => c.viewStyle.style == kRemoteViewStyleOriginal;

    mouseRegion({child}) => Obx(() {
          double getCursorScale() {
            var c = Provider.of<CanvasModel>(context);
            var cursorScale = 1.0;
            if (isWindows) {
              if (zoomCursor.value && isViewAdaptive()) {
                cursorScale = s * c.devicePixelRatio;
              }
            } else {
              if (zoomCursor.value || isViewOriginal()) {
                cursorScale = s;
              }
            }
            return cursorScale;
          }

          return MouseRegion(
              cursor: cursorOverImage.isTrue
                  ? c.cursorEmbedded
                      ? SystemMouseCursors.none
                      : widget.ffi.inputModel.relativeMouseMode.value
                          ? SystemMouseCursors.none
                          : keyboardEnabled.isTrue
                              ? (() {
                                  if (remoteCursorMoved.isTrue) {
                                    _lastRemoteCursorMoved = true;
                                    return SystemMouseCursors.none;
                                  } else {
                                    if (_lastRemoteCursorMoved) {
                                      _lastRemoteCursorMoved = false;
                                      _firstEnterImage.value = true;
                                    }
                                    return _buildCustomCursor(
                                        context, getCursorScale());
                                  }
                                }())
                              : _buildDisabledCursor(context, getCursorScale())
                  : MouseCursor.defer,
              onHover: (evt) {},
              child: child);
        });
    if (c.imageOverflow.isTrue && c.scrollStyle != ScrollStyle.scrollauto) {
      final paintWidth = c.getDisplayWidth() * s;
      final paintHeight = c.getDisplayHeight() * s;
      final paintSize = Size(paintWidth, paintHeight);
      final paintWidget =
          m.useTextureRender || widget.ffi.ffiModel.pi.forceTextureRender
              ? _BuildPaintTextureRender(
                  c, s, Offset.zero, paintSize, isViewOriginal())
              : _buildScrollbarNonTextureRender(m, paintSize, s);
      return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            c.updateScrollPercent();
            return false;
          },
          child: mouseRegion(
            child: Obx(() => _buildCrossScrollbarFromLayout(
                  context,
                  _buildListener(paintWidget),
                  c.size,
                  paintSize,
                  c.scrollHorizontal,
                  c.scrollVertical,
                )),
          ));
    } else {
      if (c.size.width > 0 && c.size.height > 0) {
        final paintWidget =
            m.useTextureRender || widget.ffi.ffiModel.pi.forceTextureRender
                ? _BuildPaintTextureRender(
                    c,
                    s,
                    Offset(
                      isLinux ? c.x.toInt().toDouble() : c.x,
                      isLinux ? c.y.toInt().toDouble() : c.y,
                    ),
                    c.size,
                    isViewOriginal())
                : _buildScrollAutoNonTextureRender(m, c, s);
        return mouseRegion(child: _buildListener(paintWidget));
      } else {
        return Container();
      }
    }
  }

  Widget _buildScrollbarNonTextureRender(
      ImageModel m, Size imageSize, double s) {
    return CustomPaint(
      size: imageSize,
      painter: ImagePainter(image: m.image, x: 0, y: 0, scale: s),
    );
  }

  Widget _buildScrollAutoNonTextureRender(
      ImageModel m, CanvasModel c, double s) {
    double sizeScale = s;
    if (widget.ffi.ffiModel.isPeerLinux) {
      final displays = widget.ffi.ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
        sizeScale = s / displays[0].scale;
      }
    }
    return CustomPaint(
      size: Size(c.size.width, c.size.height),
      painter: ImagePainter(
          image: m.image,
          x: c.x / sizeScale,
          y: c.y / sizeScale,
          scale: sizeScale),
    );
  }

  Widget _BuildPaintTextureRender(
      CanvasModel c, double s, Offset offset, Size size, bool isViewOriginal) {
    final ffiModel = c.parent.target!.ffiModel;
    final displays = ffiModel.pi.getCurDisplays();
    final children = <Widget>[];
    final rect = ffiModel.rect;
    if (rect == null) {
      return Container();
    }
    final isPeerLinux = ffiModel.isPeerLinux;
    final curDisplay = ffiModel.pi.currentDisplay;
    for (var i = 0; i < displays.length; i++) {
      final textureId = widget.ffi.textureModel
          .getTextureId(curDisplay == kAllDisplayValue ? i : curDisplay);
      if (true) {
        final sizeScale = isPeerLinux ? s / displays[i].scale : s;
        children.add(Positioned(
          left: (displays[i].x - rect.left) * s + offset.dx,
          top: (displays[i].y - rect.top) * s + offset.dy,
          width: displays[i].width * sizeScale,
          height: displays[i].height * sizeScale,
          child: Obx(() => Texture(
                textureId: textureId.value,
                filterQuality:
                    isViewOriginal ? FilterQuality.none : FilterQuality.low,
              )),
        ));
      }
    }
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(children: children),
    );
  }

  MouseCursor _buildCustomCursor(BuildContext context, double scale) {
    final cursor = Provider.of<CursorModel>(context);
    final cache = cursor.cache ?? preDefaultCursor.cache;
    return buildCursorOfCache(cursor, scale, cache);
  }

  MouseCursor _buildDisabledCursor(BuildContext context, double scale) {
    final cursor = Provider.of<CursorModel>(context);
    final cache = preForbiddenCursor.cache;
    return buildCursorOfCache(cursor, scale, cache);
  }

  Widget _buildCrossScrollbarFromLayout(
    BuildContext context,
    Widget child,
    Size layoutSize,
    Size size,
    ScrollController horizontal,
    ScrollController vertical,
  ) {
    var widget = child;
    if (layoutSize.width < size.width) {
      widget = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: horizontal,
          scrollDirection: Axis.horizontal,
          physics: cursorOverImage.isTrue
              ? const NeverScrollableScrollPhysics()
              : null,
          child: widget,
        ),
      );
    } else {
      widget = Row(
        children: [
          Container(
            width: ((layoutSize.width - size.width) ~/ 2).toDouble(),
          ),
          widget,
        ],
      );
    }
    if (layoutSize.height < size.height) {
      widget = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: vertical,
          physics: cursorOverImage.isTrue
              ? const NeverScrollableScrollPhysics()
              : null,
          child: widget,
        ),
      );
    } else {
      widget = Column(
        children: [
          Container(
            height: ((layoutSize.height - size.height) ~/ 2).toDouble(),
          ),
          widget,
        ],
      );
    }
    if (layoutSize.width < size.width) {
      widget = RawScrollbar(
        thickness: kScrollbarThickness,
        thumbColor: Colors.grey,
        controller: horizontal,
        thumbVisibility: false,
        trackVisibility: false,
        notificationPredicate: layoutSize.height < size.height
            ? (notification) => notification.depth == 1
            : defaultScrollNotificationPredicate,
        child: widget,
      );
    }
    if (layoutSize.height < size.height) {
      widget = RawScrollbar(
        thickness: kScrollbarThickness,
        thumbColor: Colors.grey,
        controller: vertical,
        thumbVisibility: false,
        trackVisibility: false,
        child: widget,
      );
    }

    return Container(
      child: widget,
      width: layoutSize.width,
      height: layoutSize.height,
    );
  }

  Widget _buildListener(Widget child) {
    if (listenerBuilder != null) {
      return listenerBuilder!(child);
    } else {
      return child;
    }
  }
}

class CursorPaint extends StatelessWidget {
  final String id;
  final RxBool zoomCursor;

  const CursorPaint({
    Key? key,
    required this.id,
    required this.zoomCursor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    double hotx = m.hotx;
    double hoty = m.hoty;
    if (m.image == null) {
      if (preDefaultCursor.image != null) {
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }

    double cx = c.x;
    double cy = c.y;
    if (c.viewStyle.style == kRemoteViewStyleOriginal &&
        c.scrollStyle == ScrollStyle.scrollbar) {
      final rect = c.parent.target!.ffiModel.rect;
      if (rect == null) {
        debugPrint('unreachable! The displays rect is null.');
        return Container();
      }
      if (cx < 0) {
        final imageWidth = rect.width * c.scale;
        cx = -imageWidth * c.scrollX;
      }
      if (cy < 0) {
        final imageHeight = rect.height * c.scale;
        cy = -imageHeight * c.scrollY;
      }
    }

    double x = (m.x - hotx) * c.scale + cx;
    double y = (m.y - hoty) * c.scale + cy;
    double scale = 1.0;
    final isViewOriginal = c.viewStyle.style == kRemoteViewStyleOriginal;
    if (zoomCursor.value || isViewOriginal) {
      x = m.x - hotx + cx / c.scale;
      y = m.y - hoty + cy / c.scale;
      scale = c.scale;
    }

    return CustomPaint(
      painter: ImagePainter(
        image: m.image ?? preDefaultCursor.image,
        x: x,
        y: y,
        scale: scale,
      ),
    );
  }
}
