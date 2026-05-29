from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from . import (
    AddTripleResponse,
    CloneGraphResponse,
    CompatModel,
    EntityEdge,
    EntityNode,
    Episode,
    EpisodeData,
    EpisodeMentions,
    EpisodeResponse,
    Graph as GraphModel,
    GraphListResponse,
    GraphSearchResults,
    InternalServerError,
    NotFoundError,
    SuccessResponse,
    to_model,
)


def to_obj(value: Any) -> Any:
    return to_model(value)


def as_model(value: Any, model: type[CompatModel]) -> CompatModel:
    if isinstance(value, model):
        return value
    if isinstance(value, dict):
        return model(**value)
    if isinstance(value, CompatModel):
        return model(**dict(value))
    return model(value=value)


def as_list(value: Any, model: type[CompatModel]) -> list[CompatModel]:
    return [as_model(item, model) for item in value or []]


def quote(value: str) -> str:
    return urllib.parse.quote(str(value), safe="")


def body_value(value: Any) -> Any:
    if value is ...:
        return None
    if isinstance(value, CompatModel):
        return {key: body_value(item) for key, item in value.items() if item is not None}
    if isinstance(value, dict):
        return {key: body_value(item) for key, item in value.items() if item is not None}
    if isinstance(value, list | tuple):
        return [body_value(item) for item in value]
    if isinstance(value, type):
        return getattr(value, "__name__", str(value))
    return value


def compact_dict(value: dict[str, Any]) -> dict[str, Any]:
    return {key: body_value(item) for key, item in value.items() if item is not None}


def graph_key(graph_id: str | None = None, user_id: str | None = None) -> str:
    key = graph_id or user_id
    if not key:
        raise ValueError("graph_id or user_id is required")
    return str(key)


def ontology_entities(value: Any) -> Any:
    if not value:
        return None
    if not isinstance(value, dict):
        return body_value(value)

    from zep_cloud.external_clients.ontology import entity_model_to_api_schema

    result = []
    for name, model_class in value.items():
        if hasattr(model_class, "model_json_schema"):
            result.append(entity_model_to_api_schema(model_class, name))
        else:
            result.append({"name": name, "properties": body_value(model_class)})
    return result


def ontology_edges(value: Any) -> Any:
    if not value:
        return None
    if not isinstance(value, dict):
        return body_value(value)

    from zep_cloud.external_clients.ontology import edge_model_to_api_schema

    result = []
    for name, edge_definition in value.items():
        edge_class = edge_definition
        source_targets = []
        if isinstance(edge_definition, tuple) and edge_definition:
            edge_class = edge_definition[0]
            source_targets = edge_definition[1] if len(edge_definition) > 1 else []
        if hasattr(edge_class, "model_json_schema"):
            schema = edge_model_to_api_schema(edge_class, name)
        else:
            schema = {"name": name, "properties": body_value(edge_class)}
        schema["source_targets"] = body_value(source_targets or [])
        result.append(schema)
    return result


class Api:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.timeout = float(os.environ.get("ZEP_COMPAT_TIMEOUT_SECONDS", "900"))
        self.retries = int(os.environ.get("ZEP_COMPAT_RETRIES", "6"))
        self.retry_delay = float(os.environ.get("ZEP_COMPAT_RETRY_DELAY_SECONDS", "5"))

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        query: dict[str, Any] | None = None,
    ) -> Any:
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(
                {k: v for k, v in query.items() if v is not None}
            )
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        body = None
        for attempt in range(self.retries + 1):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as response:
                    body = response.read()
                break
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="replace")
                if exc.code == 404:
                    raise NotFoundError(f"{method} {url} failed: {detail}") from exc
                raise InternalServerError(
                    f"{method} {url} failed: {exc.code} {detail}"
                ) from exc
            except OSError as exc:
                if attempt >= self.retries:
                    raise InternalServerError(f"{method} {url} failed: {exc}") from exc
                time.sleep(self.retry_delay)
        if not body:
            return None
        return json.loads(body.decode("utf-8"))


class GraphNode:
    def __init__(self, api: Api):
        self.api = api

    def get_by_graph_id(
        self,
        graph_id: str,
        *,
        limit: int = 100,
        uuid_cursor: str | None = None,
        request_options: Any = None,
    ) -> list[EntityNode]:
        data = self.api.request(
            "GET",
            f"/graphs/{quote(graph_id)}/nodes",
            query={"limit": limit, "uuid_cursor": uuid_cursor},
        )
        return as_list(data, EntityNode)

    def get_by_user_id(
        self,
        user_id: str,
        *,
        limit: int = 100,
        uuid_cursor: str | None = None,
        request_options: Any = None,
    ) -> list[EntityNode]:
        return self.get_by_graph_id(
            user_id,
            limit=limit,
            uuid_cursor=uuid_cursor,
            request_options=request_options,
        )

    def get(self, uuid_: str, *, request_options: Any = None) -> EntityNode:
        return as_model(self.api.request("GET", f"/nodes/{quote(uuid_)}"), EntityNode)

    def get_edges(
        self, node_uuid: str, *, request_options: Any = None
    ) -> list[EntityEdge]:
        data = self.api.request("GET", f"/nodes/{quote(node_uuid)}/edges")
        return as_list(data, EntityEdge)

    def get_entity_edges(
        self, node_uuid: str, *, request_options: Any = None
    ) -> list[EntityEdge]:
        return self.get_edges(node_uuid, request_options=request_options)

    def get_episodes(
        self, node_uuid: str, *, request_options: Any = None
    ) -> EpisodeResponse:
        return EpisodeResponse(episodes=[])


class GraphEdge:
    def __init__(self, api: Api):
        self.api = api

    def get_by_graph_id(
        self,
        graph_id: str,
        *,
        limit: int = 100,
        uuid_cursor: str | None = None,
        request_options: Any = None,
    ) -> list[EntityEdge]:
        data = self.api.request(
            "GET",
            f"/graphs/{quote(graph_id)}/edges",
            query={"limit": limit, "uuid_cursor": uuid_cursor},
        )
        return as_list(data, EntityEdge)

    def get_by_user_id(
        self,
        user_id: str,
        *,
        limit: int = 100,
        uuid_cursor: str | None = None,
        request_options: Any = None,
    ) -> list[EntityEdge]:
        return self.get_by_graph_id(
            user_id,
            limit=limit,
            uuid_cursor=uuid_cursor,
            request_options=request_options,
        )

    def get(self, uuid_: str, *, request_options: Any = None) -> EntityEdge:
        return as_model(self.api.request("GET", f"/entity-edge/{quote(uuid_)}"), EntityEdge)

    def delete(self, uuid_: str, *, request_options: Any = None) -> SuccessResponse:
        return SuccessResponse(message=f"edge {uuid_} delete is not implemented locally")


class GraphEpisode:
    def __init__(self, api: Api):
        self.api = api

    def get(self, uuid_: str, *, request_options: Any = None) -> Episode:
        data = self.api.request("GET", f"/episodes/{quote(uuid_)}")
        if isinstance(data, dict) and data.get("error"):
            raise InternalServerError(f"episode {uuid_} failed: {data['error']}")
        return as_model(data, Episode)

    def get_by_graph_id(
        self, graph_id: str, *, lastn: int | None = None, request_options: Any = None
    ) -> EpisodeResponse:
        data = self.api.request(
            "GET",
            f"/graphs/{quote(graph_id)}/episodes",
            query={"last_n": lastn},
        )
        if isinstance(data, dict) and "episodes" in data:
            return as_model(data, EpisodeResponse)
        return EpisodeResponse(episodes=as_list(data, Episode))

    def get_by_user_id(
        self, user_id: str, *, lastn: int | None = None, request_options: Any = None
    ) -> EpisodeResponse:
        return self.get_by_graph_id(user_id, lastn=lastn, request_options=request_options)

    def delete(self, uuid_: str, *, request_options: Any = None) -> SuccessResponse:
        return SuccessResponse(message=f"episode {uuid_} delete is not implemented locally")

    def get_nodes_and_edges(
        self, uuid_: str, *, request_options: Any = None
    ) -> EpisodeMentions:
        return EpisodeMentions(nodes=[], edges=[])


class Graph:
    def __init__(self, api: Api):
        self.api = api
        self.node = GraphNode(api)
        self.edge = GraphEdge(api)
        self.episode = GraphEpisode(api)

    def create(
        self,
        *,
        graph_id: str,
        name: str = "",
        description: str = "",
        request_options: Any = None,
        **kwargs: Any,
    ) -> GraphModel:
        return as_model(
            self.api.request(
                "POST",
                "/graphs",
                {
                    "graph_id": graph_id,
                    "name": name,
                    "description": description,
                    **body_value(kwargs),
                },
            ),
            GraphModel,
        )

    def get(self, graph_id: str, *, request_options: Any = None) -> GraphModel:
        return GraphModel(graph_id=graph_id, uuid=graph_id, uuid_=graph_id, name=graph_id)

    def update(
        self,
        graph_id: str,
        *,
        name: str | None = None,
        description: str | None = None,
        request_options: Any = None,
        **kwargs: Any,
    ) -> GraphModel:
        return GraphModel(
            graph_id=graph_id,
            uuid=graph_id,
            uuid_=graph_id,
            name=name or graph_id,
            description=description,
            **body_value(kwargs),
        )

    def list_all(
        self,
        *,
        page_number: int | None = None,
        page_size: int | None = None,
        request_options: Any = None,
    ) -> GraphListResponse:
        return GraphListResponse(graphs=[])

    def clone(
        self,
        *,
        source_graph_id: str | None = None,
        source_user_id: str | None = None,
        target_graph_id: str | None = None,
        target_user_id: str | None = None,
        request_options: Any = None,
    ) -> CloneGraphResponse:
        return CloneGraphResponse(
            graph_id=target_graph_id,
            user_id=target_user_id,
            source_graph_id=source_graph_id,
            source_user_id=source_user_id,
        )

    def delete(
        self, graph_id: str, *, request_options: Any = None
    ) -> SuccessResponse:
        self.api.request("DELETE", f"/graphs/{quote(graph_id)}")
        return SuccessResponse(message="Deleted")

    def set_ontology(
        self,
        graph_ids: list[str],
        entities: Any = None,
        edges: Any = None,
        request_options: Any = None,
    ) -> list[Any]:
        results = []
        for graph_id in graph_ids:
            payload = {"entities": ontology_entities(entities), "edges": ontology_edges(edges)}
            results.append(self.api.request("POST", f"/graphs/{quote(graph_id)}/ontology", payload))
        return to_obj(results)

    def set_entity_types(self, *args: Any, **kwargs: Any) -> Any:
        graph_ids = kwargs.get("graph_ids") or []
        return self.set_ontology(
            graph_ids=graph_ids,
            entities=kwargs.get("entity_types"),
            edges=kwargs.get("edge_types"),
        )

    def list_entity_types(self, *args: Any, **kwargs: Any) -> list[Any]:
        return []

    def set_entity_types_internal(self, *args: Any, **kwargs: Any) -> Any:
        return self.set_entity_types(*args, **kwargs)

    def add_batch(
        self,
        *,
        episodes: list[EpisodeData],
        graph_id: str | None = None,
        user_id: str | None = None,
        request_options: Any = None,
    ) -> list[Episode]:
        group_id = graph_key(graph_id, user_id)
        payload = {
            "episodes": [
                compact_dict(
                    {
                        "data": episode.data,
                        "type": episode.type,
                        "uuid": getattr(episode, "uuid", None)
                        or getattr(episode, "uuid_", None),
                        "name": getattr(episode, "name", "mirofish"),
                        "source_description": getattr(
                            episode, "source_description", None
                        )
                        or "mirofish",
                    }
                )
                for episode in episodes
            ]
        }
        return as_list(
            self.api.request("POST", f"/graphs/{quote(group_id)}/episodes/batch", payload),
            Episode,
        )

    def add(
        self,
        *,
        data: str,
        type: str,
        graph_id: str | None = None,
        user_id: str | None = None,
        created_at: str | None = None,
        source_description: str | None = None,
        request_options: Any = None,
    ) -> Episode:
        group_id = graph_key(graph_id, user_id)
        payload = {
            "data": data,
            "type": type,
            "name": "mirofish",
            "created_at": created_at,
            "source_description": source_description,
        }
        return as_model(
            self.api.request("POST", f"/graphs/{quote(group_id)}/episodes", body_value(payload)),
            Episode,
        )

    def add_fact_triple(
        self,
        *,
        fact: str,
        fact_name: str,
        source_node_name: str,
        target_node_name: str,
        graph_id: str | None = None,
        user_id: str | None = None,
        **kwargs: Any,
    ) -> AddTripleResponse:
        episode = self.add(
            graph_id=graph_id,
            user_id=user_id,
            type="text",
            data=f"{source_node_name} -[{fact_name}]-> {target_node_name}: {fact}",
        )
        return AddTripleResponse(episode=episode, fact=fact, name=fact_name)

    def search(
        self,
        *,
        query: str,
        graph_id: str | None = None,
        user_id: str | None = None,
        limit: int = 10,
        scope: str = "edges",
        reranker: str | None = None,
        request_options: Any = None,
        **kwargs: Any,
    ) -> GraphSearchResults:
        group_id = graph_key(graph_id, user_id)
        payload = {"query": query, "limit": limit, "scope": scope, "reranker": reranker}
        return as_model(
            self.api.request("POST", f"/graphs/{quote(group_id)}/search", body_value(payload)),
            GraphSearchResults,
        )


class Zep:
    def __init__(self, api_key: str | None = None, base_url: str | None = None, **_: Any):
        compat_url = base_url or os.environ.get("ZEP_COMPAT_BASE_URL")
        if not compat_url:
            raise ValueError("ZEP_COMPAT_BASE_URL is required for local Graphiti")
        self.api_key = api_key
        self.graph = Graph(Api(compat_url))


class AsyncZep(Zep):
    pass
