"""Schema/transport contracts only: never connect to a SketchUp instance."""
import json
from unittest.mock import AsyncMock

import pytest
from sketchup_mcp.app import mcp
from sketchup_mcp import tools, assembly_tools
from sketchup_mcp.assembly_schema import CameraSpec


@pytest.fixture
def wire(monkeypatch):
    call = AsyncMock(return_value="{}")
    monkeypatch.setattr(tools, "_call", call)
    monkeypatch.setattr(assembly_tools, "_call", call)
    return call


@pytest.mark.parametrize("name,args", [
    ("create_assembly", {"name": "Module", "member_paths": ["10.20"], "parent_path": ""}),
    ("reparent_entities", {"entity_paths": ["10.20"], "parent_path": "30"}),
    ("duplicate_component", {"instance_path": "10.20", "name": "Copy"}),
    ("get_camera", {}), ("set_camera", {"view_preset": "front", "projection": "parallel", "frame_paths": ["10"]}),
    ("save_scene", {"name": "Front", "pose_paths": ["10.20"]}),
    ("list_scenes", {}), ("activate_scene", {"scene_id": 42}),
    ("delete_scene", {"scene_id": 42}),
    ("save_model", {"path": "C:/Output/Master.skp", "expected_current_path": "C:/Original.skp"}),
])
async def test_new_tools_are_registered_and_forward_only_structured_arguments(wire, name, args):
    await mcp.call_tool(name, args)
    assert wire.await_count == 1
    assert wire.call_args.args[1] == name
    assert "code" not in wire.call_args.kwargs
    for key, value in args.items():
        assert wire.call_args.kwargs[key] == (str(value) if key == "scene_id" and name != "save_scene" else value)


@pytest.mark.parametrize("name,args", [
    ("create_component", {"parent_path": "10", "coordinate_space": "world"}),
    ("create_curve", {"points": [[0, 0, 0], [10, 0, 0]], "parent_path": ""}),
    ("create_circle", {"center": [0, 0, 0], "radius": 10, "parent_path": "10"}),
    ("list_components", {"parent_path": "10", "include_hierarchy": True}),
    ("find_components", {"parent_path": "10", "include_hierarchy": True}),
    ("get_component_info", {"instance_path": "10.20"}),
    ("get_selection", {"include_hierarchy": True}),
    ("transform_component", {"instance_path": "10.20", "axis": [0, 0, 1], "angle_degrees": 90, "pivot_mm": [0, 0, 0]}),
])
async def test_existing_tools_forward_extensions(wire, name, args):
    await mcp.call_tool(name, args)
    assert wire.await_count == 1
    for key, value in args.items():
        assert wire.call_args.kwargs[key] == value


@pytest.mark.parametrize("name,args", [
    ("create_assembly", {"name": "A", "member_paths": []}),
    ("create_assembly", {"name": "A", "member_paths": ["1.bad"]}),
    ("reparent_entities", {"entity_paths": ["1"], "parent_path": "-2"}),
    ("transform_component", {"instance_path": "1", "matrix_mm": [1, 2]}),
    ("transform_component", {"instance_path": "1", "translation_mm": [float("nan"), 0, 0]}),
    ("get_component_info", {}),
    ("save_scene", {}),
    ("set_camera", {"camera": {"eye_mm": [0, 0, 0], "target_mm": [0, 0, 0], "up": [0, 0, 1]}}),
])
async def test_invalid_data_never_reaches_transport(wire, name, args):
    with pytest.raises(Exception):
        await mcp.call_tool(name, args)
    wire.assert_not_called()


async def test_legacy_creation_does_not_inject_parent_or_change_wire_args(wire):
    await tools.create_component(None)
    assert wire.call_args.kwargs == {"type": "cube", "position": [0, 0, 0], "dimensions": [100, 100, 100]}


async def test_scene_rename_does_not_recapture(wire):
    await assembly_tools.save_scene(None, scene_id=10, name="Renamed")
    assert wire.call_args.kwargs == {"scene_id": 10, "name": "Renamed"}


async def test_camera_conflicting_inputs_are_rejected(wire):
    camera = CameraSpec(eye_mm=[0, -1000, 0], target_mm=[0, 0, 0], up=[0, 0, 1])
    with pytest.raises(ValueError):
        await assembly_tools.set_camera(None, camera=camera, view_preset="front")
    wire.assert_not_called()


async def test_screenshot_forwards_scene_and_preserves_camera_metadata(monkeypatch):
    result = {"png_base64": "aGVsbG8=", "width": 800, "height": 600,
              "camera": {"projection": "parallel"}, "scene_id": 12}
    call = AsyncMock(return_value={"content": [{"text": json.dumps(result)}]})
    monkeypatch.setattr(tools, "_raw_call", call)
    images = await tools.get_viewport_screenshot(None, scene_id=12)
    assert call.call_args.kwargs["scene_id"] == 12
    assert json.loads(images[1])["camera"] == {"projection": "parallel"}


@pytest.mark.parametrize("name,args", [
    ("save_model", {"path": "C:/Master.skp"}),
    ("create_assembly", {"name": "A", "member_paths": ["1"]}),
    ("activate_scene", {"scene_id": 1}),
    ("get_viewport_screenshot", {"scene_id": 1, "restore_view": False}),
    ("get_viewport_screenshot", {"frame_paths": ["1"], "restore_view": True}),
])
async def test_uncertain_structured_operations_are_not_replayed(make_connection, fake_streams, name, args):
    from sketchup_mcp.errors import SketchUpError
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_eof()
    conn.connect = AsyncMock(side_effect=AssertionError("must not replay"))
    with pytest.raises(SketchUpError):
        await conn.send_command(name, args)
    conn.connect.assert_not_awaited()
