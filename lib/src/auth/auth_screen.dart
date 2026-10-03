import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../widgets/code_input.dart';
import 'auth_repository.dart';

enum _Mode { login, register, code, reset }

const _errText = <String, String>{
  'BAD_CREDENTIALS': 'Неверный логин или пароль',
  'EMAIL_NOT_VERIFIED': 'Почта не подтверждена — введи код из письма',
  'NICK_TAKEN': 'Такой ник уже занят',
  'EMAIL_TAKEN': 'Такая почта уже зарегистрирована',
  'BAD_NICK': 'Ник: 3–24 символа (латиница, цифры, _ .)',
  'BAD_EMAIL': 'Проверь почту',
  'WEAK_PASSWORD': 'Пароль короче 8 символов',
  'BAD_CODE': 'Неверный код',
  'CODE_EXPIRED': 'Код протух — запроси новый',
  'RESEND_COOLDOWN': 'Подожди минуту перед повторной отправкой',
  'RATE_LIMITED': 'Слишком часто, подожди немного',
};

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  _Mode _mode = _Mode.login;
  // Server address lives here for now; a settings screen comes later.
  static const _host = '127.0.0.1';
  static const _port = 8181;
  final _login = TextEditingController();
  final _nick = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;
  DateTime? _resendAt;

  @override
  void dispose() {
    _login.dispose();
    _nick.dispose();
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final conn = ref.read(connectionProvider);
    if (!conn.isOpen) {
      await conn.connect(_host, _port);
    }
  }

  void _startCooldown() {
    _resendAt = DateTime.now().add(const Duration(seconds: 60));
  }

  Future<void> _run(Future<void> Function(AuthRepository) action) async {    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _connect();
      await action(ref.read(authRepositoryProvider));
    } on GrchatException catch (e) {
      setState(() => _error = _errText[e.code] ?? 'Ошибка: ${e.code}');
    } catch (e) {
      setState(() => _error = 'Нет соединения: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session != null) {
      return Scaffold(
        body: Center(child: Text('Привет, ${session.nick}! Чат — следующим шагом.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.brightness_6),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Center(child: _Logo()),
              const SizedBox(height: 12),
              Text(_title(),
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ..._modeFields(),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '...' : _submitLabel()),
              ),
              const SizedBox(height: 8),
              ..._switchLinks(),
            ],
          ),
        ),
      ),
    );
  }

  String _title() => switch (_mode) {
        _Mode.login => 'С возвращением',
        _Mode.register => 'Создать аккаунт',
        _Mode.code => 'Код из письма',
        _Mode.reset => 'Новый пароль',
      };

  String _submitLabel() => switch (_mode) {
        _Mode.login => 'Войти',
        _Mode.register => 'Зарегистрироваться',
        _Mode.code => 'Подтвердить',
        _Mode.reset => 'Сбросить пароль',
      };

  List<Widget> _modeFields() => switch (_mode) {
        _Mode.login => [
            _field(_login, 'ник или почта'),
            const SizedBox(height: 8),
            _field(_password, 'пароль', secret: true),
          ],
        _Mode.register => [
            _field(_nick, 'ник'),
            const SizedBox(height: 8),
            _field(_email, 'почта', keyboard: TextInputType.emailAddress),
            const SizedBox(height: 8),
            _field(_password, 'пароль (мин. 8)', secret: true),
          ],
        _Mode.code => [
            if (_email.text.trim().isEmpty)
              _field(_email, 'почта',
                  keyboard: TextInputType.emailAddress)
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                    'Код отправлен на ${_email.text.trim()}\nСрок действия — 20 минут',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ),
            CodeInput(
              key: ValueKey(_email.text.trim()),
              onCompleted: (v) {
                _code.text = v;
                _submit();
              },
            ),
          ],
        _Mode.reset => [
            _field(_email, 'почта', keyboard: TextInputType.emailAddress),
            const SizedBox(height: 8),
            _field(_code, 'код из письма', keyboard: TextInputType.number),
            const SizedBox(height: 8),
            _field(_password, 'новый пароль', secret: true),
          ],
      };

  List<Widget> _switchLinks() {
    TextButton link(String t, _Mode m, {bool resend = false}) => TextButton(
        onPressed: () {
          if (resend) {
            _run((r) => r.resendCode(email: _email.text.trim()));
            setState(() => _resendAt =
                DateTime.now().add(const Duration(seconds: 60)));
          } else {
            if (m == _Mode.code) _startCooldown();
            setState(() => _mode = m);
          }
        },
        child: Text(t));
    if (_mode == _Mode.code) {
      final left = _resendAt == null
          ? 0
          : _resendAt!.difference(DateTime.now()).inSeconds;
      return [
        if (left > 0)
          _CountdownText(
              seconds: left,
              onTick: () {
                if (mounted) setState(() {});
              })
        else
          link('Отправить код ещё раз', _Mode.code, resend: true),
        link('Не та почта? Назад к регистрации', _Mode.register),
        link('Назад ко входу', _Mode.login),
      ];
    }
    return switch (_mode) {
      _Mode.login => [
          link('Нет аккаунта? Зарегистрироваться', _Mode.register),
          link('Забыл пароль', _Mode.reset),
          link('Есть код из письма', _Mode.code),
        ],
      _Mode.register => [
          link('Уже есть аккаунт? Войти', _Mode.login),
          link('Есть код из письма', _Mode.code),
        ],
      _Mode.code => [
          link('Отправить код ещё раз', _Mode.code, resend: true),
          link('Не та почта? Назад к регистрации', _Mode.register),
          link('Назад ко входу', _Mode.login),
        ],
      _Mode.reset => [
          link('Назад ко входу', _Mode.login),
        ],
    };
  }

  void _submit() {
    switch (_mode) {
      case _Mode.login:
        _run((r) async {
          final s = await r.login(
              login: _login.text.trim(), password: _password.text);
          ref.read(sessionProvider.notifier).set(s);
        });
      case _Mode.register:
        _run((r) async {
          final needVerify = await r.register(
              nick: _nick.text.trim(),
              email: _email.text.trim(),
              password: _password.text);
          if (!mounted) return;
          if (needVerify) {
            _email.text = _email.text.trim();
            _startCooldown();
            setState(() => _mode = _Mode.code);
          }
        });
      case _Mode.code:
        _run((r) async {
          await r.verifyEmail(
              email: _email.text.trim(), code: _code.text.trim());
          if (mounted) setState(() => _mode = _Mode.login);
        });
      case _Mode.reset:
        _run((r) async {
          if (_password.text.isEmpty) {
            await r.forgot(email: _email.text.trim());
            if (mounted) {
              setState(() =>
                  _error = 'Код отправлен — введи его и новый пароль');
            }
          } else {
            await r.reset(
                email: _email.text.trim(),
                code: _code.text.trim(),
                newPassword: _password.text);
            if (mounted) setState(() => _mode = _Mode.login);
          }
        });
    }
  }

  Widget _field(TextEditingController c, String hint,
      {bool secret = false, TextInputType keyboard = TextInputType.text}) {
    return TextField(
      controller: c,
      obscureText: secret,
      keyboardType: keyboard,
      decoration: InputDecoration(
          hintText: hint,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
      onSubmitted: (_) {
        if (!_busy) _submit();
      },
    );
  }
}

class _CountdownText extends StatefulWidget {
  const _CountdownText({required this.seconds, required this.onTick});

  final int seconds;
  final VoidCallback onTick;

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) widget.onTick();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.seconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text('Повторить отправку через 0:${s.toString().padLeft(2, '0')}',
          style: const TextStyle(color: Colors.grey)),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
            colors: [Color(0xFF574CC9), Color(0xFF8AB4FF)]),
      ),
      alignment: Alignment.center,
      child: const Text('G',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
    );
  }
}
