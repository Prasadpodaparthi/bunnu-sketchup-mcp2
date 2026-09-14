# Structured assemblies and Scenes

This extension adds ten typed tools without replacing the existing 24 tools.
All geometry changes use explicit handlers, not the Ruby evaluation tool.
Changes are implemented in the source checkout. Deploy the Python/Ruby pair
together before using the new tools; updating Python alone does not install the
SketchUp extension. This implementation was tested outside SketchUp, using
in-memory API doubles; it has not been exercised against a live document.

## Identity and coordinates

Legacy `id` values remain SketchUp `entityID` values. New `instance_path` values
contain **persistent IDs**, joined with dots, from the model root to the target.
Use `list_components(include_hierarchy=true)` to discover paths. Do not construct
paths by concatenating legacy IDs. `parent_path=""` explicitly means model root.
Omitting `parent_path` on an old creation tool retains its original active-edit-
context behavior. Explicit parents ignore the UI editing context.

Hierarchy results include `persistent_id`, `instance_path`, `parent_path`,
`definition_id`, `transform_local_mm`, `transform_world_mm`, and world bounds.
`get_component_info(instance_path=...)` resolves exactly one occurrence of a
shared definition. `get_selection(include_hierarchy=true)` includes the current
editing path. Concise hierarchy queries retain occurrence identifiers.

Matrices contain 16 numbers in SketchUp's column-major order. Entries 12, 13,
and 14 are translations in millimeters. The last row must be `[0,0,0,1]` and the
linear part must be invertible. Distances otherwise use mm; angles use degrees.
World matrices include the entire parent transformation chain.

## Assembly tools

| Tool | Required input | Behavior |
|---|---|---|
| `create_assembly` | `name`, nonempty `member_paths` | Wrap existing parts into a named `group` or true `component`; optional `parent_path` defaults to root. Preserves world placement. |
| `reparent_entities` | `entity_paths`, `parent_path` | Move groups/components to another parent. World placement is preserved unless `preserve_world_transform=false`. |
| `duplicate_component` | `instance_path`, `name` | Copy to `parent_path`; `definition_mode="unique"` recursively isolates definitions. `"shared"` requires a component source. Optional `matrix_mm` is absolute parent-space placement. |

The source objects are not flattened or unioned. Reparenting may recreate
instances, so responses contain old-to-new member references and
`refresh_descendant_paths=true`. Refresh the subtree after structural changes.
Materials, tags, names, hidden state, shadow properties, and instance attributes
are copied. Reparenting an object to its existing parent is a no-op.

Create parts explicitly at root first, then group them bottom-up. Empty placeholder
groups are not required. `create_component`, `create_circle`, and `create_curve`
also accept `parent_path` and `coordinate_space="parent"|"world"` to add later parts
to an existing assembly. World-space creation compensates transformed parents.

New mutation paths reject locked instances and shared ancestors. Changing a child
of a shared definition could affect another furniture instance, so this fails
before an operation starts. The engine does not silently make existing ancestors
unique. A top-level shared component can instead be duplicated with `unique` mode.
Ancestor/descendant selections, self-parenting, recursive definitions, stale
paths, and singular matrices are rejected. Each structured mutation is one
operation and aborts on failure. No unrelated model entities are cleared.

## Transforms

Old `transform_component(id, position, rotation, scale)` behavior is unchanged:
position is absolute bounding-box minimum; rotation/scale are relative about the
bounding-box center. Advanced arguments select the new path-aware handler:

- `instance_path` identifies the exact occurrence; `id`, if also provided, must match.
- `coordinate_space` is `parent` (default), `world`, or `local`.
- `translation_mm` is relative translation in that space.
- `axis`, `angle_degrees`, and optional `pivot_mm` support hinge rotations.
- `rotation` remains sequential XYZ rotation; do not combine it with axis/angle.
- `pivot_mm` also controls scaling. Without it, use the bounding-box center.
- `matrix_mm` restores an absolute parent/world transform; it cannot be combined
  with relative operations or `position`, and does not accept local space.

Composition order is rotation, scale, translation, then absolute bbox-min
position. Bare legacy IDs with advanced arguments must resolve to exactly one
occurrence. The response reports the resulting world bounds and matrices.

## Cameras, Scenes, and capture

| Tool | Behavior |
|---|---|
| `get_camera` | Read world-space eye/target/up, projection, FOV and its axis, parallel height, and aspect ratios. |
| `set_camera` | Set `camera` explicitly, or use `view_preset`, `frame_paths`, `projection`, and `margin`. Explicit camera and preset/framing options are mutually exclusive. |
| `save_scene` | Create with `name`, or update exactly `scene_id`. Updates preserve settings unless `capture_current=true`. Supports description, visibility overrides, transition time, animation inclusion, and optional pose capture. |
| `list_scenes` | Return persistent Scene IDs in native order, settings, active state, and stored poses. |
| `activate_scene` | Select a native Scene with zero transition, restore stored poses, refresh, and return readiness. |
| `delete_scene` | Delete a single Scene without deleting geometry. |

Camera input contains `eye_mm`, `target_mm`, `up`, `projection`, and either
`fov_degrees` or `height_mm`. FOV is in SketchUp's native camera axis, reported by
`get_camera`; supported range is 1..120 degrees. Two-point perspective/match-photo
camera restoration is rejected. Framing uses only requested assembly bounds and
fits both viewport dimensions, including portrait viewports.

New Scenes capture camera, object/tag visibility, and rendering options. Other
native Scene properties (section cuts, axes, shadow settings, hidden raw geometry,
style selection, environment) are disabled on newly created Scenes. Updating an
existing Scene preserves its unrelated native flags. Saving a Scene never moves
geometry or changes live object visibility.

Native Scenes do not store instance positions. Optional `pose_paths` stores the
selected instances' local matrices as Scene attributes. Capture the same set of
paths for every closed/open/exploded Scene. An empty list clears stored poses;
omitting the argument preserves them. Scene activation and native Scene-tab
selection restore these poses. Observers attach on extension load/model activation
but never apply poses merely because a model was opened. Stale/shared/locked pose
targets are rejected before any pose is applied. After structural reparenting,
refresh the affected Scenes' pose paths.

`get_viewport_screenshot` retains its legacy parameters and adds `scene_id`,
`camera`, `frame_paths`, `projection`, and `margin`. Scene capture cannot be combined
with camera/framing overrides. Explicit capture rejects `zoom_extents` because it
would override the requested framing. The result includes effective camera data.
Scene capture supports the camera/visibility/rendering Scene properties above;
unsupported native flags fail explicitly rather than produce a misleading image.

Restoring captures roll back temporary pose/visibility changes and restore camera
state. Failures restore state even when `restore_view=false`. Successful
non-restoring captures commit their changes. Structured captures are not replayed
automatically after uncertain transport failures. Native Scene selection is not
changed during screenshot capture.

## One explicit master file

`save_model(path, overwrite=false, expected_current_path=None)` saves the entire
active document to an absolute `.skp` filename and establishes it as the working
master. The destination directory must exist; existing files require explicit
overwrite. `expected_current_path` is an exact active-document guard, with `""`
representing an untitled document. Failure is reported and the actual resulting
model path is returned on success. Geometry is not filtered or reconstructed.

`export_scene` retains its original temporary-export semantics. Neither Scene
creation nor view capture creates additional SketchUp model files.

## Tests and implementation boundaries

Run `python -m pytest tests/ -p no:cacheprovider` and `ruby test/run_all.rb`.
The Ruby suite needs `minitest` and `rubyzip`. New tests use real matrix math with
in-memory SketchUp doubles; save tests never write a valid `.skp` file. Existing
transport tests use mocks/local fake servers and never target the SketchUp port.
No live smoke scripts are part of this upgrade's verification.

Tests cover schema rejection and forwarding, persistent occurrence paths,
transformed/shared parents, hinge pivots, idempotent matrix restoration, retained
unrelated entities, reparenting, recursive unique duplication, camera framing,
Scene pose/visibility behavior, native tab callbacks, capture restoration, and
explicit save guards. The existing package test recognizes newly registered
handler files without requiring staging, while still rejecting stray files.
