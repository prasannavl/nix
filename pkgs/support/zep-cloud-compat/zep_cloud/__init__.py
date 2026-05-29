from __future__ import annotations

import sys
import types as module_types
from typing import Any


class InternalServerError(Exception):
    pass


class BadRequestError(Exception):
    pass


class NotFoundError(Exception):
    pass


class CompatModel(dict):
    """Small SDK-like model: dict-serializable with attribute access."""

    def __init__(self, **kwargs: Any):
        if "uuid" in kwargs and "uuid_" not in kwargs:
            kwargs["uuid_"] = kwargs["uuid"]
        if "uuid_" in kwargs and "uuid" not in kwargs:
            kwargs["uuid"] = kwargs["uuid_"]
        super().__init__({key: to_model(value) for key, value in kwargs.items()})

    def __getattr__(self, key: str) -> Any:
        try:
            return self[key]
        except KeyError as exc:
            raise AttributeError(key) from exc

    def __setattr__(self, key: str, value: Any) -> None:
        self[key] = to_model(value)

    def model_dump(self, *_, by_alias: bool = False, **__) -> dict[str, Any]:
        data = dict(self)
        if by_alias and "uuid_" in data and "uuid" not in data:
            data["uuid"] = data["uuid_"]
        return data

    def dict(self, *args: Any, **kwargs: Any) -> dict[str, Any]:
        return self.model_dump(*args, **kwargs)


def to_model(value: Any) -> Any:
    if isinstance(value, CompatModel):
        return value
    if isinstance(value, dict):
        if "uuid" in value and "uuid_" not in value:
            value = {**value, "uuid_": value["uuid"]}
        return CompatModel(**value)
    if isinstance(value, list):
        return [to_model(item) for item in value]
    return value


class ApiError(CompatModel):
    pass


class AddThreadMessagesRequest(CompatModel):
    pass


class AddThreadMessagesResponse(CompatModel):
    pass


class AddTripleResponse(CompatModel):
    pass


class CloneGraphResponse(CompatModel):
    pass


class ContextTemplateResponse(CompatModel):
    pass


class DateFilter(CompatModel):
    pass


class EdgeType(CompatModel):
    pass


class EntityEdge(CompatModel):
    pass


class EntityNode(CompatModel):
    pass


class EntityProperty(CompatModel):
    pass


class EntityType(CompatModel):
    pass


class EntityTypeResponse(CompatModel):
    pass


class Episode(CompatModel):
    pass


class EpisodeData(CompatModel):
    def __init__(
        self,
        data: str,
        type: str = "text",
        uuid: str | None = None,
        name: str = "mirofish",
        created_at: str | None = None,
        source_description: str | None = None,
        **kwargs: Any,
    ):
        super().__init__(
            data=data,
            type=type,
            uuid=uuid,
            uuid_=uuid,
            name=name,
            created_at=created_at,
            source_description=source_description,
            **kwargs,
        )


class EpisodeMentions(CompatModel):
    pass


class EpisodeResponse(CompatModel):
    def __init__(self, episodes: list[Any] | None = None, **kwargs: Any):
        super().__init__(episodes=episodes or [], **kwargs)


class FactRatingExamples(CompatModel):
    pass


class FactRatingInstruction(CompatModel):
    pass


class GetTaskResponse(CompatModel):
    pass


class Graph(CompatModel):
    pass


class GraphEdgesRequest(CompatModel):
    pass


class GraphListResponse(CompatModel):
    pass


class GraphNodesRequest(CompatModel):
    pass


class GraphSearchResults(CompatModel):
    def __init__(
        self,
        edges: list[Any] | None = None,
        episodes: list[Any] | None = None,
        nodes: list[Any] | None = None,
        **kwargs: Any,
    ):
        super().__init__(
            edges=edges or [],
            episodes=episodes or [],
            nodes=nodes or [],
            **kwargs,
        )


class ListContextTemplatesResponse(CompatModel):
    pass


class ListUserInstructionsResponse(CompatModel):
    pass


class Message(CompatModel):
    pass


class MessageListResponse(CompatModel):
    pass


class ModelsFactRatingExamples(CompatModel):
    pass


class ModelsFactRatingInstruction(CompatModel):
    pass


class ProjectInfo(CompatModel):
    pass


class ProjectInfoResponse(CompatModel):
    pass


class SearchFilters(CompatModel):
    pass


class SuccessResponse(CompatModel):
    def __init__(self, message: str | None = None, **kwargs: Any):
        super().__init__(message=message, **kwargs)


class TaskErrorResponse(CompatModel):
    pass


class TaskProgress(CompatModel):
    pass


class Thread(CompatModel):
    pass


class ThreadContextResponse(CompatModel):
    pass


class ThreadListResponse(CompatModel):
    pass


class User(CompatModel):
    pass


class UserInstruction(CompatModel):
    pass


class UserListResponse(CompatModel):
    pass


class UserNodeResponse(CompatModel):
    pass


class EntityEdgeSourceTarget(CompatModel):
    def __init__(self, source: str | None = None, target: str | None = None, **kwargs: Any):
        super().__init__(source=source, target=target, **kwargs)


ComparisonOperator = Any
EntityPropertyType = Any
GraphDataType = Any
GraphSearchScope = Any
Reranker = Any
RoleType = Any
ThreadGetUserContextRequestMode = Any
ZepEnvironment = Any
__version__ = "3.13.0-local-graphiti"


_type_exports = {
    name: value
    for name, value in globals().items()
    if name[0].isupper()
    or name
    in {
        "ComparisonOperator",
        "EntityPropertyType",
        "GraphDataType",
        "GraphSearchScope",
        "Reranker",
        "RoleType",
    }
}


def _snake_case(name: str) -> str:
    result = []
    for index, char in enumerate(name):
        if char.isupper() and index > 0:
            previous = name[index - 1]
            next_char = name[index + 1] if index + 1 < len(name) else ""
            if previous.islower() or next_char.islower():
                result.append("_")
        result.append(char.lower())
    return "".join(result)


types_module = module_types.ModuleType("zep_cloud.types")
types_module.__path__ = []
for name, value in _type_exports.items():
    setattr(types_module, name, value)
sys.modules.setdefault("zep_cloud.types", types_module)

for name, value in _type_exports.items():
    module_name = f"zep_cloud.types.{_snake_case(name)}"
    type_module = module_types.ModuleType(module_name)
    setattr(type_module, name, value)
    sys.modules.setdefault(module_name, type_module)

errors_module = module_types.ModuleType("zep_cloud.errors")
errors_module.__path__ = []
errors_module.BadRequestError = BadRequestError
errors_module.InternalServerError = InternalServerError
errors_module.NotFoundError = NotFoundError
sys.modules.setdefault("zep_cloud.errors", errors_module)

for _name, _error in {
    "bad_request_error": BadRequestError,
    "internal_server_error": InternalServerError,
    "not_found_error": NotFoundError,
}.items():
    _module = module_types.ModuleType(f"zep_cloud.errors.{_name}")
    setattr(_module, _error.__name__, _error)
    sys.modules.setdefault(f"zep_cloud.errors.{_name}", _module)

from .client import AsyncZep, Zep


__all__ = [
    *_type_exports.keys(),
    "AsyncZep",
    "BadRequestError",
    "CompatModel",
    "InternalServerError",
    "NotFoundError",
    "ThreadGetUserContextRequestMode",
    "Zep",
    "ZepEnvironment",
    "__version__",
    "to_model",
]
