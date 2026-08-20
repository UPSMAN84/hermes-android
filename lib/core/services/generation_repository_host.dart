import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/comfy_workflow.dart';
import 'atomic_json_store.dart';
import 'background_activity_service.dart';
import 'character_generation_context_store.dart';
import 'comfyui.dart';
import 'comfyui_client.dart';
import 'comfyui_socket.dart';
import 'generation_job_store.dart';
import 'generation_repository.dart';
import 'media_asset_store.dart';
import 'media_cache_service.dart';
import 'workflow_store.dart';

/// The app's real [ComfyEndpointConfig]: the active endpoint comes from the
/// same SharedPreferences key the settings screen writes
/// ([ComfyUiPrefs.baseUrl]); the stable per-installation client ID is
/// generated once and persisted alongside it so ComfyUI's `/ws?clientId=`
/// and `/prompt`'s `client_id` always agree across restarts.
final class SharedPreferencesEndpointConfig implements ComfyEndpointConfig {
  const SharedPreferencesEndpointConfig();

  static const _clientIdKey = 'comfyui_client_id';

  @override
  Future<ComfyEndpoint?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ComfyUiPrefs.loadConfiguredEndpoint(prefs);
  }

  @override
  Future<String> stableClientId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_clientIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = _generateClientId();
    await prefs.setString(_clientIdKey, generated);
    return generated;
  }

  static String _generateClientId() {
    final random = Random.secure();
    final seed = List<int>.generate(16, (_) => random.nextInt(256));
    return sha256.convert(seed).toString().substring(0, 32);
  }
}

final class DefaultComfyUiClientFactory implements ComfyUiClientFactory {
  const DefaultComfyUiClientFactory();

  @override
  ComfyUiClient create({
    required ComfyEndpoint endpoint,
    required String clientId,
  }) => ComfyUiClient(endpoint: endpoint, clientId: clientId);
}

/// App-scoped composition root for [GenerationRepository]: one shared
/// [ComfyStorageIndex] and one repository instance for the whole process,
/// matching the design's "one repository, replaying workflow/job/media/
/// context streams" requirement -- screens must never construct their own
/// stores or repository.
final class GenerationRepositoryHost {
  GenerationRepositoryHost._(this.repository);

  final GenerationRepository repository;

  static GenerationRepositoryHost? _instance;
  static Future<GenerationRepositoryHost>? _instanceFuture;

  static Future<GenerationRepositoryHost> instance() {
    final existing = _instance;
    if (existing != null) return Future.value(existing);
    return _instanceFuture ??= _create().then((host) {
      _instance = host;
      return host;
    });
  }

  static Future<GenerationRepositoryHost> _create() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}${Platform.pathSeparator}comfyui');
    final index = ComfyStorageIndex(root: root);

    final repository = DefaultGenerationRepository(
      endpointConfig: const SharedPreferencesEndpointConfig(),
      clientFactory: const DefaultComfyUiClientFactory(),
      socketFactory: const DefaultComfyUiSocketFactory(),
      workflowStore: WorkflowStore(root: root, index: index),
      jobStore: GenerationJobStore(root: root, index: index),
      mediaStore: MediaAssetStore(root: root, index: index),
      contextStore: CharacterGenerationContextStore(root: root, index: index),
      mediaCache: MediaCacheService.appDefault,
      foregroundLease: const GenerationForegroundLease(),
      clock: DateTime.now,
    );
    await repository.initialize();
    return GenerationRepositoryHost._(repository);
  }
}
