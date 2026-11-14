"""Offline contracts against the real core; only the LLM/network is replaced.

Install requirements.txt in an isolated environment, then run this file.
These tests deliberately stay separate from the dependency-light package tests.
"""

from __future__ import annotations

import asyncio
import importlib.metadata
import importlib.util
import inspect
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

os.environ["GRAPHITI_TELEMETRY_ENABLED"] = "false"

from graphiti_core.driver.driver import GraphProvider
from graphiti_core.edges import EntityEdge, get_entity_edge_from_record
from graphiti_core.graph_queries import get_fulltext_indices, get_range_indices
from graphiti_core.llm_client.config import LLMConfig, ModelSize
from graphiti_core.llm_client.errors import RefusalError
from graphiti_core.nodes import EntityNode, get_episodic_node_from_record
from graphiti_core.prompts.dedupe_edges import EdgeDuplicate
from graphiti_core.prompts.dedupe_nodes import NodeResolutions
from graphiti_core.prompts.models import Message
from openai.types.chat import ChatCompletion

PACKAGE_DIR = Path(__file__).resolve().parents[1]
RELEASE = json.loads((PACKAGE_DIR / "release.json").read_text())

spec = importlib.util.spec_from_file_location(
    "zep_graphiti_candidate", PACKAGE_DIR / "app" / "main.py"
)
assert spec is not None and spec.loader is not None
app = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = app
spec.loader.exec_module(app)


def completion(content: str) -> ChatCompletion:
    return ChatCompletion.model_validate(
        {
            "id": "offline",
            "object": "chat.completion",
            "created": 0,
            "model": "local-small",
            "choices": [
                {
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": content},
                }
            ],
            "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
        }
    )


class CoreContractTest(unittest.IsolatedAsyncioTestCase):
    def client(self, *contents: str, **kwargs):
        dispatch = AsyncMock(side_effect=[completion(content) for content in contents])
        client = app.ConfigurableOpenAIClient(
            config=LLMConfig(
                api_key="offline", model="local-main", small_model="local-small"
            ),
            client=SimpleNamespace(
                chat=SimpleNamespace(completions=SimpleNamespace(create=dispatch))
            ),
            reasoning_effort="none",
            request_timeout_seconds=1,
            **kwargs,
        )
        return client, dispatch

    def test_exact_candidate_is_installed(self):
        self.assertEqual(
            importlib.metadata.version("graphiti-core"), RELEASE["coreVersion"]
        )

    async def test_independent_inference_clients_reach_their_own_binding(self):
        await self.assert_inference_bindings(independent=True)

    async def test_legacy_inference_clients_share_the_chat_binding(self):
        await self.assert_inference_bindings(independent=False)

    async def assert_inference_bindings(self, *, independent):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(
                    (
                        self.server.server_port,
                        self.path,
                        self.headers["Authorization"],
                        body,
                    )
                )
                response = (
                    {
                        "object": "list",
                        "data": [
                            {
                                "object": "embedding",
                                "index": 0,
                                "embedding": [0.25] * 768,
                            }
                        ],
                        "model": "served-embedding",
                        "usage": {"prompt_tokens": 1, "total_tokens": 1},
                    }
                    if self.path.endswith("/embeddings")
                    else completion('{"ok":true}').model_dump()
                )
                encoded = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(2)]
        workers = [
            threading.Thread(target=server.serve_forever, daemon=True)
            for server in servers
        ]
        for worker in workers:
            worker.start()
        graph = None
        try:
            environment = {
                "OPENAI_API_KEY": "synthetic-chat-only",
                "OPENAI_BASE_URL": f"http://127.0.0.1:{servers[0].server_port}/chat/v1",
                "MODEL_NAME": "served-chat",
                "SMALL_MODEL_NAME": "served-chat",
                "EMBEDDING_MODEL_NAME": "served-embedding",
                "NEO4J_URI": "bolt://127.0.0.1:1",
                "NEO4J_PASSWORD": "synthetic-unused",
                "LLM_MAX_TOKENS": "32768",
                "LLM_REQUEST_TIMEOUT_SECONDS": "1",
                "LLM_STRUCTURED_MAX_RETRIES": "2",
                "LLM_REASONING_EFFORT": "none",
            }
            if independent:
                environment.update({
                    "EMBEDDING_API_KEY": "synthetic-embedding-only",
                    "EMBEDDING_BASE_URL": (
                        f"http://127.0.0.1:{servers[1].server_port}/embedding/v1"
                    ),
                })
            with (
                patch.dict(os.environ, environment, clear=True),
                patch.object(
                    app,
                    "Graphiti",
                    side_effect=lambda *args, **kwargs: SimpleNamespace(**kwargs),
                ),
            ):
                graph = app.new_graph()
            self.assertEqual(
                await graph.llm_client.generate_response(
                    [Message(role="user", content="Synthetic")]
                ),
                {"ok": True},
            )
            self.assertEqual(
                len(await graph.embedder.create(input_data="Synthetic")), 768
            )
            self.assertEqual(len(requests), 2)
            chat, embedding = requests
            self.assertEqual(
                chat[:3],
                (
                    servers[0].server_port,
                    "/chat/v1/chat/completions",
                    "Bearer synthetic-chat-only",
                ),
            )
            self.assertEqual(chat[3]["model"], "served-chat")
            self.assertEqual(chat[3]["max_tokens"], 32768)
            self.assertEqual(chat[3]["reasoning_effort"], "none")
            self.assertEqual(
                embedding[:3],
                (
                    servers[1 if independent else 0].server_port,
                    "/embedding/v1/embeddings" if independent else "/chat/v1/embeddings",
                    (
                        "Bearer synthetic-embedding-only"
                        if independent
                        else "Bearer synthetic-chat-only"
                    ),
                ),
            )
            self.assertEqual(embedding[3]["model"], "served-embedding")
            self.assertEqual(graph.llm_client.MAX_RETRIES, 2)
            self.assertEqual(graph.llm_client.request_timeout_seconds, 1)
        finally:
            if graph is not None:
                await graph.llm_client.client.close()
                await graph.embedder.client.close()
            for server in servers:
                server.shutdown()
                server.server_close()
            for worker in workers:
                worker.join()

    def test_partial_or_blank_embedding_binding_fails_before_constructing_clients(self):
        for binding in (
            {"EMBEDDING_API_KEY": "synthetic-embedding-only"},
            {"EMBEDDING_BASE_URL": "http://127.0.0.1:1/v1"},
            {"EMBEDDING_API_KEY": "", "EMBEDDING_BASE_URL": "http://127.0.0.1:1/v1"},
            {"EMBEDDING_API_KEY": "synthetic-embedding-only", "EMBEDDING_BASE_URL": " "},
        ):
            with (
                self.subTest(binding=binding),
                patch.dict(os.environ, binding, clear=True),
                patch.object(app, "ConfigurableOpenAIClient") as chat,
                patch.object(app, "OpenAIEmbedder") as embedder,
                patch.object(app, "Graphiti") as graph,
            ):
                with self.assertRaisesRegex(ValueError, "EMBEDDING_API_KEY.*EMBEDDING_BASE_URL"):
                    app.new_graph()
                chat.assert_not_called()
                embedder.assert_not_called()
                graph.assert_not_called()

    async def test_legacy_missing_chat_binding_retains_upstream_defaults(self):
        environment = {"NEO4J_URI": "bolt://127.0.0.1:1", "NEO4J_PASSWORD": "synthetic-unused"}
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(app, "Graphiti", side_effect=lambda *a, **kw: SimpleNamespace(**kw)),
        ):
            graph = app.new_graph()
        try:
            self.assertEqual(graph.llm_client.client.api_key, "ollama")
            self.assertEqual(graph.embedder.client.api_key, "ollama")
            self.assertEqual(str(graph.llm_client.client.base_url), "https://api.openai.com/v1/")
            self.assertEqual(str(graph.embedder.client.base_url), "https://api.openai.com/v1/")
            self.assertEqual(graph.embedder.config.embedding_model, "nomic-embed-text")
        finally:
            await graph.llm_client.client.close()
            await graph.embedder.client.close()

    def test_requirements_pin_matches_canonical_release(self):
        core_pins = [
            line.strip().split("==", 1)[1]
            for line in (PACKAGE_DIR / "tests" / "requirements.txt")
            .read_text()
            .splitlines()
            if line.strip().startswith("graphiti-core==")
        ]
        self.assertEqual(core_pins, [RELEASE["coreVersion"]])

    def test_changed_release_target_rejects_old_core_and_requirements(self):
        with patch.dict(RELEASE, {"coreVersion": "0.0.0-unreviewed"}):
            with self.assertRaises(AssertionError):
                self.test_exact_candidate_is_installed()
            with self.assertRaises(AssertionError):
                self.test_requirements_pin_matches_canonical_release()

    async def test_real_structured_dispatch_normalizes_models_and_tracks_tokens(self):
        client, dispatch = self.client(
            '```json\n{"entity_resolutions":[{"id":"3","name":"Alice",'
            '"Duplicate Candidate ID":"4"}]}\n```'
        )
        result = await client.generate_response(
            [Message(role="system", content="Resolve nodes")],
            response_model=NodeResolutions,
            model_size=ModelSize.small,
            prompt_name="node-contract",
        )
        self.assertEqual(
            NodeResolutions.model_validate(result)
            .entity_resolutions[0]
            .duplicate_candidate_id,
            4,
        )
        request = dispatch.call_args.kwargs
        self.assertEqual(request["model"], "local-small")
        self.assertEqual(request["reasoning_effort"], "none")
        self.assertEqual(request["response_format"], {"type": "json_object"})
        self.assertIn("duplicate_candidate_id", request["messages"][0]["content"])
        self.assertNotIn("verbosity", request)
        self.assertNotIn("reasoning", request)
        usage = client.token_tracker.get_usage()["node-contract"]
        self.assertEqual((usage.total_input_tokens, usage.total_output_tokens), (11, 7))

    async def test_real_edge_model_and_json_path(self):
        client, _ = self.client(
            '{"duplicate_facts":["2","bad"],"contradicted_facts":["3"]}',
            '{"ok":true}',
        )
        result = await client.generate_response(
            [Message(role="system", content="Resolve edges")],
            response_model=EdgeDuplicate,
        )
        parsed = EdgeDuplicate.model_validate(result)
        self.assertEqual(parsed.duplicate_facts, [2])
        self.assertEqual(parsed.contradicted_facts, [3])
        result = await client.generate_response(
            [Message(role="system", content="JSON")]
        )
        self.assertEqual(result, {"ok": True})

    async def test_configured_retries_reach_real_upstream_loop(self):
        client, dispatch = self.client("not JSON", "not JSON", structured_max_retries=1)
        with self.assertRaisesRegex(ValueError, "valid JSON"):
            await client.generate_response(
                [Message(role="system", content="Resolve edges")],
                response_model=EdgeDuplicate,
            )
        self.assertEqual(dispatch.await_count, 2)

    async def test_cancellation_stops_dispatch_in_real_upstream_loop(self):
        client, dispatch = self.client("{}", structured_max_retries=0)
        app.graph_cancellations.add("offline-canceled")
        token = app.current_graph_id.set("offline-canceled")
        try:
            with self.assertRaisesRegex(RuntimeError, "canceled"):
                await client.generate_response(
                    [Message(role="system", content="Resolve edges")],
                    response_model=EdgeDuplicate,
                )
            dispatch.assert_not_called()
        finally:
            app.current_graph_id.reset(token)
            app.graph_cancellations.remove("offline-canceled")

    async def test_timeout_bounds_real_client_dispatch(self):
        client, dispatch = self.client("{}", structured_max_retries=0)
        client.request_timeout_seconds = 0.01

        async def hang(**kwargs):
            await asyncio.sleep(1)

        dispatch.side_effect = hang
        with self.assertRaises(TimeoutError):
            await client.generate_response(
                [Message(role="system", content="Resolve edges")],
                response_model=EdgeDuplicate,
            )

    async def test_refusal_uses_real_upstream_non_retryable_error(self):
        client, dispatch = self.client("", structured_max_retries=2)
        response = completion("")
        response.choices[0].message.refusal = "offline refusal"
        dispatch.side_effect = [response]
        with self.assertRaises(RefusalError):
            await client.generate_response(
                [Message(role="system", content="Resolve edges")],
                response_model=EdgeDuplicate,
            )
        self.assertEqual(dispatch.await_count, 1)

    def test_existing_neo4j_records_decode_without_new_metadata(self):
        now = app.datetime.now(app.timezone.utc)
        episode = get_episodic_node_from_record(
            {
                "uuid": "episode",
                "name": "existing",
                "group_id": "offline",
                "created_at": now,
                "valid_at": now,
                "content": "Alice knows Bob",
                "source": "text",
                "source_description": "existing",
                "entity_edges": [],
            }
        )
        self.assertIsNone(episode.episode_metadata)
        edge = get_entity_edge_from_record(
            {
                "uuid": "edge",
                "name": "KNOWS",
                "fact": "Alice knows Bob",
                "group_id": "offline",
                "source_node_uuid": "alice",
                "target_node_uuid": "bob",
                "created_at": now,
                "valid_at": now,
                "invalid_at": None,
                "expired_at": None,
                "episodes": [],
                "attributes": {"profile": '{"value":1}'},
            },
            GraphProvider.NEO4J,
        )
        self.assertIsNone(edge.reference_time)
        payload = app.edge_payload(edge)
        self.assertEqual(payload["source_node_uuid"], "alice")
        self.assertEqual(payload["target_node_uuid"], "bob")
        self.assertEqual(payload["uuid_"], "edge")
        self.assertTrue(app.episode_payload("episode", episode)["processed"])

    def test_neo4j_startup_queries_are_additive_and_owned_calls_still_bind(self):
        indices = get_range_indices(GraphProvider.NEO4J) + get_fulltext_indices(
            GraphProvider.NEO4J
        )
        self.assertEqual(len(indices), 31)
        self.assertTrue(
            all(
                query.startswith("CREATE ") and "IF NOT EXISTS" in query
                for query in indices
            )
        )
        inspect.signature(app.Graphiti.add_episode).bind(
            "graph",
            group_id="offline",
            name="episode",
            episode_body="text",
            reference_time=app.datetime.now(app.timezone.utc),
            source=app.EpisodeType.text,
            source_description="offline",
            entity_types={},
            edge_types={},
            edge_type_map={},
        )
        inspect.signature(app.Graphiti.search).bind(
            "graph", group_ids=["offline"], query="Alice", num_results=3
        )
        for method in (
            app.EntityNode.get_by_group_ids,
            app.EntityEdge.get_by_group_ids,
        ):
            inspect.signature(method).bind(
                "driver", ["offline"], limit=100, uuid_cursor=None
            )

    async def test_bulk_hook_preserves_actual_candidate_forwarding_and_properties(self):
        now = app.datetime.now(app.timezone.utc)
        node = EntityNode(
            name="Alice",
            group_id="offline",
            created_at=now,
            attributes={"profile": {"name": "Alice"}},
        )
        edge = EntityEdge(
            source_node_uuid=node.uuid,
            target_node_uuid=node.uuid,
            name="KNOWS",
            fact="Alice knows Alice",
            group_id="offline",
            created_at=now,
            attributes={"nested": {"value": 1}},
        )
        original = app._original_add_nodes_and_edges_bulk
        inspect.signature(original).bind("driver", [], [], [node], [edge], "embedder")
        forward = AsyncMock(return_value="saved")
        with patch.object(app, "_original_add_nodes_and_edges_bulk", forward):
            result = await app.graphiti_module.add_nodes_and_edges_bulk(
                "driver", [], [], [node], [edge], "embedder"
            )
        self.assertEqual(result, "saved")
        self.assertEqual(node.attributes["profile"], '{"name":"Alice"}')
        self.assertEqual(edge.attributes["nested"], '{"value":1}')
        forward.assert_awaited_once_with("driver", [], [], [node], [edge], "embedder")


if __name__ == "__main__":
    unittest.main()
