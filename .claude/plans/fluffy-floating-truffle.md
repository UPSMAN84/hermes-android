# ComfyUI-style node canvas for Workflows

**Status: all 5 stages implemented and verified (2026-08-21).** `flutter analyze`:
clean. `flutter test`: 464 passed, 2 skipped (pre-existing, unrelated), 0 failed.
One deliberate scope reduction from the original wording: the import-time
`_BindingConfirmationDialog` (name/kind + auto-suggested bindings, shown once right
after import) was kept as-is rather than also routed through the canvas -- it still
provides real value reviewing bulk auto-suggested bindings, and rewiring it risked
destabilizing already-well-tested import-flow tests for comparatively little gain.
"Edit bindings" (the primary post-import editing surface, for both graph shapes) and
"View graph" (also both shapes now) do route through the canvas, per plan.

## Context

Two problems came out of this session:

1. **Fixed already:** the "Generate" button could go permanently unclickable with zero
   explanation whenever an imported workflow's suggested bindings pointed at a node input
   that was actually a graph connection rather than a literal value (common for
   width/height/cfg/steps/seed driven by a shared/primitive node). Root-caused, fixed in
   `comfy_workflow_codec.dart` (`suggestBindings` now skips connection-valued inputs) and
   `generation_form.dart` (the disabled button now names the blocking field). Covered by a
   new regression test in `test/comfy_workflow_test.dart`. Verified: `flutter test` and
   `flutter analyze` both clean.

2. **This plan:** the "workflow builder" doesn't look or work like ComfyUI at all — it's a
   flat list of binding rows plus a raw-JSON textarea (`workflow_library_tab.dart`), and the
   app currently only accepts ComfyUI's **API-format** export (a flat `{class_type, inputs}`
   map with no node positions/titles/layout). You asked for the harder, more faithful path:
   import ComfyUI's **regular "Save" export** (nodes/links/positions/widget values) and
   render an actual pannable/zoomable node graph — titled boxes, typed sockets, wires — that
   looks like ComfyUI's own canvas, while keeping every existing saved workflow and the
   Image/Video "Generate" tabs working exactly as they do today.

This is a genuinely large, multi-file feature (new parsing, new rendering, a from-scratch
UI-format → API-format converter that has to replicate several ComfyUI frontend quirks). It's
staged so each stage ships something real and testable rather than landing as one giant change.

## Real sample files: findings (3 files inspected, 2026-08-21)

Inspected `DasiwaMinimaxH3WorkflowsT2VA_cMMH3V14 (1).json`, `krea2raw.json`,
`krea2turbo (2).json` (all frontendVersion 1.49.6) plus a search/fetch check against
ComfyUI/ComfyUI_frontend upstream. Confirmed and corrected against the original design:

- **Link arrays are exactly** `[id, origin_id, origin_slot, target_id, target_slot, type]` —
  the assumed shape was right, no surprises.
- **`widgets_values_named`** (a name→value dict alongside the positional array) is present on
  100% of widget-bearing nodes in all 3 files — but it's from `Comfy-Org/ComfyUI_frontend`
  PR #10392, merged **2026-07-30** (about 3 weeks before this file was written), and its
  *read-back* side ships behind a setting (`Comfy.Workflow.NamedValuesRestore`) that's
  **disabled by default**. Treat it as a nice-to-have accelerant when present — use it in
  preference to positional math when it's there — but it cannot replace the object_info-driven
  positional converter, since most workflow.json files in the wild (anything exported before
  ~July 2026, or from a frontend that hasn't shipped this yet) won't have it.
- **`PrimitiveInt`/`PrimitiveFloat`/`PrimitiveString`/`PrimitiveBoolean` are real, normal
  backend-registered nodes now** (`properties.cnr_id: "comfy-core"` in the samples), each with
  a genuine `/object_info` schema entry — they are **not** the old frontend-only generic
  `PrimitiveNode` construct that never reached `/object_info` at all. This removes the need for
  a primitive-inlining pre-pass entirely: these resolve through the normal per-node conversion
  path like any other node. (The old generic `PrimitiveNode` wasn't seen in any sample; if it
  ever shows up, it just falls into the ordinary `missing_class` path rather than getting
  special-cased.)
- **A bypassed (`mode == 4`) node in the wild had zero incoming and zero outgoing links** — a
  fully disabled/unused node, not a mid-chain feed-through. This is the common case: bypassing
  an optional branch in the ComfyUI UI produces exactly this. Refuse-to-convert should apply
  only when a bypassed node still has outgoing links that something downstream depends on (the
  true feed-through case); a bypassed node with no outgoing links is just dead weight and can
  be skipped silently, same as muted (`mode == 2`).
- **Confirmed real**: the "reconverted widget" case (an `inputs[]` entry with a `widget`
  marker object and `link: null`) exists in practice (seen on a rgthree "Use Everywhere"
  bundler node) — the fallback-to-widget-value branch designed for this is necessary, not
  speculative.
- **Real files carry organizational/annotation nodes with no executable backend class at all**
  (`MarkdownNote`, `Label (rgthree)`, and dynamically-UUID-typed rgthree bundler nodes).
  Tried a "skip if nothing depends on its output" leniency for these; a converter test caught
  that this is wrong -- a genuine sink/leaf node (`SaveImage`, `PreviewImage`, anything with no
  outputs at all) is *never distinguishable from a decorative node by graph shape alone*, so
  that heuristic would have silently dropped real, essential nodes. Reverted to the same rule
  the existing `validateObjectInfo` already uses for flat-format graphs: **every node missing
  from `/object_info` is an unconditional `missing_class` issue**, referenced or not. If
  annotation nodes turn out to need a "run anyway, ignore this decorative node" escape hatch in
  practice, that's a deliberate, explicit later feature -- not a silent default.

## Design decisions

- **Shape is detected, not stored.** A new `ComfyWorkflowCodec.shapeOf(graph)` distinguishes
  legacy flat API-format (today's only supported shape) from the new UI-format (`nodes` +
  `links` lists) by inspecting the JSON itself — no new persisted flag to drift out of sync.
- **Legacy workflows are untouched.** Every existing saved workflow keeps using today's exact
  code path (`applyBindings` → `client.submitPrompt`) byte-for-byte. All of `comfy_workflow_test.dart`
  and `generation_form_test.dart` must keep passing unmodified.
- **`WorkflowInputBinding` and `GenerationForm` don't change.** Both graph shapes address
  bindings the same way (`nodeId` + `inputName`); only *how* a binding's value gets applied
  differs internally.
- **UI-format submission needs a live ComfyUI endpoint.** Converting stored node/link data
  into the flat prompt ComfyUI's `/prompt` expects requires a fresh `/object_info` fetch
  (this mirrors a real constraint in ComfyUI's own frontend, not a shortcut). No reachable
  endpoint → clear `SubmissionFailed` job state, same UI failure path as today, not a crash.
- **Scope boundary: viewer + widget-value editor + binding manager, not a graph builder.**
  No adding/deleting nodes, no rewiring links from scratch — you still build/wire graphs in
  ComfyUI itself and import the result. Dragging a node (reposition), editing a widget's
  value, and tap-to-expose-as-app-control are the only mutations this canvas makes.
- **Hand-rolled canvas**, not a pub.dev node-editor package — this repo deliberately avoids
  adding dependencies unless clearly justified (see `pubspec.yaml`'s own comments), and
  `InteractiveViewer` + a `CustomPainter` for wires covers everything needed here.

## Stages

### Stage 1 — Parse & view (no schema, no submit changes)
Importing a real ComfyUI "Save" export stops being rejected and renders as a real
pan/zoom node canvas: correct positions, titled boxes, colored-by-type sockets, bezier
wires — read-only. Legacy flat workflows are unaffected.

- New `lib/core/models/comfy_ui_graph.dart` — `detectGraphShape`, `UiFormatGraph.parse`
  (also serves as the new shape's structural validator), `UiGraphNode`/`UiGraphSocket`/`UiGraphLink`.
- New `lib/core/widgets/workflow_canvas_layout.dart` — pure geometry (socket offsets,
  bounding box, bezier control points), unit-testable with no widget dependency.
- New `lib/core/widgets/workflow_socket_colors.dart` — type → color palette (ComfyUI's
  own conventional colors, grey fallback + badge for unknown custom types).
- New `lib/core/widgets/workflow_canvas.dart` — `WorkflowCanvas` (`InteractiveViewer` +
  node `Stack` + wire `CustomPainter`), view-only mode for this stage.
- Change `comfy_workflow_codec.dart`: `decode()` branches on `shapeOf()` instead of always
  calling `_requireGraphShape`.
- Change `workflow_library_tab.dart`: add a "View graph" action pushing the canvas.
- Tests: new `test/comfy_ui_graph_test.dart`; extend `test/comfy_workflow_test.dart` to
  accept a UI-format sample.

### Stage 2 — Live schema
Opening the canvas with a reachable endpoint fetches `/object_info` and swaps generic
`value[i]` labels for real widget names/types; nodes with no matching class on that
server are visibly flagged, individually, without blocking the rest of the canvas.

- Change `workflow_canvas.dart`: optional object-info fetch on `initState`, per-node
  degrade, manual "Refresh schema" action.
- Change `comfy_workflow_codec.dart`: reuse/extend `validateObjectInfo` for per-node
  canvas flags via the existing `WorkflowValidationIssue` model.

### Stage 3 — UI→API converter + submit-path integration (the hard part)
A UI-format workflow can actually be **run**. Conversion happens fresh at submit time
using live `/object_info`.

- New `lib/core/services/comfy_ui_graph_converter.dart` — `ComfyUiGraphConverter.convert(...)`.
  **Implemented and verified** (see below). Per node: skip muted (`mode==2`) nodes outright;
  for bypassed (`mode==4`) nodes, skip silently if they have no outgoing links (the common
  case — a disabled/unused branch), otherwise refuse with a named `unsupported_bypass` issue
  (true mid-chain feed-through needs graph rewiring, out of scope). Resolve `class_type` via
  `node.type` or the `properties['Node name for S&R']` fallback. `PrimitiveInt`/
  `PrimitiveFloat`/`PrimitiveString`/`PrimitiveBoolean` need no special casing — confirmed via
  real exports they're normal backend-registered nodes with real `/object_info` schemas,
  resolved like any other node. For each schema-declared input, in this order: (1) a real
  link, resolved via the `links` table — confirmed via a real ComfyUI bug report (Comfy-Org
  issue #7777) that a widget converted to a connected input is removed from `widgets_values`
  entirely, so a live link never consumes a positional slot; (2) a bound override; (3)
  `widgets_values_named` by name, when the node carries that field (confirmed present on
  recent ComfyUI exports, but never assumed — most workflow.json files won't have it yet);
  (4) positional `widgets_values`, walking `/object_info`'s required→optional order and
  **advancing two slots instead of one** past any input whose schema options carry a
  truthy/string `control_after_generate` flag (confirmed a real, schema-visible field via
  search, not actually invisible as first assumed) for the synthetic companion widget. An
  `inputs[]` entry with a `widget` marker and `link: null` (reconverted, confirmed real) falls
  into the same widget-value path as (3)/(4). **Every node whose class is missing from
  `/object_info` is an unconditional `missing_class` issue** — a "skip if nothing depends on
  it" leniency was tried and reverted: a converter test caught that it silently drops genuine
  sink/leaf nodes (no outputs at all, like `SaveImage`), which are indistinguishable from
  decorative ones by graph shape alone. This matches the existing `validateObjectInfo`'s
  behavior for flat-format graphs. Exposes `resolveNodeInputs(...)` as the one shared
  implementation of this resolution order (Stage 4 reuses it — never re-derive it separately).
- Change `generation_repository.dart`: `submit()` branches on `shapeOf()`; UI-format path
  fetches `/object_info`, converts, and on failure reduces to `SubmissionFailed` exactly
  like today's `applyBindings` `StateError` path already does.
- Change `comfy_workflow_codec.dart`: `applyBindings` becomes an explicit no-op for
  UI-format graphs (application now happens inside the converter via `overrides`).
- Tests: new `test/comfy_ui_graph_converter_test.dart` covering the control-after-generate
  offset, PrimitiveNode fan-out, reconverted-widget, missing-class, bypass-refusal, and
  unwired-required-socket cases; extend the repository/submit test suite with a UI-format
  end-to-end submit against a fake client.

### Stage 4 — Tap-to-bind + inline value editing
Tapping a widget row creates/edits/removes a `WorkflowInputBinding` for that
`(nodeId, inputName)` (reusing the same fields `_EditableBinding` already edits today, just
triggered per-widget instead of from a bulk list). Editing a value without binding it writes
straight into the stored graph — flat `inputs[name]`, or the correct `widgets_values` index
via the exact same `resolveNodeInputs` helper from Stage 3.
Hit-testing is restricted to widget rows only — sockets are never tap targets — which is
what mechanically enforces "no rewiring," not just policy.

- Change `workflow_canvas.dart`: add bind mode, `onBindingChanged`/`onValueEdited` callbacks.
- Change `comfy_workflow_codec.dart`: `updateUiGraphWidgetValue(...)` and
  `updateFlatGraphInput(...)`.
- Change `workflow_library_tab.dart`: import/"Edit bindings" now push the canvas in bind
  mode instead of `_BindingConfirmationDialog`; that dialog's field-editing logic becomes
  the content of the per-widget popover rather than being deleted.
- Tests: widget tests for tap→binding and value-edit→mutated-graph, both shapes.

### Stage 5 — Unify & harden
One canvas-based editing surface for both shapes. Legacy flat graphs get simple
insertion-order grid auto-layout (no stored `pos`) so they render on the same canvas too.
Raw-JSON edit becomes a clearly-labeled "Advanced" escape hatch rather than the primary
path. Full regression pass to confirm the legacy path is still byte-for-byte unaffected.

## Risks called out explicitly (handle, don't hide)

- `control_after_generate` positional drift is the single highest-probability silent-
  corruption bug when `widgets_values_named` isn't available — mitigated by the dedicated,
  tested skip-branch in Stage 3, and sidestepped entirely when the name-keyed field is
  present.
- Custom node types missing from a given server's `/object_info` are always a named
  `missing_class` issue for that node (no "skip if unreferenced" leniency — see above), but
  degrade per-node, never block the whole canvas from rendering/viewing.
- A bypassed node with no outgoing links is skipped silently (the common real-world case);
  only true mid-chain feed-through bypass is refused with a clear message in V1, not silently
  mis-converted.
- `widgets_values` occasionally serializes as a dict instead of a list for dynamic-input
  nodes — `UiFormatGraph.parse` must degrade that node, not crash the whole parse. (Confirmed
  distinct from, and in addition to, the newer `widgets_values_named` field.)
- `widgets_values_named` availability depends on a very recent (2026-07-30) frontend PR and a
  restore setting that's off by default — never treat its presence as guaranteed; the
  positional/object_info converter remains the primary, required path.
- Storage layer (`workflow_store.dart`, `atomic_json_store.dart`) needs **no changes at any
  stage** — confirmed it only compares canonical JSON/source-hash and never assumes a shape.

## Verification per stage

- `flutter test` for the new/extended test files listed above, plus the full existing suite
  (`test/comfy_workflow_test.dart`, `test/generation_form_test.dart`, and whatever covers
  `generation_repository.dart`) to confirm zero regression on the legacy path.
- `flutter analyze` clean on all new/changed files.
- Manual check on-device for Stage 1/2 (visual layout matches ComfyUI reasonably) and
  Stage 3 (an actual imported UI-format workflow runs to completion against a real
  ComfyUI endpoint) before moving to the next stage.
