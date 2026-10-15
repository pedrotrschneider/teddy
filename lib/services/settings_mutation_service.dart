
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../i18n/strings.g.dart';
import '../utils/platform_detector.dart';
import 'device_performance.dart';
import 'settings_service.dart';

/// Runtime effect of one stored pref. [checkCurrent] must be called after
/// every await so a profile switch mid-effect aborts the rest.
typedef _SettingsEffectHandler =
    Future<void> Function(BuildContext context, SettingsService settings, void Function()? checkCurrent);

class _SettingsEffect {
  final Pref<Object?> pref;
  final bool rebuildsRoot;
  final _SettingsEffectHandler apply;
  const _SettingsEffect(this.pref, this.apply, {this.rebuildsRoot = false});
}

/// A stored setting was saved but its runtime effect declined to apply.
///
/// This is an expected outcome, not a programming error: the companion host
/// refuses when crypto is not ready and logs the reason itself. Effects report
/// it instead of throwing past their caller, because a bulk reset or import
/// replays the whole table and must not abandon the remaining effects — and
/// because the settings tiles await their write from an `onChanged` nobody
/// watches, where a throw becomes an unhandled async error.
class SettingsEffectFailure implements Exception {
  /// The pref whose effect declined.
  final Pref<Object?> pref;

  /// Localized, user-facing reason. Safe to render in a snackbar.
  final String display;

  const SettingsEffectFailure(this.pref, this.display);

  @override
  String toString() => 'SettingsEffectFailure(${pref.key}: $display)';
}

/// One commit/effect path for settings widgets and typed callers. Existing
/// SettingsBindingOwner consumers (keyboard, theme, shaders) remain
/// the sole owners of their listener-driven effects.
class SettingsMutationService {
  const SettingsMutationService();

  /// Every pref with a runtime effect, in the order bulk import/reset replays
  /// them. Prefs without an entry are plain stored values.
  static final List<_SettingsEffect> _effects = [
    _SettingsEffect(SettingsService.appLocale, _applyAppLocale, rebuildsRoot: true),
    _SettingsEffect(
      SettingsService.forceTvMode,
      (_, settings, _) async => TvDetectionService.setForceTVSync(settings.read(SettingsService.forceTvMode)),
      rebuildsRoot: true,
    ),
    _SettingsEffect(
      SettingsService.visualEffects,
      (_, settings, _) async => DevicePerformance.setOverrideSync(settings.read(SettingsService.visualEffects)),
      rebuildsRoot: true,
    ),

  ];

  /// [Pref] compares by identity and [SettingsService.scrobblePref] mints a
  /// fresh instance per call, so lookups go through the stable key.
  static final Map<String, _SettingsEffect> _effectsByKey = {for (final effect in _effects) effect.pref.key: effect};

  static Future<void> _applyAppLocale(
    BuildContext context,
    SettingsService settings,
    void Function()? checkCurrent,
  ) async {
    final locale = settings.read(SettingsService.appLocale);
    await LocaleSettings.setLocale(locale);
    checkCurrent?.call();
  }

  /// Persist [value] and run its effect. Returns the effect's failure when it
  /// declined, so the caller can tell the user; the value is stored either way.
  Future<SettingsEffectFailure?> write<T>(
    BuildContext context,
    Pref<T> pref,
    T value, {
    bool reset = false,
    void Function()? checkCurrent,
    bool rebuildRoot = true,
  }) async {
    final settings = SettingsService.instance;
    if (!reset) SettingsService.validateEditableValue(pref, value);
    checkCurrent?.call();
    if (reset) {
      await settings.reset(pref, checkCurrent: checkCurrent);
    } else {
      await settings.write(pref, value, checkCurrent: checkCurrent);
    }
    checkCurrent?.call();
    if (!context.mounted) return null;
    return applyEffects(context, pref, checkCurrent: checkCurrent, rebuildRoot: rebuildRoot);
  }

  /// Run [pref]'s runtime effect. A declining effect is returned, not thrown:
  /// see [SettingsEffectFailure]. The root rebuild still runs, because the
  /// stored value changed regardless of whether the side effect took.
  Future<SettingsEffectFailure?> applyEffects(
    BuildContext context,
    Pref<Object?> pref, {
    void Function()? checkCurrent,
    bool rebuildRoot = true,
  }) async {
    checkCurrent?.call();
    final effect = _effectsByKey[pref.key];
    SettingsEffectFailure? failure;
    if (effect != null) {
      try {
        await effect.apply(context, SettingsService.instance, checkCurrent);
      } on SettingsEffectFailure catch (error) {
        failure = error;
      }
    }
    checkCurrent?.call();
    if (rebuildRoot && effect != null && effect.rebuildsRoot && context.mounted) rebuild(context);
    return failure;
  }

  /// Bulk import/reset bypasses typed writes but must use the same effect
  /// owners. The snapshot is command-local and only avoids unnecessary rebuilds.
  static List<Object?> captureRootConfiguration() {
    final settings = SettingsService.instance;
    return [
      for (final effect in _effects)
        if (effect.rebuildsRoot) settings.read(effect.pref),
    ];
  }

  /// Replay every effect. One declining effect must not abandon the rest — a
  /// reset that stops halfway leaves the remaining prefs stored but unapplied —
  /// so failures are collected and returned together.
  Future<List<SettingsEffectFailure>> applyStoredEffects(
    BuildContext context, {
    required List<Object?> previousRootConfiguration,
  }) async {
    final failures = <SettingsEffectFailure>[];
    for (final effect in _effects) {
      if (!context.mounted) return failures;
      final failure = await applyEffects(context, effect.pref, rebuildRoot: false);
      if (failure != null) failures.add(failure);
    }
    if (context.mounted && !listEquals(previousRootConfiguration, captureRootConfiguration())) rebuild(context);
    return failures;
  }

  /// Whether writing the pref stored under [key] requires a root rebuild. Keyed
  /// so agent control can ask for resource keys that have no [Pref].
  static bool needsRootRebuild(String key) => _effectsByKey[key]?.rebuildsRoot ?? false;

  static void rebuild(BuildContext context) {
    Navigator.of(context, rootNavigator: true).pushNamedAndRemoveUntil('/', (route) => false);
  }
}
