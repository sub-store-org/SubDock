import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:subdock/app/embedded_webview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: _ProbePage());
  }
}

class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  late final EmbeddedWebViewController _controller;
  HttpServer? _server;
  var _pageLoaded = false;
  var _bridgeInstalled = false;
  var _navigationIntercepted = false;
  var _downloadRequested = false;
  var _blobReceived = false;
  var _keyboardInputReceived = false;
  var _imeCompositionReceived = false;
  var _backspaceReceived = false;
  var _deleteReceived = false;
  var _commandSelectAllReceived = false;
  var _commandCopyReceived = false;
  var _commandPasteReceived = false;
  var _automatedPassReported = false;
  var _completePassReported = false;
  var _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = EmbeddedWebViewController.create(
      onNavigationRequest: _onNavigationRequest,
      onBlobMessage: _onMessage,
      bridgeScript: _bridgeScript,
    );
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  Future<EmbeddedNavigationDecision> _onNavigationRequest(
    EmbeddedNavigationRequest request,
  ) async {
    if (request.uri.path == '/intercept') {
      _set(() => _navigationIntercepted = true);
      _completeIfReady();
      return EmbeddedNavigationDecision.prevent;
    }
    return EmbeddedNavigationDecision.navigate;
  }

  void _onMessage(String message) {
    switch (message) {
      case 'loaded':
        _set(() => _pageLoaded = true);
        _completeIfReady();
      case 'bridge-installed':
        _set(() => _bridgeInstalled = true);
        _completeIfReady();
      case 'blob:probe-blob':
        _set(() => _blobReceived = true);
        _completeIfReady();
      case 'keyboard-input':
        _set(() => _keyboardInputReceived = true);
        _completeIfReady();
      case 'ime-composition':
        _set(() => _imeCompositionReceived = true);
        _completeIfReady();
      case 'key-backspace':
        _set(() => _backspaceReceived = true);
        _completeIfReady();
      case 'key-delete':
        _set(() => _deleteReceived = true);
        _completeIfReady();
      case 'command-select-all':
        _set(() => _commandSelectAllReceived = true);
        _completeIfReady();
      case 'command-copy':
        _set(() => _commandCopyReceived = true);
        _completeIfReady();
      case 'command-paste':
        _set(() => _commandPasteReceived = true);
        _completeIfReady();
    }
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      unawaited(_serve(server));
      _set(() => _started = true);
      await _controller.loadRequest(
        Uri.parse('http://${server.address.address}:${server.port}/'),
      );
    } catch (error) {
      _set(() => _error = '$error');
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      if (request.uri.path == '/download') {
        _set(() => _downloadRequested = true);
        _completeIfReady();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..headers.set(
            'content-disposition',
            'attachment; filename="probe.txt"',
          )
          ..write('probe-download');
      } else {
        request.response
          ..headers.contentType = ContentType.html
          ..write(_page);
      }
      await request.response.close();
    }
  }

  void _completeIfReady() {
    final automatedReady =
        _pageLoaded &&
        _bridgeInstalled &&
        _navigationIntercepted &&
        _downloadRequested &&
        _blobReceived;
    if (automatedReady && !_automatedPassReported) {
      _automatedPassReported = true;
      debugPrint(
        'WEBVIEW_PROBE_AUTOMATED_PASS: '
        'page, bridge, navigation, HTTP download, Blob channel',
      );
    }
    if (automatedReady &&
        _keyboardInputReceived &&
        _imeCompositionReceived &&
        _backspaceReceived &&
        _deleteReceived &&
        _commandSelectAllReceived &&
        _commandCopyReceived &&
        _commandPasteReceived &&
        !_completePassReported) {
      _completePassReported = true;
      debugPrint(
        'WEBVIEW_PROBE_PASS: '
        'page, bridge, navigation, HTTP download, Blob channel, '
        'keyboard input, Backspace, Delete, Cmd+A, Cmd+C, Cmd+V, '
        'IME composition',
      );
    }
  }

  void _set(void Function() update) {
    if (!mounted) return;
    setState(update);
  }

  static const _bridgeScript = '''
SubDockBlob.postMessage('bridge-installed');
''';

  static const _page = '''<!doctype html>
<html><body>
  <p>
    Type normal text, use Backspace, then place the caret before a character
    and use forward Delete (Fn+Delete where required). Select all with Cmd+A,
    copy with Cmd+C, paste with Cmd+V, then commit text with an IME.
  </p>
  <input id="keyboard" placeholder="Keyboard / IME probe">
  <button id="intercept" onclick="location.href='/intercept'">intercept</button>
  <a id="download" href="/download" download="probe.txt">download</a>
  <button id="blob" onclick="const reader = new FileReader(); reader.onload = () => SubDockBlob.postMessage('blob:' + reader.result); reader.readAsText(new Blob(['probe-blob']))">blob</button>
  <script>
    const keyboard = document.getElementById('keyboard');
    let plainKeyPending = false;
    let backspacePending = false;
    let deletePending = false;
    let selectAllPending = false;
    let copyPending = false;
    let pastePending = false;

    keyboard.addEventListener('keydown', (event) => {
      const key = event.key.toLowerCase();

      if (
        event.key.length === 1 &&
        !event.metaKey &&
        !event.ctrlKey &&
        !event.altKey
      ) {
        plainKeyPending = true;
      }

      if (event.key === 'Backspace') {
        backspacePending = true;
      } else if (event.key === 'Delete') {
        deletePending = true;
      }
      if (!event.metaKey) return;
      switch (key) {
        case 'a':
          selectAllPending = true;
          break;
        case 'c':
          copyPending = true;
          break;
        case 'v':
          pastePending = true;
          break;
      }
    });

    keyboard.addEventListener('input', (event) => {
      switch (event.inputType) {
        case 'insertText':
          if (plainKeyPending) {
            plainKeyPending = false;
            SubDockBlob.postMessage('keyboard-input');
          }
          break;
        case 'deleteContentBackward':
          if (backspacePending) {
            backspacePending = false;
            SubDockBlob.postMessage('key-backspace');
          }
          break;
        case 'deleteContentForward':
          if (deletePending) {
            deletePending = false;
            SubDockBlob.postMessage('key-delete');
          }
          break;
        case 'insertFromPaste':
          if (pastePending) {
            pastePending = false;
            SubDockBlob.postMessage('command-paste');
          }
          break;
      }
    });

    keyboard.addEventListener('select', () => {
      if (
        selectAllPending &&
        keyboard.value.length > 0 &&
        keyboard.selectionStart === 0 &&
        keyboard.selectionEnd === keyboard.value.length
      ) {
        selectAllPending = false;
        SubDockBlob.postMessage('command-select-all');
      }
    });

    keyboard.addEventListener('copy', () => {
      if (
        copyPending &&
        keyboard.selectionStart !== keyboard.selectionEnd
      ) {
        copyPending = false;
        SubDockBlob.postMessage('command-copy');
      }
    });

    keyboard.addEventListener('compositionend', (event) => {
      if (event.data && event.data.length > 0) {
        SubDockBlob.postMessage('ime-composition');
      }
    });

    keyboard.addEventListener('keyup', (event) => {
      const key = event.key.toLowerCase();
      if (
        event.key.length === 1 &&
        !event.metaKey &&
        !event.ctrlKey &&
        !event.altKey
      ) {
        plainKeyPending = false;
      }
      if (event.key === 'Backspace') backspacePending = false;
      if (event.key === 'Delete') deletePending = false;
      if (!event.metaKey) return;
      if (key === 'a') selectAllPending = false;
      if (key === 'c') copyPending = false;
      if (key === 'v') pastePending = false;
    });
    window.addEventListener('load', () => {
      SubDockBlob.postMessage('loaded');
      setTimeout(() => document.getElementById('intercept').click(), 50);
      setTimeout(() => document.getElementById('download').click(), 150);
      setTimeout(() => document.getElementById('blob').click(), 250);
    });
  </script>
</body></html>''';

  @override
  Widget build(BuildContext context) {
    final checks = <String, bool>{
      'Merged page loaded': _pageLoaded,
      'Production bridge injected': _bridgeInstalled,
      'Navigation intercepted': _navigationIntercepted,
      'HTTP download requested': _downloadRequested,
      'Blob channel received': _blobReceived,
      'Keyboard input delivered (manual)': _keyboardInputReceived,
      'IME composition committed (manual)': _imeCompositionReceived,
      'Backspace edited text (manual)': _backspaceReceived,
      'Delete edited text (manual)': _deleteReceived,
      'Cmd+A selected all (manual)': _commandSelectAllReceived,
      'Cmd+C copied selection (manual)': _commandCopyReceived,
      'Cmd+V pasted text (manual)': _commandPasteReceived,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Embedded WebView probe')),
      body: Column(
        children: [
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
          for (final check in checks.entries)
            ListTile(
              leading: Icon(check.value ? Icons.check_circle : Icons.pending),
              title: Text(check.key),
            ),
          if (!_started) const LinearProgressIndicator(),
          Expanded(child: _controller.build()),
        ],
      ),
    );
  }
}
