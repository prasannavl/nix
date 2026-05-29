from __future__ import annotations

import asyncio
import logging
import os
import uuid as uuidlib
from datetime import datetime, timezone
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, HTTPException, status
from pydantic import BaseModel, Field

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

app = FastAPI(title="Abird Graphiti")
graph: Graphiti | None = None
episode_states: dict[str, dict[str, Any]] = {}
episode_semaphore: asyncio.Semaphore | None = None


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    try:
        return int(value)
    except ValueError:
        logger.warning("invalid integer for %s=%r; using %s", name, value, default)
        return default


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
    llm = OpenAIClient(
        config=LLMConfig(
            api_key=api_key,
            base_url=base_url,
            model=model,
            small_model=small_model,
            max_tokens=env_int("LLM_MAX_TOKENS", 32768),
        ),
        max_tokens=env_int("LLM_MAX_TOKENS", 32768),
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


async def add_episode(group_id: str, episode: EpisodeRequest) -> dict[str, Any]:
    source = EpisodeType.from_str(
        episode.type
        if episode.type in {"message", "json", "text", "fact_triple"}
        else "text"
    )
    result = await require_graph().add_episode(
        # Graphiti 0.22 treats uuid as an existing episode lookup/update key,
        # not as a caller-selected id for new episodes.
        group_id=group_id,
        name=episode.name or "mirofish",
        episode_body=episode.data,
        reference_time=episode.created_at or datetime.now(timezone.utc),
        source=source,
        source_description=episode.source_description or "mirofish",
    )
    return episode_payload(result.episode.uuid)


async def process_episode_background(
    group_id: str, episode: EpisodeRequest, episode_uuid: str
) -> None:
    created_at = datetime.now(timezone.utc)
    episode_states[episode_uuid] = {
        **episode_payload(episode_uuid),
        "processed": False,
        "state": "queued",
        "queued_at": created_at,
    }
    try:
        logger.info("queued zep episode %s for graph %s", episode_uuid, group_id)
        async with require_episode_semaphore():
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
    return {
        "graph_id": request.graph_id,
        "uuid": request.graph_id,
        "uuid_": request.graph_id,
        "name": request.name,
        "description": request.description,
    }


@app.get("/zep/graphs/{graph_id}")
async def zep_get_graph(graph_id: str) -> dict[str, Any]:
    return {
        "graph_id": graph_id,
        "uuid": graph_id,
        "uuid_": graph_id,
        "name": graph_id,
        "description": "",
    }


@app.get("/zep/graphs")
async def zep_list_graphs() -> dict[str, list[Any]]:
    return {"graphs": []}


@app.delete("/zep/graphs/{graph_id}")
async def zep_delete_graph(graph_id: str) -> dict[str, bool]:
    await clear_data(require_graph().driver, group_ids=[graph_id])
    return {"success": True}


@app.post("/zep/graphs/{graph_id}/ontology")
async def zep_set_ontology(
    graph_id: str, request: dict[str, Any] | None = Body(default=None)
) -> dict[str, Any]:
    return {
        "graph_id": graph_id,
        "success": True,
        "entities": (request or {}).get("entities"),
        "edges": (request or {}).get("edges"),
    }


@app.post("/zep/graphs/{graph_id}/episodes")
async def zep_add_episode(graph_id: str, request: EpisodeRequest) -> dict[str, Any]:
    return await add_episode(graph_id, request)


@app.post("/zep/graphs/{graph_id}/episodes/batch")
async def zep_add_episode_batch(
    graph_id: str, request: EpisodeBatchRequest
) -> list[dict[str, Any]]:
    queued = []
    for episode in request.episodes:
        episode_uuid = episode.uuid or str(uuidlib.uuid4())
        queued_episode = EpisodeRequest(
            data=episode.data,
            type=episode.type,
            uuid=episode_uuid,
            name=episode.name,
            created_at=episode.created_at,
            source_description=episode.source_description,
        )
        queued.append(
            {
                **episode_payload(episode_uuid),
                "processed": False,
                "state": "queued",
            }
        )
        asyncio.create_task(
            process_episode_background(graph_id, queued_episode, episode_uuid)
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
