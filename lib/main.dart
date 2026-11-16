import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart' hide GlobalMaterialLocalizations;
import 'package:material_ui/material_ui.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'core/chat_controller.dart';
import 'core/store.dart';
import 'platform/native.dart';
import 'ui/chat_screen.dart';
import 'ui/setup_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NativeBridge.initShare();
  final dir = await getApplicationDocumentsDirectory();
  final controller = ChatController(ChatStore(dir));
  await controller.init();
  _wireBattery(controller);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent));
  runApp(PlaneChatApp(controller: controller));
}

/// Share our battery with the other phone, and switch to battery saver
/// (no typing indicator, rare status) at 20% or less when not charging.
void _wireBattery(ChatController c) {
  final battery = Battery();
  Future<DeviceStatus> read() async {
    try {
      final level = await battery.batteryLevel;
      final state = await battery.batteryState;
      final charging = state == BatteryState.charging || state == BatteryState.full;
      c.lowPower = level <= 20 && !charging;
      return DeviceStatus(battery: level, charging: charging);
    } catch (_) {
      return const DeviceStatus();
    }
  }

  c.statusProvider = read;
  try {
    battery.onBatteryStateChanged.listen((_) => c.sendStatus(force: true));
  } catch (_) {}
}

class PlaneChatApp extends StatelessWidget {
  const PlaneChatApp({super.key, required this.controller});
  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: controller, builder: (context, _) => _app());
  }

  Widget _app() {
    return MaterialApp(
      title: "צ'אט טיסה",
      debugShowCheckedModeBanner: false,
      locale: const Locale('he'),
      supportedLocales: const [Locale('he'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: switch (controller.settings['theme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: controller.settings['role'] == null
          ? SetupScreen(controller: controller)
          : ChatScreen(controller: controller),
    );
  }
}
