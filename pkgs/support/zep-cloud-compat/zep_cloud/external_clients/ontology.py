from __future__ import annotations

import typing
from enum import Enum

try:
    from pydantic import BaseModel
    from pydantic import Field
except ImportError:
    class BaseModel:
        @classmethod
        def model_json_schema(cls, *args, **kwargs):
            properties = {}
            for name, annotation in getattr(cls, "__annotations__", {}).items():
                if annotation in {int, typing.Optional[int]}:
                    field_type = "integer"
                elif annotation in {float, typing.Optional[float]}:
                    field_type = "number"
                elif annotation in {bool, typing.Optional[bool]}:
                    field_type = "boolean"
                else:
                    field_type = "string"
                properties[name] = {
                    "type": field_type,
                    "description": getattr(getattr(cls, name, None), "description", ""),
                }
            return {"properties": properties}

    class _FieldDefault:
        def __init__(self, default: typing.Any = None, description: str = ""):
            self.default = default
            self.description = description

    def Field(
        default: typing.Any = None, description: str = "", **kwargs: typing.Any
    ) -> typing.Any:
        return _FieldDefault(default=default, description=description)


class EntityPropertyType(Enum):
    Text = "Text"
    Int = "Int"
    Float = "Float"
    Boolean = "Boolean"


EntityText = typing.Optional[str]
EntityInt = typing.Optional[int]
EntityFloat = typing.Optional[float]
EntityBoolean = typing.Optional[bool]



class EntityModel(BaseModel):
    @classmethod
    def model_json_schema(cls, *args, **kwargs):
        return super().model_json_schema(*args, **kwargs)


class EdgeModel(BaseModel):
    @classmethod
    def model_json_schema(cls, *args, **kwargs):
        return super().model_json_schema(*args, **kwargs)


def _type_name(field_schema: dict[str, typing.Any]) -> str:
    field_type = field_schema.get("type")
    if not field_type and "anyOf" in field_schema:
        field_type = next(
            (
                option.get("type")
                for option in field_schema["anyOf"]
                if option.get("type") != "null"
            ),
            None,
        )
    return {
        "string": "Text",
        "integer": "Int",
        "number": "Float",
        "boolean": "Boolean",
    }.get(field_type, "Text")


def _model_to_api_schema_common(
    model_class: type[BaseModel],
    name: str,
    is_edge: bool = False,
) -> dict[str, typing.Any]:
    schema = model_class.model_json_schema()
    result: dict[str, typing.Any] = {
        "name": name,
        "description": (model_class.__doc__ or "").strip(),
        "properties": [],
    }
    if is_edge:
        result["source_targets"] = []

    for field_name, field_schema in schema.get("properties", {}).items():
        result["properties"].append(
            {
                "name": field_name,
                "type": _type_name(field_schema),
                "description": field_schema.get("description", ""),
            }
        )

    return result


def entity_model_to_api_schema(
    model_class: type[EntityModel], name: str
) -> dict[str, typing.Any]:
    return _model_to_api_schema_common(model_class, name, is_edge=False)


def edge_model_to_api_schema(
    model_class: type[EdgeModel], name: str
) -> dict[str, typing.Any]:
    return _model_to_api_schema_common(model_class, name, is_edge=True)


__all__ = [
    "EdgeModel",
    "EntityBoolean",
    "EntityFloat",
    "EntityInt",
    "EntityModel",
    "EntityPropertyType",
    "EntityText",
    "Field",
    "edge_model_to_api_schema",
    "entity_model_to_api_schema",
]
