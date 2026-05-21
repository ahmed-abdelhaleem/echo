// Entry point for the Echo client.
//
// Keep this file thin: anything testable lives in `app/`, `features/`,
// or `services/`. `main()` is the only thing the Dart VM calls directly,
// so it stays a single statement plus the ProviderScope.

import 'package:echo_client/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: EchoApp()));
}
