import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'chat_store.dart';

final class _Bubble {
  final bool user;
  String text;
  final List<String> images;

  _Bubble.user(this.text, this.images) : user = true;
  _Bubble.assistant() : user = false, text = '', images = const <String>[];
}

/// The multimodal chat surface: attach images straight from the local file
/// system and stream the model's answer.
///
/// When [restoreStatePath] is given the native KV state + history saved by
/// `EngineChat.saveState()` are loaded back, and on exit the chat saves
/// itself again (so it can be recovered from the home screen).
class ChatPage extends StatefulWidget {
  final LlamaEngine engine;
  final String title;

  /// Absolute path of the GGUF loaded into [engine] (for the save sidecar).
  final String? modelPath;

  /// Optional mmproj used by [engine].
  final String? mmprojPath;

  /// Save-file key (model basename without `.gguf`).
  final String? saveKey;

  /// `.sstate` file to restore this chat from, or null for a fresh chat.
  final String? restoreStatePath;

  const ChatPage({
    super.key,
    required this.engine,
    required this.title,
    this.modelPath,
    this.mmprojPath,
    this.saveKey,
    this.restoreStatePath,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  EngineChat? _chat;
  String? _chatError;
  final List<_Bubble> _bubbles = <_Bubble>[];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<String> _pendingImages = <String>[];
  bool _generating = false;

  /// Guards the auto-save-on-exit flow: pop is blocked while saving.
  bool _saving = false;

  bool get _visionOk => widget.engine.supportsVision;

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  Future<void> _initChat() async {
    try {
      final chat = await widget.engine.createChat();
      final restore = widget.restoreStatePath;
      if (restore != null && File(restore).existsSync()) {
        await chat.loadState(restore);
        // Rebuild bubbles from the restored history. The system prompt
        // already lives inside the saved state, so it is skipped here.
        for (final message in chat.messages) {
          switch (message.role) {
            case 'user':
              _bubbles.add(_Bubble.user(message.content, const <String>[]));
            case 'system':
              break;
            case _:
              _bubbles
                ..add(_Bubble.assistant())
                ..last.text = message.content;
          }
        }
      } else {
        chat.addSystem(
          'Eres un asistente útil y conciso. Cuando te den imágenes, '
          'describelas con precisión.',
        );
      }
      if (!mounted) return;
      setState(() => _chat = chat);
    } catch (e) {
      if (mounted) setState(() => _chatError = '$e');
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Pop is intercepted so the chat saves its state to disk first (native
  /// KV + token history + message list). With >1 messages in history there
  /// was an actual exchange worth persisting.
  Future<void> _saveAndExit() async {
    if (_saving) return;
    _saving = true;
    final chat = _chat;
    final key = widget.saveKey;
    try {
      if (chat != null &&
          key != null &&
          key.isNotEmpty &&
          chat.messageCount > 1) {
        await saveChatSession(
          chat,
          key: key,
          modelPath: widget.modelPath ?? '',
          mmprojPath: widget.mmprojPath,
          title: widget.title,
        );
      }
    } catch (e) {
      _toast('No se pudo guardar el chat: $e');
    } finally {
      _saving = false;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _attachImage() async {
    if (_generating) return;
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Imágenes',
          // ignore: unnecessary_const
          extensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
        ),
      ],
    );
    if (file == null) return;
    if (!File(file.path).existsSync()) {
      _toast('Imagen no encontrada: ${file.path}');
      return;
    }
    setState(() => _pendingImages.add(file.path));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    final chat = _chat;
    if (_generating || chat == null) return;
    final prompt = _input.text.trim();
    final images = List<String>.of(_pendingImages);
    if (prompt.isEmpty && images.isEmpty) return;
    if (images.isNotEmpty && !_visionOk) {
      _toast('Este modelo se inició sin mmproj: no puede ver imágenes.');
      return;
    }

    final text = prompt.isEmpty && images.isNotEmpty
        ? 'Describe esta imagen.'
        : prompt;

    _input.clear();
    setState(() {
      _pendingImages.clear();
      _bubbles
        ..add(_Bubble.user(text, images))
        ..add(_Bubble.assistant());
      _generating = true;
    });
    _scrollToEnd();

    final assistantBubble = _bubbles.last;
    try {
      chat.addUser(
        text,
        media: [for (final path in images) LlamaMedia.imageFile(path)],
      );
      final stream = chat.generate(
        sampler: const SamplerParams(temperature: 0.7, topP: 0.9),
        maxTokens: 768,
      );
      await for (final event in stream) {
        switch (event) {
          case TokenEvent():
            setState(() => assistantBubble.text += event.text);
            _scrollToEnd();
          case DoneEvent():
            setState(() {
              if (event.trailingText.isNotEmpty) {
                assistantBubble.text += event.trailingText;
              }
            });
          case ShiftEvent():
            break;
        }
      }
    } catch (e) {
      if (assistantBubble.text.isEmpty) {
        setState(() => assistantBubble.text = '⚠ Error: $e');
      } else {
        _toast('Error generando: $e');
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_saveAndExit());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          actions: [
            Tooltip(
              message: _visionOk
                  ? 'Visión disponible (mmproj cargado)'
                  : 'Sin mmproj: solo texto',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  _visionOk ? Icons.image : Icons.image_not_supported,
                  color: _visionOk ? null : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        ),
        body: _chatError != null
            ? Center(child: Text('Error preparando el chat: $_chatError'))
            : Column(
                children: [
                  Expanded(
                    child: _chat == null
                        ? const Center(child: CircularProgressIndicator())
                        : _bubbleList(),
                  ),
                  _composer(),
                ],
              ),
      ),
    );
  }

  Widget _bubbleList() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: _bubbles.length,
      itemBuilder: (context, index) {
        final bubble = _bubbles[index];
        return _chatBubble(bubble, isLast: index == _bubbles.length - 1);
      },
    );
  }

  Widget _chatBubble(_Bubble bubble, {required bool isLast}) {
    final theme = Theme.of(context);
    final isUser = bubble.user;
    final waiting = !isUser && bubble.text.isEmpty && isLast && _generating;
    final maxWidth = min(640.0, MediaQuery.of(context).size.width * 0.78);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: maxWidth),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final image in bubble.images)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(image),
                    width: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Text('(no se pudo mostrar la imagen)'),
                  ),
                ),
              ),
            if (waiting)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else if (bubble.text.isNotEmpty)
              SelectableText(bubble.text),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingImages.isNotEmpty) ...[
              SizedBox(
                height: 88,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final image in _pendingImages)
                      _pendingImageChip(image),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
            TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: _visionOk
                    ? 'Escribe algo, o adjunta una imagen…'
                    : 'Escribe algo…',
                border: const OutlineInputBorder(),
                prefixIcon: IconButton(
                  tooltip: _visionOk
                      ? 'Adjuntar imagen desde tu PC'
                      : 'Este modelo no soporta imágenes',
                  icon: const Icon(Icons.photo_library_outlined),
                  onPressed: _visionOk && !_generating ? _attachImage : null,
                ),
                suffixIcon: IconButton(
                  tooltip: 'Enviar',
                  icon: const Icon(Icons.send),
                  onPressed: _generating ? null : _send,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingImageChip(String image) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(image), height: 80, fit: BoxFit.cover),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: InkWell(
              onTap: () => setState(() => _pendingImages.remove(image)),
              child: const CircleAvatar(
                radius: 11,
                backgroundColor: Colors.black54,
                child: Icon(Icons.close, size: 13, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
