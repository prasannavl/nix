from __future__ import annotations

import importlib.util
import asyncio
import sys
import types
import unittest
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field


APP_DIR = Path(__file__).resolve().parents[1]


def module(name: str, **attrs: object) -> types.ModuleType:
    mod = types.ModuleType(name)
    for attr_name, attr_value in attrs.items():
        setattr(mod, attr_name, attr_value)
    return mod


class DummyFastAPI:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass

    def on_event(self, *_args: object, **_kwargs: object):
        return lambda func: func

    def get(self, *_args: object, **_kwargs: object):
        return lambda func: func

    def post(self, *_args: object, **_kwargs: object):
        return lambda func: func

    def delete(self, *_args: object, **_kwargs: object):
        return lambda func: func


class HTTPException(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class OpenAIClient:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass


class LLMConfig:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass


class OpenAIEmbedder:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass


class OpenAIEmbedderConfig:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass


class Graphiti:
    pass


class EpisodeType:
    @staticmethod
    def from_str(value: str) -> str:
        return value


def load_app_module():
    graphiti_core = module("graphiti_core", Graphiti=Graphiti)
    graphiti_core.__path__ = []
    sys.modules.update(
        {
            "uvicorn": module("uvicorn", run=lambda *args, **kwargs: None),
            "fastapi": module(
                "fastapi",
                Body=lambda default=None, **_kwargs: default,
                FastAPI=DummyFastAPI,
                HTTPException=HTTPException,
                status=types.SimpleNamespace(HTTP_202_ACCEPTED=202),
            ),
            "graphiti_core": graphiti_core,
            "graphiti_core.graphiti": module(
                "graphiti_core.graphiti",
                add_nodes_and_edges_bulk=lambda *args, **kwargs: None,
            ),
            "graphiti_core.embedder": module(
                "graphiti_core.embedder",
                OpenAIEmbedder=OpenAIEmbedder,
                OpenAIEmbedderConfig=OpenAIEmbedderConfig,
            ),
            "graphiti_core.edges": module("graphiti_core.edges", EntityEdge=object),
            "graphiti_core.errors": module(
                "graphiti_core.errors",
                EdgeNotFoundError=Exception,
                GroupsEdgesNotFoundError=Exception,
                NodeNotFoundError=Exception,
            ),
            "graphiti_core.llm_client": module(
                "graphiti_core.llm_client",
                OpenAIClient=OpenAIClient,
            ),
            "graphiti_core.llm_client.config": module(
                "graphiti_core.llm_client.config",
                LLMConfig=LLMConfig,
            ),
            "graphiti_core.nodes": module(
                "graphiti_core.nodes",
                EntityNode=object,
                EpisodeType=EpisodeType,
                EpisodicNode=object,
            ),
            "graphiti_core.utils.maintenance.graph_data_operations": module(
                "graphiti_core.utils.maintenance.graph_data_operations",
                clear_data=lambda *args, **kwargs: None,
            ),
        }
    )
    spec = importlib.util.spec_from_file_location("zep_graphiti_app", APP_DIR / "main.py")
    assert spec is not None
    assert spec.loader is not None
    app = importlib.util.module_from_spec(spec)
    sys.modules["zep_graphiti_app"] = app
    spec.loader.exec_module(app)
    return app


app = load_app_module()


class StructuredNormalizationTest(unittest.TestCase):
    def test_unwraps_single_field_model_envelope(self) -> None:
        class Edge(BaseModel):
            relation_type: str

        class ExtractedEdges(BaseModel):
            edges: list[Edge]

        normalized = app.ConfigurableOpenAIClient.normalize_structured_json(
            ExtractedEdges,
            {"edges": [{"edges": [{"Relation Type": "REPORTS_ON"}]}]},
        )

        self.assertEqual(normalized, {"edges": [{"relation_type": "REPORTS_ON"}]})
        self.assertEqual(
            ExtractedEdges.model_validate(normalized).edges[0].relation_type,
            "REPORTS_ON",
        )

    def test_canonicalizes_dynamic_attribute_keys_and_values(self) -> None:
        class EntityAttributes_Test(BaseModel):
            org_name: Optional[str] = Field(default=None)

        normalized = app.ConfigurableOpenAIClient.normalize_structured_json(
            EntityAttributes_Test,
            {"Org Name": "Olamgroup", "profile": {"name": "Olamgroup"}},
        )

        self.assertEqual(normalized["org_name"], "Olamgroup")
        self.assertEqual(normalized["profile"], '{"name":"Olamgroup"}')
        self.assertEqual(
            EntityAttributes_Test.model_validate(normalized).org_name,
            "Olamgroup",
        )

    def test_preserves_node_resolution_typo_recovery(self) -> None:
        class EntityResolution(BaseModel):
            id: int
            duplicate_idx: int
            additional_duplicates: list[int]

        class NodeResolutions(BaseModel):
            entity_resolutions: list[EntityResolution]

        normalized = app.ConfigurableOpenAIClient.normalize_structured_json(
            NodeResolutions,
            {
                "entity_resolutions": [
                    {
                        "id": "3",
                        "duplication_idx": "4",
                        "additional_duplicates": ["5", "bad"],
                    }
                ]
            },
        )

        resolution = normalized["entity_resolutions"][0]
        self.assertEqual(resolution["id"], 3)
        self.assertEqual(resolution["duplicate_idx"], 4)
        self.assertEqual(resolution["additional_duplicates"], [5])
        NodeResolutions.model_validate(normalized)

    def test_reset_graph_runtime_state_clears_batches_and_failures(self) -> None:
        app.graph_failures["graph-1"] = {"error": "failed"}
        app.graph_cancellations.add("graph-1")
        app.graph_ontologies["graph-1"] = object()
        app.episode_batches["batch-1"] = app.EpisodeBatch(
            uuid="batch-1",
            graph_id="graph-1",
            episode_ids=["episode-1"],
            created_at=app.datetime.now(app.timezone.utc),
        )
        app.episode_to_batch["episode-1"] = "batch-1"
        app.episode_states["episode-1"] = {"state": "failed"}

        app.reset_graph_runtime_state("graph-1")

        self.assertNotIn("graph-1", app.graph_failures)
        self.assertNotIn("graph-1", app.graph_cancellations)
        self.assertNotIn("graph-1", app.graph_ontologies)
        self.assertNotIn("batch-1", app.episode_batches)
        self.assertNotIn("episode-1", app.episode_to_batch)
        self.assertNotIn("episode-1", app.episode_states)

    def test_cancelled_graph_prevents_llm_dispatch(self) -> None:
        class FakeCompletions:
            def __init__(self) -> None:
                self.called = False

            async def create(self, **_kwargs: object) -> object:
                self.called = True
                return object()

        fake_completions = FakeCompletions()
        client = app.ConfigurableOpenAIClient()
        client.client = types.SimpleNamespace(
            chat=types.SimpleNamespace(completions=fake_completions)
        )

        app.graph_cancellations.add("graph-canceled")
        token = app.current_graph_id.set("graph-canceled")
        try:
            with self.assertRaisesRegex(RuntimeError, "graph graph-canceled"):
                asyncio.run(client.create_chat_completion(model="m", messages=[]))
            self.assertFalse(fake_completions.called)
        finally:
            app.current_graph_id.reset(token)
            app.graph_cancellations.discard("graph-canceled")

    def test_llm_request_timeout_bounds_hanging_call(self) -> None:
        class FakeCompletions:
            async def create(self, **_kwargs: object) -> object:
                await asyncio.sleep(1)
                return object()

        client = app.ConfigurableOpenAIClient(request_timeout_seconds=0.01)
        client.client = types.SimpleNamespace(
            chat=types.SimpleNamespace(completions=FakeCompletions())
        )

        with self.assertRaises(TimeoutError):
            asyncio.run(client.create_chat_completion(model="m", messages=[]))

    def test_structured_retry_count_is_configurable(self) -> None:
        client = app.ConfigurableOpenAIClient(structured_max_retries=4)

        self.assertEqual(client.max_retries, 4)


if __name__ == "__main__":
    unittest.main()
