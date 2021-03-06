import 'dart:async';

import 'package:angular/angular.dart';
import 'package:meta/meta.dart';

import 'base_stabilizer.dart';
import 'timer_hook_zone.dart';

/// Observes [NgZone] and custom parent zone to stabilize.
///
/// * Any microtasks are automatically waited for stability in [update].
/// * Any timers are automatically waited for stability in [update].
///
/// This stabilizer is a good choice for most tests.
///
/// **NOTE**: _Periodic_ timers are not supported by this stabilizer.
class RealTimeNgZoneStabilizer extends BaseNgZoneStabilizer<_ObservedTimer> {
  /// Creates a new stabilizer which manages a custom zone around an [NgZone].
  factory RealTimeNgZoneStabilizer(TimerHookZone timerZone, NgZone ngZone) {
    // All non-periodic timers that have been started, but not completed.
    final pendingTimers = Set<_ObservedTimer>.identity();
    timerZone.createTimer = (
      self,
      parent,
      zone,
      duration,
      callback,
    ) {
      _ObservedTimer instance;
      final wrappedCallback = () {
        try {
          callback();
        } finally {
          pendingTimers.remove(instance);
        }
      };
      final delegate = parent.createTimer(
        zone,
        duration,
        wrappedCallback,
      );
      instance = _ObservedTimer(
        delegate,
        duration,
        () => pendingTimers.remove(instance),
      );
      pendingTimers.add(instance);
      return instance;
    };
    return RealTimeNgZoneStabilizer._(
      ngZone,
      pendingTimers,
    );
  }

  RealTimeNgZoneStabilizer._(
    NgZone ngZone,
    Set<_ObservedTimer> pendingTimers,
  ) : super(ngZone, pendingTimers);

  @override
  bool get isStable => super.isStable && pendingTimers.isEmpty;

  @protected
  Future<void> waitForAsyncEvents() async {
    await super.waitForAsyncEvents();
    if (pendingTimers.isNotEmpty) {
      await Future.delayed(_minimumDurationForAllPendingTimers());
    }
  }

  Duration _minimumDurationForAllPendingTimers() {
    var result = Duration.zero;
    for (final timer in pendingTimers) {
      if (timer._duration > result) {
        result = timer._duration;
      }
    }
    return result;
  }
}

/// A wrapper interface around a [Timer] that tracks how long it will take.
class _ObservedTimer implements Timer {
  /// Underlying (live) timer implementation.
  final Timer _delegate;

  /// Scheduled duration.
  final Duration _duration;

  /// Handles a user cancelling the timer directly.
  final void Function() _onCancel;

  const _ObservedTimer(this._delegate, this._duration, this._onCancel);

  @override
  void cancel() {
    _onCancel();
    _delegate.cancel();
  }

  @override
  int get tick => _delegate.tick;

  @override
  bool get isActive => _delegate.isActive;
}
