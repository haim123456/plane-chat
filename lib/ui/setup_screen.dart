import 'package:material_ui/material_ui.dart';

import '../core/chat_controller.dart';
import '../core/protocol.dart';
import '../platform/native.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.controller, this.editing = false});
  final ChatController controller;
  final bool editing;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.controller.settings['name'] as String? ?? '');
  late final TextEditingController _ip =
      TextEditingController(text: widget.controller.settings['hostIp'] as String? ?? kDefaultHostIp);
  late String _role = widget.controller.settings['role'] as String? ??
      (NativeBridge.canHost ? 'host' : 'client');

  Future<void> _save() async {
    final name = _name.text.trim();
    await widget.controller.updateSettings({
      'name': name.isEmpty ? (_role == 'host' ? 'אנדרואיד' : 'אייפון') : name,
      'role': _role,
      'hostIp': _ip.text.trim().isEmpty ? kDefaultHostIp : _ip.text.trim(),
    });
    if (widget.editing && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: widget.editing ? AppBar(title: const Text('הגדרות')) : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            if (!widget.editing) ...[
              Center(
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(28)),
                  child: Icon(Icons.flight_takeoff_rounded, size: 48, color: cs.onPrimary),
                ),
              ),
              const SizedBox(height: 20),
              Text("צ'אט טיסה", textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('הודעות, תמונות והקלטות בין שני טלפונים במטוס, בלי אינטרנט.',
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 32),
            ],
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'השם שלי (יוצג לצד השני)'),
            ),
            const SizedBox(height: 24),
            Text('התפקיד של הטלפון הזה', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (NativeBridge.canHost)
              _RoleCard(
                selected: _role == 'host',
                icon: Icons.wifi_tethering_rounded,
                title: 'יוצר את הרשת',
                subtitle: 'הטלפון הזה (אנדרואיד) פותח רשת Wi‑Fi קטנה, והטלפון השני מצטרף אליה.',
                onTap: () => setState(() => _role = 'host'),
              ),
            _RoleCard(
              selected: _role == 'client',
              icon: Icons.wifi_rounded,
              title: 'מצטרף לרשת',
              subtitle: 'קודם מתחברים בהגדרות ה־Wi‑Fi לרשת שהטלפון השני מציג, ואז פותחים את הצ׳אט.',
              onTap: () => setState(() => _role = 'client'),
            ),
            if (_role == 'client') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _ip,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'כתובת הטלפון המארח (בדרך כלל לא משנים)'),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _save,
              child: Text(widget.editing ? 'שמירה' : 'מתחילים', style: const TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.selected, required this.icon, required this.title,
      required this.subtitle, required this.onTap});
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? cs.primaryContainer : cs.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 2 : 1),
            ),
            child: Row(children: [
              Icon(icon, size: 32, color: selected ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(color: cs.onSurfaceVariant)),
                ]),
              ),
              if (selected) Icon(Icons.check_circle_rounded, color: cs.primary),
            ]),
          ),
        ),
      ),
    );
  }
}
