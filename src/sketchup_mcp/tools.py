"""FastMCP tool handlers for SketchUp.

Most tools are thin wrappers that delegate to :func:`_call`, which centralises
connection acquisition, error handling, and response unwrapping; a few
(`eval_ruby`, `get_viewport_screenshot`) use :func:`_raw_call` directly.
"""
import base64
import json
import logging
from typing import Annotated, Literal, Optional

from mcp.server.fastmcp import Context, Image
from pydantic import AfterValidator, Field

from sketchup_mcp.assembly_schema import InstancePath, ParentPath, Paths, Matrix16, Vector3, Finite, CameraSpec
from sketchup_mcp import compat, config
from sketchup_mcp.app import mcp
from sketchup_mcp.connection import get_connection
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError, format_error

logger = logging.getLogger("sketchup_mcp.tools")

# T-06: Ñ…ÐµÐ½Ð´Ð»ÐµÑ€Ñ‹ Ð²Ð¾Ð·Ð²Ñ€Ð°Ñ‰Ð°ÑŽÑ‚ id ÐºÐ°Ðº JSON-Ñ‡Ð¸ÑÐ»Ð¾ (entity.entityID), Ð° ÑÑ…ÐµÐ¼Ñ‹
# Ñ‚Ñ€ÐµÐ±Ð¾Ð²Ð°Ð»Ð¸ ÑÑ‚Ñ€Ð¾Ð³Ð¾ str â€” Ð¼Ð¾Ð´ÐµÐ»ÑŒ, Ð¾Ñ‚Ð´Ð°ÑŽÑ‰Ð°Ñ {"id": 12345} Ð¾Ð±Ñ€Ð°Ñ‚Ð½Ð¾ ÐºÐ°Ðº int,
# Ð¿Ð¾Ð»ÑƒÑ‡Ð°Ð»Ð° ValidationError (ÐºÐ»Ð¸ÐµÐ½Ñ‚ÑÐºÐ°Ñ ÐºÐ¾ÑÑ€Ñ†Ð¸Ñ ÑÑ‚Ð¾ Ñ‡Ð°ÑÑ‚Ð¾ Ð¼Ð°ÑÐºÐ¸Ñ€ÑƒÐµÑ‚, Ð½Ð¾
# Ð¿Ñ€ÑÐ¼Ð¾Ð¹ call_tool â€” Ð½ÐµÑ‚). ÐŸÑ€Ð¸Ð½Ð¸Ð¼Ð°ÐµÐ¼ Ð¾Ð±Ð° Ñ‚Ð¸Ð¿Ð°; Ð½Ð° Ð¿Ñ€Ð¾Ð²Ð¾Ð´ ÑƒÑ…Ð¾Ð´Ð¸Ñ‚ str(id),
# wire-Ñ„Ð¾Ñ€Ð¼Ð°Ñ‚ Ð½ÐµÐ¸Ð·Ð¼ÐµÐ½ÐµÐ½ (Ruby require_id Ð¿Ð°Ñ€ÑÐ¸Ñ‚ ÑÑ‚Ñ€Ð¾ÐºÑƒ).
# P-05: int-Ð²ÐµÑ‚ÐºÐ° Ð¡Ð¢Ð ÐžÐ“ÐÐ¯ â€” bool ÑÐ²Ð»ÑÐµÑ‚ÑÑ Ð¿Ð¾Ð´ÐºÐ»Ð°ÑÑÐ¾Ð¼ int, Ð¸ Ð±ÐµÐ· strict
# True Ñ‚Ð¸Ñ…Ð¾ ÐºÐ¾ÑÑ€ÑÐ¸Ð»ÑÑ Ð±Ñ‹ Ð² id "1" (Ð²Ð°Ð»Ð¸Ð´Ð½Ð°Ñ Ð¾Ð¿ÐµÑ€Ð°Ñ†Ð¸Ñ Ð½Ð°Ð´ Ñ‡ÑƒÐ¶Ð¾Ð¹ ÑÑƒÑ‰Ð½Ð¾ÑÑ‚ÑŒÑŽ
# Ð¸Ð· Ð¼ÑƒÑÐ¾Ñ€Ð½Ð¾Ð³Ð¾ Ð²Ñ‹Ð·Ð¾Ð²Ð°). Ð¡Ñ‚Ñ€Ð¾ÐºÐ° "3" Ð¿Ñ€Ð¸ ÑÑ‚Ð¾Ð¼ ÑÐ¿Ð¾ÐºÐ¾Ð¹Ð½Ð¾ Ð¿Ñ€Ð¾Ñ…Ð¾Ð´Ð¸Ñ‚ str-Ð²ÐµÑ‚ÐºÐ¾Ð¹.
# T-05: description Ð·Ð°Ð¿ÐµÑ‡Ñ‘Ð½ Ð² alias â€” Ð²ÑÐµ Ð´ÐµÐ²ÑÑ‚ÑŒ id-Ð¿Ð°Ñ€Ð°Ð¼ÐµÑ‚Ñ€Ð¾Ð² Ð¿Ð¾Ð»ÑƒÑ‡Ð°ÑŽÑ‚
# ÐµÐ´Ð¸Ð½Ñ‹Ð¹ LLM-Ð²Ð¸Ð´Ð¸Ð¼Ñ‹Ð¹ Ñ‚ÐµÐºÑÑ‚ Ð¿Ð¾ Ð¿Ð¾ÑÑ‚Ñ€Ð¾ÐµÐ½Ð¸ÑŽ.
EntityId = Annotated[
    Annotated[int, Field(strict=True)] | Annotated[str, Field(min_length=1)],
    Field(description="Entity ID from a previous response (integer or its string form)"),
]


def _validate_scale_nonzero(v: list[float]) -> list[float]:
    # T-17 (Ð·ÐµÑ€ÐºÐ°Ð»Ð¾ Ruby): |s| <= 1e-9 â€” ÑÐ¸Ð½Ð³ÑƒÐ»ÑÑ€Ð½Ð°Ñ Ð¼Ð°Ñ‚Ñ€Ð¸Ñ†Ð°; SU2026
    # Transformation#inverse Ð½Ð° Ð½ÐµÐ¹ ÐºÐ¸Ð´Ð°ÐµÑ‚ ArgumentError.
    for i, s in enumerate(v):
        if abs(s) <= 1e-9:
            raise ValueError(f"scale[{i}] must be non-zero (|s| > 1e-9)")
    return v


async def _raw_call(ctx: Context, tool_name: str, /, **kwargs) -> dict:
    """Acquire the connection and execute one tools/call.

    Returns the raw MCP-shaped result dict
    (``{"content": [...], "isError": False}``).

    ``tool_name`` is positional-only (PEP 570) so wrappers can forward
    user kwargs containing a ``name`` key via ``**args`` without
    colliding with this parameter â€” see ``find_components`` /
    ``create_layer`` callers below for the pattern.

    Does **not** translate :class:`ConnectionError` to anything â€” that
    is each caller's responsibility, since callers have divergent
    strategies for unavailable-server (string-returning tools surface a
    graceful string, Image-returning tools raise). Centralising the
    conversion here would introduce brittle string-based detection in
    callers and lose the canonical error text shared by the 22 existing
    text-returning tools.

    See the design's Â§5.8 for the rationale on error-handling asymmetry
    between text-returning and Image-returning tools.
    """
    sketchup = await get_connection()
    # ConnectionError Ð¿Ñ€Ð¸ Ð½ÐµÐ´Ð¾ÑÑ‚ÑƒÐ¿Ð½Ð¾Ð¼ SketchUp Ð¿Ð¾Ð´Ð½Ð¸Ð¼Ð°ÐµÑ‚ send_command
    # (Ð»ÐµÐ½Ð¸Ð²Ñ‹Ð¹ connect Ð¿Ð¾Ð´ conn._lock, T-08), Ð½Ðµ get_connection â€” callers
    # Ð»Ð¾Ð²ÑÑ‚ ÐµÑ‘ ÐºÐ°Ðº Ñ€Ð°Ð½ÑŒÑˆÐµ.
    return await sketchup.send_command(tool_name, kwargs)  # raises SketchUpError


def _extract_text(result: object) -> str:
    """Unwrap a Ruby handler's MCP content envelope to its text payload.

    Both :func:`_call` and the ``eval_ruby`` tool share the same response
    shape â€” ``{"content": [{"text": ...}], ...}``. Falls back to a JSON
    dump for any result that isn't a well-formed text-content envelope.
    """
    content = result.get("content") if isinstance(result, dict) else None
    if (
        isinstance(content, list)
        and content
        and isinstance(content[0], dict)
        and "text" in content[0]
    ):
        return content[0]["text"]
    return json.dumps(result)


async def _call(ctx: Context, tool_name: str, /, **kwargs) -> str:
    """Dispatch a tool call to SketchUp and shape the response for Claude.

    Same external contract as before â€” kept for compatibility with the 22
    existing string-returning tools. Now delegates to :func:`_raw_call`
    for connection acquisition and converts the result to a string.
    Connection failures surface as the canonical legacy string so the LLM
    sees a stable, actionable hint.
    """
    try:
        result = await _raw_call(ctx, tool_name, **kwargs)
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        # Locally-raised transport errors (timeout, stale socket, oversize)
        # carry no `tool` in data â†’ format_error would render `tool=?`.
        # Backfill it from the tool name; setdefault never overrides a
        # Ruby-origin error that already carries its own `tool`.
        e.data.setdefault("tool", tool_name)
        return format_error(e, debug=config.LOG_LEVEL == "DEBUG")
    return _extract_text(result)


@mcp.tool()
async def create_component(
    ctx: Context,
    type: Annotated[
        Literal["cube", "cylinder", "cone", "sphere"],
        Field(description="Primitive type to create"),
    ] = "cube",
    position: Annotated[
        list[float],
        Field(min_length=3, max_length=3,
              description="Bounding-box MIN corner [x, y, z] in mm (not the center)"),
    ] = [0, 0, 0],
    dimensions: Annotated[
        list[Annotated[float, Field(ge=0.1)]],
        Field(min_length=3, max_length=3,
              description="Sizes [x, y, z] in mm; cylinder/cone use "
                          "[0]=diameter, [2]=height; sphere uses [0]=diameter"),
    ] = [100, 100, 100],
    name: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Optional name for the new group so "
                          "find_components can locate it later"),
    ] = None,
    parent_path: Annotated[ParentPath | None, Field(description='Parent persistent-ID path; empty string means model root')] = None,
    coordinate_space: Annotated[Literal["parent", "world"] | None, Field(description='Coordinate frame; creation requires explicit parent_path')] = None,
) -> str:
    """Create a primitive (cube / cylinder / cone / sphere) in SketchUp.

    All linear values are millimeters (mm). Minimum size per dimension:
    0.1 mm for cube (thin stock like veneer is fine), 1.0 mm for sphere /
    cylinder / cone (tessellated types degenerate earlier). position is the
    bounding-box MIN corner (not the center); the same anchor is used by
    transform_component.position. Per-type dimensions: cube uses [x, y, z];
    cylinder and cone use [0]=diameter, [2]=height ([1] is ignored); sphere
    uses [0]=diameter only. New geometry is wrapped in a SketchUp Group.

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}. Read bbox_mm to
    verify the result before the next step.
    """
    args: dict = {"type": type, "position": position, "dimensions": dimensions}
    if name is not None:
        args["name"] = name
    if parent_path is not None:
        args["parent_path"] = parent_path
    if coordinate_space is not None:
        if parent_path is None:
            raise ValueError("coordinate_space requires explicit parent_path")
        args["coordinate_space"] = coordinate_space
    return await _call(ctx, "create_component", **args)


@mcp.tool()
async def create_curve(
    ctx: Context,
    points: Annotated[
        list[list[float]],
        Field(
            min_length=2,
            description="3D curve points [[x,y,z], ...] in mm. At least 2 points.",
        ),
    ],
    closed: Annotated[
        bool,
        Field(description="Whether to close the curve by connecting the last point to the first point"),
    ] = False,
    name: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Optional name for the curve group"),
    ] = None,
    parent_path: Annotated[ParentPath | None, Field(description='Parent persistent-ID path; empty string means model root')] = None,
    coordinate_space: Annotated[Literal["parent", "world"] | None, Field(description='Coordinate frame; creation requires explicit parent_path')] = None,
) -> str:
    """Create a SketchUp curve from 3D points.

    All coordinates are millimeters (mm).

    Points are interpreted as model coordinates [x, y, z].
    The resulting curve is wrapped in a SketchUp Group.

    Set closed=true to connect the final point back to the first point.

    Returns JSON containing:
    {id, name, type, closed, point_count, bbox_mm{min,max}}.
    """
    args: dict = {
        "points": points,
        "closed": closed,
    }

    if name is not None:
        args["name"] = name

    if parent_path is not None:
        args["parent_path"] = parent_path
    if coordinate_space is not None:
        if parent_path is None:
            raise ValueError("coordinate_space requires explicit parent_path")
        args["coordinate_space"] = coordinate_space
    return await _call(ctx, "create_curve", **args)

@mcp.tool()
async def create_circle(
    ctx: Context,
    center: Annotated[
        list[float],
        Field(
            min_length=3,
            max_length=3,
            description="Circle center [x, y, z] in mm",
        ),
    ],
    radius: Annotated[
        float,
        Field(
            gt=0,
            description="Circle radius in mm",
        ),
    ],
    normal: Annotated[
        list[float],
        Field(
            min_length=3,
            max_length=3,
            description="Circle plane normal vector [x, y, z]",
        ),
    ] = [0, 0, 1],
    segments: Annotated[
        int,
        Field(
            ge=8,
            le=512,
            description="Number of segments used to represent the circle",
        ),
    ] = 96,
    name: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Optional name for the circle group"),
    ] = None,
    parent_path: Annotated[ParentPath | None, Field(description='Parent persistent-ID path; empty string means model root')] = None,
    coordinate_space: Annotated[Literal["parent", "world"] | None, Field(description='Coordinate frame; creation requires explicit parent_path')] = None,
) -> str:
    """Create a true circular curve in SketchUp.

    All linear values are millimeters.

    center is the circle center [x, y, z].
    radius is the true circle radius in mm.
    normal defines the plane perpendicular to the circle.
    segments controls geometric resolution; higher values produce
    a more accurate circular approximation.

    Returns JSON containing:
    {id, name, type, center_mm, radius_mm, normal, segments,
     bbox_mm{min,max}}.
    """
    args: dict = {
        "center": center,
        "radius": radius,
        "normal": normal,
        "segments": segments,
    }

    if name is not None:
        args["name"] = name

    if parent_path is not None:
        args["parent_path"] = parent_path
    if coordinate_space is not None:
        if parent_path is None:
            raise ValueError("coordinate_space requires explicit parent_path")
        args["coordinate_space"] = coordinate_space
    return await _call(ctx, "create_circle", **args)


@mcp.tool()
async def delete_component(
    ctx: Context,
    id: Annotated[EntityId, Field(description='Legacy entityID; must match instance_path when both are supplied')],
) -> str:
    """Delete a group or component by entity ID.

    Returns: JSON {ok: true}.
    """
    return await _call(ctx, "delete_component", id=str(id))


@mcp.tool()
async def transform_component(
    ctx: Context,
    id: Annotated[EntityId | None, Field(description='Legacy entityID; must match instance_path when both are supplied')] = None,
    position: Annotated[
        Optional[Annotated[list[float], Field(min_length=3, max_length=3)]],
        Field(description="ABSOLUTE target for the bbox-min corner, mm"),
    ] = None,
    rotation: Annotated[
        Optional[Annotated[list[float], Field(min_length=3, max_length=3)]],
        Field(description="relative degrees around bbox center, "
                          "applied X then Y then Z"),
    ] = None,
    scale: Annotated[
        Optional[
            Annotated[list[float], Field(min_length=3, max_length=3),
                      AfterValidator(_validate_scale_nonzero)]
        ],
        Field(description="relative factors about bbox center, each |s| > 1e-9"),
    ] = None,
    instance_path: Annotated[InstancePath | None, Field(description='Persistent-ID occurrence path from hierarchy inspection')] = None,
    coordinate_space: Annotated[Literal["parent", "world", "local"] | None, Field(description='Coordinate frame; creation requires explicit parent_path')] = None,
    translation_mm: Annotated[Vector3 | None, Field(description='Relative translation in mm')] = None,
    pivot_mm: Annotated[Vector3 | None, Field(description='Rotation/scaling pivot in the requested frame, mm')] = None,
    axis: Annotated[Vector3 | None, Field(description='Nonzero rotation axis')] = None,
    angle_degrees: Annotated[Finite | None, Field(description='Relative rotation about axis in degrees')] = None,
    matrix_mm: Annotated[Matrix16 | None, Field(description='Absolute column-major affine matrix; translation entries 12..14 in mm')] = None,
) -> str:
    """Move, rotate and/or scale a group or component (mm / degrees).

    - position: ABSOLUTE target for the entity's bounding-box MIN corner,
      in mm â€” the same anchor create_component uses. Applied LAST (after
      rotation/scale), so the final bbox-min lands exactly at [x, y, z]
      even in combined calls. It is NOT a relative offset: repeating the
      same position is idempotent.
    - rotation: RELATIVE rotation in degrees around the bbox center,
      applied sequentially about world X, then Y, then Z.
    - scale: RELATIVE scale factors about the bbox center.

    These validations (3-element lists, non-zero scale) apply only to this
    typed tool â€” raw Ruby driven through eval_ruby bypasses them.

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}. Read bbox_mm to
    verify the result; it is null for empty geometry.
    """
    if id is None and instance_path is None:
        raise ValueError("id or instance_path is required")
    args: dict = {"id": str(id)} if id is not None else {}
    args.update({k: v for k, v in dict(instance_path=instance_path,
        coordinate_space=coordinate_space, translation_mm=translation_mm,
        pivot_mm=pivot_mm, axis=axis, angle_degrees=angle_degrees,
        matrix_mm=matrix_mm).items() if v is not None})
    if position is not None:
        args["position"] = position
    if rotation is not None:
        args["rotation"] = rotation
    if scale is not None:
        args["scale"] = scale
    return await _call(ctx, "transform_component", **args)


@mcp.tool()
async def get_selection(
    ctx: Context,
    include_hierarchy: Annotated[bool, Field(description="Include persistent instance paths in the current edit context")] = False,
) -> str:
    """Get the entities currently selected in the SketchUp UI.

    Returns: JSON {entities: [...]} â€” groups/components are {id, name, type,
    layer, depth, bbox_mm|null}; other selected entities (edges, faces, ...)
    are {id, type} only.
    """
    return await _call(ctx, "get_selection", **({"include_hierarchy": True} if include_hierarchy else {}))


@mcp.tool()
async def set_material(
    ctx: Context,
    id: Annotated[EntityId, Field(description='Legacy entityID; must match instance_path when both are supplied')],
    material: Annotated[
        str,
        Field(min_length=1,
              description="Named color or 6-digit hex string like #a05030"),
    ],
) -> str:
    """Assign a material (color) to a group or component.

    material accepts a named color â€” red, green, blue, yellow, cyan,
    turquoise, magenta, purple, white, black, brown, wood, orange, gray,
    grey â€” or a 6-digit hex string like "#a05030" (#rrggbb). Anything else
    fails with error -32602. Named colors are case-insensitive. Painting
    affects only this instance (it is made unique first). That applies to
    groups/components; painting a raw face/edge id (obtainable via
    get_selection) colors the shared definition â€” all instances show it.

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}.
    """
    return await _call(ctx, "set_material", id=str(id), material=material)


# Note: Ruby tool name is 'export' (wire mapping pinned in tests/test_tools.py).
@mcp.tool()
async def export_scene(
    ctx: Context,
    format: Annotated[
        Literal["skp", "obj", "dae", "stl", "png", "jpg"],
        Field(description="skp (native), obj / dae / stl (geometry), "
                          "png / jpg (viewport render)"),
    ] = "skp",
) -> str:
    """Export the current scene to a temp file on the SketchUp host.

    Formats: skp (native), obj / dae / stl (geometry), png / jpg (viewport
    render, default 1920Ã—1080). The file is written on the machine running
    SketchUp â€” on a split-host setup the path is not directly readable here.

    Returns: JSON {path, format} plus a "warning" field when exporting skp
    from a never-saved model (SketchUp binds the live document to the export
    path â€” relay the warning to the user).
    """
    return await _call(ctx, "export", format=format)


# Pydantic always sends the sized defaults (50/25/10 mm) on the wire, so they
# override Ruby's V.optional_positive defaults â€” keep the two sides in sync
# (see mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb).
@mcp.tool()
async def create_mortise_tenon(
    ctx: Context,
    mortise_id: EntityId,
    tenon_id: EntityId,
    width: Annotated[float, Field(gt=0, description="Joint width in mm")] = 50.0,
    height: Annotated[float, Field(gt=0, description="Joint height in mm")] = 25.0,
    depth: Annotated[float, Field(gt=0, description="Joint depth in mm")] = 10.0,
    offset_x: Annotated[float, Field(
        description="Joint offset from the board face's center along X, mm")] = 0.0,
    offset_y: Annotated[float, Field(
        description="Joint offset from the board face's center along Y, mm")] = 0.0,
    offset_z: Annotated[float, Field(
        description="Joint offset from the board face's center along Z, mm")] = 0.0,
) -> str:
    """Create a mortise-and-tenon joint between two boards.

    All dimensions in millimeters; offsets shift the joint from the board
    face's center. Defaults are sized for ~100 mm boards. The two boards must
    already touch/overlap along the joint axis.

    Returns: JSON {mortise: {id, name, type, bbox_mm|null}, tenon: {...},
    boolean_cuts: {attempted, failed}} â€” non-zero failed means some cuts did
    not apply (likely non-manifold geometry); verify via bbox_mm.
    """
    return await _call(
        ctx,
        "create_mortise_tenon",
        mortise_id=str(mortise_id),
        tenon_id=str(tenon_id),
        width=width,
        height=height,
        depth=depth,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def create_dovetail(
    ctx: Context,
    tail_id: EntityId,
    pin_id: EntityId,
    width: Annotated[float, Field(gt=0, description="Joint width in mm")] = 50.0,
    height: Annotated[float, Field(gt=0, description="Joint height in mm")] = 50.0,
    depth: Annotated[float, Field(gt=0, description="Joint depth in mm")] = 15.0,
    angle: Annotated[float, Field(
        gt=0, le=60,
        description="Dovetail flare angle in degrees, 0 < angle <= 60")] = 15.0,
    num_tails: Annotated[int, Field(gt=0, description="Number of tails")] = 3,
    offset_x: Annotated[float, Field(
        description="Joint offset from the board face's center along X, mm")] = 0.0,
    offset_y: Annotated[float, Field(
        description="Joint offset from the board face's center along Y, mm")] = 0.0,
    offset_z: Annotated[float, Field(
        description="Joint offset from the board face's center along Z, mm")] = 0.0,
) -> str:
    """Create a dovetail joint between two boards.

    All dimensions in millimeters; angle is in degrees, valid range (0, 60].
    Offsets shift the joint from the board face's center. Defaults are sized
    for ~100 mm boards. The two boards must already touch/overlap along the
    joint axis.

    Returns: JSON {tail: {id, name, type, bbox_mm|null}, pin: {...},
    boolean_cuts: {attempted, failed}} â€” non-zero failed means some cuts did
    not apply (likely non-manifold geometry); verify via bbox_mm.
    """
    return await _call(
        ctx,
        "create_dovetail",
        tail_id=str(tail_id),
        pin_id=str(pin_id),
        width=width,
        height=height,
        depth=depth,
        angle=angle,
        num_tails=num_tails,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def create_finger_joint(
    ctx: Context,
    board1_id: EntityId,
    board2_id: EntityId,
    width: Annotated[float, Field(gt=0, description="Joint width in mm")] = 50.0,
    height: Annotated[float, Field(gt=0, description="Joint height in mm")] = 25.0,
    depth: Annotated[float, Field(gt=0, description="Joint depth in mm")] = 10.0,
    num_fingers: Annotated[int, Field(gt=0, description="Number of fingers")] = 5,
    offset_x: Annotated[float, Field(
        description="Joint offset from the board face's center along X, mm")] = 0.0,
    offset_y: Annotated[float, Field(
        description="Joint offset from the board face's center along Y, mm")] = 0.0,
    offset_z: Annotated[float, Field(
        description="Joint offset from the board face's center along Z, mm")] = 0.0,
) -> str:
    """Create a finger joint (box joint) between two boards.

    All dimensions in millimeters; offsets shift the joint from the board
    face's center. Defaults are sized for ~100 mm boards. The two boards must
    already touch/overlap along the joint axis.

    Returns: JSON {board1: {id, name, type, bbox_mm|null}, board2: {...},
    boolean_cuts: {attempted, failed}} â€” non-zero failed means some cuts did
    not apply (likely non-manifold geometry); verify via bbox_mm.
    """
    return await _call(
        ctx,
        "create_finger_joint",
        board1_id=str(board1_id),
        board2_id=str(board2_id),
        width=width,
        height=height,
        depth=depth,
        num_fingers=num_fingers,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def eval_ruby(
    ctx: Context,
    code: Annotated[
        str,
        Field(min_length=1, description="Ruby code to evaluate inside SketchUp"),
    ],
) -> str:
    """Evaluate arbitrary Ruby code in SketchUp.

    Enabled by default; the user can close the gate in the SketchUp
    extension's Settings. When closed, the SketchUp side returns JSON-RPC
    code -32010 with a user-facing message explaining how to re-enable it.
    This wrapper surfaces that message as a plain string so the LLM can
    repeat it to the user verbatim â€” without the `[code]` prefix that
    format_error would otherwise add.

    Returns the .to_s of the LAST evaluated expression; stdout (puts) is NOT
    captured. End scripts with an explicit expression â€” e.g. a final
    `result.to_json` â€” to get structured data back. Errors return
    "[code] message" with the Ruby exception class and message.
    """
    try:
        result = await _raw_call(ctx, "eval_ruby", code=code)
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        if e.code == compat.EVAL_DISABLED_CODE:
            return e.message
        # Same tool-name backfill as _call, placed AFTER the -32010 verbatim
        # path so the eval-disabled message stays untouched.
        e.data.setdefault("tool", "eval_ruby")
        return format_error(e, debug=config.LOG_LEVEL == "DEBUG")

    return _extract_text(result)


@mcp.tool()
async def boolean_operation(
    ctx: Context,
    target_id: EntityId,
    tool_id: EntityId,
    operation: Annotated[
        Literal["union", "difference", "intersection"],
        Field(description="union, difference (target minus tool), "
                          "or intersection"),
    ] = "union",
    delete_originals: Annotated[
        bool,
        Field(description="erase the two source bodies after a "
                          "successful operation"),
    ] = False,
) -> str:
    """Perform a boolean operation (union / difference / intersection) on two solids.

    difference = target minus tool. Operating on an instance of a shared
    definition consumes only that instance â€” the result is a new group,
    sibling instances are untouched. Unreliable on non-manifold geometry.

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}. Read bbox_mm to
    verify the result; it is null for empty geometry (e.g. a difference that
    consumed the whole body).
    """
    return await _call(
        ctx,
        "boolean_operation",
        target_id=str(target_id),
        tool_id=str(tool_id),
        operation=operation,
        delete_originals=delete_originals,
    )


# Ruby tool name is `chamfer_edges` (plural); Python parameter `id` maps to
# Ruby `entity_id`. Default 5 mm is visible on the documented 100 mm-cube
# use case.
@mcp.tool()
async def chamfer_edge(
    ctx: Context,
    id: Annotated[EntityId, Field(description='Legacy entityID; must match instance_path when both are supplied')],
    distance: Annotated[
        float, Field(gt=0, description="Chamfer distance in mm"),
    ] = 5.0,
) -> str:
    """Chamfer (bevel) edges of a group/component by ``distance`` mm.

    By default ALL edges are chamfered. Unreliable on non-manifold geometry.

    Returns: JSON {id, name, type, bbox_mm|null, edges_chamfered,
    stats{attempted, skipped_no_match, subtract_failed, succeeded}} â€” check
    stats.subtract_failed == 0 (failed cuts) and stats.skipped_no_match == 0
    (edges consumed by earlier cuts).
    """
    return await _call(ctx, "chamfer_edges", entity_id=str(id), distance=distance)


# Ruby tool name is `fillet_edges` (plural); Python parameter `id` maps to
# Ruby parameter `entity_id`.
@mcp.tool()
async def fillet_edge(
    ctx: Context,
    id: Annotated[EntityId, Field(description='Legacy entityID; must match instance_path when both are supplied')],
    radius: Annotated[
        float, Field(gt=0, description="Fillet radius in mm"),
    ] = 5.0,
    segments: Annotated[
        int, Field(gt=0, description="Arc segments per rounded edge"),
    ] = 8,
) -> str:
    """Round (fillet) edges of a group/component by ``radius`` mm with
    ``segments`` arc segments.

    By default ALL edges are filleted. Unreliable on non-manifold geometry.

    Returns: JSON {id, name, type, bbox_mm|null, edges_filleted,
    stats{attempted, skipped_no_match, subtract_failed, succeeded}} â€” check
    stats.subtract_failed == 0 (failed cuts) and stats.skipped_no_match == 0
    (edges consumed by earlier cuts).
    """
    return await _call(
        ctx, "fillet_edges", entity_id=str(id), radius=radius, segments=segments
    )


# Note on operation order (Ruby handler): snapshot â†’ preset â†’ style â†’
# zoom_extents â†’ write_image â†’ restore. Restore runs in an outer `ensure`
# block, so an exception anywhere between snapshot and write_image still
# leaves the viewport in its original state.
@mcp.tool()
async def get_viewport_screenshot(
    ctx: Context,
    max_size: Annotated[
        int,
        Field(ge=64, le=4096,
              description="Largest side of the returned PNG in pixels; the "
                          "other side follows the viewport aspect ratio"),
    ] = 800,
    view_preset: Annotated[
        Literal[
            "current", "front", "back", "left", "right",
            "top", "bottom", "iso",
        ],
        Field(description="Camera preset to switch to before snapping; "
                          "'current' leaves the camera alone"),
    ] = "current",
    zoom_extents: Annotated[
        bool,
        Field(description="Zoom to fit the whole model before snapping"),
    ] = False,
    style: Annotated[
        Literal["default", "shaded", "hidden_line", "wireframe"],
        Field(description="Temporary rendering style for the shot; "
                          "'default' leaves rendering options alone"),
    ] = "default",
    restore_view: Annotated[
        bool,
        Field(description="Restore the camera and rendering options after "
                          "the shot, leaving the user's viewport unchanged"),
    ] = True,
    scene_id: Annotated[EntityId | None, Field(description='Persistent Scene ID returned by list_scenes')] = None,
    camera: Annotated[CameraSpec | None, Field(description='Explicit world-space camera with distances in mm')] = None,
    frame_paths: Annotated[Paths | None, Field(description='Persistent-ID assembly paths to frame')] = None,
    projection: Annotated[Literal["perspective", "parallel"] | None, Field(description='Perspective or parallel projection')] = None,
    margin: Annotated[Annotated[Finite, Field(ge=1, le=10)] | None, Field(description='Framing multiplier, 1..10')] = None,
    # NB: bare `list` on purpose â€” `list[Image | str]` crashes FastMCP tool
    # registration on mcp 1.27.
) -> list:
    """Capture the current SketchUp viewport; returns the PNG image plus a JSON text block {width, height, preset_used, style_used}.

    Useful for letting Claude visually verify the scene between steps.

    Parameters
    - max_size: largest side of the returned PNG (64..4096). Aspect ratio is
      taken from the current viewport; the smaller side is scaled proportionally.
    - view_preset: switch the camera to a standard view before snapping.
      ``current`` leaves the camera alone.
    - zoom_extents: call view.zoom_extents before snapping.
    - style: temporarily flip a small set of rendering_options keys.
      ``default`` leaves them alone.
    - restore_view: when true (default), camera and rendering_options are
      snapshotted before mutation and restored after the snapshot, so the
      user's viewport is unchanged.

    Legacy capture retries after a stale connection. Structured capture with
    scene/camera/framing parameters is not automatically replayed. See
    docs/structured-assemblies.md for restoration and Scene property support.
    """
    # Delegate connection + send_command to _raw_call so we don't duplicate
    # the transport logic of _call. _raw_call does NOT translate
    # ConnectionError (text-tools and Image-tools have divergent strategies),
    # so we convert here: there is no Image sentinel for "not connected",
    # so raise SketchUpError. See design Â§5.8 for the error-handling
    # asymmetry rationale.
    try:
        raw = await _raw_call(
            ctx,
            "get_viewport_screenshot",
            max_size=max_size,
            view_preset=view_preset,
            zoom_extents=zoom_extents,
            style=style,
            restore_view=restore_view,
            **{k: v for k, v in dict(scene_id=scene_id,
                camera=camera.model_dump() if camera else None,
                frame_paths=frame_paths, projection=projection, margin=margin).items() if v is not None},
        )
    except ConnectionError as e:
        raise SketchUpError(-32000, f"SketchUp not running: {e}") from e

    # Ruby returns MCP-shaped {content: [{type: "text", text: JSON-blob}], ...}.
    # Extract the JSON blob and decode the base64 PNG into raw bytes.
    text: Optional[str] = None
    if isinstance(raw, dict):
        content = raw.get("content")
        if (
            isinstance(content, list)
            and content
            and isinstance(content[0], dict)
        ):
            text = content[0].get("text")
    if not isinstance(text, str):
        raise SketchUpError(
            -32603, f"unexpected screenshot response shape: {raw!r}"
        )
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as e:
        raise SketchUpError(-32603, f"screenshot response not JSON: {e}") from e
    # Guard before .get(): a JSON scalar/array decodes fine but has no .get,
    # which would leak an AttributeError to the MCP client instead of a clean
    # SketchUpError (mirrors the isinstance(text, str) guard above).
    if not isinstance(payload, dict):
        raise SketchUpError(
            -32603,
            f"screenshot payload is not a JSON object: {type(payload).__name__}",
        )
    b64 = payload.get("png_base64")
    if not isinstance(b64, str):
        raise SketchUpError(-32603, "screenshot response missing png_base64")
    try:
        png_bytes = base64.b64decode(b64, validate=True)
    except (ValueError, base64.binascii.Error) as e:
        raise SketchUpError(-32603, f"png_base64 decode failed: {e}") from e
    # T-28: Ruby Ð¾Ñ‚Ð´Ð°Ñ‘Ñ‚ Ñ€Ð°Ð·Ð¼ÐµÑ€Ñ‹ Ð¸ Ñ„Ð°ÐºÑ‚Ð¸Ñ‡ÐµÑÐºÐ¸ Ð¿Ñ€Ð¸Ð¼ÐµÐ½Ñ‘Ð½Ð½Ñ‹Ðµ preset/style â€”
    # Ð¿Ñ€Ð¾Ð±Ñ€Ð°ÑÑ‹Ð²Ð°ÐµÐ¼ Ð¸Ñ… Ñ‚ÐµÐºÑÑ‚Ð¾Ð²Ñ‹Ð¼ Ð±Ð»Ð¾ÐºÐ¾Ð¼ Ñ€ÑÐ´Ð¾Ð¼ Ñ ÐºÐ°Ñ€Ñ‚Ð¸Ð½ÐºÐ¾Ð¹, Ñ‡Ñ‚Ð¾Ð±Ñ‹ Ð¼Ð¾Ð´ÐµÐ»ÑŒ Ð¼Ð¾Ð³Ð»Ð°
    # Ð¿Ñ€Ð¾Ð²ÐµÑ€Ð¸Ñ‚ÑŒ Ð¿Ð°Ñ€Ð°Ð¼ÐµÑ‚Ñ€Ñ‹ Ð·Ð°Ñ…Ð²Ð°Ñ‚Ð° (Ð° Ð½Ðµ Ð²Ñ‹Ð±Ñ€Ð°ÑÑ‹Ð²Ð°ÐµÐ¼, ÐºÐ°Ðº Ñ€Ð°Ð½ÑŒÑˆÐµ).
    meta = {
        "width": payload.get("width"),
        "height": payload.get("height"),
        "preset_used": payload.get("preset_used"),
        "style_used": payload.get("style_used"),
    }
    for key in ("camera", "scene_id"):
        if key in payload:
            meta[key] = payload[key]
    return [Image(data=png_bytes, format="png"), json.dumps(meta)]


@mcp.tool()
async def get_model_info(ctx: Context) -> str:
    """Get current SketchUp model info: file path, title, units, bounding box, entity count, layer list.

    Returns: JSON {path, title, units: "mm", bounding_box_mm|null,
    entity_count, layers[]}.
    """
    return await _call(ctx, "get_model_info")


@mcp.tool()
async def list_components(
    ctx: Context,
    recursive: Annotated[
        bool, Field(description="Descend into nested groups/components"),
    ] = False,
    max_depth: Annotated[
        int,
        Field(ge=1, le=10,
              description="Maximum nesting depth to descend when recursive"),
    ] = 3,
    limit: Annotated[
        int,
        Field(ge=1, le=500,
              description="Page size â€” maximum components per response"),
    ] = 50,
    offset: Annotated[
        int,
        Field(ge=0, description="How many components to skip (pagination)"),
    ] = 0,
    response_format: Annotated[
        Literal["concise", "detailed"],
        Field(description="detailed includes bbox_mm per component; "
                          "concise omits it"),
    ] = "detailed",
    parent_path: Annotated[ParentPath | None, Field(description='Parent persistent-ID path; empty string means model root')] = None,
    include_hierarchy: Annotated[bool, Field(description='Include parent/instance paths and local/world matrices')] = False,
) -> str:
    """List groups and component instances in the model (paginated).

    Each component is {id, name, type, layer, depth, bbox_mm} (detailed) or
    {id, name, type, layer, depth} (concise); bounds are world-coordinate mm.
    Set recursive=true to descend into nested components (bounded by
    max_depth, default 3).

    Returns: JSON {components[], total, offset, truncated} â€” if truncated,
    request the next page with offset += limit.
    """
    return await _call(ctx, "list_components",
                       **({"parent_path": parent_path} if parent_path is not None else {}),
                       **({"include_hierarchy": True} if include_hierarchy else {}),
                       recursive=recursive,
                       max_depth=max_depth, limit=limit, offset=offset,
                       response_format=response_format)


@mcp.tool()
async def get_component_info(
    ctx: Context,
    id: Annotated[EntityId | None, Field(description='Legacy entityID; must match instance_path when both are supplied')] = None,
    instance_path: Annotated[InstancePath | None, Field(description='Persistent-ID occurrence path from hierarchy inspection')] = None,
) -> str:
    """Detailed info for a single group or component instance by entity ID.

    Returns: JSON {id, name, type, layer, depth, bbox_mm|null}.
    """
    if id is None and instance_path is None:
        raise ValueError("id or instance_path is required")
    args = {"id": str(id)} if id is not None else {}
    if instance_path is not None:
        args["instance_path"] = instance_path
    return await _call(ctx, "get_component_info", **args)


@mcp.tool()
async def find_components(
    ctx: Context,
    name: Annotated[
        Annotated[str, Field(min_length=1)] | None,
        Field(description="Case-insensitive substring to match against "
                          "component names"),
    ] = None,
    layer: Annotated[
        Annotated[str, Field(min_length=1)] | None,
        Field(description="Exact layer (tag) name to filter by"),
    ] = None,
    type: Annotated[
        Literal["group", "component"] | None,
        Field(description="Restrict results to groups or component instances"),
    ] = None,
    max_depth: Annotated[
        int,
        Field(ge=1, le=10, description="Maximum nesting depth to search"),
    ] = 3,
    limit: Annotated[
        int,
        Field(ge=1, le=500,
              description="Page size â€” maximum components per response"),
    ] = 50,
    offset: Annotated[
        int,
        Field(ge=0, description="How many components to skip (pagination)"),
    ] = 0,
    response_format: Annotated[
        Literal["concise", "detailed"],
        Field(description="detailed includes bbox_mm per component; "
                          "concise omits it"),
    ] = "detailed",
    parent_path: Annotated[ParentPath | None, Field(description='Parent persistent-ID path; empty string means model root')] = None,
    include_hierarchy: Annotated[bool, Field(description='Include parent/instance paths and local/world matrices')] = False,
) -> str:
    """Find components matching name substring, layer, and/or type.

    Name matching is case-insensitive substring; layer must match exactly.
    Searches recursively (bounded by max_depth). With no filters it returns
    all components up to max_depth (paginated) â€” same traversal as
    list_components.

    Returns: JSON {components[], total, offset, truncated} â€” if truncated,
    request the next page with offset += limit.
    """
    args: dict = {"max_depth": max_depth, "limit": limit, "offset": offset,
                  "response_format": response_format}
    if name is not None:
        args["name"] = name
    if layer is not None:
        args["layer"] = layer
    if type is not None:
        args["type"] = type
    if parent_path is not None:
        args["parent_path"] = parent_path
    if include_hierarchy:
        args["include_hierarchy"] = True
    return await _call(ctx, "find_components", **args)


@mcp.tool()
async def list_layers(ctx: Context) -> str:
    """List all model layers (tags).

    Returns: JSON {layers: [{name, visible, color, id}]}.
    """
    return await _call(ctx, "list_layers")


@mcp.tool()
async def create_layer(
    ctx: Context,
    name: Annotated[
        str, Field(min_length=1, description="Name for the new layer"),
    ],
) -> str:
    """Create a new layer (tag) with the given name.

    Returns: JSON {id, name, visible}.
    """
    return await _call(ctx, "create_layer", name=name)


@mcp.tool()
async def undo(ctx: Context) -> str:
    """Undo the last atomic operation in SketchUp. One MCP tool-call = one undo step.

    Returns: JSON {ok: true}.
    """
    return await _call(ctx, "undo")


@mcp.tool()
async def get_version(ctx: Context) -> str:
    """Return the server version and Pythonâ†”Ruby compatibility verdict.

    Useful as a runtime sanity probe â€” always returns a payload, even
    when the connection or other tools surface errors. The result is a
    JSON string with fields: python_version, ruby_version,
    min_compatible_ruby, max_compatible_ruby, ruby_min_compatible_python,
    ruby_max_compatible_python, compatible (bool), error (string | null).
    """
    def _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg):
        return json.dumps({
            "python_version": compat.CLIENT_VERSION,
            "ruby_version": ruby_version,
            "min_compatible_ruby": compat.MIN_RUBY,
            "max_compatible_ruby": compat.MAX_RUBY,
            "ruby_min_compatible_python": ruby_min,
            "ruby_max_compatible_python": ruby_max,
            "compatible": compatible,
            "error": error_msg,
        })

    try:
        raw = await _raw_call(ctx, "get_version")
    except ConnectionError as e:
        return _payload(None, None, None, False,
                        f"SketchUp not running or extension not started: {e}")
    except SketchUpError as e:
        # Covers old Ruby returning -32601 "unknown tool: get_version"
        # and any other JSON-RPC error envelope. Version compatibility is
        # validated once at connect-time in ``_handshake``; once a
        # connection survives that, tool-level errors here come from the
        # Ruby handler itself (not from per-request version checks).
        return _payload(None, None, None, False, str(e))

    # Defensive parse: any unexpected shape (missing keys, non-list content,
    # non-string text, invalid JSON, non-dict payload) must STILL produce a
    # payload â€” the tool's contract is "always returns a payload even on
    # mismatch / error", so a KeyError/IndexError/TypeError/JSONDecodeError
    # escaping here would violate it.
    try:
        ruby_payload = json.loads(raw["content"][0]["text"])
        if not isinstance(ruby_payload, dict):
            raise TypeError(
                f"ruby payload is {type(ruby_payload).__name__}, expected dict"
            )
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as e:
        return _payload(None, None, None, False,
                        f"unexpected get_version response shape: {e}")
    ruby_version = ruby_payload.get("ruby_version")
    ruby_min = ruby_payload.get("min_compatible_python")
    ruby_max = ruby_payload.get("max_compatible_python")

    # Two-way compatibility: BOTH sides' tables must accept the counterpart.
    try:
        compat.check_ruby_version(ruby_version)
        python_accepts_ruby, py_error = True, None
    except IncompatibleVersionError as e:
        python_accepts_ruby, py_error = False, str(e)

    try:
        ruby_accepts_python = bool(
            ruby_min and ruby_max and
            compat.parse(ruby_min)
            <= compat.parse(compat.CLIENT_VERSION)
            <= compat.parse(ruby_max)
        )
    except ValueError:
        ruby_accepts_python = False

    compatible = python_accepts_ruby and ruby_accepts_python
    if py_error:
        error_msg = py_error
    elif not ruby_accepts_python:
        error_msg = (
            f"SketchUp plugin advertises Python compatibility "
            f"{ruby_min}..{ruby_max}, which excludes v{compat.CLIENT_VERSION}."
        )
    else:
        error_msg = None

    return _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg)



# Register structured tools after shared wrappers are defined.
import sketchup_mcp.assembly_tools  # noqa: E402, F401
