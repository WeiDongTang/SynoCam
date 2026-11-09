import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..bootstrap(),
      child: const SynoCamApp(),
    ),
  );
}
