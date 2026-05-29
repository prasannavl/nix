from __future__ import annotations

import json
import os
import sys
import urllib.error
import unittest
from pathlib import Path
from typing import Any
from unittest import mock


PACKAGE_PARENT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PACKAGE_PARENT))

from zep_cloud import (  # noqa: E402
    EntityEdge,
    EntityEdgeSourceTarget,
    EntityNode,
    EpisodeData,
    GraphSearchResults,
    InternalServerError,
    NotFoundError,
    SuccessResponse,
)
from zep_cloud.client import Api, Graph, Zep  # noqa: E402
from zep_cloud.external_clients.ontology import (  # noqa: E402
    EdgeModel,
    EntityInt,
    EntityModel,
    EntityText,
    Field,
)


class RecordingApi:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        query: dict[str, Any] | None = None,
    ) -> Any:
        json.dumps(payload)
        self.calls.append(
            {"method": method, "path": path, "payload": payload, "query": query}
        )
        if path == "/graphs":
            return {
                "graph_id": payload["graph_id"],
                "uuid": payload["graph_id"],
                "name": payload["name"],
                "description": payload["description"],
            }
        if path.endswith("/ontology"):
            return {"success": True}
        if path.endswith("/episodes/batch"):
            return [
                {"uuid": "episode-1", "processed": False},
                {"uuid": "episode-2", "processed": False},
            ]
        if path.endswith("/episodes"):
            return {"uuid": "episode-3", "processed": False}
        if path == "/episodes/episode-1":
            return {"uuid": "episode-1", "processed": True, "content": "source"}
        if path == "/episodes/episode-error":
            return {"uuid": "episode-error", "processed": False, "error": "broken"}
        if path.endswith("/nodes"):
            return [
                {
                    "uuid": "node-1",
                    "name": "Alice",
                    "labels": ["Entity", "Person"],
                    "summary": "Investor",
                    "created_at": "2026-05-20T00:00:00Z",
                }
            ]
        if path == "/nodes/node-1":
            return {
                "uuid": "node-1",
                "name": "Alice",
                "labels": ["Entity", "Person"],
                "summary": "Investor",
                "created_at": "2026-05-20T00:00:00Z",
            }
        if path == "/nodes/node-1/edges" or path.endswith("/edges"):
            return [
                {
                    "uuid": "edge-1",
                    "name": "INVESTS_IN",
                    "fact": "Alice invests in ExampleCo",
                    "source_node_uuid": "node-1",
                    "target_node_uuid": "node-2",
                    "created_at": "2026-05-20T00:00:00Z",
                }
            ]
        if path == "/entity-edge/edge-1":
            return {
                "uuid": "edge-1",
                "name": "INVESTS_IN",
                "fact": "Alice invests in ExampleCo",
                "source_node_uuid": "node-1",
                "target_node_uuid": "node-2",
                "created_at": "2026-05-20T00:00:00Z",
            }
        if path.endswith("/search"):
            return {
                "edges": [
                    {
                        "uuid": "edge-1",
                        "name": "INVESTS_IN",
                        "fact": "Alice invests in ExampleCo",
                        "source_node_uuid": "node-1",
                        "target_node_uuid": "node-2",
                        "created_at": "2026-05-20T00:00:00Z",
                    }
                ],
                "nodes": [
                    {
                        "uuid": "node-1",
                        "name": "Alice",
                        "labels": ["Entity", "Person"],
                        "summary": "Investor",
                        "created_at": "2026-05-20T00:00:00Z",
                    }
                ],
                "episodes": [{"uuid": "episode-1", "processed": True}],
            }
        if path == "/graphs/mirofish_test":
            return {"success": True}
        raise AssertionError(f"unexpected request: {method} {path}")


class MiroFishZepCompatTest(unittest.TestCase):
    def setUp(self) -> None:
        self.api = RecordingApi()
        self.graph = Graph(self.api)

    def test_sdk_import_surface(self) -> None:
        from zep_cloud.errors.internal_server_error import (
            InternalServerError as InternalServerErrorModule,
        )
        from zep_cloud.types.entity_edge import EntityEdge as EntityEdgeModule
        from zep_cloud.types.entity_node import EntityNode as EntityNodeModule
        from zep_cloud.types.graph_search_results import (
            GraphSearchResults as GraphSearchResultsModule,
        )

        self.assertIs(InternalServerErrorModule, InternalServerError)
        self.assertIs(EntityEdgeModule, EntityEdge)
        self.assertIs(EntityNodeModule, EntityNode)
        self.assertIs(GraphSearchResultsModule, GraphSearchResults)

    def test_models_are_jsonable_and_have_uuid_aliases(self) -> None:
        node = EntityNode(uuid="node-1", name="Alice", labels=[], summary="")
        edge = EntityEdge(
            uuid_="edge-1",
            name="KNOWS",
            fact="Alice knows Bob",
            source_node_uuid="node-1",
            target_node_uuid="node-2",
        )
        search = GraphSearchResults(edges=[edge], nodes=[node])

        self.assertEqual(node.uuid_, "node-1")
        self.assertEqual(edge.uuid, "edge-1")
        self.assertEqual(search.edges[0].fact, "Alice knows Bob")
        json.dumps(search)
        self.assertEqual(node.model_dump(by_alias=True)["uuid"], "node-1")

    def test_graph_build_calls_used_by_mirofish(self) -> None:
        created = self.graph.create(
            graph_id="mirofish_test",
            name="MiroFish",
            description="Graph",
            request_options={"timeout": 1},
        )
        self.assertEqual(created.graph_id, "mirofish_test")

        batch = self.graph.add_batch(
            graph_id="mirofish_test",
            episodes=[
                EpisodeData(data="chunk one", type="text"),
                EpisodeData(data="chunk two", type="text"),
            ],
        )
        self.assertEqual([episode.uuid_ for episode in batch], ["episode-1", "episode-2"])
        batch_payload = self.api.calls[-1]["payload"]
        self.assertEqual(
            [episode["source_description"] for episode in batch_payload["episodes"]],
            ["mirofish", "mirofish"],
        )
        json.dumps(batch_payload)

        episode = self.graph.episode.get(uuid_="episode-1")
        self.assertTrue(episode.processed)

        nodes = self.graph.node.get_by_graph_id(
            "mirofish_test", limit=100, uuid_cursor=None
        )
        edges = self.graph.edge.get_by_graph_id("mirofish_test", limit=100)
        self.assertEqual(nodes[0].uuid_, "node-1")
        self.assertEqual(edges[0].fact, "Alice invests in ExampleCo")

        node = self.graph.node.get(uuid_="node-1")
        node_edges = self.graph.node.get_entity_edges(node_uuid="node-1")
        edge = self.graph.edge.get(uuid_="edge-1")
        self.assertEqual(node.name, "Alice")
        self.assertEqual(node_edges[0].uuid_, "edge-1")
        self.assertEqual(edge.source_node_uuid, "node-1")

        search = self.graph.search(
            graph_id="mirofish_test",
            query="Alice",
            limit=10,
            scope="both",
            reranker="cross_encoder",
        )
        self.assertEqual(search.edges[0].uuid_, "edge-1")
        self.assertEqual(search.nodes[0].uuid_, "node-1")

        added = self.graph.add(graph_id="mirofish_test", type="text", data="activity")
        self.assertEqual(added.uuid_, "episode-3")

        deleted = self.graph.delete(graph_id="mirofish_test")
        self.assertIsInstance(deleted, SuccessResponse)

    def test_episode_errors_raise_sdk_errors(self) -> None:
        with self.assertRaisesRegex(InternalServerError, "episode episode-error failed"):
            self.graph.episode.get(uuid_="episode-error")

    def test_ontology_models_are_serialized_to_zep_schema(self) -> None:
        class Person(EntityModel):
            """A person."""

            bio: EntityText = Field(default=None, description="Biography")
            age: EntityInt = Field(default=None, description="Age")

        class InvestsIn(EdgeModel):
            """Investment relation."""

            thesis: EntityText = Field(default=None, description="Investment thesis")

        self.graph.set_ontology(
            graph_ids=["mirofish_test"],
            entities={"Person": Person},
            edges={
                "INVESTS_IN": (
                    InvestsIn,
                    [EntityEdgeSourceTarget(source="Person", target="Company")],
                )
            },
        )

        payload = self.api.calls[-1]["payload"]
        self.assertEqual(payload["entities"][0]["name"], "Person")
        self.assertEqual(payload["entities"][0]["properties"][0]["name"], "bio")
        self.assertEqual(payload["edges"][0]["name"], "INVESTS_IN")
        self.assertEqual(
            payload["edges"][0]["source_targets"][0],
            {"source": "Person", "target": "Company"},
        )

    def test_user_id_aliases_cover_sdk_shape(self) -> None:
        self.assertEqual(
            self.graph.node.get_by_user_id("mirofish_test")[0].uuid_, "node-1"
        )
        self.assertEqual(
            self.graph.edge.get_by_user_id("mirofish_test")[0].uuid_, "edge-1"
        )
        self.assertEqual(
            self.graph.search(user_id="mirofish_test", query="Alice").edges[0].uuid_,
            "edge-1",
        )
        self.assertEqual(
            self.graph.add(user_id="mirofish_test", type="text", data="activity").uuid_,
            "episode-3",
        )

    def test_zep_constructor_uses_compat_base_url(self) -> None:
        old_value = os.environ.get("ZEP_COMPAT_BASE_URL")
        os.environ["ZEP_COMPAT_BASE_URL"] = "http://127.0.0.1:65535/zep"
        try:
            client = Zep(api_key="local")
            self.assertEqual(client.api_key, "local")
            self.assertTrue(hasattr(client.graph, "add_batch"))
        finally:
            if old_value is None:
                os.environ.pop("ZEP_COMPAT_BASE_URL", None)
            else:
                os.environ["ZEP_COMPAT_BASE_URL"] = old_value

    def test_http_errors_map_to_sdk_errors(self) -> None:
        class ErrorResponse:
            def __init__(self, body: bytes):
                self.body = body

            def read(self) -> bytes:
                return self.body

            def close(self) -> None:
                pass

        def not_found_urlopen(*args: Any, **kwargs: Any) -> Any:
            raise urllib.error.HTTPError(
                "http://example.invalid",
                404,
                "not found",
                {},
                ErrorResponse(b'{"detail":"missing"}'),
            )

        def internal_urlopen(*args: Any, **kwargs: Any) -> Any:
            raise urllib.error.HTTPError(
                "http://example.invalid",
                500,
                "server error",
                {},
                ErrorResponse(b'{"detail":"broken"}'),
            )

        api = Api("http://example.invalid")
        with mock.patch("urllib.request.urlopen", not_found_urlopen):
            with self.assertRaises(NotFoundError):
                api.request("GET", "/nodes/missing")

        with mock.patch("urllib.request.urlopen", internal_urlopen):
            with self.assertRaises(InternalServerError):
                api.request("POST", "/graphs", {"graph_id": "x"})


if __name__ == "__main__":
    unittest.main()
