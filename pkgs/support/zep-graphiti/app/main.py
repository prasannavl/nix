from __future__ import annotations

import asyncio
import contextvars
import json
import logging
import os
import re
import uuid as uuidlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import Any, Optional, get_args, get_origin

import uvicorn
from fastapi import Body, FastAPI, HTTPException, status
from pydantic import BaseModel, Field, create_model

import graphiti_core.graphiti as graphiti_module
from graphiti_core import Graphiti
from graphiti_core.embedder import OpenAIEmbedder, OpenAIEmbedderConfig
from graphiti_core.edges import EntityEdge
from graphiti_core.errors import EdgeNotFoundError, GroupsEdgesNotFoundError, NodeNotFoundError
from graphiti_core.llm_client import OpenAIClient
from graphiti_core.llm_client.config import LLMConfig
from graphiti_core.nodes import EntityNode, EpisodeType, EpisodicNode
from graphiti_core.utils.maintenance.graph_data_operations import clear_data

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("zep_graphiti")
GRAPH_PROPERTY_SCALARS = (str, int, float, bool, datetime)

app = FastAPI(title="Abird Graphiti")
graph: Graphiti | None = None
episode_states: dict[str, dict[str, Any]] = {}
episode_batches: dict[str, "EpisodeBatch"] = {}
episode_to_batch: dict[str, str] = {}
graph_failures: dict[str, dict[str, Any]] = {}
graph_cancellations: set[str] = set()
graph_ontologies: dict[str, "GraphOntology"] = {}
episode_semaphore: asyncio.Semaphore | None = None
current_graph_id: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "current_graph_id",
    default=None,
)
_original_add_nodes_and_edges_bulk = graphiti_module.add_nodes_and_edges_bulk


@dataclass
class EpisodeBatch:
    uuid: str
    graph_id: str
    episode_ids: list[str]
    created_at: datetime
    state: str = "queued"
    failed_episode_uuid: str | None = None
    error: str | None = None
    finished_at: datetime | None = None
    tasks: dict[str, asyncio.Task[None]] = field(default_factory=dict)


@dataclass
class GraphOntology:
    entities: dict[str, type[BaseModel]]
    edges: dict[str, type[BaseModel]]
    edge_type_map: dict[tuple[str, str], list[str]]
    raw_entities: list[dict[str, Any]]
    raw_edges: list[dict[str, Any]]


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    try:
        return int(value)
    except ValueError:
        logger.warning("invalid integer for %s=%r; using %s", name, value, default)
        return default


def env_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    try:
        return float(value)
    except ValueError:
        logger.warning("invalid float for %s=%r; using %s", name, value, default)
        return default


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None or value == "":
        return default

    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False

    logger.warning("invalid boolean for %s=%r; using %s", name, value, default)
    return default


def env_optional(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name, default)
    if value is None:
        return None
    value = value.strip()
    return value or None


RESERVED_GRAPH_PROPERTY_NAMES = {
    "uuid",
    "name",
    "group_id",
    "name_embedding",
    "summary",
    "created_at",
}


def safe_graph_property_name(name: str) -> str:
    normalized = re.sub(r"\W+", "_", str(name)).strip("_") or "value"
    if normalized.lower() in RESERVED_GRAPH_PROPERTY_NAMES:
        return f"entity_{normalized}"
    return normalized


def safe_model_name(name: str, default: str) -> str:
    parts = [part for part in re.split(r"\W+", str(name)) if part]
    if not parts:
        return default
    model_name = "".join(part[:1].upper() + part[1:] for part in parts)
    if not model_name[0].isalpha():
        model_name = f"{default}{model_name}"
    return model_name


def schema_properties(value: dict[str, Any]) -> list[dict[str, Any]]:
    properties = value.get("properties", value.get("attributes", []))
    return properties if isinstance(properties, list) else []


def ontology_model(
    name: str, description: str, properties: list[dict[str, Any]]
) -> type[BaseModel]:
    fields = {}
    for prop in properties:
        if not isinstance(prop, dict):
            continue
        prop_name = safe_graph_property_name(prop.get("name", "value"))
        prop_description = str(prop.get("description") or prop_name)
        fields[prop_name] = (Optional[str], Field(default=None, description=prop_description))

    model = create_model(safe_model_name(name, "OntologyModel"), **fields)
    model.__doc__ = description
    return model


def build_graph_ontology(request: dict[str, Any] | None) -> GraphOntology:
    request = request or {}
    raw_entities = request.get("entities") or request.get("entity_types") or []
    raw_edges = request.get("edges") or request.get("edge_types") or []
    raw_entities = raw_entities if isinstance(raw_entities, list) else []
    raw_edges = raw_edges if isinstance(raw_edges, list) else []

    entities = {}
    for entity in raw_entities:
        if not isinstance(entity, dict):
            continue
        name = str(entity.get("name") or "").strip()
        if not name:
            continue
        entities[name] = ontology_model(
            name,
            str(entity.get("description") or f"A {name} entity."),
            schema_properties(entity),
        )

    edges = {}
    edge_type_map: dict[tuple[str, str], list[str]] = {}
    for edge in raw_edges:
        if not isinstance(edge, dict):
            continue
        name = str(edge.get("name") or "").strip()
        if not name:
            continue
        edges[name] = ontology_model(
            safe_model_name(name, "Edge"),
            str(edge.get("description") or f"A {name} relationship."),
            schema_properties(edge),
        )

        source_targets = edge.get("source_targets") or []
        if not isinstance(source_targets, list):
            source_targets = []
        if not source_targets:
            source_targets = [{"source": "Entity", "target": "Entity"}]
        for source_target in source_targets:
            if not isinstance(source_target, dict):
                continue
            signature = (
                str(source_target.get("source") or "Entity"),
                str(source_target.get("target") or "Entity"),
            )
            edge_type_map.setdefault(signature, []).append(name)

    return GraphOntology(
        entities=entities,
        edges=edges,
        edge_type_map=edge_type_map,
        raw_entities=raw_entities,
        raw_edges=raw_edges,
    )


def jsonable_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, BaseModel):
        return jsonable_value(value.model_dump())
    if isinstance(value, list):
        return [jsonable_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): jsonable_value(item) for key, item in value.items()}
    return value


def graph_property_value(value: Any) -> Any:
    if value is None or isinstance(value, GRAPH_PROPERTY_SCALARS):
        return value

    if isinstance(value, list):
        if all(item is None or isinstance(item, GRAPH_PROPERTY_SCALARS) for item in value):
            return value

    return json.dumps(
        jsonable_value(value),
        default=str,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def sanitize_graph_attributes(attributes: dict[str, Any] | None) -> dict[str, Any]:
    return {
        str(key): graph_property_value(value)
        for key, value in (attributes or {}).items()
    }


def structured_key_token(key: Any) -> str:
    return safe_graph_property_name(str(key)).replace("_", "").lower()


def model_field_map(response_model: type[BaseModel]) -> dict[str, str]:
    fields = getattr(response_model, "model_fields", {})
    field_map = {}

    for field_name, field_info in fields.items():
        candidates = [field_name]
        for attr_name in ("alias", "serialization_alias"):
            alias = getattr(field_info, attr_name, None)
            if isinstance(alias, str):
                candidates.append(alias)

        for candidate in candidates:
            field_map[structured_key_token(candidate)] = field_name

    return field_map


def normalize_model_envelope(
    response_model: type[BaseModel], value: dict[str, Any]
) -> dict[str, Any]:
    fields = getattr(response_model, "model_fields", {})
    if len(fields) != 1:
        return value

    model_name = getattr(response_model, "__name__", "")
    model_token = structured_key_token(model_name)
    single_field = next(iter(fields))

    for key, nested_value in value.items():
        if structured_key_token(key) != model_token:
            continue
        if isinstance(nested_value, dict):
            return nested_value
        return {single_field: nested_value}

    return value


def normalize_model_field_keys(
    response_model: type[BaseModel], value: dict[str, Any]
) -> dict[str, Any]:
    field_map = model_field_map(response_model)
    if not field_map:
        return value
    return {
        field_map.get(structured_key_token(key), str(key)): nested_value
        for key, nested_value in value.items()
    }


def base_model_annotation(annotation: Any) -> type[BaseModel] | None:
    if isinstance(annotation, type) and issubclass(annotation, BaseModel):
        return annotation

    for arg in get_args(annotation):
        model = base_model_annotation(arg)
        if model is not None:
            return model

    return None


def normalize_structured_value(annotation: Any, value: Any, field_name: str = "") -> Any:
    origin = get_origin(annotation)
    args = get_args(annotation)
    field_token = structured_key_token(field_name) if field_name else ""
    if origin is list and args and isinstance(value, list):
        normalized = []
        for item in value:
            if isinstance(item, dict):
                matching_values = [
                    nested_value
                    for key, nested_value in item.items()
                    if field_token and structured_key_token(key) == field_token
                ]
                if len(matching_values) == 1 and isinstance(matching_values[0], list):
                    normalized.extend(
                        normalize_structured_value(args[0], nested_item)
                        for nested_item in matching_values[0]
                    )
                    continue

            normalized.append(normalize_structured_value(args[0], item))
        return normalized
    if origin is list and args and isinstance(value, dict):
        matching_values = [
            nested_value
            for key, nested_value in value.items()
            if field_token and structured_key_token(key) == field_token
        ]
        if len(matching_values) == 1:
            return normalize_structured_value(annotation, matching_values[0], field_name)

    model = base_model_annotation(annotation)
    if model is not None and isinstance(value, dict):
        return normalize_structured_model_value(model, value)

    return value


def normalize_structured_model_value(
    response_model: type[BaseModel], value: dict[str, Any]
) -> dict[str, Any]:
    value = normalize_model_envelope(response_model, value)
    value = normalize_model_field_keys(response_model, value)
    fields = getattr(response_model, "model_fields", {})
    return {
        key: normalize_structured_value(fields[key].annotation, nested_value, key)
        if key in fields
        else nested_value
        for key, nested_value in value.items()
    }


def normalize_graph_attribute_response(
    response_model: type[BaseModel], attributes: dict[str, Any]
) -> dict[str, Any]:
    normalized = normalize_structured_model_value(response_model, attributes)
    return sanitize_graph_attributes(normalized)


def sanitize_graphiti_bulk_payload(nodes: list[Any], edges: list[Any]) -> None:
    for node in nodes:
        node.attributes = sanitize_graph_attributes(getattr(node, "attributes", None))
    for edge in edges:
        edge.attributes = sanitize_graph_attributes(getattr(edge, "attributes", None))


async def add_nodes_and_edges_bulk_with_sanitized_properties(
    driver: Any,
    episodes: list[Any],
    episodic_edges: list[Any],
    entity_nodes: list[Any],
    entity_edges: list[Any],
    embedder: Any,
) -> Any:
    sanitize_graphiti_bulk_payload(entity_nodes, entity_edges)
    return await _original_add_nodes_and_edges_bulk(
        driver,
        episodes,
        episodic_edges,
        entity_nodes,
        entity_edges,
        embedder,
    )


def install_graphiti_property_sanitizer() -> None:
    graphiti_module.add_nodes_and_edges_bulk = (
        add_nodes_and_edges_bulk_with_sanitized_properties
    )


def coerce_int(value: Any, default: int | None = -1) -> int | None:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            return default
    return default


def coerce_int_list(value: Any) -> list[int]:
    if not isinstance(value, list):
        return []
    return [
        item
        for item in (coerce_int(item, default=None) for item in value)
        if item is not None
    ]


def normalize_node_resolutions(value: dict[str, Any]) -> dict[str, Any]:
    resolutions = value.get("entity_resolutions")
    if not isinstance(resolutions, list):
        return value

    for resolution in resolutions:
        if not isinstance(resolution, dict):
            continue
        if "duplicate_idx" not in resolution and "duplication_idx" in resolution:
            resolution["duplicate_idx"] = resolution["duplication_idx"]
        resolution["id"] = coerce_int(resolution.get("id"))
        resolution["duplicate_idx"] = coerce_int(resolution.get("duplicate_idx"))
        resolution["additional_duplicates"] = coerce_int_list(
            resolution.get("additional_duplicates")
        )
    return value


def normalize_edge_duplicate(value: dict[str, Any]) -> dict[str, Any]:
    value["duplicate_fact_id"] = coerce_int(value.get("duplicate_fact_id"))
    value["contradicted_facts"] = coerce_int_list(value.get("contradicted_facts"))
    if not isinstance(value.get("fact_type"), str) or not value["fact_type"].strip():
        value["fact_type"] = "DEFAULT"
    return value


install_graphiti_property_sanitizer()


class ConfigurableOpenAIClient(OpenAIClient):
    def __init__(
        self,
        *args: Any,
        reasoning_effort: str | None = None,
        request_timeout_seconds: float | None = None,
        structured_max_retries: int | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(*args, **kwargs)
        self.reasoning_effort = reasoning_effort
        self.request_timeout_seconds = request_timeout_seconds
        if structured_max_retries is not None:
            self.max_retries = structured_max_retries

    def request_kwargs(self) -> dict[str, Any]:
        kwargs = {}
        if self.reasoning_effort is not None:
            kwargs["reasoning_effort"] = self.reasoning_effort
        if self.request_timeout_seconds is not None:
            kwargs["timeout"] = self.request_timeout_seconds
        return kwargs

    @staticmethod
    def raise_if_graph_cancelled() -> None:
        graph_id = current_graph_id.get()
        if graph_id is None or graph_id not in graph_cancellations:
            return

        error = graph_failure_error(graph_id) or f"graph {graph_id} has been canceled"
        raise RuntimeError(error)

    async def create_chat_completion(self, **kwargs: Any) -> Any:
        self.raise_if_graph_cancelled()
        request = self.client.chat.completions.create(**kwargs)
        if self.request_timeout_seconds is None:
            response = await request
        else:
            response = await asyncio.wait_for(
                request,
                timeout=self.request_timeout_seconds,
            )
        self.raise_if_graph_cancelled()
        return response

    @staticmethod
    def structured_messages(
        messages: list[Any], response_model: type[BaseModel]
    ) -> list[Any]:
        schema = json.dumps(response_model.model_json_schema(), separators=(",", ":"))
        guard = {
            "role": "system",
            "content": (
                "Return only valid JSON matching the requested schema. "
                "Do not wrap JSON in markdown fences. Do not add prose.\n"
                f"JSON schema: {schema}"
            ),
        }
        return [guard, *messages]

    @staticmethod
    def extract_json(content: str) -> Any:
        normalized = content.strip()
        fenced_match = re.fullmatch(
            r"```(?:json)?\s*(.*?)\s*```",
            normalized,
            flags=re.IGNORECASE | re.DOTALL,
        )
        if fenced_match is not None:
            normalized = fenced_match.group(1).strip()

        decoder = json.JSONDecoder()
        for index, char in enumerate(normalized):
            if char not in "{[":
                continue
            try:
                value, _ = decoder.raw_decode(normalized[index:])
                return value
            except json.JSONDecodeError:
                continue
        raise ValueError("structured response did not contain valid JSON")

    @staticmethod
    def parsed_response(parsed: BaseModel) -> Any:
        message = SimpleNamespace(parsed=parsed, refusal=None)
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])

    @staticmethod
    def normalize_structured_json(response_model: type[BaseModel], value: Any) -> Any:
        if not isinstance(value, dict):
            return value

        value = normalize_structured_model_value(response_model, value)

        model_name = getattr(response_model, "__name__", "")
        if model_name == "NodeResolutions":
            return normalize_node_resolutions(value)
        if model_name == "EdgeDuplicate":
            return normalize_edge_duplicate(value)
        if model_name.startswith(("EntityAttributes_", "EdgeAttributes_")):
            return normalize_graph_attribute_response(response_model, value)
        return value

    async def _create_completion(
        self,
        model: str,
        messages: list[Any],
        temperature: float | None,
        max_tokens: int,
        response_model: type[BaseModel] | None = None,
    ) -> Any:
        return await self.create_chat_completion(
            model=model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            response_format={"type": "json_object"},
            **self.request_kwargs(),
        )

    async def _create_structured_completion(
        self,
        model: str,
        messages: list[Any],
        temperature: float | None,
        max_tokens: int,
        response_model: type[BaseModel],
    ) -> Any:
        response = await self.create_chat_completion(
            model=model,
            messages=self.structured_messages(messages, response_model),
            temperature=temperature,
            max_tokens=max_tokens,
            response_format={"type": "json_object"},
            **self.request_kwargs(),
        )
        content = response.choices[0].message.content or ""
        parsed_json = self.extract_json(content)
        parsed_json = self.normalize_structured_json(response_model, parsed_json)
        parsed = response_model.model_validate(parsed_json)
        return self.parsed_response(parsed)


class Message(BaseModel):
    content: str
    uuid: str | None = None
    name: str = ""
    role_type: str = "user"
    role: str | None = None
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    source_description: str = ""


class AddMessagesRequest(BaseModel):
    group_id: str
    messages: list[Message]


class SearchQuery(BaseModel):
    group_ids: list[str] | None = None
    query: str
    max_facts: int = 10


class EpisodeRequest(BaseModel):
    data: str
    type: str = "text"
    uuid: str | None = None
    name: str = "mirofish"
    created_at: datetime | None = None
    source_description: str = "mirofish"


class EpisodeBatchRequest(BaseModel):
    episodes: list[EpisodeRequest]


class ZepSearchRequest(BaseModel):
    query: str
    limit: int = 10
    scope: str = "edges"
    reranker: str | None = None


class GraphCreateRequest(BaseModel):
    graph_id: str
    name: str = ""
    description: str = ""


def new_graph() -> Graphiti:
    api_key = os.environ.get("OPENAI_API_KEY", "ollama")
    base_url = os.environ.get("OPENAI_BASE_URL")
    model = os.environ.get("MODEL_NAME")
    small_model = os.environ.get("SMALL_MODEL_NAME", model)
    embedding_model = os.environ.get("EMBEDDING_MODEL_NAME", "nomic-embed-text")
    llm_max_tokens = env_int("LLM_MAX_TOKENS", 32768)
    llm_request_timeout = env_float("LLM_REQUEST_TIMEOUT_SECONDS", 120.0)
    llm_structured_max_retries = max(env_int("LLM_STRUCTURED_MAX_RETRIES", 2), 0)
    llm = ConfigurableOpenAIClient(
        config=LLMConfig(
            api_key=api_key,
            base_url=base_url,
            model=model,
            small_model=small_model,
            max_tokens=llm_max_tokens,
        ),
        max_tokens=llm_max_tokens,
        reasoning_effort=env_optional("LLM_REASONING_EFFORT", "none"),
        request_timeout_seconds=(
            llm_request_timeout if llm_request_timeout > 0 else None
        ),
        structured_max_retries=llm_structured_max_retries,
    )
    embedder = OpenAIEmbedder(
        config=OpenAIEmbedderConfig(
            api_key=api_key,
            base_url=base_url,
            embedding_model=embedding_model,
        )
    )
    return Graphiti(
        os.environ["NEO4J_URI"],
        os.environ.get("NEO4J_USER", "neo4j"),
        os.environ["NEO4J_PASSWORD"],
        llm_client=llm,
        embedder=embedder,
    )


def require_graph() -> Graphiti:
    if graph is None:
        raise HTTPException(status_code=503, detail="graphiti is not ready")
    return graph


def require_episode_semaphore() -> asyncio.Semaphore:
    if episode_semaphore is None:
        raise HTTPException(status_code=503, detail="graphiti episode worker is not ready")
    return episode_semaphore


def clean(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, list):
        return [clean(v) for v in value]
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    return value


def node_payload(node: EntityNode) -> dict[str, Any]:
    uuid = getattr(node, "uuid", "")
    return clean(
        {
            "uuid": uuid,
            "uuid_": uuid,
            "name": getattr(node, "name", "") or "",
            "labels": getattr(node, "labels", []) or [],
            "summary": getattr(node, "summary", "") or "",
            "attributes": getattr(node, "attributes", {}) or {},
            "created_at": getattr(node, "created_at", None),
            "score": getattr(node, "score", None),
            "relevance": getattr(node, "relevance", None),
        }
    )


def edge_payload(edge: EntityEdge) -> dict[str, Any]:
    uuid = getattr(edge, "uuid", "")
    return clean(
        {
            "uuid": uuid,
            "uuid_": uuid,
            "name": getattr(edge, "name", "") or "",
            "fact": getattr(edge, "fact", "") or "",
            "source_node_uuid": getattr(edge, "source_node_uuid", "") or "",
            "target_node_uuid": getattr(edge, "target_node_uuid", "") or "",
            "attributes": getattr(edge, "attributes", {}) or {},
            "created_at": getattr(edge, "created_at", None),
            "valid_at": getattr(edge, "valid_at", None),
            "invalid_at": getattr(edge, "invalid_at", None),
            "expired_at": getattr(edge, "expired_at", None),
            "episodes": getattr(edge, "episodes", None) or [],
            "score": getattr(edge, "score", None),
            "relevance": getattr(edge, "relevance", None),
        }
    )


def episode_payload(uuid: str, episode: Any | None = None) -> dict[str, Any]:
    payload = {
        "uuid": uuid,
        "uuid_": uuid,
        "processed": True,
        "state": "processed",
    }
    if episode is not None:
        payload.update(clean(episode.model_dump()))
        payload["uuid"] = payload.get("uuid") or uuid
        payload["uuid_"] = payload.get("uuid_") or payload["uuid"]
        payload["processed"] = payload.get("processed", True)
    return payload


def cancel_episode_state(episode_uuid: str, reason: str) -> None:
    canceled_at = datetime.now(timezone.utc)
    existing = episode_states.get(episode_uuid, episode_payload(episode_uuid))
    if existing.get("state") == "canceled" and existing.get("finished_at"):
        return

    queued_at = existing.get("queued_at")
    elapsed_seconds = (
        round((canceled_at - queued_at).total_seconds(), 3)
        if isinstance(queued_at, datetime)
        else None
    )
    episode_states[episode_uuid] = {
        **existing,
        "processed": False,
        "state": "canceled",
        "failed": True,
        "canceled": True,
        "error": reason,
        "finished_at": canceled_at,
        **({"elapsed_seconds": elapsed_seconds} if elapsed_seconds is not None else {}),
    }


def cancel_batch(batch: EpisodeBatch, failed_episode_uuid: str, error: str) -> None:
    if batch.state in {"failed", "canceled"}:
        return

    batch.state = "failed"
    batch.failed_episode_uuid = failed_episode_uuid
    batch.error = error
    batch.finished_at = datetime.now(timezone.utc)

    reason = f"batch {batch.uuid} canceled after episode {failed_episode_uuid} failed"
    for episode_uuid in batch.episode_ids:
        if episode_uuid == failed_episode_uuid:
            continue

        state = episode_states.get(episode_uuid, {})
        if state.get("finished_at"):
            continue

        cancel_episode_state(episode_uuid, reason)
        task = batch.tasks.get(episode_uuid)
        if task is not None and not task.done():
            task.cancel()


def graph_failure_error(graph_id: str) -> str | None:
    failure = graph_failures.get(graph_id)
    if failure is None and graph_id in graph_cancellations:
        return f"graph {graph_id} has been canceled"
    if failure is None:
        return None
    return str(failure.get("error") or f"graph {graph_id} has failed")


def require_graph_accepting_episodes(graph_id: str) -> None:
    error = graph_failure_error(graph_id)
    if error is not None:
        raise HTTPException(status_code=409, detail=error)


def fail_graph(graph_id: str, failed_episode_uuid: str, error: str) -> None:
    graph_cancellations.add(graph_id)
    if graph_id not in graph_failures:
        graph_failures[graph_id] = {
            "graph_id": graph_id,
            "failed_episode_uuid": failed_episode_uuid,
            "error": error,
            "failed_at": datetime.now(timezone.utc),
        }

    reason = f"graph {graph_id} canceled after episode {failed_episode_uuid} failed"
    current_task = asyncio.current_task()
    for batch in episode_batches.values():
        if batch.graph_id != graph_id:
            continue

        if batch.state not in {"failed", "canceled"}:
            batch.state = "failed"
            batch.failed_episode_uuid = failed_episode_uuid
            batch.error = error
            batch.finished_at = datetime.now(timezone.utc)

        for episode_uuid in batch.episode_ids:
            if episode_uuid == failed_episode_uuid:
                continue

            state = episode_states.get(episode_uuid, {})
            if state.get("finished_at"):
                continue

            cancel_episode_state(episode_uuid, reason)
            task = batch.tasks.get(episode_uuid)
            if task is not None and task is not current_task and not task.done():
                task.cancel()


def batch_for_episode(episode_uuid: str) -> EpisodeBatch | None:
    batch_uuid = episode_to_batch.get(episode_uuid)
    if batch_uuid is None:
        return None
    return episode_batches.get(batch_uuid)


def finish_batch_if_done(batch: EpisodeBatch) -> None:
    if batch.state != "queued":
        return

    if all(episode_states.get(uuid, {}).get("finished_at") for uuid in batch.episode_ids):
        batch_failed = any(
            episode_states.get(uuid, {}).get("state") in {"failed", "canceled"}
            for uuid in batch.episode_ids
        )
        batch.state = "failed" if batch_failed else "processed"
        batch.finished_at = datetime.now(timezone.utc)


def reset_graph_runtime_state(group_id: str, cancel_tasks: bool = True) -> None:
    graph_failures.pop(group_id, None)
    graph_cancellations.discard(group_id)
    graph_ontologies.pop(group_id, None)

    batch_uuids = [
        batch_uuid
        for batch_uuid, batch in episode_batches.items()
        if batch.graph_id == group_id
    ]
    episode_uuids = {
        episode_uuid
        for batch_uuid in batch_uuids
        for episode_uuid in episode_batches[batch_uuid].episode_ids
    }

    for batch_uuid in batch_uuids:
        batch = episode_batches.pop(batch_uuid)
        if cancel_tasks:
            for task in batch.tasks.values():
                if not task.done():
                    task.cancel()

    for episode_uuid in episode_uuids:
        episode_states.pop(episode_uuid, None)
        episode_to_batch.pop(episode_uuid, None)


async def add_episode(group_id: str, episode: EpisodeRequest) -> dict[str, Any]:
    require_graph_accepting_episodes(group_id)
    ontology = graph_ontologies.get(group_id)
    source = EpisodeType.from_str(
        episode.type
        if episode.type in {"message", "json", "text", "fact_triple"}
        else "text"
    )
    graph_token = current_graph_id.set(group_id)
    try:
        result = await require_graph().add_episode(
            # Graphiti 0.22 treats uuid as an existing episode lookup/update key,
            # not as a caller-selected id for new episodes.
            group_id=group_id,
            name=episode.name or "mirofish",
            episode_body=episode.data,
            reference_time=episode.created_at or datetime.now(timezone.utc),
            source=source,
            source_description=episode.source_description or "mirofish",
            entity_types=ontology.entities if ontology is not None else None,
            edge_types=ontology.edges if ontology is not None else None,
            edge_type_map=ontology.edge_type_map if ontology is not None else None,
        )
        return episode_payload(result.episode.uuid)
    finally:
        current_graph_id.reset(graph_token)


async def process_episode_background(
    group_id: str, episode: EpisodeRequest, episode_uuid: str
) -> None:
    state = episode_states.get(episode_uuid, episode_payload(episode_uuid))
    created_at = state.get("queued_at")
    if not isinstance(created_at, datetime):
        created_at = datetime.now(timezone.utc)
        episode_states[episode_uuid] = {
            **state,
            "processed": False,
            "state": "queued",
            "queued_at": created_at,
        }

    try:
        logger.info("queued zep episode %s for graph %s", episode_uuid, group_id)
        graph_error = graph_failure_error(group_id)
        if graph_error is not None:
            cancel_episode_state(episode_uuid, graph_error)
            return

        batch = batch_for_episode(episode_uuid)
        if batch is not None and batch.state in {"failed", "canceled"}:
            cancel_episode_state(
                episode_uuid,
                f"batch {batch.uuid} already {batch.state}",
            )
            return

        async with require_episode_semaphore():
            graph_error = graph_failure_error(group_id)
            if graph_error is not None:
                cancel_episode_state(episode_uuid, graph_error)
                return

            batch = batch_for_episode(episode_uuid)
            if batch is not None and batch.state in {"failed", "canceled"}:
                cancel_episode_state(
                    episode_uuid,
                    f"batch {batch.uuid} already {batch.state}",
                )
                return

            started_at = datetime.now(timezone.utc)
            episode_states[episode_uuid] = {
                **episode_states[episode_uuid],
                "processed": False,
                "state": "processing",
                "started_at": started_at,
            }
            logger.info("processing zep episode %s for graph %s", episode_uuid, group_id)
            result = await add_episode(group_id, episode)
        finished_at = datetime.now(timezone.utc)
        graphiti_uuid = result.get("uuid") or result.get("uuid_")
        episode_states[episode_uuid] = {
            **result,
            "uuid": episode_uuid,
            "uuid_": episode_uuid,
            "graphiti_uuid": graphiti_uuid,
            "processed": True,
            "state": "processed",
            "queued_at": created_at,
            "started_at": started_at,
            "finished_at": finished_at,
            "elapsed_seconds": round((finished_at - created_at).total_seconds(), 3),
        }
        logger.info(
            "processed zep episode %s as graphiti episode %s",
            episode_uuid,
            graphiti_uuid,
        )
        batch = batch_for_episode(episode_uuid)
        if batch is not None:
            finish_batch_if_done(batch)
    except asyncio.CancelledError:
        cancel_episode_state(episode_uuid, "episode canceled after batch failure")
        logger.info("canceled zep episode %s for graph %s", episode_uuid, group_id)
        raise
    except Exception as exc:
        failed_at = datetime.now(timezone.utc)
        logger.exception("failed processing zep episode %s", episode_uuid)
        episode_states[episode_uuid] = {
            **episode_payload(episode_uuid),
            "processed": False,
            "state": "failed",
            "failed": True,
            "error": str(exc),
            "queued_at": created_at,
            "finished_at": failed_at,
            "elapsed_seconds": round((failed_at - created_at).total_seconds(), 3),
        }
        batch = batch_for_episode(episode_uuid)
        if batch is not None:
            if batch.failed_episode_uuid is None:
                batch.failed_episode_uuid = episode_uuid
                batch.error = str(exc)

            if env_bool("GRAPHITI_BATCH_FAIL_FAST", True):
                cancel_batch(batch, episode_uuid, str(exc))
                fail_graph(group_id, episode_uuid, str(exc))
            else:
                finish_batch_if_done(batch)


async def list_nodes(
    group_id: str, limit: int | None = None, uuid_cursor: str | None = None
) -> list[dict[str, Any]]:
    nodes = await EntityNode.get_by_group_ids(
        require_graph().driver, [group_id], limit=limit, uuid_cursor=uuid_cursor
    )
    return [node_payload(node) for node in nodes]


async def list_edges(
    group_id: str, limit: int | None = None, uuid_cursor: str | None = None
) -> list[dict[str, Any]]:
    try:
        edges = await EntityEdge.get_by_group_ids(
            require_graph().driver, [group_id], limit=limit, uuid_cursor=uuid_cursor
        )
    except GroupsEdgesNotFoundError:
        edges = []
    return [edge_payload(edge) for edge in edges]


def text_score(query: str, text: str) -> int:
    haystack = (text or "").lower()
    needle = (query or "").lower()
    if not needle or not haystack:
        return 0
    if needle in haystack:
        return 100
    return sum(
        10
        for word in needle.replace(",", " ").split()
        if len(word) > 1 and word in haystack
    )


@app.on_event("startup")
async def startup() -> None:
    global episode_semaphore, graph
    graph = new_graph()
    episode_semaphore = asyncio.Semaphore(
        int(os.environ.get("GRAPHITI_EPISODE_CONCURRENCY", "1"))
    )
    await graph.build_indices_and_constraints()


@app.on_event("shutdown")
async def shutdown() -> None:
    pending_tasks = [
        task
        for batch in episode_batches.values()
        for task in batch.tasks.values()
        if not task.done()
    ]
    for task in pending_tasks:
        task.cancel()
    if pending_tasks:
        await asyncio.gather(*pending_tasks, return_exceptions=True)

    if graph is not None:
        await graph.close()


@app.get("/healthcheck")
async def healthcheck() -> dict[str, bool]:
    return {"ok": graph is not None}


@app.post("/messages", status_code=status.HTTP_202_ACCEPTED)
async def add_messages(request: AddMessagesRequest) -> dict[str, Any]:
    episodes = []
    for message in request.messages:
        role = message.role or ""
        body = f"{role}({message.role_type}): {message.content}"
        episodes.append(
            await add_episode(
                request.group_id,
                EpisodeRequest(
                    uuid=message.uuid,
                    name=message.name or "message",
                    data=body,
                    type="message",
                    source_description=message.source_description,
                ),
            )
        )
    return {"success": True, "episodes": episodes}


@app.post("/search")
async def search(query: SearchQuery) -> dict[str, Any]:
    edges = await require_graph().search(
        group_ids=query.group_ids,
        query=query.query,
        num_results=query.max_facts,
    )
    return {"facts": [edge_payload(edge) for edge in edges]}


@app.delete("/group/{group_id}")
async def delete_group(group_id: str) -> dict[str, bool]:
    reset_graph_runtime_state(group_id)
    await clear_data(require_graph().driver, group_ids=[group_id])
    return {"success": True}


@app.get("/entity-edge/{uuid}")
async def get_entity_edge(uuid: str) -> dict[str, Any]:
    try:
        edge = await EntityEdge.get_by_uuid(require_graph().driver, uuid)
        return edge_payload(edge)
    except EdgeNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/zep/entity-edge/{uuid}")
async def zep_get_entity_edge(uuid: str) -> dict[str, Any]:
    return await get_entity_edge(uuid)


@app.get("/episodes/{group_id}")
async def get_episodes(group_id: str, last_n: int = 10) -> list[dict[str, Any]]:
    episodes = await require_graph().retrieve_episodes(
        group_ids=[group_id],
        last_n=last_n,
        reference_time=datetime.now(timezone.utc),
    )
    return [clean(episode.model_dump()) for episode in episodes]


@app.post("/zep/graphs")
async def zep_create_graph(request: GraphCreateRequest) -> dict[str, Any]:
    reset_graph_runtime_state(request.graph_id)
    return {
        "graph_id": request.graph_id,
        "uuid": request.graph_id,
        "uuid_": request.graph_id,
        "name": request.name,
        "description": request.description,
    }


@app.get("/zep/graphs/{graph_id}")
async def zep_get_graph(graph_id: str) -> dict[str, Any]:
    failure = graph_failures.get(graph_id)
    ontology = graph_ontologies.get(graph_id)
    return {
        "graph_id": graph_id,
        "uuid": graph_id,
        "uuid_": graph_id,
        "name": graph_id,
        "description": "",
        "state": "failed" if failure is not None else "active",
        "failure": clean(failure) if failure is not None else None,
        "ontology": {
            "entities": ontology.raw_entities,
            "edges": ontology.raw_edges,
        }
        if ontology is not None
        else None,
    }


@app.get("/zep/graphs")
async def zep_list_graphs() -> dict[str, list[Any]]:
    return {"graphs": []}


@app.delete("/zep/graphs/{graph_id}")
async def zep_delete_graph(graph_id: str) -> dict[str, bool]:
    reset_graph_runtime_state(graph_id)
    await clear_data(require_graph().driver, group_ids=[graph_id])
    return {"success": True}


@app.post("/zep/graphs/{graph_id}/ontology")
async def zep_set_ontology(
    graph_id: str, request: dict[str, Any] | None = Body(default=None)
) -> dict[str, Any]:
    ontology = build_graph_ontology(request)
    graph_ontologies[graph_id] = ontology
    return {
        "graph_id": graph_id,
        "success": True,
        "entities": ontology.raw_entities,
        "edges": ontology.raw_edges,
    }


@app.post("/zep/graphs/{graph_id}/episodes")
async def zep_add_episode(graph_id: str, request: EpisodeRequest) -> dict[str, Any]:
    return await add_episode(graph_id, request)


@app.post("/zep/graphs/{graph_id}/episodes/batch")
async def zep_add_episode_batch(
    graph_id: str, request: EpisodeBatchRequest
) -> list[dict[str, Any]]:
    require_graph_accepting_episodes(graph_id)

    queued = []
    batch_uuid = str(uuidlib.uuid4())
    episode_ids = [episode.uuid or str(uuidlib.uuid4()) for episode in request.episodes]
    batch = EpisodeBatch(
        uuid=batch_uuid,
        graph_id=graph_id,
        episode_ids=episode_ids,
        created_at=datetime.now(timezone.utc),
    )
    episode_batches[batch_uuid] = batch

    for episode, episode_uuid in zip(request.episodes, episode_ids):
        queued_episode = EpisodeRequest(
            data=episode.data,
            type=episode.type,
            uuid=episode_uuid,
            name=episode.name,
            created_at=episode.created_at,
            source_description=episode.source_description,
        )
        episode_to_batch[episode_uuid] = batch_uuid
        episode_states[episode_uuid] = {
            **episode_payload(episode_uuid),
            "processed": False,
            "state": "queued",
            "batch_uuid": batch_uuid,
            "queued_at": batch.created_at,
        }
        queued.append(episode_states[episode_uuid])
        batch.tasks[episode_uuid] = asyncio.create_task(
            process_episode_background(graph_id, queued_episode, episode_uuid),
            name=f"zep-episode-{episode_uuid}",
        )
    return queued


@app.get("/zep/graphs/{graph_id}/episodes")
async def zep_get_graph_episodes(
    graph_id: str, last_n: int = 10
) -> dict[str, list[dict[str, Any]]]:
    return {"episodes": await get_episodes(graph_id, last_n=last_n)}


@app.get("/zep/episodes/{uuid}")
async def zep_get_episode(uuid: str) -> dict[str, Any]:
    if uuid in episode_states:
        state = episode_states[uuid]
        queued_at = state.get("queued_at")
        if isinstance(queued_at, datetime) and not state.get("finished_at"):
            return clean(
                {
                    **state,
                    "elapsed_seconds": round(
                        (datetime.now(timezone.utc) - queued_at).total_seconds(), 3
                    ),
                }
            )
        return clean(state)
    try:
        episode = await EpisodicNode.get_by_uuid(require_graph().driver, uuid)
        return episode_payload(uuid, episode)
    except NodeNotFoundError:
        pass
    return episode_payload(uuid)


@app.get("/zep/graphs/{graph_id}/nodes")
async def zep_get_nodes(
    graph_id: str, limit: int = 100, uuid_cursor: str | None = None
) -> list[dict[str, Any]]:
    return await list_nodes(graph_id, limit=limit, uuid_cursor=uuid_cursor)


@app.get("/zep/graphs/{graph_id}/edges")
async def zep_get_edges(
    graph_id: str, limit: int = 100, uuid_cursor: str | None = None
) -> list[dict[str, Any]]:
    return await list_edges(graph_id, limit=limit, uuid_cursor=uuid_cursor)


@app.get("/zep/nodes/{uuid}")
async def zep_get_node(uuid: str) -> dict[str, Any]:
    try:
        node = await EntityNode.get_by_uuid(require_graph().driver, uuid)
        return node_payload(node)
    except NodeNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/zep/nodes/{uuid}/edges")
async def zep_get_node_edges(uuid: str) -> list[dict[str, Any]]:
    edges = await EntityEdge.get_by_node_uuid(require_graph().driver, uuid)
    return [edge_payload(edge) for edge in edges]


@app.post("/zep/graphs/{graph_id}/search")
async def zep_search(graph_id: str, request: ZepSearchRequest) -> dict[str, Any]:
    edges: list[dict[str, Any]] = []
    nodes: list[dict[str, Any]] = []
    if request.scope in {"edges", "both"}:
        try:
            found = await require_graph().search(
                group_ids=[graph_id],
                query=request.query,
                num_results=request.limit,
            )
            edges = [edge_payload(edge) for edge in found]
        except Exception:
            all_edges = await list_edges(graph_id)
            scored = [
                (
                    text_score(
                        request.query, edge.get("fact", "") + " " + edge.get("name", "")
                    ),
                    edge,
                )
                for edge in all_edges
            ]
            edges = [
                edge
                for score, edge in sorted(
                    scored, key=lambda item: item[0], reverse=True
                )
                if score > 0
            ][: request.limit]
    if request.scope in {"nodes", "both"}:
        all_nodes = await list_nodes(graph_id)
        scored = [
            (
                text_score(
                    request.query, node.get("name", "") + " " + node.get("summary", "")
                ),
                node,
            )
            for node in all_nodes
        ]
        nodes = [
            node
            for score, node in sorted(scored, key=lambda item: item[0], reverse=True)
            if score > 0
        ][: request.limit]
    episodes = []
    if request.scope in {"episodes", "both"}:
        all_episodes = await get_episodes(graph_id, last_n=50)
        scored_episodes = [
            (
                text_score(
                    request.query,
                    episode.get("content", "") + " " + episode.get("name", ""),
                ),
                episode,
            )
            for episode in all_episodes
        ]
        episodes = [
            episode
            for score, episode in sorted(
                scored_episodes, key=lambda item: item[0], reverse=True
            )
            if score > 0
        ][: request.limit]
    return {"edges": edges, "nodes": nodes, "episodes": episodes}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
