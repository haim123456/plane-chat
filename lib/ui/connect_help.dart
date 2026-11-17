// Hebrew connection help: the two host modes, hotspot instructions, and the
// honest self-check banner shown on both phones until they connect.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/native.dart';
import 'network_sheet.dart';

const String kModeHotspot = 'hotspot';
const String kModeDirect = 'direct';

/// Result of the periodic self-check.
class NetCheck {
  const NetCheck(this.ok, this.text, {this.suggestHotspot = false});
  final bool ok;
  final String text;
  final bool suggestHotspot;
}

class ModeChoice extends StatelessWidget {
  const ModeChoice({super.key, required this.mode, required this.onChanged});
  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget tile(String v, IconData icon, String title, String sub) {
      final sel = mode == v;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: sel ? cs.primaryContainer : cs.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onChanged(v),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: sel ? cs.primary : cs.outlineVariant, width: sel ? 2 : 1),
              ),
              child: Row(children: [
                Icon(icon, color: sel ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sub, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13.5)),
                  ]),
                ),
                if (sel) Icon(Icons.check_circle_rounded, color: cs.primary),
              ]),
            ),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      tile(kModeHotspot, Icons.wifi_tethering_rounded, 'נקודה חמה (מומלץ)',
          'מדליקים את הנקודה החמה הרגילה של הטלפון הזה, האייפון מצטרף אליה, והאפליקציות מוצאות זו את זו לבד. עובד גם בלי אינטרנט. אפשר גם ששני הטלפונים יהיו באותה רשת Wi‑Fi.'),
      tile(kModeDirect, Icons.settings_input_antenna_rounded, 'רשת ישירה (Wi‑Fi Direct)',
          'האפליקציה פותחת רשת בעצמה. יש אייפונים שלא רואים רשת כזאת, ולכן זו רק אפשרות גיבוי.'),
    ]);
  }
}

/// Step-by-step hotspot instructions for the host (Android) phone.
class HotspotCard extends StatelessWidget {
  const HotspotCard({super.key, this.check, this.live});
  final NetCheck? check;

  /// When given, the status line follows the periodic self-check.
  final ValueListenable<NetCheck?>? live;

  @override
  Widget build(BuildContext context) {
    if (live != null) {
      return ValueListenableBuilder<NetCheck?>(
        valueListenable: live!,
        builder: (_, v, __) => HotspotCard(check: v ?? check),
      );
    }
    final cs = Theme.of(context).colorScheme;
    Widget step(String n, String t) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 12, backgroundColor: cs.primary,
                child: Text(n, style: TextStyle(color: cs.onPrimary, fontSize: 13, fontWeight: FontWeight.w700))),
            const SizedBox(width: 10),
            Expanded(child: Text(t, style: TextStyle(color: cs.onPrimaryContainer, fontSize: 15))),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.wifi_tethering_rounded, color: cs.onPrimaryContainer),
          const SizedBox(width: 8),
          Text('חיבור דרך נקודה חמה', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onPrimaryContainer)),
        ]),
        const SizedBox(height: 8),
        step('1', 'אם צריך מצב טיסה, מדליקים אותו קודם. אחר כך מדליקים את הנקודה החמה. אם מדליקים מצב טיסה אחרי הנקודה החמה, היא נכבית.'),
        step('2', 'בטלפון הזה: הגדרות ← רשת ואינטרנט ← נקודה חמה ושיתוף אינטרנט ← נקודה חמה של Wi‑Fi. מדליקים. (הכפתור למטה פותח את המסך.)'),
        step('3', 'שם וסיסמה: בוחרים סיסמה פשוטה (למשל 8 ספרות). הנקודה החמה עובדת גם בלי אינטרנט. כדאי לכבות ב"מתקדם" את "כיבוי אוטומטי של הנקודה החמה", ואם "חוסך הנתונים" דלוק, לכבות גם אותו. בהגדרות הנקודה החמה יש גם קוד QR שהמצלמה של האייפון יודעת לסרוק.'),
        step('4', 'באייפון: הגדרות ← Wi‑Fi ← בוחרים את הנקודה החמה, מקלידים את הסיסמה, ופותחים את צ\'אט טיסה. אם האייפון שואל על "רשת מקומית", מאשרים.'),
        step('5', 'זהו. האפליקציות מוצאות זו את זו לבד, בלי להקליד כתובות.'),
        const SizedBox(height: 10),
        if (check != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12)),
            child: Text(check!.text, style: TextStyle(color: check!.ok ? const Color(0xFF15803D) : cs.error)),
          ),
        if (Platform.isAndroid) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: NativeBridge.openHotspotSettings,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('פתיחת הגדרות הנקודה החמה'),
          ),
        ],
      ]),
    );
  }
}

Future<void> showHostHelp(BuildContext context,
    {required String mode, GroupInfo? group, NetCheck? check, ValueListenable<NetCheck?>? live}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: mode == kModeDirect && group != null
            ? NetworkCard(info: group)
            : HotspotCard(check: check, live: live),
      ),
    ),
  );
}

/// Thin status strip under the app bar while not connected.
class NetCheckBanner extends StatelessWidget {
  const NetCheckBanner({super.key, required this.check, this.onHelp, this.onRetry, this.onUseHotspot});
  final NetCheck check;
  final VoidCallback? onHelp;
  final VoidCallback? onRetry;
  final VoidCallback? onUseHotspot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = check.ok ? cs.secondaryContainer : cs.errorContainer;
    final fg = check.ok ? cs.onSecondaryContainer : cs.onErrorContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(check.ok ? Icons.check_circle_outline_rounded : Icons.warning_amber_rounded, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(check.text, style: TextStyle(color: fg))),
        ]),
        Wrap(spacing: 4, children: [
          if (onHelp != null) TextButton(onPressed: onHelp, child: const Text('איך מתחברים')),
          if (onUseHotspot != null && check.suggestHotspot)
            TextButton(onPressed: onUseHotspot, child: const Text('מעבר לנקודה חמה')),
          if (onRetry != null && !check.ok) TextButton(onPressed: onRetry, child: const Text('לנסות שוב')),
        ]),
      ]),
    );
  }
}
