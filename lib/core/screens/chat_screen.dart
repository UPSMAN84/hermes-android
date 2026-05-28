import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:uuid/uuid.dart';
import '../services/connection_manager.dart';

class ChatScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  const ChatScreen({
    required this.connection,
    required this.session,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ApiClient _client;
  late final GatewayChatClient _chat;
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  List<_ChatMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;
  String _streamingText = '';

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
    );
    _chat = GatewayChatClient(_client);
    _fetchMessages();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _fetchMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final messages = await _client.getMessages(widget.session.id);
      if (!mounted) return;
      setState(() {
        _messages = messages.map((m) {
          return _ChatMessage(
            id: (m['id'] ?? const Uuid().v4()).toString(),
            role: (m['role'] as String?) ?? 'assistant',
            content: (m['content'] as String?) ?? '',
          );
        }).toList();
        _loading = false;
      });
    } catch (e) {
      if (e.toString().contains('HTTP 404')) {
        setState(() {
          _messages = [];
          _loading = false;
        });
      } else if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _sendMessage() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    final userMsg = _ChatMessage(
      id: 'user-${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: text,
    );

    setState(() {
      _messages.add(userMsg);
      _sending = true;
      _streamingText = '';
    });
    _inputCtrl.clear();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    final history = _messages
        .where((m) => !m.isStreaming)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    _chat.sendMessageStreaming(
      message: text,
      sessionId: widget.session.id,
      history: history,
      onToken: (token) {
        if (!mounted) return;
        setState(() {
          _streamingText += token;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _sending = false;
          if (_streamingText.isNotEmpty) {
            _messages.add(_ChatMessage(
              id: 'assistant-${DateTime.now().millisecondsSinceEpoch}',
              role: 'assistant',
              content: _streamingText,
            ));
          }
          _streamingText = '';
        });
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _sending = false;
          final errorMsg = _ChatMessage(
            id: 'error-${DateTime.now().millisecondsSinceEpoch}',
            role: 'error',
            content: error,
          );
          _messages.add(errorMsg);
          _streamingText = '';
        });
      },
    );
  }

  Widget _buildStreamingBubble() {
    if (_streamingText.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MarkdownBody(
              data: _streamingText.isEmpty ? '\u2026' : _streamingText,
              styleSheet: _markdownStyle(context),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNewSession = widget.session.messageCount == 0 ||
        widget.session.id.startsWith('mob-');

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isNewSession ? 'New Chat' : widget.session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchMessages,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text('Failed to load messages',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _fetchMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_messages.isEmpty && !_sending) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              'Start a conversation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Type a message below to begin',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _messages.length + (_streamingText.isNotEmpty ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length && _streamingText.isNotEmpty) {
          return _buildStreamingBubble();
        }

        final msg = _messages[index];
        if (msg.role == 'error') {
          return _buildErrorBubble(msg);
        }

        final isUser = msg.role == 'user';
        return _MessageBubble(content: msg.content, isUser: isUser);
      },
    );
  }

  Widget _buildErrorBubble(_ChatMessage msg) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg.content,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
        ),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              focusNode: _inputFocus,
              enabled: !_sending,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
              decoration: InputDecoration(
                hintText: _sending ? 'Waiting for response\u2026' : 'Type a message\u2026',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            height: 44,
            child: FloatingActionButton.small(
              onPressed: _sending ? null : _sendMessage,
              child: _sending
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send, size: 20, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatMessage {
  final String id;
  final String role;
  final String content;

  const _ChatMessage({
    required this.id,
    required this.role,
    required this.content,
  });

  bool get isStreaming => false;
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;

  const _MessageBubble({required this.content, required this.isUser});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isUser) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - 80,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(18),
          ),
          child: MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
              code: TextStyle(
                backgroundColor: Colors.white.withValues(alpha: 0.15),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MarkdownBody(
        data: content,
        styleSheet: _markdownStyle(context),
      ),
    );
  }
}

MarkdownStyleSheet _markdownStyle(BuildContext context) {
  final theme = Theme.of(context);
  return MarkdownStyleSheet(
    p: theme.textTheme.bodyMedium,
    h1: theme.textTheme.headlineSmall,
    h2: theme.textTheme.titleLarge,
    h3: theme.textTheme.titleMedium,
    code: TextStyle(
      backgroundColor: Colors.white.withValues(alpha: 0.1),
      fontFamily: 'monospace',
      fontSize: 13,
    ),
    blockquote: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: theme.colorScheme.primary, width: 3),
      ),
    ),
    a: TextStyle(color: theme.colorScheme.primary),
    em: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
    strong: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
  );
}
