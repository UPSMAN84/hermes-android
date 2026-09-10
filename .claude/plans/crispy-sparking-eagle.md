# Simplify the workflow editor: drop the node canvas, flat-only downstream of import

## Context

The just-shipped ComfyUI-style node canvas (`workflow_canvas.dart` + `_layout` + `_socket_colors`,
`comfy_ui_graph.dart`, `comfy_ui_graph_converter.dart` — ~4000 lines total, plan doc
`fluffy-floating-truffle.md`) is a hand-rolled clone of ComfyUI's own graph editor: pan/zoom,
bezier wires, typed sockets, live `/object_info` schema resolution, and a converter that
replicates several ComfyUI-frontend-internal quirks (positional `widgets_values` walking,
`control_after_generate` slot-skipping, `widgets_values_named` preference, bypass/mute handling)
to turn ComfyUI's native "Save" export into the flat `{class_type, inputs}` format actually POSTed
to `/prompt`. Nearly all of that complexity exists to faithfully render/re-derive a graph shape the
app doesn't otherwise need — `GenerationForm` only ever reads `workflow.bindings`, never the graph
shape itself.

Goal: a much simpler editor. Confirmed with you:
- Drop the visual node canvas entirely — no pan/zoom/wires/sockets, no "View graph" action, no
  read-only stand-in.
- Normalize every imported workflow to **flat API-format at import time**. A native "Save" export
  (UI-format) runs through the existing `ComfyUiGraphConverter.convert` **once, at import** (needs
  a live ComfyUI endpoint); ComfyUI's "Export (API)" format imports exactly as it does today, zero
  network. Downstream of import (editing, submit), the app only ever sees flat graphs —
  `ComfyGraphShape.uiFormat` never appears past the import step.
- Replace the canvas-based post-import editor with one plain scrollable list screen: grouped by
  node, one row per input, always-editable literal value + an "expose as app control" toggle that
  reveals the binding fields (label/role/control type/required/min/max/choices). This is the one
  place today's two separate, ~130-line-duplicated implementations (`_EditableBinding` at import,
  `_WidgetEditDialog` in the canvas) get unified.
- No migration for any already-saved UI-format `workingGraph` — confirmed greenfield, safe to
  require re-import.
- Accepted trade-off: today's per-submit UI-format re-fetch of `/object_info` doubles as informal
  drift detection (catches server-side schema/model changes since import). Moving conversion to
  import-time-only gives that up in favor of the existing, separate "Validate against server"
  action, which is unaffected by this change and remains the supported way to catch drift.

## New widget: `lib/core/widgets/workflow_binding_editor.dart`

Full-screen (`Navigator.push`, not a dialog — a fixed-width dialog doesn't scale to a row per
literal input across a large graph). Local-state batch editor, one explicit "Save" action —
**not** a live per-edit callback like the canvas's `onValueChanged`/`onWidgetTap`, since a
higher row count would turn per-edit repository writes into a write storm for no benefit.

```dart
class WorkflowBindingEditorResult {
  final String? name;                        // only when showNameAndKind
  final ComfyMediaKind? kind;                 // only when showNameAndKind
  final JsonObject graph;                     // flat graph with row edits applied
  final List<WorkflowInputBinding> bindings;  // built from exposed rows only
}

class WorkflowBindingEditorScreen extends StatefulWidget {
  const WorkflowBindingEditorScreen({
    required this.graph,               // already-flat JsonObject
    required this.initialBindings,     // suggestBindings() result, or workflow.bindings
    required this.title,
    this.showNameAndKind = false,
    this.initialName,
    this.initialKind,
  });
}
```

- **Rows**: walk `graph.entries` (skip metadata keys, existing convention), then each node's
  `inputs`, skipping connection-valued entries entirely (no rewiring UI). Requires promoting
  `ComfyWorkflowCodec._isConnection` → public `isConnectionValue` (used internally today, now
  also by this widget) instead of re-deriving the same 2-line predicate a third time.
- **Row fields**: one "Value" text field (doubles as literal graph value and, when exposed, the
  binding's `defaultValue` — both existing implementations already conflate these, not a new
  behavior) + an "Expose as app control" checkbox revealing label/role/control-type/required/
  min+max (numeric)/choices (enum), mirroring `_WidgetEditDialog`'s reveal-on-toggle (collapsed by
  default matters once row counts are in the hundreds). A row starts exposed iff `initialBindings`
  has a matching `(nodeId, inputName)`.
- **Grouping**: collapsible section per node, header `"$classType (#$nodeId)"`, default-expanded.
- **Search/filter**: one text field, matches input name / row label / class_type, case-insensitive;
  force-expands matching groups while active, restores prior collapse state when cleared. Nothing
  beyond this — no other new UI surface.
- **Save-time mutation**: deep-copy `graph` once up front, mutate the copy in place per row inline
  (not via `updateFlatGraphInput` in a loop — that helper deep-copies the whole graph per call).
- Light inline validation before Save enables: required-and-empty blocks; numeric min > max, or
  value outside min/max, blocks; enum control type with empty choices blocks. Matches the fields
  the model already carries — not new scope, just not letting the editor save a broken binding.

## File-by-file

**Delete entirely**: `lib/core/widgets/workflow_canvas.dart`,
`lib/core/widgets/workflow_canvas_layout.dart`, `lib/core/widgets/workflow_socket_colors.dart`,
`test/workflow_canvas_test.dart`. Confirmed no importers outside `workflow_library_tab.dart` and
their own tests.

**`lib/core/models/comfy_ui_graph.dart`** — delete `flatGraphToUiFormat` and its private
layout-only helpers (canvas-only display code); keep `ComfyGraphShape`/`detectGraphShape`,
`UiGraphSocket`/`UiGraphNode`/`UiGraphLink`, `UiFormatGraph.parse` — still needed as the one-shot
import-time parser feeding the converter. Leave `pos`/`size` fields alone (parsed-but-unread after
this change; touching the constructor for a cosmetic-only cleanup isn't worth the risk here).

**`lib/core/services/comfy_ui_graph_converter.dart`** — keep `convert`/`resolveNodeInputs`/
`resolveClassType` as-is, fully reused, just called from a new call site. Delete
`widgetValueIndex` — its only caller (`updateUiGraphWidgetValue`) is being deleted, and it has no
test coverage of its own, so this is zero-risk cleanup, not required.

**`lib/core/services/comfy_workflow_codec.dart`**:
- Delete `updateUiGraphWidgetValue` (needed live `/object_info`, canvas-only).
- Simplify `applyBindings`: delete the UI-format no-op early-return — `workingGraph` is flat by
  construction downstream of import now, so the flat-apply logic becomes unconditional.
- Rename `_isConnection` → public `isConnectionValue`.
- Unchanged: `decode`, `shapeOf`, `updateFlatGraphInput`, `suggestBindings`, `validateLocal`,
  `validateObjectInfo` — all already flat-shape-native; `suggestBindings` will now always run
  against a flat graph, incidentally fixing today's latent gap where calling it directly on a
  freshly-decoded native UI-format import silently produces zero suggestions.

**`lib/core/services/generation_repository.dart`**:
- Add `Future<GraphConversionResult> normalizeImportedGraph(JsonObject graph)` (interface method
  near `fetchObjectInfo`, impl replacing `_convertUiFormatGraph`). Flat input passes through
  unchanged, zero network. UI-format input: no reachable endpoint → `ConversionFailed` with a
  clear `no_endpoint` message ("connect to ComfyUI, or re-export using ComfyUI's Export (API)
  format instead"); `getObjectInfo()` failure → `ConversionFailed('object_info_unavailable')`;
  otherwise `UiFormatGraph.parse` + `ComfyUiGraphConverter.convert(overrides: const {})` (no
  bindings exist yet at import time — suggested *after* this call, against the resulting flat
  graph). Reuses the existing `GraphConversionResult`/`ConvertedPrompt`/`ConversionFailed`/
  `WorkflowValidationIssue` types unchanged — no new error shape.
- Simplify `submit()`: delete the shape branch — `applyBindings`'s output is already flat, so
  `client.submitPrompt(graph)` is called directly.
- Delete `_convertUiFormatGraph` (fully superseded).

**`lib/core/widgets/workflow_library_tab.dart`**:
- Delete `_viewGraph` + the "View graph" button/wiring, `_WorkflowBindScreen`, `_WidgetEditDialog`/
  `_WidgetEditResult`, the role/control-type inference helpers, `_BindingConfirmationDialog`/
  `_BindingConfirmationResult`/`_EditableBinding`.
- Rewrite `_startDraft`: after `ComfyWorkflowCodec.decode`, call `normalizeImportedGraph`; on
  failure show the joined issue messages via the existing banner pattern; on success compute
  `suggestBindings` against the flat result and push `WorkflowBindingEditorScreen(showNameAndKind:
  true, ...)`; on a non-null result, save the `ComfyWorkflowDefinition` with `workingGraph:
  result.graph` (still hashing/storing the *original* uploaded bytes for trust purposes, unchanged).
- Rewrite `_editBindings`: push `WorkflowBindingEditorScreen(showNameAndKind: false, graph:
  workflow.workingGraph, initialBindings: workflow.bindings, ...)`; on a non-null result, persist
  `workingGraph`/`bindings` in one save call, same pattern `_editRawGraph` already uses.
- `_RawGraphEditDialog`/`_editRawGraph`: untouched, out of scope.

**`lib/core/widgets/generation_form.dart`**: no changes — already shape-agnostic, reads only
`workflow.bindings`.

## Tests

- Delete `test/workflow_canvas_test.dart` entirely.
- `test/comfy_ui_graph_test.dart`: delete the `flatGraphToUiFormat` group; keep `parse`/
  shape-detection tests.
- `test/comfy_ui_graph_converter_test.dart`: unchanged, stays fully valid.
- New `test/workflow_binding_editor_test.dart`: one row per literal input grouped by node;
  connection-valued inputs produce no row; value edits land in `result.graph`; expose-toggle
  reveals/hides binding fields and controls `result.bindings` membership; search/filter narrows by
  name/label/class_type and restores collapse state on clear; per-node collapse is independent;
  required/min-max/choices validation blocks Save; `showNameAndKind` true/false; pre-population
  parity for both the import (`suggestBindings`) and edit (`workflow.bindings`) cases; Cancel
  discards edits with no repository interaction.
- `test/workflow_library_tab_test.dart`: keep the endpoint-settings and export/delete/validation
  groups unchanged. Adapt the flat-format import test to the new screen's controls; add two new
  import tests (UI-format import succeeds and reaches the editor pre-populated via `suggestBindings`
  on the converted graph; UI-format import with no reachable endpoint shows the `no_endpoint`/
  `object_info_unavailable` banner instead of opening the editor). Delete the "View graph" test and
  the saved-UI-format-workflow edit-binding tests (no longer reachable post-import, greenfield);
  replace with flat-graph-only versions of the same three behaviors (inline edit without binding,
  expose a widget, expose an enum/dropdown with real choices) against the new screen.

## Rollout order (keep the app buildable/green at each step)

1. Promote `isConnectionValue`; add `normalizeImportedGraph` + its own tests; add
   `workflow_binding_editor.dart` + its own tests. Old canvas/dialogs still wired up and working.
2. Cut over `_startDraft` to `normalizeImportedGraph` → `WorkflowBindingEditorScreen`; delete the
   old import-time dialog; update import tests.
3. Cut over `_editBindings`; delete `_WorkflowBindScreen`/`_WidgetEditDialog`/inference helpers/
   "View graph"; rewrite the corresponding library-tab tests.
4. Delete the three canvas files, `flatGraphToUiFormat`, `updateUiGraphWidgetValue`, the
   `submit()` shape branch, `_convertUiFormatGraph`, optionally `widgetValueIndex`; sweep imports.
5. `flutter analyze` (catches any straggler reference to a deleted symbol) + full `flutter test`.

## Verification

- `flutter analyze` clean after each rollout step, especially step 5.
- `flutter test` full suite green at each step; new/adapted test files listed above cover the
  behavior changes directly.
- Manual on-device check: import a flat "Export (API)" workflow (zero-network path unchanged),
  import a native "Save" export against a live ComfyUI endpoint (new one-shot conversion), edit
  bindings on each, run a generation end-to-end for both.
