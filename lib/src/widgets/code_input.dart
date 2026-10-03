import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Six-box code input: auto-advance, backspace back, full-code paste.
class CodeInput extends StatefulWidget {
  const CodeInput({super.key, required this.onCompleted});

  final ValueChanged<String> onCompleted;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  final _nodes = List.generate(6, (_) => FocusNode());
  final _ctrs =
      List.generate(6, (_) => TextEditingController());

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    for (final c in _ctrs) {
      c.dispose();
    }
    super.dispose();
  }

  String get _code => _ctrs.map((c) => c.text).join();

  void _fill(String text, int from) {
    final digits = text.replaceAll(RegExp(r'\D'), '');
    var i = from;
    for (final ch in digits.split('')) {
      if (i >= 6) break;
      _ctrs[i].text = ch;
      i++;
    }
    if (_code.length == 6) {
      _nodes[5].unfocus();
      widget.onCompleted(_code);
    } else if (i < 6) {
      _nodes[i].requestFocus();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 6; i++)
          Container(
            width: 44,
            height: 52,
            margin: EdgeInsets.only(left: i == 0 ? 0 : 8),
            child: TextField(
              controller: _ctrs[i],
              focusNode: _nodes[i],
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                  counterText: '',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.zero),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              onChanged: (v) {
                if (v.length > 1) {
                  _fill(v, i);
                  return;
                }
                if (v.isNotEmpty) {
                  if (i < 5) {
                    _nodes[i + 1].requestFocus();
                  } else {
                    _nodes[i].unfocus();
                  }
                  if (_code.length == 6) widget.onCompleted(_code);
                  setState(() {});
                } else if (i > 0) {
                  _nodes[i - 1].requestFocus();
                }
              },
            ),
          ),
      ],
    );
  }
}
