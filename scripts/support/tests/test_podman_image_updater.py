#!/usr/bin/env python3
import importlib.util
import io
import pathlib
import tempfile
import unittest
import urllib.error
import urllib.parse
from email.message import Message
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "podman-image-updater.py"
SPEC = importlib.util.spec_from_file_location("podman_image_updater", SCRIPT_PATH)
podman_image_updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(podman_image_updater)


class PodmanImageUpdaterTest(unittest.TestCase):
    def test_registry_handshake_builds_correct_http_requests(self):
        registry_url = "https://registry.example/v2/team/image/tags/list"
        headers = Message()
        headers.add_header("WWW-Authenticate", 'Basic realm="private"')
        headers.add_header(
            "WWW-Authenticate",
            'bEaReR realm = "https://auth.example/token?audience=images",'
            'service = "registry.example",scope = "repository:team/image:pull,push",'
            'Basic realm="other"',
        )
        requests = []

        def respond(request, timeout):
            requests.append(request)
            self.assertEqual(timeout, 20)
            self.assertEqual(request.get_header("Accept"), "application/json")
            if len(requests) == 1:
                self.assertEqual(request.full_url, registry_url)
                self.assertIsNone(request.get_header("Authorization"))
                raise urllib.error.HTTPError(
                    registry_url, 401, "Unauthorized", headers, None
                )
            if len(requests) == 2:
                parsed = urllib.parse.urlsplit(request.full_url)
                self.assertEqual(parsed.netloc, "auth.example")
                self.assertIsNone(request.get_header("Authorization"))
                self.assertEqual(
                    urllib.parse.parse_qs(parsed.query),
                    {
                        "audience": ["images"],
                        "service": ["registry.example"],
                        "scope": ["repository:team/image:pull,push"],
                    },
                )
                return io.BytesIO(b'{"access_token": "opaque-token"}')
            self.assertEqual(request.full_url, registry_url)
            self.assertEqual(request.get_header("Authorization"), "Bearer opaque-token")
            return io.BytesIO(b'{"tags": ["1.0", "1.1"]}')

        with mock.patch.object(podman_image_updater.urllib.request, "urlopen", respond):
            tags = podman_image_updater.registry_tags("registry.example", "team/image")
        self.assertEqual(tags, ["1.0", "1.1"])
        self.assertEqual(len(requests), 3)

    def test_registry_tag_pagination_reuses_bearer_token(self):
        first_url = "https://registry.example/v2/team/image/tags/list?n=1000"
        second_url = (
            "https://registry.example/v2/team/image/tags/list?n=1000&last=app-v1.1.0"
        )
        error = urllib.error.HTTPError(
            first_url,
            401,
            "Unauthorized",
            {
                "WWW-Authenticate": (
                    'Bearer realm="https://auth.example/token",'
                    'service="registry.example",scope="repository:team/image:pull"'
                )
            },
            None,
        )
        with mock.patch.object(
            podman_image_updater,
            "request_json",
            side_effect=[
                error,
                {"token": "opaque-token"},
                {"tags": ["app-v1.0.0", "app-v1.1.0"]},
                {"tags": []},
            ],
        ) as request:
            tags = podman_image_updater.registry_tags(
                "registry.example", "team/image", all_pages=True
            )

        self.assertEqual(tags, ["app-v1.0.0", "app-v1.1.0"])
        self.assertEqual(request.call_args_list[0], mock.call(first_url))
        self.assertEqual(
            request.call_args_list[2], mock.call(first_url, "opaque-token")
        )
        self.assertEqual(
            request.call_args_list[3], mock.call(second_url, "opaque-token")
        )

    def test_registry_tag_pagination_rejects_repeated_cursor(self):
        with mock.patch.object(
            podman_image_updater,
            "request_registry_json_with_token",
            side_effect=[
                ({"tags": ["app-v1.0.0"]}, None),
                ({"tags": ["app-v1.0.0"]}, None),
            ],
        ):
            with self.assertRaisesRegex(RuntimeError, "did not advance"):
                podman_image_updater.registry_tags(
                    "registry.example", "team/image", all_pages=True
                )

    def test_malformed_bearer_parameters_remain_explicit_failures(self):
        for challenge in ['Bearer realm=', 'Bearer realm="https://auth.example",broken']:
            with self.subTest(challenge=challenge):
                with self.assertRaisesRegex(RuntimeError, "Malformed registry Bearer"):
                    podman_image_updater.bearer_parameters(challenge)

    def test_public_registry_needs_no_token_request(self):
        with mock.patch.object(
            podman_image_updater, "request_json", return_value={"tags": ["1.0"]}
        ) as request:
            tags = podman_image_updater.registry_tags("registry-1.docker.io", "team/image")
        self.assertEqual(tags, ["1.0"])
        request.assert_called_once_with("https://registry-1.docker.io/v2/team/image/tags/list")

    def test_nonstandard_tag_api_keeps_its_adapter(self):
        with (
            mock.patch.object(podman_image_updater, "quay_tags", return_value=["1.0"]) as quay,
            mock.patch.object(podman_image_updater, "request_registry_json") as standard,
        ):
            tags = podman_image_updater.registry_tags("quay.io", "team/image")
        self.assertEqual(tags, ["1.0"])
        quay.assert_called_once_with("team/image", False)
        standard.assert_not_called()

    def test_quay_tag_pagination_stays_on_quay(self):
        with mock.patch.object(
            podman_image_updater,
            "request_json",
            side_effect=[
                {
                    "page": 1,
                    "has_additional": True,
                    "tags": [{"name": "app-v1.0.0"}],
                },
                {
                    "page": 2,
                    "has_additional": False,
                    "tags": [{"name": "app-v1.1.0"}],
                },
            ],
        ) as request:
            tags = podman_image_updater.registry_tags(
                "quay.io", "team/image", all_pages=True
            )

        self.assertEqual(tags, ["app-v1.0.0", "app-v1.1.0"])
        self.assertIn("quay.io/api/v1/repository/team/image/tag/", request.call_args_list[0].args[0])
        self.assertIn("page=1", request.call_args_list[0].args[0])
        self.assertIn("page=2", request.call_args_list[1].args[0])

    def test_invalid_token_realms_fail_before_token_fetch(self):
        for parameters in [
            {},
            {"realm": "http://auth.example/token"},
            {"realm": "file:///token.json"},
            {"realm": "/token"},
            {"realm": "https://username:password@auth.example/token"},
        ]:
            with self.subTest(parameters=parameters):
                with self.assertRaisesRegex(RuntimeError, "realm"):
                    podman_image_updater.registry_token_url(parameters)

    def test_token_service_denial_remains_a_failed_check(self):
        error = urllib.error.HTTPError(
            "https://registry.example", 401, "Unauthorized",
            {"WWW-Authenticate": 'Bearer realm="https://auth.example/token"'}, None,
        )
        denial = urllib.error.HTTPError(
            "https://auth.example/token", 403, "Forbidden", {}, None
        )
        with mock.patch.object(
            podman_image_updater, "request_json", side_effect=[error, denial]
        ) as request:
            check = podman_image_updater.inspect_image("registry.example/team/image:1.0")
        self.assertEqual(check.state, "failed")
        self.assertIn("Registry token request failed", check.error)
        self.assertIn("403", check.error)
        self.assertEqual(request.call_count, 2)

    def test_registry_tags_answer_anonymous_bearer_challenges(self):
        cases = [
            (
                "docker.io",
                "library/postgres",
                'Bearer realm="https://auth.docker.io/token",'
                'service="registry.docker.io",scope="repository:library/postgres:pull"',
                "https://auth.docker.io/token",
                {"service": ["registry.docker.io"], "scope": ["repository:library/postgres:pull"]},
                {"token": "anonymous-token"},
            ),
            (
                "ghcr.io",
                "zulip/zulip-server",
                'Bearer realm="https://ghcr.io/token",'
                'service="ghcr.io",scope="repository:zulip/zulip-server:pull"',
                "https://ghcr.io/token",
                {"service": ["ghcr.io"], "scope": ["repository:zulip/zulip-server:pull"]},
                {"token": "anonymous-token"},
            ),
            (
                "codeberg.org",
                "forgejo/forgejo",
                'Bearer realm="https://codeberg.org/v2/token",'
                'service="container_registry",scope="*"',
                "https://codeberg.org/v2/token",
                {"service": ["container_registry"], "scope": ["*"]},
                {"token": "anonymous-token"},
            ),
            (
                "docker.n8n.io",
                "n8nio/n8n",
                'Bearer realm="https://auth.docker.io/token",'
                'service="registry.docker.io",scope="repository:n8nio/n8n:pull"',
                "https://auth.docker.io/token",
                {"service": ["registry.docker.io"], "scope": ["repository:n8nio/n8n:pull"]},
                {"access_token": "anonymous-token"},
            ),
        ]
        for registry, repository, challenge, realm, query, token_data in cases:
            with self.subTest(registry=registry):
                endpoint = "registry-1.docker.io" if registry == "docker.io" else registry
                url = f"https://{endpoint}/v2/{repository}/tags/list"
                error = urllib.error.HTTPError(
                    url, 401, "Unauthorized", {"WWW-Authenticate": challenge}, None
                )
                with mock.patch.object(
                    podman_image_updater,
                    "request_json",
                    side_effect=[error, token_data, {"tags": ["12-rootless", "16-rootless"]}],
                ) as request:
                    tags = podman_image_updater.registry_tags(registry, repository)

                self.assertEqual(tags, ["12-rootless", "16-rootless"])
                self.assertEqual(request.call_args_list[0], mock.call(url))
                token_url = request.call_args_list[1].args[0]
                parsed = urllib.parse.urlsplit(token_url)
                self.assertEqual(f"{parsed.scheme}://{parsed.netloc}{parsed.path}", realm)
                self.assertEqual(urllib.parse.parse_qs(parsed.query), query)
                self.assertEqual(request.call_args_list[2], mock.call(url, "anonymous-token"))

    def test_registry_challenge_preserves_realm_query_and_scope_entries(self):
        url = "https://registry.example/v2/team/image/tags/list"
        challenge = (
            'bearer Realm="https://auth.example/token?audience=images",'
            'Service="registry.example",'
            'Scope="repository:team/image:pull repository:team/base:pull"'
        )
        error = urllib.error.HTTPError(
            url, 401, "Unauthorized", {"WWW-Authenticate": challenge}, None
        )
        with mock.patch.object(
            podman_image_updater,
            "request_json",
            side_effect=[error, {"token": "anonymous-token"}, {"tags": []}],
        ) as request:
            podman_image_updater.request_registry_json(url)

        query = urllib.parse.urlsplit(request.call_args_list[1].args[0]).query
        self.assertEqual(
            urllib.parse.parse_qs(query),
            {
                "audience": ["images"],
                "service": ["registry.example"],
                "scope": ["repository:team/image:pull", "repository:team/base:pull"],
            },
        )

    def test_registry_non_bearer_and_non_401_errors_remain_failures(self):
        for code, challenge in [(401, 'Basic realm="private"'), (401, ""), (403, "Bearer")]:
            with self.subTest(code=code, challenge=challenge):
                error = urllib.error.HTTPError(
                    "https://registry.example",
                    code,
                    "Denied",
                    {"WWW-Authenticate": challenge},
                    None,
                )
                with mock.patch.object(
                    podman_image_updater, "request_json", side_effect=error
                ) as request:
                    with self.assertRaises(RuntimeError) as raised:
                        podman_image_updater.registry_tags("registry.example", "private/image")
                self.assertIn(f"HTTP Error {code}", str(raised.exception))
                self.assertIn(
                    "https://registry.example/v2/private/image/tags/list", str(raised.exception)
                )
                self.assertIn("Registry tag lookup failed", str(raised.exception))
                self.assertEqual(request.call_count, 1)

    def test_registry_retries_authenticated_request_only_once(self):
        url = "https://registry.example/v2/private/image/tags/list"
        error = urllib.error.HTTPError(
            url,
            401,
            "Unauthorized",
            {"WWW-Authenticate": 'Bearer realm="https://auth.example/token"'},
            None,
        )
        with mock.patch.object(
            podman_image_updater,
            "request_json",
            side_effect=[error, {"token": "anonymous-token"}, error],
        ) as request:
            with self.assertRaisesRegex(RuntimeError, "Authenticated registry tag lookup failed"):
                podman_image_updater.request_registry_json(url)
        self.assertEqual(request.call_count, 3)

    def test_registry_missing_token_remains_a_failed_check(self):
        url = "https://registry.example/v2/private/image/tags/list"
        error = urllib.error.HTTPError(
            url,
            401,
            "Unauthorized",
            {"WWW-Authenticate": 'Bearer realm="https://auth.example/token"'},
            None,
        )
        with mock.patch.object(
            podman_image_updater, "request_json", side_effect=[error, {}]
        ) as request:
            check = podman_image_updater.inspect_image("registry.example/private/image:1.0")
        self.assertEqual(check.state, "failed")
        self.assertIn("returned no Bearer token", check.error)
        self.assertEqual(request.call_count, 2)

    def test_failed_checks_stop_updates_and_report_an_explicit_summary(self):
        ref = "registry.example/private/image:1.0"
        check = podman_image_updater.ImageCheck(
            ref, "registry.example/private/image", "1.0", None, "failed", "Denied"
        )
        for argv, consequence in [
            ([], "no image pins were written"),
            (["--report"], "report is incomplete"),
        ]:
            with self.subTest(argv=argv):
                args = podman_image_updater.parse_args(argv)
                with (
                    mock.patch.object(podman_image_updater, "parse_args", return_value=args),
                    mock.patch.object(podman_image_updater, "run_nix_eval", return_value={}),
                    mock.patch.object(
                        podman_image_updater, "inspect_images", return_value={ref: check}
                    ),
                    mock.patch.object(podman_image_updater, "plan_updates") as plan,
                    mock.patch("builtins.print") as output,
                ):
                    status = podman_image_updater.main()
                self.assertEqual(status, 1)
                plan.assert_not_called()
                summary = output.call_args.args[0]
                self.assertIn("1 unique image(s)", summary)
                self.assertIn(consequence, summary)
                self.assertIn(ref, summary)
                self.assertIn("Error: Denied", summary)

    def test_read_timeout_reports_request_stage_endpoint_and_limit(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.side_effect = TimeoutError("The read operation timed out")
        with mock.patch.object(
            podman_image_updater.urllib.request, "urlopen", return_value=response
        ):
            check = podman_image_updater.inspect_image("docker.io/redis:7.2-alpine")
        self.assertEqual(check.state, "failed")
        self.assertIn("Registry tag lookup failed", check.error)
        self.assertIn("GET https://registry-1.docker.io/v2/library/redis/tags/list", check.error)
        self.assertIn("timed out while reading the response body", check.error)
        self.assertIn("socket timeout: 20s", check.error)
        self.assertEqual(check.error.count("GET "), 1)

    def test_open_timeout_and_invalid_json_have_distinct_causes(self):
        url = "https://registry.example/v2/team/image/tags/list"
        with mock.patch.object(
            podman_image_updater.urllib.request, "urlopen",
            side_effect=urllib.error.URLError(TimeoutError("timed out")),
        ):
            with self.assertRaisesRegex(RuntimeError, "timed out while opening the request"):
                podman_image_updater.request_json(url)
        with mock.patch.object(
            podman_image_updater.urllib.request, "urlopen", return_value=io.BytesIO(b"not JSON")
        ):
            with self.assertRaisesRegex(
                RuntimeError, "invalid JSON while reading the response body"
            ):
                podman_image_updater.request_json(url)

    def test_authenticated_read_timeout_preserves_stage_without_repeating_url(self):
        headers = Message()
        headers.add_header("WWW-Authenticate", 'Bearer realm="https://auth.example/token"')
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.side_effect = TimeoutError("read timed out")
        with mock.patch.object(
            podman_image_updater.urllib.request, "urlopen",
            side_effect=[
                urllib.error.HTTPError(
                    "https://registry.example", 401, "Unauthorized", headers, None
                ),
                io.BytesIO(b'{"token": "opaque-token"}'),
                response,
            ],
        ):
            check = podman_image_updater.inspect_image("registry.example/team/image:1.0")
        self.assertIn("Authenticated registry tag lookup failed", check.error)
        self.assertIn("timed out while reading the response body", check.error)
        self.assertEqual(check.error.count("GET "), 1)

    def test_failure_summary_lists_each_unique_image_and_all_affected_contexts(self):
        ref = "docker.io/redis:7.2-alpine"
        contexts = {
            ("abird", "abird-corp", "abird"): {"outline": [ref, ref]},
            ("abird-dev", "abird-corp", "abird"): {"outline": [ref]},
            ("gap3", "gap3-rivendell", "gap3"): {"outline": [ref]},
            ("", "other-host", "other-compose"): {"other-instance": [ref]},
        }
        check = podman_image_updater.ImageCheck(
            ref, "docker.io/redis", "7.2-alpine", None, "failed", "read timed out"
        )
        with mock.patch("builtins.print") as output:
            podman_image_updater.print_failed_image_checks(contexts, [check], True)
        summary = output.call_args.args[0]
        self.assertEqual(summary.count(f"- {ref}\n"), 1)
        self.assertEqual(summary.count("Used by:"), 4)
        for use in [
            "abird | abird-corp | abird | outline",
            "abird-dev | abird-corp | abird | outline",
            "gap3 | gap3-rivendell | gap3 | outline",
            "other-host | other-compose | other-instance",
        ]:
            self.assertIn(use, summary)

    def test_http_diagnostics_omit_credentials_and_query_values(self):
        error = podman_image_updater.HttpRequestFailure(
            "https://username:password@auth.example/token?token=opaque-token#fragment", "Denied"
        )
        self.assertEqual(str(error), "GET https://auth.example/token: Denied")

    def test_parse_image_ref_ignores_parameter_expansion_colon(self):
        parsed = podman_image_updater.parse_image_ref(
            "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}"
        )

        self.assertEqual(
            parsed,
            (
                "ghcr.io",
                "immich-app/immich-server",
                "ghcr.io/immich-app/immich-server",
                "${IMMICH_VERSION:-release}",
                None,
            ),
        )

    def test_parse_explicit_docker_official_image_adds_library_namespace(self):
        parsed = podman_image_updater.parse_image_ref("docker.io/postgres:16-alpine")

        self.assertEqual(parsed[0], "docker.io")
        self.assertEqual(parsed[1], "library/postgres")
        self.assertEqual(parsed[2], "docker.io/postgres")

    def test_parameterized_tag_reports_as_variable_tag(self):
        line = podman_image_updater.image_report_line(
            "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}",
            False,
        )

        self.assertEqual(
            line,
            "- ghcr.io/immich-app/immich-server: ${IMMICH_VERSION:-release} [variable tag]",
        )

    def test_release_tag_reports_as_floating_tag(self):
        line = podman_image_updater.image_report_line(
            "ghcr.io/immich-app/immich-server:release",
            False,
        )

        self.assertEqual(
            line,
            "- ghcr.io/immich-app/immich-server: release [floating tag]",
        )

    def test_stable_tag_reports_as_floating_tag(self):
        line = podman_image_updater.image_report_line(
            "docker.io/jitsi/jvb:stable",
            False,
        )

        self.assertEqual(line, "- docker.io/jitsi/jvb: stable [floating tag]")

    def test_digest_reports_as_pinned_without_claiming_latest(self):
        line = podman_image_updater.image_report_line(
            "docker.io/jitsi/jvb@sha256:abc123",
            False,
        )

        self.assertEqual(
            line,
            "- docker.io/jitsi/jvb: latest@sha256:abc123 [digest pinned]",
        )

    def test_immich_uses_latest_github_release_tag(self):
        with (
            mock.patch.dict(
                podman_image_updater.os.environ,
                {"GITHUB_TOKEN": "github_test_token"},
            ),
            mock.patch.object(
                podman_image_updater,
                "request_json",
                return_value={"tag_name": "v3.0.2"},
            ) as request,
            mock.patch.object(
                podman_image_updater,
                "registry_tags",
                return_value=["v1.91.1"],
            ),
        ):
            latest = podman_image_updater.latest_known_tag(
                "ghcr.io",
                "immich-app/immich-server",
                "v2.0.0",
            )

        self.assertEqual(latest, "v3.0.2")
        request.assert_called_once_with(
            "https://api.github.com/repos/immich-app/immich/releases/latest",
            "github_test_token",
        )

    def test_stirling_release_strips_non_registry_v_prefix(self):
        with mock.patch.object(
            podman_image_updater,
            "request_json",
            return_value={"tag_name": "v2.14.3"},
        ):
            latest = podman_image_updater.latest_known_tag(
                "docker.stirlingpdf.com",
                "stirlingtools/stirling-pdf",
                "2.14.2",
            )

        self.assertEqual(latest, "2.14.3")

    def test_nginx_updates_within_even_minor_stable_releases(self):
        with mock.patch.object(
            podman_image_updater,
            "registry_tags",
            return_value=["1.30.3", "1.30.4", "1.31.5", "1.30.4-alpine"],
        ):
            latest = podman_image_updater.latest_known_tag(
                "registry-1.docker.io",
                "library/nginx",
                "1.30.3",
            )

        self.assertEqual(latest, "1.30.4")

    def test_postgres_preserves_selected_major_release_track(self):
        with mock.patch.object(
            podman_image_updater,
            "registry_tags",
            return_value=["16-alpine", "17-alpine", "18-alpine"],
        ):
            latest = podman_image_updater.latest_known_tag(
                "docker.io",
                "library/postgres",
                "16-alpine",
            )

        self.assertEqual(latest, "16-alpine")

    def test_timescale_pg_tag_compares_within_pg_major(self):
        latest = podman_image_updater.latest_comparable_tag(
            "pg18.4-ts2.28.1",
            [
                "pg18.4-ts2.28.1",
                "pg18.4-ts2.28.2",
                "pg18.4-ts2.28.2-all",
                "pg19.1-ts2.29.0",
            ],
        )

        self.assertEqual(latest, "pg18.4-ts2.28.2")

    def test_stable_build_tag_compares_build_numbers(self):
        latest = podman_image_updater.latest_comparable_tag(
            "stable-10978",
            [
                "stable",
                "stable-10532-1",
                "stable-10978",
                "stable-11031",
                "unstable-12000",
            ],
        )

        self.assertEqual(latest, "stable-11031")

    def test_stable_build_tag_compares_release_revisions(self):
        latest = podman_image_updater.latest_comparable_tag(
            "stable-10532",
            ["stable-10532", "stable-10532-1"],
        )

        self.assertEqual(latest, "stable-10532-1")

    def test_stable_build_image_reports_new_release(self):
        with mock.patch.object(
            podman_image_updater,
            "registry_tags",
            return_value=["stable", "stable-10978", "stable-11031"],
        ):
            line = podman_image_updater.image_report_line(
                "docker.io/jitsi/jvb:stable-10978",
                False,
            )

        self.assertEqual(
            line,
            "- docker.io/jitsi/jvb: stable-10978 -> stable-11031",
        )

    def test_trailing_semver_compares_only_within_exact_tag_family(self):
        latest = podman_image_updater.latest_comparable_tag(
            "server-rocm-v0.4.1",
            [
                "server-rocm-v0.4.1",
                "server-rocm-v0.4.2",
                "server-rocm-0.5.0",
                "server-cuda-v0.6.0",
                "server-rocm-b11058",
            ],
        )
        unprefixed_v = podman_image_updater.latest_comparable_tag(
            "enterprise-1.2.3",
            ["enterprise-1.2.3", "enterprise-1.3.0", "community-2.0.0"],
        )

        self.assertEqual(latest, "server-rocm-v0.4.2")
        self.assertEqual(unprefixed_v, "enterprise-1.3.0")
        self.assertIsNone(podman_image_updater.trailing_version_tag_parts("v1.2.3"))

    def test_inspection_shares_registry_tags_across_image_variants(self):
        rocm = "ghcr.io/ggml-org/llama.cpp:server-rocm-v0.4.1"
        cuda = "ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1"
        contexts = {
            ("pvl", "host", "pvl"): {
                "llama-router": [rocm],
                "llama-router-nvidia": [cuda],
            }
        }
        tags = [
            "server-rocm-v0.4.1",
            "server-rocm-v0.4.2",
            "server-cuda-v0.4.1",
            "server-cuda-v0.4.2",
        ]
        with mock.patch.object(
            podman_image_updater, "registry_tags", return_value=tags
        ) as registry_tags:
            checks = podman_image_updater.inspect_images(contexts, 2)

        registry_tags.assert_called_once_with(
            "ghcr.io", "ggml-org/llama.cpp", True
        )
        self.assertEqual(checks[rocm].latest, "server-rocm-v0.4.2")
        self.assertEqual(checks[cuda].latest, "server-cuda-v0.4.2")

    def test_inspection_pages_once_when_one_repository_tag_family_needs_it(self):
        plain = "registry.example/team/image:1.2.3"
        variant = "registry.example/team/image:gpu-v1.2.3"
        contexts = {
            ("pvl", "host", "pvl"): {
                "plain": [plain],
                "variant": [variant],
            }
        }
        tags = ["1.2.3", "1.2.4", "gpu-v1.2.3", "gpu-v1.2.4"]
        with mock.patch.object(
            podman_image_updater, "registry_tags", return_value=tags
        ) as registry_tags:
            checks = podman_image_updater.inspect_images(contexts, 2)

        registry_tags.assert_called_once_with(
            "registry.example", "team/image", True
        )
        self.assertEqual(checks[plain].latest, "1.2.4")
        self.assertEqual(checks[variant].latest, "gpu-v1.2.4")

    def test_collect_images_keeps_instance_boundary(self):
        contexts = podman_image_updater.collect_images_by_context_and_instance(
            {
                "nixos-host": {
                    "hostName": "pvl-x2",
                    "stackName": "pvl",
                    "podmanSources": {
                        "pvl": {
                            "dockge": {
                                "source": {
                                    "services": {
                                        "dockge": {
                                            "image": "louislam/dockge:1.5.0",
                                        },
                                    },
                                },
                            },
                            "immich": {
                                "source": """
                                  services:
                                    valkey:
                                      image: docker.io/valkey/valkey:9
                                """,
                            },
                        },
                    },
                },
            },
        )

        self.assertEqual(
            contexts,
            {
                ("pvl", "pvl-x2", "pvl"): {
                    "dockge": ["louislam/dockge:1.5.0"],
                    "immich": ["docker.io/valkey/valkey:9"],
                },
            },
        )

    def test_collect_images_ignores_generated_nix_local_images(self):
        contexts = podman_image_updater.collect_images_by_context_and_instance(
            {
                "nixos-host": {
                    "hostName": "pvl-x2",
                    "stackName": "pvl",
                    "podmanSources": {
                        "pvl": {
                            "local": {
                                "source": """
                                  services:
                                    app:
                                      image: localhost/nix-local/image:abc123
                                """,
                            },
                            "remote": {
                                "source": """
                                  services:
                                    app:
                                      image: docker.io/library/nginx:1.29
                                """,
                            },
                        },
                    },
                },
            },
        )

        self.assertEqual(
            contexts,
            {
                ("pvl", "pvl-x2", "pvl"): {
                    "remote": ["docker.io/library/nginx:1.29"],
                },
            },
        )

    def test_prefix_image_report_line_adds_instance_boundary(self):
        line = podman_image_updater.prefix_image_report_line(
            "- louislam/dockge: 1.5.0 [latest]",
            "dockge",
            False,
        )

        self.assertEqual(line, "- dockge | louislam/dockge: 1.5.0 [latest]")

    def test_collect_source_files_maps_flake_definitions(self):
        with tempfile.TemporaryDirectory() as directory:
            repo_root = pathlib.Path(directory)
            source_dir = repo_root / "hosts/example/services/app"
            source_dir.mkdir(parents=True)
            source_file = source_dir / "default.nix"
            source_file.write_text("{}\n")
            sources = {
                "host": {
                    "hostName": "example",
                    "stackName": "pvl",
                    "repoSource": "/nix/store/hash-source",
                    "definitions": [
                        {
                            "file": "/nix/store/hash-source/hosts/example/services/app",
                            "instances": {"pvl": ["app"]},
                        }
                    ],
                    "podmanSources": {},
                }
            }

            files = podman_image_updater.collect_source_files_by_context_and_instance(
                sources, repo_root
            )

        self.assertEqual(files, {("pvl", "example", "pvl"): {"app": [source_file]}})

    def test_plan_updates_exact_image_declaration(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            source_file.write_text(
                "source = ''\n  image: docker.io/example/app:1.0.0\n'';\n"
            )
            context = ("pvl", "host", "pvl")
            contexts = {context: {"app": ["docker.io/example/app:1.0.0"]}}
            source_files = {context: {"app": [source_file]}}
            checks = {
                "docker.io/example/app:1.0.0": podman_image_updater.ImageCheck(
                    "docker.io/example/app:1.0.0",
                    "docker.io/example/app",
                    "1.0.0",
                    "1.1.0",
                    "update",
                )
            }

            edits, originals, errors = podman_image_updater.plan_updates(
                contexts, source_files, checks
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 1)
        self.assertIn("docker.io/example/app:1.1.0", updated[source_file])

    def test_plan_updates_distinguishes_image_reference_prefixes(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            source_file.write_text(
                "source = ''\n"
                "  image: docker.io/example/app:1.0.0-rocm\n"
                "  image: docker.io/example/app:1.0.0\n"
                "'';\n"
            )
            context = ("pvl", "host", "pvl")
            rocm_ref = "docker.io/example/app:1.0.0-rocm"
            default_ref = "docker.io/example/app:1.0.0"
            contexts = {context: {"app": [rocm_ref, default_ref]}}
            source_files = {context: {"app": [source_file]}}
            checks = {
                rocm_ref: podman_image_updater.ImageCheck(
                    rocm_ref,
                    "docker.io/example/app",
                    "1.0.0-rocm",
                    "1.1.0-rocm",
                    "update",
                ),
                default_ref: podman_image_updater.ImageCheck(
                    default_ref,
                    "docker.io/example/app",
                    "1.0.0",
                    "1.1.0",
                    "update",
                ),
            }

            edits, originals, errors = podman_image_updater.plan_updates(
                contexts, source_files, checks
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 2)
        self.assertEqual(
            updated[source_file],
            "source = ''\n"
            "  image: docker.io/example/app:1.1.0-rocm\n"
            "  image: docker.io/example/app:1.1.0\n"
            "'';\n",
        )

    def test_plan_updates_deduplicates_shared_version_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            source_file.write_text(
                'let version = "v3.0.2"; in ""\n'
                "  image: ghcr.io/example/server:${version}\n"
                "  image: ghcr.io/example/worker:${version}\n"
            )
            context = ("pvl", "host", "pvl")
            server = "ghcr.io/example/server:v3.0.2"
            worker = "ghcr.io/example/worker:v3.0.2"
            contexts = {context: {"app": [server, worker]}}
            source_files = {context: {"app": [source_file]}}
            checks = {
                ref: podman_image_updater.ImageCheck(
                    ref, ref.rsplit(":", 1)[0], "v3.0.2", "v3.2.0", "update"
                )
                for ref in (server, worker)
            }

            edits, originals, errors = podman_image_updater.plan_updates(
                contexts, source_files, checks
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 1)
        self.assertIn('version = "v3.2.0"', updated[source_file])

    def test_plan_updates_quoted_image_variable(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            ref = "docker.io/example/app:1.0.0"
            source_file.write_text(f'let image = "{ref}"; in "image: ${{image}}\\n"\n')
            context = ("pvl", "host", "pvl")
            check = podman_image_updater.ImageCheck(
                ref, "docker.io/example/app", "1.0.0", "1.1.0", "update"
            )

            edits, originals, errors = podman_image_updater.plan_updates(
                {context: {"app": [ref]}},
                {context: {"app": [source_file]}},
                {ref: check},
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 1)
        self.assertIn('image = "docker.io/example/app:1.1.0"', updated[source_file])

    def test_plan_updates_rejects_ambiguous_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source_files = [root / "one.nix", root / "two.nix"]
            ref = "docker.io/example/app:1.0.0"
            for source_file in source_files:
                source_file.write_text(f"source = ''\n  image: {ref}\n'';\n")
            context = ("pvl", "host", "pvl")
            check = podman_image_updater.ImageCheck(
                ref, "docker.io/example/app", "1.0.0", "1.1.0", "update"
            )

            _, _, errors = podman_image_updater.plan_updates(
                {context: {"app": [ref]}},
                {context: {"app": source_files}},
                {ref: check},
            )

        self.assertEqual(len(errors), 1)
        self.assertIn("declaration is ambiguous", errors[0])

    def test_apply_updates_is_atomic_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            original = "image: docker.io/example/app:1.0.0\n"
            source_file.write_text(original)
            source_file.chmod(0o640)
            start = original.index("1.0.0")
            edit = podman_image_updater.TextEdit(
                source_file, start, start + len("1.0.0"), "1.1.0"
            )

            podman_image_updater.apply_updates([edit], {source_file: original})

            self.assertEqual(
                source_file.read_text(), "image: docker.io/example/app:1.1.0\n"
            )
            self.assertEqual(source_file.stat().st_mode & 0o777, 0o640)

    def test_apply_updates_rolls_back_partial_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            first = root / "first.nix"
            second = root / "second.nix"
            first.write_text("old-first\n")
            second.write_text("old-second\n")
            originals = {first: first.read_text(), second: second.read_text()}
            edits = [
                podman_image_updater.TextEdit(first, 0, 3, "new"),
                podman_image_updater.TextEdit(second, 0, 3, "new"),
            ]
            real_replace = podman_image_updater.os.replace
            calls = 0

            def fail_second_replacement(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("simulated failure")
                return real_replace(source, destination)

            with (
                mock.patch.object(
                    podman_image_updater.os,
                    "replace",
                    side_effect=fail_second_replacement,
                ),
                self.assertRaisesRegex(RuntimeError, "was rolled back"),
            ):
                podman_image_updater.apply_updates(edits, originals)

            self.assertEqual(first.read_text(), "old-first\n")
            self.assertEqual(second.read_text(), "old-second\n")


if __name__ == "__main__":
    unittest.main()
