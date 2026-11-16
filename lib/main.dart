import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart' hide GlobalMaterialLocalizations;
import 'package:material_ui/material_ui.dart';
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
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent));
  runApp(PlaneChatApp(controller: controller));
}

class PlaneChatApp extends StatelessWidget {
  const PlaneChatApp({super.key, required this.controller});
  final ChatController controller;

  @override
  Widget build(BuildContext context) {
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
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.settings['role'] == null
            ? SetupScreen(controller: controller)
            : ChatScreen(controller: controller),
      ),
    );
  }
}
