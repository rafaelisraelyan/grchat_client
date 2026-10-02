import 'package:flutter/material.dart';
import 'package:riverpod/riverpod.dart';

import '../auth/auth_repository.dart';
import '../transport/grchat_connection.dart';

final connectionProvider = Provider<GrchatConnection>((ref) {
  final c = GrchatConnection();
  ref.onDispose(c.dispose);
  return c;
});

final authRepositoryProvider = Provider<AuthRepository>(
    (ref) => AuthRepository(ref.watch(connectionProvider)));

class SessionState extends Notifier<Session?> {
  @override
  Session? build() => null;

  void set(Session? s) => state = s;
}

final sessionProvider =
    NotifierProvider<SessionState, Session?>(SessionState.new);

class ThemeModeState extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;

  void toggle() =>
      state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
}

final themeModeProvider =
    NotifierProvider<ThemeModeState, ThemeMode>(ThemeModeState.new);
