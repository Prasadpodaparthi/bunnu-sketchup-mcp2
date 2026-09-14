"""Shared, bounded data contracts. No connection or registration side effects."""
from typing import Annotated, Literal
from pydantic import BaseModel, ConfigDict, Field, model_validator

Finite = Annotated[float, Field(allow_inf_nan=False)]
Vector3 = Annotated[list[Finite], Field(min_length=3, max_length=3)]
InstancePath = Annotated[str, Field(pattern=r"^[1-9][0-9]*(\.[1-9][0-9]*)*$", max_length=2048)]
ParentPath = Annotated[str, Field(pattern=r"^([1-9][0-9]*(\.[1-9][0-9]*)*)?$", max_length=2048)]
Paths = Annotated[list[InstancePath], Field(min_length=1, max_length=500)]
Matrix16 = Annotated[list[Finite], Field(min_length=16, max_length=16)]


class CameraSpec(BaseModel):
    """World-space camera: millimeters; FOV uses the native camera axis."""
    model_config = ConfigDict(extra="forbid")
    eye_mm: Vector3
    target_mm: Vector3
    up: Vector3
    projection: Literal["perspective", "parallel"] = "perspective"
    fov_degrees: Annotated[Finite, Field(ge=1, le=120)] = 35
    height_mm: Annotated[Finite, Field(gt=0)] = 1000

    @model_validator(mode="after")
    def valid_basis(self):
        direction = [b-a for a, b in zip(self.eye_mm, self.target_mm)]
        cross = [direction[1]*self.up[2]-direction[2]*self.up[1],
                 direction[2]*self.up[0]-direction[0]*self.up[2],
                 direction[0]*self.up[1]-direction[1]*self.up[0]]
        if sum(v*v for v in direction) <= 1e-18 or sum(v*v for v in cross) <= 1e-18:
            raise ValueError("camera eye/target/up must form a non-degenerate basis")
        return self


class VisibilityOverride(BaseModel):
    model_config = ConfigDict(extra="forbid")
    instance_path: InstancePath
    visible: Annotated[bool, Field(strict=True)]
