"""Run only against a disposable, password-enabled Kanidm 1.10.4 fixture.

KANIDM_PROOF_URL must be HTTPS loopback. KANIDM_PROOF_CA and
KANIDM_PROOF_ADMIN_PASSWORD name private fixture files, never production files.
The suite creates uniquely named people, a group and a public OAuth client,
then removes its own records. It never provisions or reads repository secrets.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import unittest
from urllib.parse import parse_qs, urlsplit

import requests
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature


def decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


class Client:
    def __init__(self, url, ca):
        self.url = url
        self.http = requests.Session()
        self.http.verify = ca
        self.http.trust_env = False

    def request(self, method, path, **kwargs):
        return self.http.request(
            method, self.url + path, timeout=10, allow_redirects=False, **kwargs,
        )

    def call(self, method, path, value=None, **kwargs):
        response = self.request(method, path, json=value, **kwargs)
        # Upstream bodies may contain credentials. Never include them in errors.
        if response.status_code != 200:
            raise AssertionError(f"{method} {path}: HTTP {response.status_code}")
        session = response.headers.get("x-kanidm-auth-session-id")
        if session:
            self.http.headers["x-kanidm-auth-session-id"] = session
        return response.json()

    def login(self, name, password, privileged=False):
        self.call("POST", "/v1/auth", {"step": {"init2": {
            "username": name, "issue": "token", "privileged": privileged,
        }}})
        self.call("POST", "/v1/auth", {"step": {"begin": "password"}})
        response = self.call("POST", "/v1/auth", {
            "step": {"cred": {"password": password}},
        })
        token = response["state"].get("success")
        if not token:
            raise AssertionError("Fixture login did not succeed")
        self.http.headers["Authorization"] = "Bearer " + token
        self.http.headers.pop("x-kanidm-auth-session-id", None)
        return self


class KanidmAuthorityProof(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.url = os.environ["KANIDM_PROOF_URL"].rstrip("/")
        endpoint = urlsplit(cls.url)
        assert endpoint.scheme == "https"
        assert endpoint.hostname in ("localhost", "127.0.0.1", "::1")
        assert endpoint.port and endpoint.port != 443
        assert not endpoint.path and not endpoint.query and not endpoint.fragment
        assert endpoint.username is None and endpoint.password is None
        cls.ca = os.environ["KANIDM_PROOF_CA"]
        password = Path(os.environ["KANIDM_PROOF_ADMIN_PASSWORD"]).read_text().strip()
        cls.admin = Client(cls.url, cls.ca).login("idm_admin", password, True)
        prefix = "identity-proof-" + secrets.token_hex(5)
        cls.client_id = prefix
        cls.group = prefix + "-users"
        cls.people = {prefix + "-peter": secrets.token_urlsafe(32),
                      prefix + "-pvl": secrets.token_urlsafe(32)}
        cls.admin.call("POST", "/v1/oauth2/_public", {"attrs": {
            "name": [cls.client_id], "displayname": ["Isolated identity proof"],
            "oauth2_rs_origin_landing": [cls.url], "oauth2_strict_redirect_uri": ["true"],
        }})
        cls.addClassCleanup(cls.admin.call, "DELETE", f"/v1/oauth2/{cls.client_id}")
        cls.admin.call("PATCH", f"/v1/oauth2/{cls.client_id}", {"attrs": {
            "oauth2_allow_localhost_redirect": ["true"],
        }})
        cls.admin.call("POST", "/v1/group", {"attrs": {"name": [cls.group]}})
        cls.addClassCleanup(cls.admin.call, "DELETE", f"/v1/group/{cls.group}")
        cls.admin.call("POST", f"/v1/oauth2/{cls.client_id}/_scopemap/{cls.group}",
                       ["openid", "profile", "groups"])
        for name, password in cls.people.items():
            cls.admin.call("POST", "/v1/person", {"attrs": {
                "name": [name], "displayname": [name],
            }})
            cls.addClassCleanup(cls.admin.call, "DELETE", f"/v1/person/{name}")
            token, _ = cls.admin.call("GET", f"/v1/person/{name}/_credential/_update")
            cls.admin.call("POST", "/v1/credential/_update", [{"password": password}, token])
            cls.admin.call("POST", "/v1/credential/_commit", token)
        cls.admin.call("PUT", f"/v1/group/{cls.group}/_attr/member", list(cls.people))

    def person(self, index=0):
        name, password = list(self.people.items())[index]
        return Client(self.url, self.ca).login(name, password)

    def userinfo(self, client, tokens):
        return client.request("GET", f"/oauth2/openid/{self.client_id}/userinfo",
                              headers={"Authorization": "Bearer " + tokens["access_token"]})

    def refresh(self, client, tokens):
        return client.request("POST", "/oauth2/token", headers={"Authorization": None}, data={
            "grant_type": "refresh_token", "client_id": self.client_id,
            "refresh_token": tokens["refresh_token"],
        })

    def oauth(self, client, port=18640, browser=False):
        verifier = secrets.token_urlsafe(32)
        nonce, state = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        redirect = f"http://127.0.0.1:{port}/api/abird.v1alpha1/login/callback"
        params = {
            "response_type": "code", "client_id": self.client_id,
            "redirect_uri": redirect, "scope": "openid profile groups",
            "state": state, "nonce": nonce, "code_challenge_method": "S256",
            "code_challenge": base64.urlsafe_b64encode(
                hashlib.sha256(verifier.encode()).digest(),
            ).decode().rstrip("="),
        }
        if browser:
            name, password = next(iter(self.people.items()))
            response = subprocess.run(
                ["node", str(Path(__file__).with_name("browser_proof.cjs"))],
                input=json.dumps({"url": self.url, "params": params,
                                  "username": name, "password": password,
                                  "listen_port": 18642}),
                text=True, capture_output=True, timeout=30, check=False,
            )
            self.assertEqual(response.returncode, 0, "Isolated browser login failed")
            callback = json.loads(response.stdout)
            self.assertEqual(callback["state"], state)
            self.assertIsNone(callback["origin"])
            code = callback["code"]
        else:
            response = client.request("GET", "/oauth2/authorise", params=params)
            self.assertIn(response.status_code, (200, 302))
            if response.status_code == 200:
                consent = response.json()["ConsentRequested"]["consent_token"]
                response = client.request("POST", "/oauth2/authorise/permit", json=consent)
                self.assertEqual(response.status_code, 200)
            query = parse_qs(urlsplit(response.headers["Location"]).query)
            self.assertEqual(query["state"], [state])
            code = query["code"][0]
        response = client.request("POST", "/oauth2/token", headers={"Authorization": None},
                                  data={"grant_type": "authorization_code",
                                        "client_id": self.client_id, "code": code,
                                        "redirect_uri": redirect, "code_verifier": verifier})
        self.assertEqual(response.status_code, 200)
        tokens = response.json()
        info = self.userinfo(client, tokens)
        self.assertEqual(info.status_code, 200)
        info = info.json()
        head, body, signature = tokens["id_token"].split(".")
        header, claims = json.loads(decode(head)), json.loads(decode(body))
        discovery = client.call("GET", f"/oauth2/openid/{self.client_id}/.well-known/openid-configuration")
        jwks_path = urlsplit(discovery["jwks_uri"]).path
        self.assertEqual(urlsplit(discovery["jwks_uri"]).netloc, urlsplit(self.url).netloc)
        keys = client.call("GET", jwks_path)["keys"]
        jwk = next(key for key in keys if key["kid"] == header["kid"])
        self.assertEqual(header["alg"], "ES256")
        self.assertEqual(jwk["crv"], "P-256")
        key = ec.EllipticCurvePublicNumbers(int.from_bytes(decode(jwk["x"]), "big"),
                                          int.from_bytes(decode(jwk["y"]), "big"),
                                          ec.SECP256R1()).public_key()
        sig = decode(signature)
        key.verify(encode_dss_signature(int.from_bytes(sig[:32], "big"),
                                       int.from_bytes(sig[32:], "big")),
                   f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256()))
        self.assertEqual(claims["iss"], self.url + "/oauth2/openid/" + self.client_id)
        self.assertEqual(discovery["issuer"], claims["iss"])
        self.assertEqual(claims["aud"], self.client_id)
        self.assertEqual(claims["nonce"], nonce)
        self.assertEqual(claims["sub"], info["sub"])
        self.assertGreater(claims["exp"], time.time())
        return tokens, info

    def test_identity_membership_and_separate_grants(self):
        client = self.person()
        first, info = self.oauth(client)
        second, repeated = self.oauth(self.person(), 18641)
        _, other = self.oauth(self.person(1))
        self.assertEqual(info["sub"], repeated["sub"])
        self.assertNotEqual(info["sub"], other["sub"])
        name = next(iter(self.people))
        renamed = name + "-renamed"
        self.admin.call("PUT", f"/v1/person/{name}/_attr/name", [renamed])
        try:
            self.assertEqual(self.userinfo(client, first).json()["sub"], info["sub"])
        finally:
            self.admin.call("PUT", f"/v1/person/{renamed}/_attr/name", [name])
        group_uuid = self.admin.call("GET", f"/v1/group/{self.group}")["attrs"]["uuid"][0]
        self.assertIn(group_uuid, info["groups"])
        self.admin.call("PUT", f"/v1/group/{self.group}/_attr/member", list(self.people)[1:])
        try:
            self.assertNotIn(group_uuid, self.userinfo(client, first).json()["groups"])
        finally:
            self.admin.call("PUT", f"/v1/group/{self.group}/_attr/member", list(self.people))
        response = self.refresh(client, first)
        self.assertEqual(response.status_code, 200)
        rotated = response.json()
        self.assertTrue(rotated["refresh_token"] != first["refresh_token"],
                        "Refresh must rotate the credential")
        self.assertEqual(self.userinfo(client, rotated).status_code, 200)
        revoked = client.request("POST", "/oauth2/token/revoke", headers={"Authorization": None},
                                 data={"client_id": self.client_id,
                                       "token": rotated["refresh_token"]})
        self.assertEqual(revoked.status_code, 200)
        self.assertEqual(self.userinfo(client, rotated).status_code, 400)
        self.assertEqual(self.userinfo(client, second).status_code, 200)

    def test_parent_expiry_requires_refresh_then_userinfo(self):
        self.admin.call("POST", f"/v1/group/{self.group}/_attr/class", ["account_policy"])
        self.admin.call("PUT", f"/v1/group/{self.group}/_attr/authsession_expiry", ["3"])
        try:
            client = self.person()
            tokens, _ = self.oauth(client)
            time.sleep(4)
            self.assertEqual(client.request("GET", "/v1/auth/valid").status_code, 401)
            response = self.refresh(client, tokens)
            # 1.10.4 can return success after expiring its parent on this write.
            # A lease may only renew if the subsequent UserInfo also succeeds.
            if response.status_code == 200:
                self.assertEqual(self.userinfo(client, response.json()).status_code, 400)
            else:
                self.assertEqual(response.status_code, 400)
        finally:
            self.admin.call("DELETE", f"/v1/group/{self.group}/_attr/authsession_expiry")

    def test_parent_logout_prevents_refresh(self):
        client = self.person()
        tokens, _ = self.oauth(client)
        client.call("GET", "/v1/logout")
        self.assertEqual(self.userinfo(client, tokens).status_code, 400)
        self.assertEqual(self.refresh(client, tokens).status_code, 400)

    @unittest.skipUnless(os.environ.get("KANIDM_PROOF_BROWSER"), "Browser tooling not configured")
    def test_browser_and_forwarded_callback(self):
        client = self.person()
        _, expected = self.oauth(client)  # Retain consent before browser login.
        _, direct = self.oauth(Client(self.url, self.ca), 18642, browser=True)
        self.assertEqual(direct["sub"], expected["sub"])
        if forwarded := os.environ.get("KANIDM_PROOF_FORWARD_PORT"):
            _, remote = self.oauth(Client(self.url, self.ca), int(forwarded), browser=True)
            self.assertEqual(remote["sub"], expected["sub"])


if __name__ == "__main__":
    unittest.main()
