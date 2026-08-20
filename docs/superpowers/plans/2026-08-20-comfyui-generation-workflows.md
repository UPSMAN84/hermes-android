# ComfyUI Generation and Workflow Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add direct ComfyUI Image, Video, and Workflows tabs with character-aware inputs, durable jobs, global media, and safe mobile workflow execution.

**Architecture:** A strict `ComfyEndpoint` and typed `ComfyUiClient` sit below a persistent `GenerationRepository`. API-format workflow JSON and Hermes input bindings remain separate; screens consume repository streams and never own HTTP, WebSocket, filesystem, or job-state logic. Existing Gateway chat generation remains compatible and only contributes typed media records.

**Tech Stack:** Flutter/Dart 3.12+, `http`, `dart:io` WebSocket, SharedPreferences, app-support JSON files, `crypto`, `file_picker`, `url_launcher`, `media_kit`, Flutter unit/widget/integration tests.

**Spec:** `docs/superpowers/specs/2026-08-20-comfyui-generation-workflows-design.md`

## Global Constraints

- Target direct self-hosted ComfyUI only; do not change Hermes Gateway APIs.
- Do not add a Flutter node canvas, embedded WebView, Comfy Cloud, model installer, or video chat attachment.
- Accept only HTTP(S) endpoints with authority and optional port/path; reject user-info, query, and fragment.
- Preserve reverse-proxy paths with `Uri`; never concatenate endpoint strings.
- Treat missing or literal `http://0.0.0.0:8188` as unconfigured; preserve every other saved endpoint.
- Keep original workflow bytes; mutate a deep-copied parsed graph; preserve unknown fields.
- Never automatically retry `POST /prompt`; an uncertain submission remains uncertain.
- Persist workflows, jobs, media, and character contexts as atomic JSON/app-owned files; add no database.
- Limits: workflow 5 MiB, upload 25 MiB, JSON response 32 MiB, WebSocket text 2 MiB, HTTP connect 10 s, API idle 30 s, image auto-cache 50 MiB, manual-save confirmation for unknown or over 512 MiB.
- Ignore binary WebSocket previews in v1. Video remains stream-first.
- Reuse the shared foreground-service lease only while observing/reconciling jobs.
- Pin new packages: `crypto: ^3.0.7`, `file_picker: ^12.0.0`, `url_launcher: ^6.3.2`; add `integration_test` from the Flutter SDK.
- Use `C:\src\flutter\bin\flutter.bat` for every Flutter command.
- Preserve current Gateway SSE/chat behavior; no direct ComfyUI orchestration inside `ChatScreen`.

## Mandatory Composition and Contract Details

- Define `typedef JsonObject = Map<String, dynamic>;` once and use it for decoded workflow/API JSON so node/input indexing remains type-safe.
- Production owns one app-scoped `DefaultGenerationRepository`; screens accept the `GenerationRepository` interface and never construct/dispose independent repositories.
- `GenerationRepositoryHost.open` resolves the app-support directory, preferences, unified storage index, client/socket factories, cache, and foreground lease. Its idempotent `initialize()` rebuilds indexes and starts one recovery pass; `dispose()` closes streams/clients once.
- Endpoint settings are read through `ComfyEndpointConfig`; `ComfyUiClientFactory` creates clients from the active endpoint for new submissions and from each saved endpoint snapshot for recovery/media. Endpoint changes never rewrite existing jobs/assets.
- `ForegroundLeasePort` wraps the existing shared data-sync foreground service. One balanced lease covers all currently observed/reconciling generation work, with generation-specific notification text; never acquire one lease per listener.
- `ComfyStorageIndex` is the sole owner of `comfyui/index.json` with schema version and workflow/job/media/context ID lists. Stores atomically replace records before updating this index. Rebuild scans each typed directory in deterministic order and quarantines only corrupt records.
- Atomic writes serialize by canonical target path and use a unique sibling temporary name. The replace routine must overwrite an existing target on Windows and clean every abandoned temporary file.
- `MediaCachePort` and `MediaDownloadPort` are injected. The default download opens one streamed response, exposes status/content type/declared length to an async confirmation callback before body chunks, counts chunks, and promotes a complete file atomically. No `HEAD` assumption.
- HTTP connect timeout ends when response headers arrive. Idle timeout resets after each response chunk. Count the 32 MiB JSON limit before decoding. After a prompt request starts, connect/idle ambiguity becomes uncertain and is never retried.
- Upload accepts image MIME types only, sanitizes the filename, and rejects processed bytes over 25 MiB before network I/O.
- Socket decoding includes status, execution start, cached nodes, executing, progress, executed outputs, success, error, interruption, and loss. Filter by prompt ID only when the event contains one. `executing(node: null)` and socket close are never success.
- The repository guards duplicate active submissions independently of the form guard. Restore changes `submitting` without prompt ID to `uncertain` before any network call; only saved prompt IDs enter history/queue reconciliation.
- Workflow export has distinct source-byte, validated-working-graph, and Hermes-sidecar operations. External browser fallback uses an injected `UriClipboardPort` when no handler exists.
- Chat exposes one `Create media` overflow action. It awaits `CharacterGenerationContextStore.get(session.id)` before navigation. Tabs are exactly `Image`, `Video`, and `Workflows`.
- `MediaAsset` stores nullable source session and message IDs. Show source navigation only when both exist. Direct-generation outputs never create Gateway messages.
- Every named fake/fixture in a test step is implemented in that same test file or a named `test/support/comfy_fakes.dart`; no test step may leave fixture symbols undefined.

---

## File Structure

### New production files

- `lib/core/models/comfy_workflow.dart` — workflow graph metadata, bindings, validation records, output references.
- `lib/core/models/generation_job.dart` — generation request/job/progress/state reducer.
- `lib/core/models/media_asset.dart` — durable server-output reference and source metadata.
- `lib/core/models/character_generation_context.dart` — app-owned character prompt/reference snapshot.
- `lib/core/services/comfy_workflow_codec.dart` — import, hash, deep-copy binding, local/object-info validation.
- `lib/core/services/atomic_json_store.dart` — size-bounded atomic record IO and quarantine.
- `lib/core/services/workflow_store.dart` — working/source/sidecar workflow persistence.
- `lib/core/services/generation_job_store.dart` — job records and nonterminal recovery.
- `lib/core/services/media_asset_store.dart` — global media index and endpoint-aware deduplication.
- `lib/core/services/character_generation_context_store.dart` — context JSON and app-owned reference images.
- `lib/core/services/comfyui_client.dart` — bounded local ComfyUI HTTP API.
- `lib/core/services/comfyui_socket.dart` — typed WebSocket events and prompt filtering.
- `lib/core/services/generation_repository.dart` — submission, observation, cancellation, retry, reconciliation, streams.
- `lib/core/services/generation_repository_host.dart` — app-scoped composition, initialization, and disposal.
- `lib/core/services/workflow_document_port.dart` — file-picker import/export and external-browser adapter.
- `lib/core/screens/create_screen.dart` — Image/Video/Workflows shell.
- `lib/core/widgets/workflow_library_tab.dart` — import, binding, validation, JSON draft, export/test-run UI.
- `lib/core/widgets/generation_form.dart` — binding-driven Image/Video form.
- `lib/core/widgets/generation_job_card.dart` — progress/error/cancel/output actions.
- `lib/core/widgets/generated_media_view.dart` — shared image/video presentation and one-active-video control.
- `test/comfyui_protocol_fake_server_test.dart` — full loopback HTTP/WebSocket protocol test.
- `integration_test/comfyui_generation_app_test.dart` — device app navigation/persistence harness.
- `tool/run_comfyui_live_verification.ps1` — parameterized real-server/device verification and report writer.

### Modified production files

- `lib/core/services/comfyui.dart` — endpoint parsing/migration, typed `/view`, legacy filename extraction.
- `lib/core/services/media_cache_service.dart` — streamed bounded cache/downloads.
- `lib/core/services/media_export_service.dart` — counted remote save/share.
- `lib/core/services/background_activity_service.dart` — generation-specific shared foreground lease adapter.
- `lib/core/screens/settings_screen.dart` — validated ComfyUI endpoint state/test.
- `lib/core/screens/session_list_screen.dart` — Create drawer destination.
- `lib/core/screens/chat_screen.dart` — Create/Media navigation, context save, discuss-image draft, chat-media upsert.
- `lib/core/screens/media_gallery_screen.dart` — repository-backed global Media filters.
- `android/app/src/main/AndroidManifest.xml` — HTTPS browser visibility.
- `pubspec.yaml` / `pubspec.lock` — three runtime packages plus SDK integration test.
- `README.md` — setup, workflow export/import, endpoint security, usage.

### New/modified tests

- `test/comfyui_test.dart`
- `test/comfy_workflow_test.dart`
- `test/generation_job_test.dart`
- `test/workflow_store_test.dart`
- `test/media_cache_service_test.dart`
- `test/comfyui_client_test.dart`
- `test/comfyui_socket_test.dart`
- `test/generation_repository_test.dart`
- `test/workflow_library_tab_test.dart`
- `test/generation_form_test.dart`
- `test/generation_job_card_test.dart`
- `test/create_screen_test.dart`
- `test/chat_screen_test.dart`
- `test/media_gallery_screen_test.dart`
- `test/support/comfy_fakes.dart`

---

### Task 1: Strict ComfyUI Endpoint and Output References

**Files:**
- Modify: `lib/core/services/comfyui.dart:10-71`
- Create: `lib/core/models/comfy_workflow.dart`
- Modify: `test/comfyui_test.dart`

**Interfaces:**
- Produces: `ComfyEndpoint.parse(String)`, `route(String, {Map<String,String>? query})`, `websocketUri(String)`, `ComfyOutputRef`, `ComfyUiPrefs.loadConfiguredEndpoint(SharedPreferences)`.
- Consumes: `SharedPreferences`; no later task may parse or concatenate ComfyUI URLs itself.

- [ ] **Step 1: Write endpoint and output-reference failures**

```dart
test('preserves proxy path and encodes output query', () {
  final endpoint = ComfyEndpoint.parse('https://host.example/comfy');
  final uri = endpoint.viewUri(ComfyOutputRef(
    filename: 'clip 01.mp4', subfolder: 'jobs/a', type: 'output'));
  expect(uri.path, '/comfy/view');
  expect(uri.queryParameters, {
    'filename': 'clip 01.mp4', 'subfolder': 'jobs/a', 'type': 'output'});
});

test('rejects unsafe base components', () {
  for (final raw in [
    'https://user@host/comfy',
    'https://host/comfy?token=x',
    'https://host/comfy#fragment',
  ]) {
    expect(() => ComfyEndpoint.parse(raw), throwsFormatException);
  }
});

test('migrates only missing and wildcard placeholder values', () async {
  SharedPreferences.setMockInitialValues({});
  expect(await ComfyUiPrefs.loadConfiguredEndpoint(
      await SharedPreferences.getInstance()), isNull);
  SharedPreferences.setMockInitialValues({
    ComfyUiPrefs.baseUrl: 'https://host/comfy',
  });
  expect((await ComfyUiPrefs.loadConfiguredEndpoint(
      await SharedPreferences.getInstance()))!.baseUri.path, '/comfy');
});
```

- [ ] **Step 2: Run the endpoint tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\comfyui_test.dart`

Expected: FAIL because `ComfyEndpoint`, `ComfyOutputRef`, and configured-only loading do not exist.

- [ ] **Step 3: Implement the endpoint and reference types**

```dart
final class ComfyEndpoint {
  ComfyEndpoint._(this.baseUri);
  final Uri baseUri;

  factory ComfyEndpoint.parse(String raw) {
    final text = raw.trim().contains('://') ? raw.trim() : 'http://${raw.trim()}';
    final uri = Uri.parse(text);
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException('ComfyUI endpoint must be HTTP(S) authority plus optional path');
    }
    return ComfyEndpoint._(uri.replace(path: _cleanBasePath(uri.path)));
  }

  static String _cleanBasePath(String path) {
    final withoutTrailingSlash = path.replaceFirst(RegExp(r'/+$'), '');
    if (withoutTrailingSlash.isEmpty) return '';
    return withoutTrailingSlash.startsWith('/')
        ? withoutTrailingSlash
        : '/$withoutTrailingSlash';
  }

  Uri route(String leaf, {Map<String, String>? query}) => baseUri.replace(
    path: '${baseUri.path == '/' ? '' : baseUri.path}/${leaf.replaceFirst(RegExp(r'^/+'), '')}',
    queryParameters: query,
  );

  Uri websocketUri(String clientId) => route('ws', query: {'clientId': clientId})
      .replace(scheme: baseUri.scheme == 'https' ? 'wss' : 'ws');

  Uri viewUri(ComfyOutputRef output) => route('view', query: output.query);
}

final class ComfyOutputRef {
  ComfyOutputRef._({required this.filename, required this.subfolder, required this.type});
  factory ComfyOutputRef({required String filename, String subfolder = '', String type = 'output'}) {
    if (filename.isEmpty || filename.contains('/') || filename.contains('\\') || filename == '..' ||
        subfolder.split(RegExp(r'[/\\]+')).any((part) => part == '..') ||
        !const {'input', 'output', 'temp'}.contains(type)) {
      throw const FormatException('Unsafe ComfyUI output reference');
    }
    return ComfyOutputRef._(filename: filename, subfolder: subfolder, type: type);
  }
  final String filename;
  final String subfolder;
  final String type;
  Map<String, String> get query => {
    'filename': filename, if (subfolder.isNotEmpty) 'subfolder': subfolder, 'type': type};
}
```

Keep `ComfyUi.extractMediaFilenames` and `ComfyUi.isVideo` as compatibility helpers. Validate output `type` against `input`, `output`, `temp`, reject path traversal, and return `null` for missing/wildcard preferences.

- [ ] **Step 4: Run endpoint tests**

Run: `C:\src\flutter\bin\flutter.bat test test\comfyui_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit the endpoint foundation**

```powershell
git add lib/core/services/comfyui.dart lib/core/models/comfy_workflow.dart test/comfyui_test.dart
git commit -m "feat: add strict ComfyUI endpoint model"
```

---

### Task 2: Workflow Import, Binding, Hashing, and Validation

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/core/services/comfy_workflow_codec.dart`
- Expand: `lib/core/models/comfy_workflow.dart`
- Create: `test/comfy_workflow_test.dart`

**Interfaces:**
- Consumes: `ComfyEndpoint` from Task 1.
- Produces: `ComfyWorkflowDefinition`, `WorkflowInputBinding`, `WorkflowValidationResult`, `ImportedWorkflow`, `ComfyWorkflowCodec.decode/applyBindings/validateLocal/validateObjectInfo/suggestBindings`.

- [ ] **Step 1: Add `crypto` and resolve dependencies**

Add under dependencies:

```yaml
  crypto: ^3.0.7
```

Run: `C:\src\flutter\bin\flutter.bat pub get`

Expected: dependency resolution succeeds and `pubspec.lock` records `crypto`.

- [ ] **Step 2: Write workflow codec failures**

```dart
test('binding mutates only a deep copy and preserves unknown fields', () {
  final imported = ComfyWorkflowCodec.decode(
    utf8.encode('{"6":{"class_type":"CustomText","inputs":{"text":"old","opaque":{"x":1}}},"_meta":{"v":9}}'),
    sourceFileName: 'workflow.json',
  );
  final binding = WorkflowInputBinding(
    id: 'prompt', nodeId: '6', inputName: 'text', label: 'Prompt',
    role: BindingRole.prompt, controlType: WorkflowControlType.multiline,
    required: true,
  );
  final runGraph = ComfyWorkflowCodec.applyBindings(
    imported.graph, [binding], {'prompt': 'new'});
  expect(runGraph['6']['inputs']['text'], 'new');
  expect(imported.graph['6']['inputs']['text'], 'old');
  expect(runGraph['6']['inputs']['opaque'], {'x': 1});
  expect(runGraph['_meta'], {'v': 9});
});

test('object info reports missing classes and mapped inputs', () {
  final result = ComfyWorkflowCodec.validateObjectInfo(
    definition: fixtureDefinition(),
    endpoint: ComfyEndpoint.parse('http://host:8188'),
    objectInfo: {'Known': {'input': {'required': {'text': ['STRING', {}]}}}},
  );
  expect(result.issues.map((e) => e.code), containsAll(['missing_class', 'missing_input']));
});
```

- [ ] **Step 3: Run codec tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\comfy_workflow_test.dart`

Expected: FAIL because workflow types and codec are absent.

- [ ] **Step 4: Implement exact workflow types**

```dart
enum ComfyMediaKind { image, video }
enum BindingRole { prompt, negativePrompt, seed, width, height, steps, cfg, frames, fps, inputImage, custom }
enum WorkflowControlType { text, multiline, integer, decimal, toggle, enumeration, file }

final class WorkflowInputBinding {
  const WorkflowInputBinding({
    required this.id, required this.nodeId, required this.inputName,
    required this.label, required this.role, required this.controlType,
    required this.required, this.helpText, this.defaultValue,
    this.minimum, this.maximum, this.step, this.choices = const [],
  });
  final String id;
  final String nodeId;
  final String inputName;
  final String label;
  final BindingRole role;
  final WorkflowControlType controlType;
  final bool required;
  final String? helpText;
  final Object? defaultValue;
  final num? minimum;
  final num? maximum;
  final num? step;
  final List<String> choices;
  Map<String, Object?> toJson();
  factory WorkflowInputBinding.fromJson(Map<String, Object?> json);
}

final class ComfyWorkflowDefinition {
  const ComfyWorkflowDefinition({
    required this.id, required this.name, required this.kind,
    required this.workingGraph, required this.sourceHash,
    required this.sourceFileName, required this.bindings,
    required this.createdAt, required this.updatedAt,
    this.validation, this.lastSuccessfulJobId,
  });
  final String id;
  final String name;
  final ComfyMediaKind kind;
  final Map<String, Object?> workingGraph;
  final String sourceHash;
  final String sourceFileName;
  final List<WorkflowInputBinding> bindings;
  final DateTime createdAt;
  final DateTime updatedAt;
  final WorkflowValidationResult? validation;
  final String? lastSuccessfulJobId;
  ComfyWorkflowDefinition copyWith({
    String? name,
    ComfyMediaKind? kind,
    Map<String, Object?>? workingGraph,
    List<WorkflowInputBinding>? bindings,
    DateTime? updatedAt,
    WorkflowValidationResult? validation,
    String? lastSuccessfulJobId,
  });
  Map<String, Object?> toJson();
  factory ComfyWorkflowDefinition.fromJson(Map<String, Object?> json);
}
```

`decode` must enforce the 5 MiB limit, require a map root and per-node `class_type`/`inputs`, compute `sha256.convert(sourceBytes).toString()`, and retain source bytes separately from the parsed graph. `applyBindings` must use JSON encode/decode for a deep copy and verify every binding target before assignment.

- [ ] **Step 5: Implement object-info validation and binding suggestions**

`validateObjectInfo` must hash normalized endpoint plus recursively key-sorted object-info JSON. It may block only missing classes, missing mapped inputs, primitive/range/enum mismatches exposed by schema, and schema-enumerated missing models. `suggestBindings` proposes but never saves common fields (`text`, `seed`, `width`, `height`, `steps`, `cfg`, `frames`, `fps`, `image`). Tests prove an invalid raw draft cannot replace the saved graph, an unedited source export is byte-exact, an edited export preserves unknown fields, the sidecar stays separate, and endpoint/object-info changes invalidate the prior fingerprint.

- [ ] **Step 6: Run codec tests**

Run: `C:\src\flutter\bin\flutter.bat test test\comfy_workflow_test.dart`

Expected: PASS, including byte-source hash, JSON round trip, unknown fields, immutable binding, size limit, missing nodes/inputs, and fingerprint invalidation.

- [ ] **Step 7: Commit workflow codec**

```powershell
git add pubspec.yaml pubspec.lock lib/core/models/comfy_workflow.dart lib/core/services/comfy_workflow_codec.dart test/comfy_workflow_test.dart
git commit -m "feat: add ComfyUI workflow codec and validation"
```

---

### Task 3: Generation, Media, and Character Domain Models

**Files:**
- Create: `lib/core/models/generation_job.dart`
- Create: `lib/core/models/media_asset.dart`
- Create: `lib/core/models/character_generation_context.dart`
- Create: `test/generation_job_test.dart`

**Interfaces:**
- Consumes: `ComfyMediaKind`, `ComfyOutputRef`, workflow IDs.
- Produces: `GenerationRequest`, `GenerationJob`, `GenerationJobState`, `GenerationEvent`, `reduceGenerationJob`, `MediaAsset`, `CharacterGenerationContext`.

- [ ] **Step 1: Write serialization and state-race failures**

```dart
test('socket loss reconciles and success wins a cancellation race', () {
  final running = job(state: GenerationJobState.running);
  final lost = reduceGenerationJob(running, const SocketLost(), now());
  expect(lost.state, GenerationJobState.reconciling);

  final cancelling = job(state: GenerationJobState.cancelling);
  final completed = reduceGenerationJob(
    cancelling, ExecutionSucceeded([outputRef()]), now());
  expect(completed.state, GenerationJobState.succeeded);
});

test('media identity includes endpoint snapshot', () {
  expect(asset(endpoint: 'http://a').identityKey,
      isNot(asset(endpoint: 'http://b').identityKey));
});

test('model JSON round trips retain unknown-safe defaults', () {
  final restored = GenerationJob.fromJson(job().toJson());
  expect(restored.toJson(), job().toJson());
});
```

- [ ] **Step 2: Run model tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\generation_job_test.dart`

Expected: FAIL because the domain models and reducer do not exist.

- [ ] **Step 3: Implement exact job states and reducer**

```dart
enum GenerationJobState {
  draft, submitting, queued, running, cancelling, reconciling,
  succeeded, failed, cancelled, uncertain,
}

sealed class GenerationEvent { const GenerationEvent(); }
final class PromptAccepted extends GenerationEvent { const PromptAccepted(this.promptId); final String promptId; }
final class PromptQueued extends GenerationEvent { const PromptQueued(); }
final class ExecutionStarted extends GenerationEvent { const ExecutionStarted(); }
final class ExecutionProgressed extends GenerationEvent { const ExecutionProgressed(this.nodeId, this.value, this.max); final String? nodeId; final int value; final int max; }
final class ExecutionSucceeded extends GenerationEvent { const ExecutionSucceeded(this.outputs); final List<ComfyOutputRef> outputs; }
final class ExecutionFailed extends GenerationEvent { const ExecutionFailed(this.message, {this.nodeErrors = const {}}); final String message; final Map<String,Object?> nodeErrors; }
final class ExecutionInterrupted extends GenerationEvent { const ExecutionInterrupted(); }
final class SocketLost extends GenerationEvent { const SocketLost(); }
final class SubmissionUnknown extends GenerationEvent { const SubmissionUnknown(this.message); final String message; }
final class QueueReconciled extends GenerationEvent { const QueueReconciled(this.present); final bool present; }
final class HistoryReconciled extends GenerationEvent {
  const HistoryReconciled({required this.completed, this.outputs = const <ComfyOutputRef>[], this.error});
  final bool completed;
  final List<ComfyOutputRef> outputs;
  final String? error;
}
final class QueueRemovalConfirmed extends GenerationEvent { const QueueRemovalConfirmed(); }
final class RestoreWithoutPromptId extends GenerationEvent { const RestoreWithoutPromptId(); }
```

Implement a pure `GenerationJob reduceGenerationJob(GenerationJob job, GenerationEvent event, DateTime now)` with legal terminal/race rules from the spec. A restored submitting job without a prompt ID becomes uncertain; known socket loss reconciles; close never succeeds; success with an empty payload preserves outputs already seen in executed events; terminal success/error wins a cancelling race. JSON fields must include endpoint snapshot, submitted values, prompt ID, progress, outputs, nullable source session/message/context IDs, error, and timestamps.

- [ ] **Step 4: Implement media and character models**

`MediaAsset.identityKey` is SHA-256 over normalized endpoint + filename + subfolder + type. It stores nullable source session and message IDs independently. `CharacterGenerationContext.fromCard({required String sessionId, required CharacterCard card, required DateTime now})` copies the card name/description into an editable snapshot. `composeGenerationPrompt({required String userPrompt, CharacterGenerationContext? context, required bool useContext})` returns a new string without mutating the context. The context also stores an optional app-owned reference-image path and timestamps. Every model uses handwritten `toJson/fromJson` matching existing project style.

- [ ] **Step 5: Run model tests**

Run: `C:\src\flutter\bin\flutter.bat test test\generation_job_test.dart`

Expected: PASS for every legal state transition, cancel/success/error/socket races, uncertain restore, serialization, and endpoint-aware media identity.

- [ ] **Step 6: Commit domain models**

```powershell
git add lib/core/models/generation_job.dart lib/core/models/media_asset.dart lib/core/models/character_generation_context.dart test/generation_job_test.dart
git commit -m "feat: model ComfyUI jobs media and character context"
```

---

### Task 4: Atomic Workflow, Job, Media, and Character Stores

**Files:**
- Create: `lib/core/services/atomic_json_store.dart`
- Create: `lib/core/services/workflow_store.dart`
- Create: `lib/core/services/generation_job_store.dart`
- Create: `lib/core/services/media_asset_store.dart`
- Create: `lib/core/services/character_generation_context_store.dart`
- Create: `test/workflow_store_test.dart`

**Interfaces:**
- Consumes: Tasks 2-3 models.
- Produces: injectable directory-backed stores used by `GenerationRepository`.

- [ ] **Step 1: Write atomicity, rebuild, quarantine, and image-copy failures**

```dart
late Directory temp;
setUp(() async => temp = await Directory.systemTemp.createTemp('hermes-comfy-store-'));
tearDown(() async => temp.delete(recursive: true));

test('rebuilds index and quarantines one corrupt record', () async {
  final store = WorkflowStore(root: temp);
  await store.save(definition(), originalSource: utf8.encode(validGraph));
  final workflows = Directory('${temp.path}${Platform.pathSeparator}workflows');
  await File('${workflows.path}${Platform.pathSeparator}broken.hermes.json')
      .writeAsString('{');
  final result = await store.rebuildIndex();
  expect(result.records, hasLength(1));
  expect(Directory('${temp.path}${Platform.pathSeparator}quarantine').listSync(), isNotEmpty);
});

test('context copies and deletes the reference image', () async {
  final source = File('${temp.path}${Platform.pathSeparator}picked.png')
    ..writeAsBytesSync([1, 2, 3]);
  final store = CharacterGenerationContextStore(root: temp);
  final saved = await store.save(context(), referenceImage: source);
  expect(File(saved.referenceImagePath!).readAsBytesSync(), [1, 2, 3]);
  await store.delete(saved.sessionId);
  expect(File(saved.referenceImagePath!).existsSync(), isFalse);
});
```

- [ ] **Step 2: Run store tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\workflow_store_test.dart`

Expected: FAIL because stores are absent.

- [ ] **Step 3: Implement the bounded atomic primitive**

```dart
final class AtomicJsonStore {
  AtomicJsonStore({required this.root, required this.index, this.maxRecordBytes = 5 * 1024 * 1024});
  final Directory root;
  final ComfyStorageIndex index;
  final int maxRecordBytes;

  Future<void> writeJson(File target, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > maxRecordBytes) throw const FormatException('Record exceeds size limit');
    await target.parent.create(recursive: true);
    final suffix = '$pid-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';
    final temp = File('${target.path}.$suffix.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await replaceFileAtomically(temp: temp, target: target);
  }
}

final class ComfyStorageIndex {
  static const schemaVersion = 1;
  Future<void> updateAfterRecordWrite({required String collection, required String id});
  Future<ComfyIndexSnapshot> rebuild();
}
```

Add per-record serialization locks keyed by canonical absolute target, bounded reads, unique sibling-temp cleanup, Windows overwrite-existing coverage, record-ID/path-traversal rejection, and quarantine-by-move. `ComfyStorageIndex` alone owns `comfyui/index.json`; rebuild scans workflows, jobs, media, and contexts in deterministic order. Do not delete other valid records if one record fails.

- [ ] **Step 4: Implement typed stores**

```dart
abstract interface class RecordStore<T> {
  Future<List<T>> list();
  Future<T?> get(String id);
  Future<void> save(T value);
  Future<void> delete(String id);
}
```

`WorkflowStore` additionally saves/loads `.source.json` bytes and `.hermes.json`; `GenerationJobStore.listNonterminal()` returns submitting/queued/running/cancelling/reconciling and exposes submitting-without-prompt-ID for immediate uncertain recovery; `MediaAssetStore.upsert` deduplicates by identity key without cascading server deletion; `CharacterGenerationContextStore` owns copied images. Stores update the unified index only after record replacement succeeds.

- [ ] **Step 5: Run store tests**

Run: `C:\src\flutter\bin\flutter.bat test test\workflow_store_test.dart`

Expected: PASS for atomic replace, concurrent same-record writes, missing/corrupt index rebuild, corrupt-record quarantine, source-byte retention, size ceilings, media dedupe, non-cascade deletion, and image lifecycle.

- [ ] **Step 6: Commit durable stores**

```powershell
git add lib/core/services/atomic_json_store.dart lib/core/services/workflow_store.dart lib/core/services/generation_job_store.dart lib/core/services/media_asset_store.dart lib/core/services/character_generation_context_store.dart test/workflow_store_test.dart
git commit -m "feat: persist ComfyUI workflows jobs and media atomically"
```

---

### Task 5: Streamed, Bounded Media Cache and Export

**Files:**
- Modify: `lib/core/services/media_cache_service.dart`
- Modify: `lib/core/services/media_export_service.dart`
- Modify: `lib/core/widgets/cached_media_thumbnail.dart`
- Modify: `lib/core/screens/chat_screen.dart`
- Create: `test/media_cache_service_test.dart`

**Interfaces:**
- Consumes: typed media URLs from Task 1.
- Produces: `MediaDownloadService.download`, injectable `MediaCacheService`, `MediaDownloadLimitException`.

- [ ] **Step 1: Write streamed-download boundary failures**

```dart
test('aborts a lying content-length response at the byte limit', () async {
  final client = ChunkedClient(
    declaredLength: 3,
    chunks: [Uint8List(4), Uint8List(4)],
  );
  final cache = MediaCacheService(root: temp, httpClient: client, maxImageBytes: 6);
  await expectLater(cache.cache(Uri.parse('http://host/view?filename=a.png')),
      throwsA(isA<MediaDownloadLimitException>()));
  expect(temp.listSync(recursive: true).whereType<File>(), isEmpty);
});

test('coalesces concurrent downloads for the same URI', () async {
  final client = CountingChunkedClient([Uint8List.fromList([1, 2, 3])]);
  final cache = MediaCacheService(root: temp, httpClient: client);
  await Future.wait([cache.cache(uri), cache.cache(uri)]);
  expect(client.sendCount, 1);
});
```

- [ ] **Step 2: Run cache tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\media_cache_service_test.dart`

Expected: FAIL because the existing cache buffers `bodyBytes` and has no injectable streamed limit.

- [ ] **Step 3: Implement counted streaming and atomic promotion**

```dart
final class MediaDownloadLimitException implements Exception {
  const MediaDownloadLimitException(this.limitBytes);
  final int limitBytes;
}

final class MediaDownloadInfo {
  const MediaDownloadInfo({required this.statusCode, required this.contentType, required this.declaredBytes});
  final int statusCode;
  final String? contentType;
  final int? declaredBytes;
}

abstract interface class MediaDownloadPort {
  Future<File> download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    Map<String, String> headers = const <String, String>{},
    Future<bool> Function(MediaDownloadInfo info)? confirmAfterHeaders,
  });
}

abstract interface class MediaCachePort {
  Future<File?> cache(Uri uri, {Map<String, String> headers = const <String, String>{}});
  Future<void> remove(Uri uri);
}

final class DefaultMediaDownloadService implements MediaDownloadPort {
  DefaultMediaDownloadService({required http.Client httpClient});
}
```

Use one `http.Client.send`, expose headers to `confirmAfterHeaders` before reading chunks, reject a declared size over the limit, count every received chunk even when the header is missing or false, write to a unique sibling `.part` file, flush, rename atomically, and delete partial files on every failure. Preserve protected headers, URL-keyed in-flight coalescing, and stale-file fallback only for already complete cache records. Migrate every static `MediaCacheService.fileFor` caller to an injected/default `MediaCachePort`.

- [ ] **Step 4: Apply media policy at callers**

Images may auto-cache up to 50 MiB. Generated videos must use their remote URI until the user explicitly saves or shares them. `MediaExportService.saveRemote/shareRemote` uses the same single-request counted downloader; it supplies a confirmation callback when `Content-Length` is absent or greater than 512 MiB, before accepting the first body chunk.

- [ ] **Step 5: Run focused cache/export tests**

Run: `C:\src\flutter\bin\flutter.bat test test\media_cache_service_test.dart test\media_gallery_screen_test.dart test\chat_screen_test.dart`

Expected: PASS for declared, absent, and false lengths; cleanup; coalescing; cached image fallback; and stream-first video rendering.

- [ ] **Step 6: Commit bounded media IO**

```powershell
git add lib/core/services/media_cache_service.dart lib/core/services/media_export_service.dart lib/core/widgets/cached_media_thumbnail.dart lib/core/screens/chat_screen.dart test/media_cache_service_test.dart test/media_gallery_screen_test.dart test/chat_screen_test.dart
git commit -m "fix: bound and stream generated media downloads"
```

---

### Task 6: Bounded ComfyUI HTTP Client

**Files:**
- Create: `lib/core/services/comfyui_client.dart`
- Create: `test/comfyui_client_test.dart`

**Interfaces:**
- Consumes: `ComfyEndpoint`, `ComfyOutputRef`.
- Produces: `ComfyUiClient`, `ComfyPromptSubmission`, `ComfyQueueSnapshot`, `ComfyConnectionInfo`, `ComfyHistoryResult`, `ComfyApiException`, `ComfySubmissionUncertainException`.

- [ ] **Step 1: Write protocol and no-retry failures**

```dart
test('prompt timeout sends exactly once and becomes uncertain', () async {
  final client = HangingAfterAcceptClient();
  final comfy = ComfyUiClient(
    endpoint: ComfyEndpoint.parse('http://host/proxy'),
    clientId: 'client-1',
    httpClient: client,
    idleTimeout: const Duration(milliseconds: 10),
  );
  await expectLater(comfy.submitPrompt({'1': graphNode}),
      throwsA(isA<ComfySubmissionUncertainException>()));
  expect(client.promptRequests, 1);
});

test('upload returns the server-assigned output reference', () async {
  final comfy = fixtureClient(jsonResponse: {
    'name': 'server.png', 'subfolder': 'uploads', 'type': 'input'});
  expect((await comfy.uploadImage(bytes, fileName: 'local.png')).filename,
      'server.png');
});
```

- [ ] **Step 2: Run client tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\comfyui_client_test.dart`

Expected: FAIL because the direct ComfyUI client does not exist. Tests must also cover proxy-path preservation, `/system_stats`, `/object_info`, multipart upload, `/prompt`, `/queue`, queue deletion, `/interrupt`, `/history/{promptId}`, node errors, unsafe output references, non-2xx bodies, and the 32 MiB JSON ceiling.

- [ ] **Step 3: Implement the exact client surface**

```dart
final class ComfyUiClient {
  ComfyUiClient({
    required ComfyEndpoint endpoint,
    required String clientId,
    http.Client? httpClient,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 30),
    int maxJsonBytes = 32 * 1024 * 1024,
    int maxUploadBytes = 25 * 1024 * 1024,
  });

  Future<ComfyConnectionInfo> checkConnection();
  Future<Map<String, Object?>> getObjectInfo();
  Future<ComfyOutputRef> uploadImage(Uint8List bytes, {required String fileName});
  Future<ComfyPromptSubmission> submitPrompt(Map<String, Object?> prompt);
  Future<ComfyQueueSnapshot> getQueue();
  Future<void> deleteQueuedPrompt(String promptId);
  Future<void> interrupt();
  Future<ComfyHistoryResult?> getHistory(String promptId);
  Stream<ComfyExecutionEvent> watchExecution(String promptId);
  Uri buildViewUri(ComfyOutputRef output);
  Uri openFrontend();
  void close();
}
```

Every request must be built with `ComfyEndpoint.route`. Stream and count JSON bodies. Enforce 10 seconds until headers, reset the 30-second idle timer per response chunk, and apply the 32 MiB limit before JSON decode. Reject non-image uploads, unsafe names, and processed input bytes over 25 MiB before sending. Convert only `/prompt` ambiguity after request initiation into `ComfySubmissionUncertainException`; never retry it. Parse `node_errors` into structured exception fields. Recursively collect only validated `ComfyOutputRef` values from history. Delegate `watchExecution` to the injected socket adapter.

- [ ] **Step 4: Run client tests**

Run: `C:\src\flutter\bin\flutter.bat test test\comfyui_client_test.dart`

Expected: PASS with exactly one prompt request under timeout and every route under a reverse-proxy prefix.

- [ ] **Step 5: Commit the HTTP client**

```powershell
git add lib/core/services/comfyui_client.dart test/comfyui_client_test.dart
git commit -m "feat: add bounded ComfyUI HTTP client"
```

---

### Task 7: Typed ComfyUI WebSocket Events

**Files:**
- Create: `lib/core/services/comfyui_socket.dart`
- Create: `test/comfyui_socket_test.dart`

**Interfaces:**
- Consumes: `ComfyEndpoint.websocketUri`, prompt IDs.
- Produces: injectable `ComfySocketConnector`, `ComfySocketTransport`, and `Stream<ComfyExecutionEvent>`.

- [ ] **Step 1: Write socket decoding and closure failures**

```dart
test('filters other prompts and never treats close as success', () async {
  final transport = FakeSocketTransport([
    jsonEncode({'type': 'progress', 'data': {'prompt_id': 'other', 'value': 1, 'max': 2}}),
    jsonEncode({'type': 'executing', 'data': {'prompt_id': 'mine', 'node': '7'}}),
  ]);
  final events = await ComfyUiSocket(connector: FakeConnector(transport))
      .watchExecution(endpoint, clientId: 'c', promptId: 'mine')
      .toList();
  expect(events.whereType<ComfyExecuting>().single.nodeId, '7');
  expect(events.last, isA<ComfySocketLost>());
  expect(events.whereType<ComfySucceeded>(), isEmpty);
});
```

Tests must also cover `ws`/`wss` conversion, 2 MiB text rejection, malformed JSON, binary preview ignore, progress, executed output, execution error, interrupted, and explicit success.

- [ ] **Step 2: Run socket tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\comfyui_socket_test.dart`

Expected: FAIL because the socket adapter and event types are absent.

- [ ] **Step 3: Implement typed socket transport and events**

```dart
abstract interface class ComfySocketTransport {
  Stream<Object?> get messages;
  Future<void> close();
}

abstract interface class ComfySocketConnector {
  Future<ComfySocketTransport> connect(Uri uri);
}

sealed class ComfyExecutionEvent { const ComfyExecutionEvent(); }
final class ComfyStatus extends ComfyExecutionEvent { const ComfyStatus(this.queueRemaining); final int? queueRemaining; }
final class ComfyExecutionStarted extends ComfyExecutionEvent { const ComfyExecutionStarted(); }
final class ComfyCachedNodes extends ComfyExecutionEvent { const ComfyCachedNodes(this.nodeIds); final List<String> nodeIds; }
final class ComfyProgress extends ComfyExecutionEvent { const ComfyProgress(this.nodeId, this.value, this.max); final String? nodeId; final int value; final int max; }
final class ComfyExecuting extends ComfyExecutionEvent { const ComfyExecuting(this.nodeId); final String? nodeId; }
final class ComfyExecuted extends ComfyExecutionEvent { const ComfyExecuted(this.nodeId, this.outputs); final String nodeId; final List<ComfyOutputRef> outputs; }
final class ComfySucceeded extends ComfyExecutionEvent { const ComfySucceeded(this.outputs); final List<ComfyOutputRef> outputs; }
final class ComfyExecutionError extends ComfyExecutionEvent { const ComfyExecutionError(this.message); final String message; }
final class ComfyInterrupted extends ComfyExecutionEvent { const ComfyInterrupted(); }
final class ComfySocketLost extends ComfyExecutionEvent { const ComfySocketLost(this.message); final String message; }
```

The default connector wraps `dart:io` `WebSocket`. Ignore binary messages, bound text before decoding, filter by `prompt_id` only when present, and emit `ComfySocketLost` on close/error unless a terminal event already arrived. Decode `executing` with a null node as nonterminal. Tests drive a `StreamController<Object?>` through close-before-terminal, terminal-before-close, malformed, oversized, and error paths.

- [ ] **Step 4: Run socket tests**

Run: `C:\src\flutter\bin\flutter.bat test test\comfyui_socket_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit socket decoding**

```powershell
git add lib/core/services/comfyui_socket.dart test/comfyui_socket_test.dart
git commit -m "feat: decode ComfyUI execution events"
```

---

### Task 8: Durable Generation Repository and Reconciliation

**Files:**
- Create: `lib/core/services/generation_repository.dart`
- Create: `lib/core/services/generation_repository_host.dart`
- Modify: `lib/core/services/background_activity_service.dart`
- Create: `test/generation_repository_test.dart`

**Interfaces:**
- Consumes: Tasks 2-7 stores, codec, HTTP/socket clients, and the existing foreground-service lease.
- Produces: the only orchestration API screens and chat may call.

- [ ] **Step 1: Write submission, recovery, cancellation, and race failures**

```dart
test('persists submitting before one prompt POST and makes timeout uncertain', () async {
  final client = UncertainPromptClient();
  final repository = fixtureRepository(client: client);
  final job = await repository.submit(request());
  expect(job.state, GenerationJobState.uncertain);
  expect(await jobStore.get(job.localId), isNotNull);
  expect(client.promptRequests, 1);
});

test('restore never resubmits a job without a prompt id', () async {
  await jobStore.save(job(state: GenerationJobState.submitting, promptId: null));
  final client = CountingPromptClient();
  await fixtureRepository(client: client).reconcilePending();
  expect((await jobStore.get(localId))!.state, GenerationJobState.uncertain);
  expect(client.promptRequests, 0);
});
```

Tests must cover upload-before-submit binding, history-first recovery, queue reconciliation, socket-loss reconciliation, duplicate terminal events, queued delete, running shared-interrupt confirmation, success during cancel, retry-as-new ID, media upsert, chat-tool dedupe, character prompt composition, and foreground-lease balance.

- [ ] **Step 2: Run repository tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\generation_repository_test.dart`

Expected: FAIL because the repository does not exist.

- [ ] **Step 3: Implement the exact repository API**

```dart
enum WorkflowExportKind { originalSource, workingGraph, hermesSidecar }

abstract interface class ComfyEndpointConfig {
  Future<ComfyEndpoint?> load();
  Future<String> stableClientId();
}

abstract interface class ComfyUiClientFactory {
  ComfyUiClient create({required ComfyEndpoint endpoint, required String clientId});
}

abstract interface class ForegroundLeasePort {
  Future<bool> acquire({required String notificationText});
  Future<void> release();
}

abstract interface class GenerationRepository {
  Future<void> initialize();
  Stream<List<ComfyWorkflowDefinition>> watchWorkflows();
  Stream<List<GenerationJob>> watchJobs();
  Stream<List<MediaAsset>> watchMedia();
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId);

  Future<GenerationJob> submit(GenerationRequest request);
  Future<void> cancel(String localJobId, {bool confirmSharedInterrupt = false});
  Future<GenerationJob> retryAsNew(String localJobId);
  Future<void> reconcilePending();
  Future<ComfyWorkflowDefinition?> getWorkflow(String workflowId);
  Future<void> saveWorkflow(ComfyWorkflowDefinition workflow, {required Uint8List sourceBytes});
  Future<ComfyWorkflowDefinition> duplicateWorkflow(String workflowId, {required String name});
  Future<WorkflowValidationResult> validateWorkflow(String workflowId, {required bool againstServer});
  Future<Uint8List> exportWorkflow(String workflowId, WorkflowExportKind kind);
  Future<void> deleteWorkflow(String workflowId);
  Future<void> removeMedia(String assetId, {required bool clearCache});
  Future<CharacterGenerationContext?> getCharacterContext(String sessionId);
  Future<void> saveCharacterContext(CharacterGenerationContext context, {File? referenceImage});
  Future<void> deleteCharacterContext(String sessionId);
  Future<void> upsertChatToolOutputs({
    required ComfyEndpoint endpoint,
    required String sessionId,
    required List<JsonObject> messages,
  });
  Future<void> dispose();
}

final class DefaultGenerationRepository implements GenerationRepository {
  DefaultGenerationRepository({
    required ComfyEndpointConfig endpointConfig,
    required ComfyUiClientFactory clientFactory,
    required ComfyUiSocketFactory socketFactory,
    required WorkflowStore workflowStore,
    required GenerationJobStore jobStore,
    required MediaAssetStore mediaStore,
    required CharacterGenerationContextStore contextStore,
    required MediaCachePort mediaCache,
    required ForegroundLeasePort foregroundLease,
    required DateTime Function() clock,
  });
}
```

Persist `submitting` before any network I/O. Upload reference images, apply bindings to a deep copy, then issue exactly one prompt POST. Observe only the returned prompt ID. On connection ambiguity store `uncertain`; on socket loss switch to `reconciling` and query history/queue. On app restore, never submit. Queue cancellation deletes only the target prompt. Running cancellation calls global interrupt only after explicit confirmation. Terminal history/output wins cancellation races. Resolve clients from the active endpoint only for new jobs and from saved endpoint snapshots for recovery. Use the injected foreground port and balance one shared lease across all active observation/reconciliation.

- [ ] **Step 4: Run repository tests**

Run: `C:\src\flutter\bin\flutter.bat test test\generation_repository_test.dart`

Expected: PASS for submission guard, no-retry recovery, cancellation semantics, endpoint snapshots, media dedupe, prompt composition, and balanced foreground leases.

- [ ] **Step 5: Commit repository orchestration**

```powershell
git add lib/core/services/generation_repository.dart lib/core/services/generation_repository_host.dart lib/core/services/background_activity_service.dart test/generation_repository_test.dart
git commit -m "feat: orchestrate durable ComfyUI generation jobs"
```

---

### Task 9: Endpoint Settings and Workflow Library

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `lib/core/screens/settings_screen.dart`
- Create: `lib/core/services/workflow_document_port.dart`
- Create: `lib/core/widgets/workflow_library_tab.dart`
- Create: `test/workflow_library_tab_test.dart`

**Interfaces:**
- Consumes: Tasks 1-2 endpoint/workflow APIs and Task 8 repository.
- Produces: injectable document-picker/export/browser ports plus the complete Workflows tab.

- [ ] **Step 1: Add picker/launcher dependencies and Android HTTPS visibility**

Add under dependencies:

```yaml
  file_picker: ^12.0.0
  url_launcher: ^6.3.2
```

Add `android.intent.action.VIEW` to the browser visibility query and include separate `http` and `https` data schemes. Run: `C:\src\flutter\bin\flutter.bat pub get`

Expected: package resolution succeeds and Android manifest merging accepts both schemes.

- [ ] **Step 2: Write endpoint and workflow-library widget failures**

```dart
testWidgets('invalid endpoint is not saved and test reports the reason', (tester) async {
  await tester.pumpWidget(settingsHarness(client: FakeComfyClient()));
  await tester.enterText(find.byKey(const Key('comfy-endpoint')), 'ftp://host');
  await tester.tap(find.text('Save'));
  expect(find.textContaining('HTTP or HTTPS'), findsOneWidget);
  expect(prefs.getString(ComfyUiPrefs.baseUrl), isNull);
});

testWidgets('import keeps source bytes and requires confirmed bindings', (tester) async {
  final documents = FakeWorkflowDocumentPort(importedBytes: workflowBytes);
  await tester.pumpWidget(workflowHarness(documents: documents));
  await tester.tap(find.text('Import workflow'));
  await tester.pumpAndSettle();
  expect(find.text('Confirm inputs'), findsOneWidget);
  expect(repository.savedWorkflows, isEmpty);
});
```

- [ ] **Step 3: Run widget tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\workflow_library_tab_test.dart test\comfyui_test.dart`

Expected: FAIL because strict settings state and workflow UI ports do not exist.

- [ ] **Step 4: Implement platform ports**

```dart
final class ImportedWorkflowDocument {
  const ImportedWorkflowDocument({required this.fileName, required this.bytes});
  final String fileName;
  final Uint8List bytes;
}

abstract interface class WorkflowDocumentPort {
  Future<ImportedWorkflowDocument?> pickJson();
  Future<void> saveJson({required String fileName, required Uint8List bytes});
}

abstract interface class ExternalUriLauncher {
  Future<bool> open(Uri uri);
}

abstract interface class UriClipboardPort {
  Future<void> copy(Uri uri);
}
```

`FilePickerWorkflowDocumentPort` accepts only one JSON file and enforces 5 MiB before decoding. The UI separately requests original-source bytes, validated working-graph bytes, or Hermes-sidecar bytes from the repository before calling `saveJson`. `UrlLauncherExternalUriLauncher` uses external-application mode; when it returns false, copy through `UriClipboardPort`. Keep all ports injectable in widget tests.

- [ ] **Step 5: Implement endpoint settings**

Parse with `ComfyEndpoint.parse` before saving. Show unconfigured, valid, invalid, testing, connected, and failed states. “Test connection” calls `checkConnection` and shows ComfyUI/device information without exposing secrets. Exempt literal loopback, RFC1918, RFC4193, link-local, and Tailscale/CGNAT hosts from the public-host warning; require explicit acknowledgement for every other plain-HTTP hostname/address. Preserve proxy paths, store a stable generated client ID, store no credentials/query headers, and provide “Open ComfyUI” plus copy-URI fallback. Tests cover every address class and no-handler launch.

- [ ] **Step 6: Implement the Workflows tab**

Provide saved workflow cards and import/paste actions. The editor must support name, Image/Video kind, automatic binding suggestions, explicit binding confirmation, binding role/control/default/range/choices, raw working-JSON edit on a duplicate draft, local validation, server validation, duplicate, export original, export working graph, export sidecar, delete, and test run. Invalid JSON/validation never replaces the last valid saved graph. First execution of each imported or materially changed content hash requires a trust confirmation naming the endpoint and hash; the confirmation is remembered for that hash only. Widget tests cover each rule.

- [ ] **Step 7: Run workflow/settings tests**

Run: `C:\src\flutter\bin\flutter.bat test test\workflow_library_tab_test.dart test\comfyui_test.dart`

Expected: PASS for import, paste, size rejection, binding confirmation, validation snapshots, source/working export, delete confirmation, endpoint validation, and injected launcher fallback.

- [ ] **Step 8: Commit workflow management UI**

```powershell
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml lib/core/screens/settings_screen.dart lib/core/services/workflow_document_port.dart lib/core/widgets/workflow_library_tab.dart test/workflow_library_tab_test.dart test/comfyui_test.dart
git commit -m "feat: add ComfyUI workflow library and endpoint setup"
```

---

### Task 10: Create Screen, Generation Forms, and Job Cards

**Files:**
- Create: `lib/core/screens/create_screen.dart`
- Create: `lib/core/widgets/generation_form.dart`
- Create: `lib/core/widgets/generation_job_card.dart`
- Create: `test/create_screen_test.dart`
- Create: `test/generation_form_test.dart`
- Create: `test/generation_job_card_test.dart`

**Interfaces:**
- Consumes: Task 8 repository streams, Task 9 workflow library.
- Produces: Image/Video/Workflows tab shell and binding-driven submission UI.

- [ ] **Step 1: Write tab, dynamic-form, and double-submit failures**

```dart
testWidgets('shows image video and workflows tabs', (tester) async {
  await tester.pumpWidget(createHarness(repository: FakeGenerationRepository()));
  expect(find.text('Image'), findsOneWidget);
  expect(find.text('Video'), findsOneWidget);
  expect(find.text('Workflows'), findsOneWidget);
});

testWidgets('submit is disabled until required bindings are valid', (tester) async {
  final repository = FakeGenerationRepository();
  await tester.pumpWidget(formHarness(workflow: requiredPromptWorkflow));
  final generate = find.widgetWithText(FilledButton, 'Generate');
  expect(tester.widget<FilledButton>(generate).onPressed, isNull);
  await tester.enterText(find.byKey(const Key('binding-prompt')), 'portrait');
  await tester.pump();
  expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
  await tester.tap(generate);
  await tester.tap(generate);
  expect(repository.submitCalls, 1);
});
```

- [ ] **Step 2: Run Create widget tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\create_screen_test.dart test\generation_form_test.dart test\generation_job_card_test.dart`

Expected: FAIL because the screens/widgets do not exist.

- [ ] **Step 3: Implement the Create shell**

```dart
final class CreateScreen extends StatefulWidget {
  const CreateScreen({
    super.key,
    required this.connection,
    this.initialTab = 0,
    this.repository,
    this.initialContext,
  });
  final SavedConnection connection;
  final int initialTab;
  final GenerationRepository? repository;
  final CharacterGenerationContext? initialContext;
}
```

Use a Material 3 `TabBar`/`TabBarView` with Image, Video, and Workflows. Image/Video tabs show configured workflows of the matching kind, an empty-state route to Workflows, the selected form, active jobs, history, and output actions. The app-scoped repository is required/injected; the screen never constructs or disposes it.

- [ ] **Step 4: Implement binding-driven forms**

`GenerationForm` renders widgets solely from confirmed bindings: text/multiline, integer/decimal with bounds, toggle, enum, and image picker. Prefill character appearance/reference values without overwriting user edits. Show the final composed positive prompt. Build an immutable `GenerationRequest`, validate required/range/choice/file-size rules, and hold an in-flight submit guard until the repository call returns.

- [ ] **Step 5: Implement job cards**

`GenerationJobCard` renders every durable state, node/progress when known, queued/running cancel actions with the correct confirmation, retry-as-new for failed/cancelled/uncertain jobs, reconcile status, errors/node errors, outputs, save/share, and image-only “Discuss in chat.” It must never label socket closure as success.

- [ ] **Step 6: Run Create widget tests**

Run: `C:\src\flutter\bin\flutter.bat test test\create_screen_test.dart test\generation_form_test.dart test\generation_job_card_test.dart`

Expected: PASS for tabs, workflow filtering, dynamic controls, validation, character prefills, prompt preview, submit guard, all job states, cancel confirmations, retry, and output actions.

- [ ] **Step 7: Commit Create UI**

```powershell
git add lib/core/screens/create_screen.dart lib/core/widgets/generation_form.dart lib/core/widgets/generation_job_card.dart test/create_screen_test.dart test/generation_form_test.dart test/generation_job_card_test.dart
git commit -m "feat: add image video and workflow creation tabs"
```

---

### Task 11: Drawer, Chat, Character Context, and Discuss-in-Chat Integration

**Files:**
- Modify: `lib/core/screens/session_list_screen.dart`
- Modify: `lib/core/screens/chat_screen.dart`
- Modify: `test/chat_screen_test.dart`

**Interfaces:**
- Consumes: `CreateScreen`, repository context/media methods, existing `PendingChatSend` attachment path.
- Produces: session-independent Create navigation and session-aware generation shortcuts.

- [ ] **Step 1: Write navigation/context/discuss failures**

```dart
testWidgets('drawer opens Create and chat opens it with character context', (tester) async {
  await tester.pumpWidget(appHarness(repository: repository));
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.tap(find.text('Create'));
  await tester.pumpAndSettle();
  expect(find.byType(CreateScreen), findsOneWidget);
});

testWidgets('chat Create media loads context and passes active connection/session', (tester) async {
  final repository = FakeGenerationRepository(contexts: {'session-1': characterContext});
  await tester.pumpWidget(chatHarness(repository: repository, sessionId: 'session-1'));
  await tester.tap(find.byTooltip('More options'));
  await tester.tap(find.text('Create media'));
  await tester.pumpAndSettle();
  final create = tester.widget<CreateScreen>(find.byType(CreateScreen));
  expect(create.initialTab, 0);
  expect(create.initialContext, characterContext);
  expect(create.connection.id, activeConnection.id);
});

testWidgets('discuss image prepares the existing multimodal draft without sending', (tester) async {
  await tester.pumpWidget(chatHarness(repository: repository));
  await repository.emitDiscussImage(imageAsset);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('pending-image-preview')), findsOneWidget);
  expect(fakeGateway.sendCount, 0);
});
```

- [ ] **Step 2: Run integration widget tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\chat_screen_test.dart test\create_screen_test.dart`

Expected: FAIL because the routes, context save, and Create result handling are absent.

- [ ] **Step 3: Add navigation**

Add a drawer `Create` destination above Memory. Add one `Create media` and one `Media` item to chat overflow actions. `ChatScreen._openCreate({int initialTab = 0})` awaits `repository.getCharacterContext(session.id)`, then passes the active `SavedConnection`, session-local context, initial tab, and app-scoped repository. An ordinary session passes null context. Do not pass raw credentials or place HTTP logic in widgets.

- [ ] **Step 4: Persist character generation context**

After a character card is loaded or a character session is created, compose a stable appearance snapshot from the authoritative card fields and save it for that session. Copy any available avatar/reference bytes into app support through `CharacterGenerationContextStore`; never retain a transient picker URI. Missing context must leave forms editable and unblocked.

- [ ] **Step 5: Reuse the existing chat attachment pipeline**

```dart
sealed class CreateScreenResult { const CreateScreenResult(); }
final class DiscussGeneratedImage extends CreateScreenResult {
  const DiscussGeneratedImage(this.asset);
  final MediaAsset asset;
}
```

On `DiscussGeneratedImage`, bounded-download the image, verify an image MIME type, set the existing `_pickedImageBytes`, `_pickedImageMimeType`, and data URL state, then return focus to the composer. Do not auto-send. Do not expose this action for video assets.

`GenerationJobCard` invokes an Image-tab callback; `CreateScreen` completes `Navigator.pop(context, DiscussGeneratedImage(asset))`. Test the result propagation separately from the ChatScreen attachment test.

- [ ] **Step 6: Run chat/Create tests**

Run: `C:\src\flutter\bin\flutter.bat test test\chat_screen_test.dart test\create_screen_test.dart`

Expected: PASS for drawer/overflow navigation, correct initial tab/context, context image ownership, image draft preparation, video exclusion, and zero automatic sends.

- [ ] **Step 7: Commit app integration**

```powershell
git add lib/core/screens/session_list_screen.dart lib/core/screens/chat_screen.dart test/chat_screen_test.dart test/create_screen_test.dart
git commit -m "feat: connect character chat to ComfyUI creation"
```

---

### Task 12: Global Media Library and Shared Generated-Media Views

**Files:**
- Create: `lib/core/widgets/generated_media_view.dart`
- Modify: `lib/core/screens/media_gallery_screen.dart`
- Modify: `lib/core/screens/chat_screen.dart`
- Modify: `lib/core/services/media_cache_service.dart`
- Modify: `lib/core/services/media_export_service.dart`
- Modify: `test/media_gallery_screen_test.dart`
- Modify: `test/chat_screen_test.dart`

**Interfaces:**
- Consumes: repository media stream and endpoint snapshots.
- Produces: global All/Images/Videos library and one shared media presentation path.

- [ ] **Step 1: Write global filtering, dedupe, and playback failures**

```dart
testWidgets('filters global image and video assets', (tester) async {
  final repository = FakeGenerationRepository(media: [imageAsset, videoAsset]);
  await tester.pumpWidget(mediaHarness(repository));
  expect(find.byKey(const Key('media-image')), findsOneWidget);
  expect(find.byKey(const Key('media-video')), findsOneWidget);
  await tester.tap(find.text('Videos'));
  await tester.pump();
  expect(find.byKey(const Key('media-image')), findsNothing);
  expect(find.byKey(const Key('media-video')), findsOneWidget);
});

testWidgets('starting a second video pauses the first', (tester) async {
  final coordinator = FakeGeneratedVideoCoordinator();
  await tester.pumpWidget(twoVideoHarness(coordinator));
  await tester.tap(find.byKey(const Key('play-video-1')));
  await tester.tap(find.byKey(const Key('play-video-2')));
  expect(coordinator.pausedIds, contains('video-1'));
});

testWidgets('source jump requires both session and message ids', (tester) async {
  await tester.pumpWidget(mediaHarness(FakeGenerationRepository(media: [
    imageAsset.copyWith(sourceSessionId: 's', sourceMessageId: 'm'),
    videoAsset.copyWith(sourceSessionId: 's', sourceMessageId: null),
  ])));
  expect(find.byTooltip('Open source message'), findsOneWidget);
});
```

- [ ] **Step 2: Run media tests and confirm failure**

Run: `C:\src\flutter\bin\flutter.bat test test\media_gallery_screen_test.dart test\chat_screen_test.dart`

Expected: FAIL because gallery data is transcript-only/images-only and media widgets are duplicated.

- [ ] **Step 3: Extract generated media presentation**

`GeneratedMediaView` owns image preview, stream-first video player, loading/error states, save/share/open/discuss actions, and controller disposal. A coordinator guarantees one active generated video player across the current screen. Preserve image decode-size optimization and lazy `media_kit` initialization.

- [ ] **Step 4: Replace transcript gallery with global media**

```dart
final class MediaGalleryScreen extends StatelessWidget {
  const MediaGalleryScreen({
    super.key,
    required this.repository,
    this.onOpenSourceMessage,
  });
  final GenerationRepository repository;
  final Future<void> Function(MediaAsset asset)? onOpenSourceMessage;
}
```

Render All/Images/Videos filters, newest first, job/workflow/source labels, endpoint-unavailable state, optional source-chat jump, delete-local-record/cache action, and no implied server deletion. Keep old endpoint snapshots usable after settings change.

- [ ] **Step 5: Backfill Gateway chat outputs**

On authoritative message refresh, pass parsed tool outputs to `upsertChatToolOutputs` with the endpoint snapshot, session ID, and source message ID. Retain legacy filename extraction but convert immediately to typed refs. Dedupe by endpoint plus filename/subfolder/type. When ComfyUI is unconfigured or migrated from the wildcard placeholder, show a Configure action instead of constructing a URL. Regression tests prove previously indexed media keeps its saved endpoint, same filenames from two endpoints remain distinct, direct-generation outputs never enter Gateway history, and local deletion optionally clears cache without any server delete request.

- [ ] **Step 6: Run media/chat tests**

Run: `C:\src\flutter\bin\flutter.bat test test\media_gallery_screen_test.dart test\chat_screen_test.dart test\media_cache_service_test.dart`

Expected: PASS for global filtering, endpoint-aware dedupe, one active video, stream-first playback, local-only delete, source navigation, chat backfill, and unconfigured fallback.

- [ ] **Step 7: Commit global Media**

```powershell
git add lib/core/widgets/generated_media_view.dart lib/core/screens/media_gallery_screen.dart lib/core/screens/chat_screen.dart lib/core/services/media_cache_service.dart lib/core/services/media_export_service.dart test/media_gallery_screen_test.dart test/chat_screen_test.dart test/media_cache_service_test.dart
git commit -m "feat: add global generated media library"
```

---

### Task 13: Protocol Integration, Documentation, and Live Verification

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `test/comfyui_protocol_fake_server_test.dart`
- Create: `integration_test/comfyui_generation_app_test.dart`
- Create: `tool/run_comfyui_live_verification.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: the complete production feature.
- Produces: fake-protocol coverage, repeatable real-server/device evidence, and setup instructions.

- [ ] **Step 1: Add the Flutter integration-test dependency**

```yaml
dev_dependencies:
  integration_test:
    sdk: flutter
```

Run: `C:\src\flutter\bin\flutter.bat pub get`

Expected: dependency resolution succeeds.

- [ ] **Step 2: Write a loopback ComfyUI protocol test and device app test**

In the VM test, use `HttpServer.bind(InternetAddress.loopbackIPv4, 0)` and `WebSocketTransformer.upgrade`. Serve a reverse-proxy prefix plus `/system_stats`, `/object_info`, `/upload/image`, `/prompt`, `/queue`, `/history/{promptId}`, `/interrupt`, and `/ws`. Script upload, one prompt acceptance, queued/running progress, image/video history outputs, node validation errors, cancellation, socket loss, server restart, and reconciliation. The device integration test pumps the real app shell with fakes and verifies Create navigation, persistence across widget/app restart, global Media, and image Discuss-in-chat.

- [ ] **Step 3: Run fake-server integration**

Run:

```powershell
C:\src\flutter\bin\flutter.bat test test\comfyui_protocol_fake_server_test.dart
C:\src\flutter\bin\flutter.bat test integration_test\comfyui_generation_app_test.dart -d <device-id>
```

Expected: the VM protocol test passes with one prompt POST, preserved prefix, typed progress, durable recovery, both media kinds, node errors, and cancellation semantics. The device test is run only with an explicit emulator/phone ID.

- [ ] **Step 4: Add the parameterized live-verification script**

```powershell
param(
  [Parameter(Mandatory)] [uri]$BaseUrl,
  [Parameter(Mandatory)] [string]$ImageWorkflow,
  [Parameter(Mandatory)] [string]$VideoWorkflow,
  [Parameter(Mandatory)] [string]$DeviceId,
  [string]$ReportPath = "build/comfyui-live-verification.json"
)
```

Validate explicit paths before reading/writing. Use an `Invoke-Adb` helper that always passes the explicit device ID. The JSON report schema contains `startedAtUtc`, sanitized `endpointOrigin`, `comfyVersion`, `objectInfoSha256`, `device.serial/model/sdk`, and `image/video` records with workflow SHA-256, required/missing node classes, schema model choices, local job ID, prompt ID, terminal state, output type/count, and gate status/error. Do not store prompts, workflow bodies, output filenames, credentials, or endpoint query strings. The script must never install nodes/models, mutate ComfyUI, or claim success without returned history outputs.

- [ ] **Step 5: Document setup and use**

Update README with endpoint configuration, HTTP/LAN warning, HTTPS/Tailscale recommendation, API-format workflow export from ComfyUI, import/binding confirmation, Image/Video generation, cancellation limits, uncertain jobs, global Media, Discuss in chat, cache/download ceilings, desktop browser escape hatch for node-graph editing, and the live verification command.

- [ ] **Step 6: Run the full repository gates**

Run:

```powershell
C:\src\flutter\bin\flutter.bat test
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat build apk --debug
```

Expected: all tests pass, analyzer reports no issues, and debug APK builds.

- [ ] **Step 7: Run device and real-ComfyUI gates when inputs exist**

Run:

```powershell
.\tool\run_comfyui_live_verification.ps1 -BaseUrl <explicit-http-or-https-uri> -ImageWorkflow <absolute-api-json> -VideoWorkflow <absolute-api-json> -DeviceId <adb-device-id>
```

Expected: the report proves connection, workflow validation, one image output, one video output, progress/reconnect, cancellation, persistence after relaunch, global Media, and image Discuss-in-chat. If any required endpoint/workflow/device is unavailable, record that gate as not run; do not infer live behavior from unit tests/builds.

- [ ] **Step 8: Commit integration and docs**

```powershell
git add pubspec.yaml pubspec.lock test/comfyui_protocol_fake_server_test.dart integration_test/comfyui_generation_app_test.dart tool/run_comfyui_live_verification.ps1 README.md
git commit -m "test: cover ComfyUI generation end to end"
```

---

## Final Verification Checklist

- [ ] `C:\src\flutter\bin\flutter.bat test`
- [ ] `C:\src\flutter\bin\flutter.bat analyze`
- [ ] `C:\src\flutter\bin\flutter.bat build apk --debug`
- [ ] No direct URL concatenation outside `ComfyEndpoint`.
- [ ] No automatic `POST /prompt` retry.
- [ ] Imported source bytes and unknown JSON fields round-trip.
- [ ] Nonterminal jobs survive process recreation and reconcile without resubmission.
- [ ] Videos remain stream-first and only one player runs per screen.
- [ ] Missing real server/device/workflow evidence is reported as not run.
