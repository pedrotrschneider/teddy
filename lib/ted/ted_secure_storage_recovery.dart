import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A single recovery action instead of an unusable sign-in/profile form.
class TedSecureStorageRecovery extends StatelessWidget {
  final bool busy;
  final VoidCallback onRetry;
  const TedSecureStorageRecovery({super.key, required this.busy, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 40),
                const SizedBox(height: 16),
                Text(
                  mac ? 'Keychain access needed' : 'Secure storage access needed',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  mac
                      ? 'Teddy could not access your saved sign-ins. Retry to request Keychain access again, then allow access in the macOS prompt.'
                      : 'Teddy could not access your saved sign-ins. Unlock your system keyring, then retry secure storage access.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text('Your saved profiles and downloads are kept.', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: ValueKey(busy),
                  autofocus: true,
                  onPressed: busy ? null : onRetry,
                  icon: busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock_open),
                  label: Text(
                    busy
                        ? 'Waiting for secure storage…'
                        : mac
                        ? 'Retry Keychain access'
                        : 'Retry secure storage',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  busy
                      ? 'Respond to any open system permission prompt to continue.'
                      : mac
                      ? 'If macOS still denies access without a prompt, unlock your login keychain in Keychain Access, check access for Teddy, then retry.'
                      : 'If access remains unavailable, check your system keyring and try again.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
