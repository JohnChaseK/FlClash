import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class IOSManager extends ConsumerStatefulWidget {
  final Widget child;

  const IOSManager({super.key, required this.child});

  @override
  ConsumerState<IOSManager> createState() => _IOSManagerState();
}

class _IOSManagerState extends ConsumerState<IOSManager> with ServiceListener {
  @override
  void initState() {
    super.initState();
    service?.addListener(this);
    ref.listenManual(sharedStateProvider, (previous, next) {
      if (previous != next && next.vpnOptions != null) {
        unawaited(service?.syncState(next));
        debouncer.call(FunctionTag.saveSharedFile, () async {
          await preferences.saveShareState(next);
        }, duration: const Duration(seconds: 1));
      }
    });
  }

  @override
  void onServiceEvent(CoreEvent event) {
    coreEventManager.sendEvent(event);
  }

  @override
  void onServiceStopped() {
    unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    service?.removeListener(this);
    super.dispose();
  }
}
