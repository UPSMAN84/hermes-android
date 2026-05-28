import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/services/connection_manager.dart';
import 'core/screens/session_list_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final connManager = ConnectionManager(prefs);
  runApp(HermesApp(connManager: connManager));
}

class HermesApp extends StatelessWidget {
  final ConnectionManager connManager;
  const HermesApp({required this.connManager, super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hermes Agent',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomeScreen(connManager: connManager),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final ConnectionManager connManager;
  const HomeScreen({required this.connManager, super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SavedConnection> _connections = [];
  bool _autoNavigated = false;

  void _refresh() {
    setState(() {
      _connections = widget.connManager.getConnections();
    });
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_autoNavigated && _connections.isNotEmpty) {
      _autoNavigated = true;
      final lastId = widget.connManager.prefs.getString('last_connection_id');
      final conn = _connections.where((c) => c.id == lastId).firstOrNull;
      if (conn != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _navigateToSessions(conn);
        });
      }
    }
  }

  void _navigateToSessions(SavedConnection conn) {
    widget.connManager.prefs.setString('last_connection_id', conn.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionListScreen(connection: conn),
      ),
    );
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (_) => _AddDialog(onSave: (label, host, port, apiKey) {
        widget.connManager.saveConnection(label, host, port, apiKey);
        _refresh();
      }),
    );
  }

  void _showApiKeyDialog(SavedConnection conn) {
    final ctrl = TextEditingController(text: conn.apiKey);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Update API Key'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'API Key',
            hintText: 'API_SERVER_KEY from .env',
          ),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final key = ctrl.text.trim();
              if (key.isNotEmpty) {
                widget.connManager.updateApiKey(conn.id, key);
                _refresh();
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hermes Agent')),
      body: _connections.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_outlined, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text('No connections',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Tap + to add a remote Hermes Gateway\n(API Server, port 8642)',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _connections.length,
              itemBuilder: (_, i) {
                final conn = _connections[i];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.router, color: Colors.blue),
                    title: Text(conn.label),
                    subtitle: Text(
                      '${conn.host}:${conn.port}  \u2022  Key: ${conn.apiKey.isNotEmpty ? "\u2713" : "\u2717"}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'delete') {
                          widget.connManager.deleteConnection(conn.id);
                          _refresh();
                        } else if (v == 'apikey') {
                          _showApiKeyDialog(conn);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'apikey',
                          child: Text('Update API Key'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                    onTap: () => _navigateToSessions(conn),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add Connection',
        onPressed: _showAddDialog,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

class _AddDialog extends StatefulWidget {
  final void Function(String label, String host, int port, String apiKey) onSave;
  const _AddDialog({required this.onSave});

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  final _label = TextEditingController(text: 'Home');
  final _host = TextEditingController(text: '192.168.68.188');
  final _port = TextEditingController(text: '8642');
  final _apiKey = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Gateway Connection'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              decoration: const InputDecoration(labelText: 'Host'),
              keyboardType: TextInputType.text,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8642 (API Server)',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'API_SERVER_KEY from ~/.hermes/.env',
              ),
              obscureText: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final label = _label.text.trim();
            final host = _host.text.trim();
            final port = int.tryParse(_port.text.trim()) ?? 8642;
            final apiKey = _apiKey.text.trim();
            if (label.isNotEmpty && host.isNotEmpty && port > 0) {
              widget.onSave(label, host, port, apiKey);
              Navigator.pop(context);
            }
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _apiKey.dispose();
    super.dispose();
  }
}
