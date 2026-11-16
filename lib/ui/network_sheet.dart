import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/native.dart';

/// Big, easy-to-copy network name and password for the iPhone user.
class NetworkCard extends StatelessWidget {
  const NetworkCard({super.key, required this.info, this.compact = false});
  final GroupInfo info;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget field(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: cs.onPrimaryContainer.withValues(alpha: 0.8), fontSize: 15)),
            const SizedBox(height: 4),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label הועתק')));
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12)),
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(
                    value,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 24 : 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.wifi_tethering_rounded, color: cs.onPrimaryContainer),
          const SizedBox(width: 8),
          Text('הרשת פתוחה', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onPrimaryContainer)),
        ]),
        const SizedBox(height: 6),
        Text('באייפון: הגדרות, Wi‑Fi, בוחרים את הרשת הזאת ומקלידים את הסיסמה. אחר כך פותחים את צ\'אט טיסה.',
            style: TextStyle(color: cs.onPrimaryContainer)),
        field('שם הרשת', info.ssid),
        field('סיסמה', info.passphrase),
      ]),
    );
  }
}

Future<void> showNetworkSheet(BuildContext context, GroupInfo info) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: NetworkCard(info: info),
      ),
    ),
  );
}
