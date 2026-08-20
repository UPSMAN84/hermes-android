# ComfyUI Generation and Workflow Tabs — Design Spec

**Date:** 2026-08-20
**Project:** Hermes Android (Flutter)
**Status:** Approved in chat; awaiting written-spec review

## Problem framing

Hermes Android can already display image and video files produced by the
Gateway's `image_generate` and `video_generate` tools. The chat pipeline sends
the current turn to the Gateway, receives SSE tool progress, extracts an output
filename, and renders the file through ComfyUI's `/view` route. The app also
already has disk caching, image display, `media_kit` video playback, and
save/share actions.

The app cannot yet submit a workflow directly to ComfyUI, monitor a generation
as a typed job, upload workflow inputs, or save reusable workflow definitions.
Generation is available only indirectly through an agent tool call, and media
discovery depends on parsing filenames from text tool results.

Add one `Create` destination with three tabs:

1. **Image** — run a saved image workflow with character-aware inputs.
2. **Video** — run a saved video workflow with character-aware inputs.
3. **Workflows** — import, configure, validate, duplicate, export, and test
   ComfyUI API-format workflows.

This is a direct local-ComfyUI feature. It does not require a Hermes Gateway
change and does not replace the existing chat-tool generation path.

## Goals

- Make image and video generation deterministic and usable without prompting
  the chat agent to call a tool.
- Reuse the app's current ComfyUI endpoint, media cache, image renderer, video
  player, and export actions.
- Let users keep arbitrary installed custom nodes by preserving imported
  API-format workflow semantics and retaining the original source bytes.
- Expose selected workflow inputs as mobile-friendly controls.
- Prefill generation from the active character when Create is opened from a
  character chat.
- Track queued, running, completed, failed, cancelled, and uncertain jobs.
- Resume known jobs after navigation, WebSocket loss, or app restart.
- Keep the current Gateway chat path working unchanged.

## Non-goals for v1

- A native drag-and-drop node canvas.
- Reimplementing the ComfyUI frontend or custom-node JavaScript extensions.
- Comfy Cloud support, account authentication, or billing.
- Installing models or custom nodes from the phone.
- Automatically generating a valid workflow for every ComfyUI installation.
- Uploading generated videos as multimodal Gateway chat attachments.
- Changing Hermes Gateway tool schemas or persistence.
- Exposing ComfyUI directly to the public internet.

## Chosen approach

Use a direct `ComfyUiClient` behind a typed `GenerationRepository`.

The client uses the local ComfyUI HTTP/WebSocket API to inspect nodes, upload
inputs, submit an API-format prompt graph, receive execution events, query
history, retrieve outputs, and cancel work. The repository owns job state,
workflow mutation, persistence, reconnect/reconciliation, and media indexing.
Screens depend on the repository rather than HTTP, WebSocket, or JSON details.

The Workflows tab is an API-JSON editor and binding mapper, not a graph canvas.
Users create an app workflow by importing ComfyUI's **API-format** JSON, naming
it, choosing Image or Video, and mapping node inputs to semantic controls such
as prompt, seed, width, height, frames, FPS, and reference image. An advanced
raw-JSON editor is available on a duplicated draft; invalid JSON or a graph
that fails validation cannot replace the saved version.

The store retains the original imported bytes separately from the parsed
working graph. An unedited workflow can be exported byte-for-byte. After a JSON
edit, export uses the validated working graph; unknown fields remain, but
formatting, object-key order, duplicate keys, and numeric spelling are not
promised to survive parse and serialization.

For full visual node editing, **Open in ComfyUI** launches the configured server
in the device browser. The user then exports API-format JSON and imports it back
into Hermes Android. The app does not embed a WebView in v1.

### Rejected alternatives

- **Native Flutter node canvas:** rejected because arbitrary node and custom
  widget parity would duplicate the rapidly changing ComfyUI frontend and is a
  poor primary phone UX.
- **Embedded ComfyUI WebView:** rejected for v1 because desktop graph controls,
  custom-node frontend code, authentication, mixed-content policy, and version
  drift create a large second application surface inside Hermes Android.
- **Hidden chat messages that ask the agent to generate:** rejected because a
  form-driven tab needs structured inputs, stable job IDs, deterministic
  cancellation, and machine-readable outputs.
- **Gateway proxy endpoints:** useful later for authenticated remote use, but
  rejected for v1 because the phone can already reach ComfyUI `/view` and a
  proxy would require coordinated changes outside this repository.

## Existing code to reuse

- `lib/core/services/comfyui.dart`: endpoint normalization, media extension
  classification, and `/view` URL construction. Its output reference must be
  expanded from a filename to `filename + subfolder + type`.
- `lib/core/services/media_cache_service.dart`: bounded disk cache and in-flight
  request coalescing. Its current whole-response buffering must be replaced by
  a counted streamed download before this feature accepts arbitrary outputs.
- `lib/core/services/media_export_service.dart`: Share and Save to Gallery.
- `lib/core/screens/chat_screen.dart`: image/video widgets, `media_kit` playback,
  character-session launch point, and current tool-result media handling.
- `lib/core/screens/media_gallery_screen.dart`: starting point for the unified
  Media screen.
- `lib/core/services/foreground_service_lease.dart`: shared foreground-service
  ownership while a submitted generation is being observed in the background.
- `http`, `path_provider`, `shared_preferences`, `image_picker`, and `media_kit`
  dependencies already in `pubspec.yaml`.

## UX design

### Navigation

- Add **Create** to the session-list drawer above Memory.
- `CreateScreen` uses `DefaultTabController` with Image, Video, and Workflows.
- Add **Create media** to the chat app-bar overflow. It opens Create with the
  current connection, session, character generation context, and initial tab.
- Rename the current Gallery presentation to **Media** and add All, Images, and
  Videos filters. Keep source-session navigation where a source message exists.

### Image and Video tabs

Each generation tab contains:

- ComfyUI connection status and a shortcut to endpoint settings.
- Workflow selector filtered by media kind.
- Character-context toggle when a character context is available.
- Prompt and negative-prompt fields when those bindings exist.
- Dynamic controls generated from the workflow's saved bindings.
- Optional image picker when an input-image binding exists.
- Generate button with a submission guard preventing double taps.
- Current and recent job cards with queue/running state, node progress, output
  previews, error details, retry-as-new, cancel, share, save, and Open in Media.

An empty workflow selector explains how to export an API-format workflow from
ComfyUI and links to the Workflows import action. The app ships no checkpoint-
or custom-node-specific workflow in v1 because installed models and video node
packs differ between servers.

### Workflows tab

Workflow cards show name, Image/Video kind, validation state, mapped controls,
last successful run, and last validated server fingerprint.

Actions:

- Import one `.json` file through the native document picker.
- Paste API-format JSON.
- Duplicate before editing.
- Rename and change Image/Video classification.
- Auto-suggest common bindings, then require user confirmation.
- Add, edit, reorder, or remove bindings.
- View/edit advanced JSON on a draft.
- Validate locally and against the configured ComfyUI server.
- Test Run using the same repository as the Image/Video tabs.
- Export the preserved API JSON plus a separate Hermes binding sidecar.
- Delete with confirmation.
- Open the configured ComfyUI frontend in the external browser.

Workflow import/export uses `file_picker`; external frontend launch uses
`url_launcher`. Android manifest visibility covers both `http` and `https`
browser intents. If no browser can handle the URI, the app shows the copyable
URI instead of treating the launch as successful.

## Workflow contract

### Canonical graph

The canonical executable graph is a JSON object keyed by node ID. Each node
must contain a string `class_type` and an `inputs` object. This is ComfyUI's
API format, not the frontend canvas/workflow serialization format.

The imported graph is immutable at rest. Before every run, the repository:

1. deep-copies the graph;
2. resolves saved input bindings;
3. uploads selected source images if required;
4. writes only the mapped `nodeId/inputName` values into the copy;
5. validates the copy;
6. submits the copy.

Unknown nodes and unknown inputs are preserved. The app never drops or rewrites
an unrecognized field merely because the current server cannot describe it.

The original import bytes and their hash are stored alongside the parsed
working graph. Byte-exact preservation applies to source export; validation and
execution use the parsed graph.

### Workflow definition

`ComfyWorkflowDefinition` contains:

- stable local ID;
- user-facing name;
- media kind: `image` or `video`;
- validated working API-format graph;
- ordered list of `WorkflowInputBinding` records;
- import source filename and content hash;
- created/updated timestamps;
- most recent server-validation fingerprint and result;
- optional last successful job ID.

The server fingerprint is SHA-256 over the normalized endpoint plus the
canonicalized `/object_info` response. Changing endpoint or node definitions
invalidates the prior server-validation result without altering the workflow.

`WorkflowInputBinding` contains:

- stable binding ID;
- node ID and input name;
- user label and help text;
- semantic role: prompt, negative prompt, seed, width, height, steps, CFG,
  frames, FPS, input image, or custom;
- control type: text, multiline text, integer, decimal, toggle, enum, or file;
- optional default, minimum, maximum, step, and enum choices;
- whether the field is required.

Bindings are a Hermes overlay and are not injected into exported ComfyUI API
JSON. Export writes `workflow.json` and `workflow.hermes.json` separately.

### Validation

Local validation rejects malformed JSON, a non-object root, missing
`class_type`, missing `inputs`, an invalid binding target, unsupported binding
types, and graph files above the configured import size ceiling.

Server validation fetches `/object_info`, then reports:

- missing node classes;
- missing mapped input names;
- primitive type/enum/range mismatches where the node schema exposes them;
- missing model choices only when the node schema exposes them as enum values;
- changed node definitions since the last validation.

`POST /prompt` remains the authoritative execution validation. Its top-level
error and per-node `node_errors` are preserved and shown with node IDs and
class names.

## Character integration

The current character setup is persisted to the Gateway as a hidden setup
message, while the app keeps only limited local session presentation metadata.
The media tabs therefore need a small local `CharacterGenerationContext` saved
when a character session is created.

It contains:

- session ID and character name;
- editable appearance/prompt snapshot derived from the card description;
- an app-owned copy of the avatar/reference image when available;
- created/updated timestamps.

The source picker URI or temporary cache path is never retained as the durable
reference. The image is copied into the character-context record directory and
removed when that context is deleted.

Opening Create from a character chat preselects this context. Enabling **Use
character context** prefixes the appearance snapshot to the user's prompt and
offers the avatar through an input-image binding. The final composed prompt is
always visible and editable before submission. Existing sessions without a
saved context simply open with blank character fields.

Generated jobs store the source session and character-context IDs. Output is
indexed in Media but is not automatically inserted into Gateway chat history.
For images, **Discuss in chat** downloads the output and reuses the current
multimodal image-attachment send path. Video chat attachment remains out of
scope.

## ComfyUI client contract

`ComfyUiClient` provides typed operations:

- `checkConnection()` using `/system_stats` and `/object_info`;
- `getObjectInfo()`;
- `uploadImage()` using multipart `/upload/image` and the server-returned
  filename/subfolder/type;
- `submitPrompt()` using `/prompt` with a stable installation `client_id`;
- `watchExecution()` using `/ws?clientId=...`;
- `getQueue()` and `deleteQueuedPrompt()` using `/queue`;
- `interrupt()` using `/interrupt`;
- `getHistory(promptId)` using `/history/{prompt_id}`;
- `buildViewUri(ComfyOutputRef)` using `/view`;
- `openFrontend()` using the configured base URI.

The WebSocket URI uses `ws` for HTTP and `wss` for HTTPS. All messages are
filtered by `prompt_id` when present. Supported events include status,
execution start, cached nodes, executing node, progress, executed output,
execution success, execution error, and interruption.

Completion is confirmed by `execution_success` or history containing completed
outputs. A socket close alone is never treated as success.

Output discovery recursively accepts only maps containing a safe filename and
an allowlisted `type` (`output`, `temp`, or `input`), with optional subfolder.
The response content type and extension classify the asset as image or video.
URI construction uses `Uri` query parameters; raw path fragments are never
concatenated into a filesystem path.

Official protocol references:

- <https://docs.comfy.org/development/comfyui-server/comms_routes>
- <https://docs.comfy.org/development/comfyui-server/comms_messages>
- <https://docs.comfy.org/development/core-concepts/workflow>
- <https://github.com/Comfy-Org/ComfyUI/blob/master/script_examples/websockets_api_example.py>

## Job model and state machine

`GenerationJob` contains local job ID, optional ComfyUI prompt ID, workflow ID,
media kind, source session/character IDs, submitted values, server endpoint
fingerprint and normalized base-URI snapshot, timestamps, progress, current
node, output references, and error.

`MediaAsset` contains a stable local ID, job or chat-message source, media kind,
the endpoint snapshot, filename, subfolder, Comfy file type, content type,
optional dimensions/duration, cache state, and timestamps. Its identity key is
`endpoint + filename + subfolder + type`, preventing duplicate cards while
keeping identical filenames from different servers distinct. Changing the
active ComfyUI endpoint does not break existing asset URLs.

States:

```text
draft -> submitting -> queued -> running -> succeeded
                    \-> failed
queued/running -> cancelling -> cancelled/succeeded/failed/reconciling
submitting/socket-loss -> reconciling -> queued/running/succeeded/failed
submitting without prompt_id after process death -> uncertain
```

- `/prompt` is never automatically retried. A timeout may mean ComfyUI accepted
  the graph even though the response was lost; retrying could duplicate work.
- WebSocket disconnect moves a known prompt to reconciliation, not failure.
- Reconciliation queries history and queue with bounded backoff.
- A queued prompt can be removed by prompt ID.
- Interrupting a running prompt affects shared ComfyUI execution. The UI warns
  the user before calling `/interrupt` and explains that another client may be
  using the server.
- Cancellation is confirmed from queue/history or an interruption event. A
  concurrent success remains succeeded, an execution error remains failed, and
  lost cancellation status moves to reconciliation rather than being labelled
  cancelled optimistically.
- Retry always creates a new local job and requires a user action.

## Persistence

No database dependency is required for v1. Use `path_provider` and atomic JSON
files under the app-support directory:

```text
comfyui/
  workflows/<workflow-id>.json
  workflows/<workflow-id>.source.json
  workflows/<workflow-id>.hermes.json
  jobs/<local-job-id>.json
  media/<asset-id>.json
  character-contexts/<session-id>.json
  character-contexts/<session-id>/reference-image
  index.json
```

Writes use a temporary sibling file followed by rename. The in-memory
repository serializes writes per record and rebuilds `index.json` by scanning
record files if the index is missing or corrupt. Workflow and job reads have
explicit size ceilings. SharedPreferences remains limited to the ComfyUI base
URL, stable client ID, and small UI preferences.

The Media screen is repository-backed and global, not built from one
transcript. It includes direct-generation outputs and lazily upserts chat-tool
outputs whenever an authoritative transcript is loaded. A source link is shown
only when session and message IDs are known. Removing a Media record optionally
clears its local cache entry but never deletes the ComfyUI server file. Deleting
a job does not implicitly delete its Media records.

On app start and Create-screen entry, nonterminal jobs with prompt IDs are
reconciled. A job left in `submitting` without a prompt ID becomes `uncertain`;
the app does not silently resubmit it.

## Endpoint and security rules

- Preserve every explicitly stored ComfyUI endpoint except the literal
  placeholder `http://0.0.0.0:8188`. A missing value or that placeholder
  migrates to an unconfigured state. Create stays disabled until validation
  succeeds; chat media shows a Configure ComfyUI action instead of constructing
  an unusable URL. Existing configured chat media continues using its saved
  endpoint. Migration and both chat fallbacks require regression tests.
- Accept only HTTP or HTTPS base URIs with an authority and optional port/path.
  Reject user-info, query, and fragment components. Preserve an explicitly
  configured reverse-proxy path when appending routes, and construct every HTTP
  and WebSocket endpoint with `Uri` rather than string concatenation.
- Show a clear warning for plain HTTP outside loopback, RFC1918, RFC4193,
  link-local, or Tailscale/CGNAT literal addresses. Plain-HTTP hostnames require
  explicit acknowledgement because the app cannot prove their network scope.
- Recommend a trusted LAN, VPN/Tailscale, or HTTPS proxy that does not require
  app-supplied credentials. Do not encourage direct public exposure of
  ComfyUI.
- Do not store Comfy Cloud keys or arbitrary request headers in v1.
- Imported workflows are executable server programs. Show a trust warning and
  require confirmation before the first run of each imported content hash.
- Never embed app credentials, Gateway credentials, or endpoint secrets in
  exported workflow JSON.
- Default hard limits are 5 MiB workflow JSON, 25 MiB uploaded input after
  image processing, 32 MiB JSON response, and 2 MiB WebSocket text message.
  Binary WebSocket previews are ignored in v1. HTTP connect timeout is 10 s;
  API response/idle timeout is 30 s. Generation runtime has no total timeout.
- Media downloads use `http.Client.send`, reject an over-limit declared
  `Content-Length`, count every received chunk, abort if a missing or false
  length crosses the limit, and delete the partial temporary file. Automatic
  image caching is capped at 50 MiB. Video is stream-first and is not
  automatically cached. Manual Save requires confirmation for an unknown size
  or a declared size above 512 MiB and still uses counted streaming.
- Redact prompt text, workflow JSON, endpoint query strings, and filenames from
  normal logs unless verbose diagnostics are explicitly enabled.

## Failure handling

| Failure | User-visible behavior |
|---|---|
| Endpoint unreachable | Preserve draft; show tested URI and timeout/refusal reason |
| `/object_info` unavailable | Imported graph remains saved but cannot be marked server-valid |
| Missing custom node/schema-enumerated model | Show node ID/class or missing enum choice; block Generate |
| Upload rejected | Keep selected local input; show server response; allow explicit retry |
| Prompt validation error | Show top-level error and expandable per-node errors |
| Prompt submission timeout | Mark uncertain; never automatic retry |
| WebSocket disconnect | Show reconnecting; reconcile through queue/history |
| Queued cancellation | Remove that prompt ID and mark cancelled after queue confirmation |
| Running cancellation | Warn about shared-server interrupt, then reconcile final state |
| App killed during run | ComfyUI continues; restore and reconcile known prompt ID on launch |
| Output missing/unsupported | Keep successful job metadata; show raw output keys in diagnostics |
| Media download too large | Keep remote output reference; do not cache or decode automatically |
| Corrupt local record | Quarantine that record, rebuild index, preserve other workflows/jobs |

## Files and boundaries

Expected new files:

- `lib/core/models/comfy_workflow.dart`
- `lib/core/models/generation_job.dart`
- `lib/core/models/media_asset.dart`
- `lib/core/models/character_generation_context.dart`
- `lib/core/services/comfyui_client.dart`
- `lib/core/services/comfyui_socket.dart`
- `lib/core/services/workflow_store.dart`
- `lib/core/services/media_asset_store.dart`
- `lib/core/services/generation_repository.dart`
- `lib/core/screens/create_screen.dart`
- `lib/core/widgets/generation_form.dart`
- `lib/core/widgets/generation_job_card.dart`
- focused unit/widget tests matching those units

Expected modified files:

- `lib/core/services/comfyui.dart`
- `lib/core/screens/session_list_screen.dart`
- `lib/core/screens/chat_screen.dart`
- `lib/core/screens/settings_screen.dart`
- `lib/core/screens/media_gallery_screen.dart`
- `lib/core/services/media_cache_service.dart`
- `android/app/src/main/AndroidManifest.xml` for HTTP and HTTPS browser intent visibility
- `pubspec.yaml` for `file_picker` and `url_launcher`

The existing `ChatScreen` must not absorb ComfyUI submission, workflow storage,
or job-state logic. It receives only navigation results and reusable media
actions from the repository.

## Testing strategy

### Unit tests

- Base/path-preserving HTTP and WebSocket URI construction.
- Endpoint rejection for missing authority, user-info, query, and fragment.
- API-format JSON parsing and local validation.
- Immutable workflow binding application.
- Unknown-field/custom-node preservation through import/export.
- `/object_info` binding validation and fingerprint invalidation.
- Multipart upload response parsing.
- `/prompt` success, validation failure, timeout, and no-auto-retry behavior.
- WebSocket event decoding/filtering and completion semantics.
- Queue/history reconciliation and job state transitions.
- Cancellation races with success, failure, interruption, and socket loss.
- Output-reference safety, media classification, and size limits.
- Declared, missing, and false `Content-Length` streaming-limit behavior.
- Endpoint snapshotting and cross-server media deduplication.
- Atomic record writes, index rebuild, and corrupt-record quarantine.
- Character prompt composition without mutating the saved context.

### Widget tests

- Create drawer entry and Image/Video/Workflows tab routing.
- Empty workflow state and import flow.
- Dynamic form controls from saved bindings.
- Generate double-submit guard.
- Progress, reconnecting, error, uncertain, completed, and cancel UI.
- Workflow draft validation prevents replacing a valid saved version.
- Character context prefill and visible final composed prompt.
- Media All/Image/Video filters and one-active-video behavior.
- HTTP/HTTPS external launch and no-handler copy-URI fallback.

### Integration tests

- Fake ComfyUI HTTP/WebSocket server covering upload, prompt, progress, history,
  output, disconnect/reconnect, node validation errors, and cancellation.
- Real local ComfyUI image workflow: import, bind, submit, render, save/share.
- Real local ComfyUI video workflow: submit, background, resume, play, save/share.
- Missing custom-node workflow produces a precise blocked validation state.
- App restart during a running known prompt restores and reconciles the job.

Repository tests and analyzer prove app behavior only. Final delivery also
requires a real ComfyUI run and Android-device checks for background execution,
large media, memory pressure, and video codec playback.

The live image/video gate is environment-qualified because v1 ships no
model-specific workflow. Its verification artifact records the sanitized
API-workflow JSON and SHA-256, ComfyUI version, `/object_info` fingerprint,
required node classes, model filenames, device, and observed outputs so another
matching environment can reproduce the run.

## Acceptance criteria

- Create is reachable from the drawer and a character chat.
- Image and Video tabs can run a validated saved workflow without a chat-agent
  tool call.
- Workflows can be imported, duplicated, bound, validated, test-run, exported,
  and deleted without losing unknown JSON fields.
- Missing nodes/inputs and schema-enumerated model choices block submission with
  actionable node-level errors. Dynamic/free-form model paths remain subject to
  authoritative `/prompt` validation.
- A submitted job has a stable local record and, once returned, a Comfy prompt
  ID; double taps and automatic submission retries cannot duplicate it.
- Progress and completion survive ordinary WebSocket reconnects.
- Known jobs reconcile after app restart; unknown submissions are never silently
  retried.
- Image and video outputs use the existing cache/player/export path and appear
  in Media.
- Changing the configured ComfyUI endpoint does not break previously indexed
  media, and deleting a Media record never deletes its server file.
- Character Create launch visibly prefills editable character context.
- Existing Gateway chat streaming and tool-generated media continue to work.
- Analyzer, full Flutter tests, fake-server integration tests, real ComfyUI image
  and video runs, and Android-device media/background checks pass before release.

## Implementation sequence

1. Models, URI rules, workflow parsing/binding, and atomic stores.
2. Fake-server-tested HTTP/WebSocket client and job state machine.
3. Workflow import, mapping, validation, export, and test-run UI.
4. Image and Video generation forms and job cards.
5. Drawer/chat navigation and character-generation context persistence.
6. Unified Media image/video index and existing media action reuse.
7. Background/restart reconciliation, security limits, and error polish.
8. Real ComfyUI and Android-device verification.
