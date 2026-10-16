import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/key_event_utils.dart';

/// Give Android system Back the same action as the screen's Escape handler.
/// Dialog routes remain above this scope and receive Back first.
class TedBackScope extends StatelessWidget {
  final Widget child;
  final VoidCallback onBack;
  const TedBackScope({super.key, required this.child, required this.onBack});

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (didPop || ModalRoute.of(context)?.isCurrent != true) return;
      if (BackKeyCoordinator.consumeIfHandled()) return;
      if (MediaQuery.viewInsetsOf(context).bottom > 0) {
        FocusManager.instance.primaryFocus?.unfocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        return;
      }
      onBack();
    },
    child: child,
  );
}
