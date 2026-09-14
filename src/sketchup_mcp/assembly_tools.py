"""Structured assembly and Scene tools; no arbitrary code execution."""
from typing import Annotated, Literal
from pydantic import Field
from mcp.server.fastmcp import Context
from sketchup_mcp.app import mcp
from sketchup_mcp.tools import _call, EntityId
from sketchup_mcp.assembly_schema import (
    CameraSpec, VisibilityOverride, InstancePath, ParentPath, Paths, Matrix16, Finite,
)


@mcp.tool()
async def create_assembly(ctx: Context, name: Annotated[Annotated[str, Field(min_length=1)], Field(description='Meaningful assembly or Scene name')],
                          member_paths: Annotated[Paths, Field(description='Paths of existing parts to wrap, preserving world placement')], parent_path: Annotated[ParentPath, Field(description='Parent persistent-ID path; empty string means model root')] = "",
                          kind: Annotated[Literal["group", "component"], Field(description='Group or true component assembly')] = "group") -> str:
    """Wrap named parts into a nested group or true component, preserving world placement.

    Paths use persistent IDs separated by dots; parent_path='' means model root.
    Shared/locked ancestors and recursive destinations are rejected. Returns the
    assembly and old-to-new member paths; refresh descendant paths after moving.
    """
    return await _call(ctx, "create_assembly", name=name, member_paths=member_paths,
                       parent_path=parent_path, kind=kind)


@mcp.tool()
async def reparent_entities(ctx: Context, entity_paths: Annotated[Paths, Field(description='Paths of existing assemblies to move')], parent_path: Annotated[ParentPath, Field(description='Parent persistent-ID path; empty string means model root')],
                            preserve_world_transform: Annotated[bool, Field(description='Keep world placement when changing parents')] = True) -> str:
    """Move assemblies into a parent (empty path = root), keeping world placement by default.

    Rejects cycles, ancestor/descendant selections and shared/locked ancestors.
    Returns new paths; old entity IDs/descendant paths may change.
    """
    return await _call(ctx, "reparent_entities", entity_paths=entity_paths,
                       parent_path=parent_path, preserve_world_transform=preserve_world_transform)


@mcp.tool()
async def duplicate_component(ctx: Context, instance_path: Annotated[InstancePath, Field(description='Persistent-ID occurrence path from hierarchy inspection')],
                               name: Annotated[Annotated[str, Field(min_length=1)], Field(description='Meaningful assembly or Scene name')],
                               parent_path: Annotated[ParentPath, Field(description='Parent persistent-ID path; empty string means model root')] = "",
                               definition_mode: Annotated[Literal["unique", "shared"], Field(description='unique isolates the whole subtree; shared requires a component')] = "unique",
                               matrix_mm: Annotated[Matrix16 | None, Field(description='Absolute column-major affine matrix; translation entries 12..14 in mm')] = None) -> str:
    """Copy an assembly. Unique recursively isolates definitions; shared requires a component.

    matrix_mm is an optional absolute parent-space column-major affine matrix,
    translation entries 12..14 in mm. Otherwise preserve world placement.
    """
    args = dict(instance_path=instance_path, name=name, parent_path=parent_path,
                definition_mode=definition_mode)
    if matrix_mm is not None:
        args["matrix_mm"] = matrix_mm
    return await _call(ctx, "duplicate_component", **args)


@mcp.tool()
async def get_camera(ctx: Context) -> str:
    """Read world-space camera, projection, FOV axis, orthographic height and aspect ratios."""
    return await _call(ctx, "get_camera")


@mcp.tool()
async def set_camera(ctx: Context, camera: Annotated[CameraSpec | None, Field(description='Explicit world-space camera with distances in mm')] = None,
                     view_preset: Annotated[Literal["current", "front", "back", "left", "right", "top", "bottom", "iso"] | None, Field(description='Standard view direction, or current')] = None,
                     frame_paths: Annotated[Paths | None, Field(description='Persistent-ID assembly paths to frame')] = None,
                     projection: Annotated[Literal["perspective", "parallel"] | None, Field(description='Perspective or parallel projection')] = None,
                     margin: Annotated[Annotated[Finite, Field(ge=1, le=10)] | None, Field(description='Framing multiplier, 1..10')] = None) -> str:
    """Set an explicit camera OR a preset framed on specific assemblies, without changing geometry.

    Explicit camera and preset/framing options are mutually exclusive. Positions
    and parallel height use mm. FOV uses SketchUp's camera axis, returned by get_camera.
    """
    args = {k: v for k, v in dict(view_preset=view_preset, frame_paths=frame_paths,
                                  projection=projection, margin=margin).items() if v is not None}
    if camera is not None:
        if args:
            raise ValueError("camera cannot be combined with preset/framing/projection")
        args["camera"] = camera.model_dump()
    return await _call(ctx, "set_camera", **args)


@mcp.tool()
async def save_scene(ctx: Context, name: Annotated[Annotated[str, Field(min_length=1)] | None, Field(description='Meaningful assembly or Scene name')] = None,
                     scene_id: Annotated[EntityId | None, Field(description='Persistent Scene ID returned by list_scenes')] = None, camera: Annotated[CameraSpec | None, Field(description='Explicit world-space camera with distances in mm')] = None,
                     capture_current: Annotated[bool | None, Field(description='Recapture view settings; defaults true for new Scenes, false for updates')] = None,
                     visibility: Annotated[Annotated[list[VisibilityOverride], Field(max_length=500)] | None, Field(description='Scene object visibility overrides')] = None,
                     pose_paths: Annotated[Annotated[list[InstancePath], Field(max_length=500)] | None, Field(description='Paths whose local transforms are stored; empty list clears poses')] = None,
                     description: Annotated[Annotated[str, Field(min_length=1)] | None, Field(description='Description stored with the Scene')] = None,
                     transition_time: Annotated[Annotated[Finite, Field(ge=0)] | None, Field(description='Scene transition duration in seconds')] = None,
                     include_in_animation: Annotated[bool | None, Field(description='Include Scene in native animation')] = None) -> str:
    """Create a native Scene, or update exactly scene_id (persistent ID).

    New Scenes capture current camera/visibility/rendering; updates preserve
    existing settings unless capture_current=true. Visibility uses instance paths.
    pose_paths optionally stores LOCAL transforms for later structured activation;
    [] clears poses. Save each open/closed Scene with the same set of pose paths.
    """
    args = {k: v for k, v in dict(name=name, scene_id=scene_id, capture_current=capture_current,
                                  pose_paths=pose_paths, description=description,
                                  transition_time=transition_time,
                                  include_in_animation=include_in_animation).items() if v is not None}
    if scene_id is None and name is None:
        raise ValueError("name is required for a new Scene")
    if camera is not None:
        args["camera"] = camera.model_dump()
    if visibility is not None:
        args["visibility"] = [v.model_dump() for v in visibility]
    return await _call(ctx, "save_scene", **args)


@mcp.tool()
async def list_scenes(ctx: Context) -> str:
    """List native Scenes with persistent IDs, camera settings, active state and saved poses."""
    return await _call(ctx, "list_scenes")


@mcp.tool()
async def activate_scene(ctx: Context, scene_id: Annotated[EntityId, Field(description='Persistent Scene ID returned by list_scenes')]) -> str:
    """Activate a Scene without transition; restore its explicitly saved poses and report readiness."""
    return await _call(ctx, "activate_scene", scene_id=str(scene_id))


@mcp.tool()
async def delete_scene(ctx: Context, scene_id: Annotated[EntityId, Field(description='Persistent Scene ID returned by list_scenes')]) -> str:
    """Delete exactly one native Scene by persistent ID. Geometry is retained."""
    return await _call(ctx, "delete_scene", scene_id=str(scene_id))


@mcp.tool()
async def save_model(ctx: Context, path: Annotated[Annotated[str, Field(min_length=1)], Field(description='Absolute .skp master filename on the SketchUp host')],
                     overwrite: Annotated[bool, Field(description='Allow replacing an existing destination')] = False, expected_current_path: Annotated[str | None, Field(description='Exact expected active document path; empty means untitled')] = None) -> str:
    """Save the entire current model to an explicit absolute .skp master path.

    This establishes the working master (Save As), unlike export_scene's temp copy.
    Existing target files require overwrite=true. Optional expected_current_path
    guards against saving a different active document. Returns actual model path.
    """
    args = dict(path=path, overwrite=overwrite)
    if expected_current_path is not None:
        args["expected_current_path"] = expected_current_path
    return await _call(ctx, "save_model", **args)
