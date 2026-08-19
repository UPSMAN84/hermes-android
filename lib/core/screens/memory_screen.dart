// Memory status screen — surfaces which memory backend is active and what
// it holds, via the gateway's memory-status endpoint.
//
// API: GET /api/memory returns:
//   {
//     "active": "<provider name, or "" for the built-in file-based memory>",
//     "providers": [{name, description, available, configured, status, setup}, ...],
//     "builtin_files": {"memory": <bytes>, "user": <bytes>}
//   }
// There is no endpoint that returns memory *content* (individual facts) --
// the gateway only exposes status/config, not a list of entries. An earlier
// version of this screen expected `entries`/`memory` list keys that this
// endpoint has never returned, so a valid 200 response always rendered as
// "no memory entries" regardless of what was actually stored.
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';

class MemoryScreen extends StatefulWidget {
  final SavedConnection connection;
  const MemoryScreen({required this.connection, super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late DashboardClient _client;
  String _active = '';
  Map<String, int> _builtinFiles = {};
  List<Map<String, dynamic>> _providers = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? "",
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
    _loadMemory();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadMemory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await _client.apiGet('memory');
      if (!mounted) return;
      final providers = (data['providers'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          <Map<String, dynamic>>[];
      final builtinRaw = data['builtin_files'];
      final builtinFiles = <String, int>{
        if (builtinRaw is Map)
          for (final entry in builtinRaw.entries)
            entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
      };
      setState(() {
        _active = (data['active'] as String?)?.trim() ?? '';
        _providers = providers;
        _builtinFiles = builtinFiles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadMemory,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ready':
        return Colors.green;
      case 'needs_config':
        return Colors.orange;
      case 'unavailable':
      case 'missing':
        return Colors.grey;
      default:
        return Colors.grey;
    }
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
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Failed to load memory',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loadMemory,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMemory,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Active backend',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _active.isEmpty ? 'Built-in (file-based)' : _active,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_active.isEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'MEMORY.md: ${_formatBytes(_builtinFiles['memory'] ?? 0)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      'USER.md: ${_formatBytes(_builtinFiles['user'] ?? 0)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Stored under ~/.hermes/memories/. Content isn\'t '
                      'browsable from here -- this shows size only.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_providers.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Available providers',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            for (final provider in _providers)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(provider['name']?.toString() ?? ''),
                  subtitle: Text(provider['description']?.toString() ?? ''),
                  trailing: Chip(
                    label: Text(
                      provider['status']?.toString() ?? 'unknown',
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        _statusColor(provider['status']?.toString() ?? ''),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
