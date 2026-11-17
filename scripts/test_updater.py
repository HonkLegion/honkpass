"""Synthetic updater tests; never access production or real credentials."""

import copy
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from upload_release import (
    ApiError,
    CurlAPI,
    TransportError,
    UploadError,
    canonical,
    expected_release_paths,
    load_token,
    select_app,
    upload,
    validate_release,
)


INFO = {
    "CFBundleIdentifier": "cz.honklegion.honkpass",
    "SUPublicEDKey": "public-test-key",
    "SUFeedURL": "https://update.honklegion.cz/apps/honkpass/appcast.xml",
}
META = {
    "version": "1.0",
    "build": "1",
    "minimum_macos": "14.0",
    "notes": "Test notes",
}
ART = {
    "path": Path("/tmp/synthetic/HonkPass.dmg"),
    "original_name": "HonkPass.dmg",
    "type": "dmg",
    "size": 123,
    "sha256": "a" * 64,
    "signature": "synthetic-signature",
}


def verified_artifact():
    return {
        **{key: value for key, value in ART.items() if key != "path"},
        "verified_at": "2026-09-12 00:00:00",
        "download_url": None,
    }


class FakeAPI:
    def __init__(self):
        self.app = {
            "id": 4,
            "bundle_id": INFO["CFBundleIdentifier"],
            "public_key": INFO["SUPublicEDKey"],
            "feed_url": INFO["SUFeedURL"],
            "publication_pending": False,
            "upload_max_bytes": 1000,
        }
        self.other_app = {
            **self.app,
            "id": 3,
            "bundle_id": "cz.honklegion.githonk",
        }
        self.release = {
            "id": 9,
            "application_id": 4,
            **META,
            "revision": 1,
            "state": "draft",
            "artifact": None,
        }
        self.calls = []
        self.create_faults = []
        self.upload_faults = []
        self.uploads = 0
        self.change_on_get = None

    def request(self, method, route, **kwargs):
        self.calls.append((method, route, copy.deepcopy(kwargs)))
        if method == "GET" and route == "/apps":
            return [copy.deepcopy(self.other_app), copy.deepcopy(self.app)]
        if method == "GET" and route == "/apps/4":
            return copy.deepcopy(self.app)
        if method == "POST" and route == "/apps/4/releases":
            if self.create_faults:
                raise self.create_faults.pop(0)
            return copy.deepcopy(self.release)
        if method == "GET" and route == "/apps/4/releases/9":
            if self.change_on_get:
                self.change_on_get(self.release)
                self.change_on_get = None
            return copy.deepcopy(self.release)
        if method == "POST" and route == "/apps/4/releases/9/artifact":
            self.uploads += 1
            if kwargs["revision"] != self.release["revision"]:
                raise AssertionError("Client used a stale revision")
            fault = self.upload_faults.pop(0) if self.upload_faults else None
            if fault == "lost_before":
                self.release["revision"] += 1
                raise TransportError()
            if isinstance(fault, Exception):
                raise fault
            self.release["artifact"] = verified_artifact()
            self.release["revision"] += 1
            if fault == "lost_after":
                raise TransportError()
            if fault == "conflict_after":
                raise ApiError(409)
            return copy.deepcopy(self.release)
        raise AssertionError("Unexpected or forbidden API operation")


class SelectionTests(unittest.TestCase):
    def test_selects_one_matching_app_from_multi_app_token(self):
        api = FakeAPI()
        selected = select_app([api.other_app, api.app], INFO, ART["size"])
        self.assertEqual(selected["id"], 4)

    def test_no_match_duplicate_match_pending_and_limit_are_rejected(self):
        api = FakeAPI()
        with self.assertRaises(UploadError):
            select_app([api.other_app], INFO, ART["size"])
        with self.assertRaises(UploadError):
            select_app([api.app, copy.deepcopy(api.app)], INFO, ART["size"])
        for key, value in (
            ("publication_pending", True),
            ("publication_pending", None),
            ("upload_max_bytes", 122),
        ):
            candidate = copy.deepcopy(api.app)
            candidate[key] = value
            with self.subTest(key=key), self.assertRaises(UploadError):
                select_app([candidate], INFO, ART["size"])


class WorkflowTests(unittest.TestCase):
    def run_upload(self, api):
        return upload(api, INFO, META, ART, sleep=lambda _: None)

    def test_success_is_idempotent_and_does_not_publish(self):
        api = FakeAPI()
        self.assertEqual(self.run_upload(api)[1]["state"], "draft")
        self.assertEqual(api.calls[-1][:2], ("GET", "/apps/4/releases/9"))
        self.run_upload(api)
        self.assertEqual(api.uploads, 1)
        keys = [call[2]["key"] for call in api.calls if call[1] == "/apps/4/releases"]
        self.assertEqual(keys[0], keys[1])
        self.assertFalse(any("publish" in call[1] for call in api.calls))

    def test_lost_create_and_upload_responses_are_reconciled(self):
        api = FakeAPI()
        api.create_faults = [TransportError(), ApiError(503)]
        self.run_upload(api)
        self.assertEqual(
            len([call for call in api.calls if call[1] == "/apps/4/releases"]), 3
        )
        for fault in ("lost_after", "conflict_after"):
            with self.subTest(fault=fault):
                api = FakeAPI()
                api.upload_faults = [fault]
                self.run_upload(api)
                self.assertEqual(api.uploads, 1)

    def test_normalized_filename_reconciles_without_reupload(self):
        api = FakeAPI()
        api.release["artifact"] = verified_artifact()
        api.release["artifact"]["original_name"] = "honkpass.dmg"
        self.assertEqual(self.run_upload(api)[1]["state"], "draft")
        self.assertEqual(api.uploads, 0)

        for field, value in (
            ("original_name", "other.dmg"),
            ("original_name", "../honkpass.dmg"),
            ("sha256", "b" * 64),
            ("size", 42),
            ("type", "zip"),
            ("signature", "wrong"),
            ("verified_at", None),
        ):
            with self.subTest(field=field, value=value):
                changed = copy.deepcopy(api.release)
                changed["artifact"][field] = value
                with self.assertRaises(UploadError):
                    validate_release(changed, 4, META, ART)

    def test_missing_upload_retries_are_bounded_with_fresh_revisions(self):
        api = FakeAPI()
        api.upload_faults = ["lost_before", "lost_before"]
        self.run_upload(api)
        revisions = [
            call[2]["revision"]
            for call in api.calls
            if call[1].endswith("/artifact")
        ]
        self.assertEqual(revisions, [1, 2, 3])

        api = FakeAPI()
        api.upload_faults = ["lost_before"] * 10
        with self.assertRaises(TransportError):
            self.run_upload(api)
        self.assertEqual(api.uploads, 3)

    def test_changed_metadata_artifact_and_state_fail_closed(self):
        api = FakeAPI()
        api.change_on_get = lambda release: release.update(notes="Changed in admin")
        with self.assertRaises(UploadError):
            self.run_upload(api)
        self.assertEqual(api.uploads, 0)

        for field, value in (
            ("sha256", "b" * 64),
            ("size", 42),
            ("signature", "wrong"),
            ("verified_at", None),
        ):
            with self.subTest(field=field):
                api = FakeAPI()
                api.release["artifact"] = verified_artifact()
                api.release["artifact"][field] = value
                with self.assertRaises(UploadError):
                    self.run_upload(api)
                self.assertEqual(api.uploads, 0)

        api = FakeAPI()
        api.release["state"] = "withdrawn"
        with self.assertRaises(UploadError):
            self.run_upload(api)

    def test_auth_conflicts_and_invalid_release_ids_are_safe(self):
        for status in (401, 403):
            api = FakeAPI()
            api.create_faults = [ApiError(status)]
            with self.assertRaises(ApiError):
                self.run_upload(api)
            self.assertEqual(len(api.calls), 2)
        for status in (409, 422):
            api = FakeAPI()
            api.upload_faults = [ApiError(status)]
            with self.assertRaises(UploadError):
                self.run_upload(api)
            self.assertEqual(api.uploads, 1)

        for field, value in (("id", True), ("revision", 0), ("application_id", 8)):
            release = copy.deepcopy(FakeAPI().release)
            release[field] = value
            with self.subTest(field=field), self.assertRaises(UploadError):
                validate_release(release, 4, META, ART)


class CredentialAndTransportTests(unittest.TestCase):
    def test_release_paths_follow_the_last_complete_update_package(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            output = root / ".build/distribution/update-fixture"
            output.mkdir(parents=True)
            marker = output.parent / "latest-update.txt"
            marker.write_text(str(output))
            with patch.dict(os.environ, {"DISTRIBUTION_DIR": str(output.parent)}):
                self.assertEqual(expected_release_paths(root),
                                 (output / "HonkPass.app", output / "HonkPass.dmg"))
                marker.write_text("/tmp/unrelated")
                with self.assertRaises(UploadError):
                    expected_release_paths(root)

    def test_environment_token_is_required_and_not_forwarded(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(UploadError):
                load_token()
        with patch.dict(os.environ, {"UPDATER_TOKEN": "hlu_SYNTHETIC"}):
            self.assertEqual(load_token(), "hlu_SYNTHETIC")

    @patch("upload_release.subprocess.run")
    def test_token_uses_stdin_and_multipart_streams_file(self, run):
        token = "hlu_SYNTHETIC_only"
        run.return_value = subprocess.CompletedProcess(
            [], 0, b'{"data": {}}\n200', b""
        )
        with patch.dict(os.environ, {"UPDATER_TOKEN": token}):
            CurlAPI(token).request(
                "POST", "/apps/4/releases/9/artifact", artifact=ART, revision=1
            )
        args = run.call_args.args[0]
        kwargs = run.call_args.kwargs
        self.assertNotIn(token, repr(args))
        self.assertNotIn("UPDATER_TOKEN", kwargs["env"])
        self.assertEqual(kwargs["input"], f"Authorization: Bearer {token}\n".encode())
        self.assertEqual(args[1], "-q")
        self.assertNotIn("--location", args)
        self.assertNotIn("--insecure", args)
        self.assertIn('file=@"/tmp/synthetic/HonkPass.dmg";filename=HonkPass.dmg', args)

    @patch("upload_release.subprocess.run")
    def test_redirect_auth_body_and_forbidden_routes_fail_without_leaks(self, run):
        for status in (302, 401, 403, 503):
            run.return_value = subprocess.CompletedProcess(
                [], 0, b"secret-response\n" + str(status).encode(), b"secret"
            )
            with self.assertRaises(ApiError) as caught:
                CurlAPI("hlu_SYNTHETIC").request("GET", "/apps")
            self.assertNotIn("secret", str(caught.exception))
            run.reset_mock()
        for route in (
            "/apps/4/recover",
            "/apps/4/releases/9/publish",
            "/apps/4/releases/9/withdraw",
            "https://evil.test",
            "/apps/../apps",
        ):
            with self.assertRaises(UploadError):
                CurlAPI("hlu_SYNTHETIC").request("POST", route)
        run.assert_not_called()


class LoopbackTransportTests(unittest.TestCase):
    def test_real_curl_multipart_and_redirect_rejection(self):
        fake = FakeAPI()
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.server.redirect:
                    self.send_response(302)
                    self.send_header(
                        "Location", f"http://127.0.0.1:{self.server.server_port}/forbidden"
                    )
                    self.end_headers()
                    return
                data = fake.request("GET", self.path.removeprefix("/api/v1"))
                self.respond(200, data)

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                received["authorization"] = self.headers.get("Authorization")
                route = self.path.removeprefix("/api/v1")
                if route.endswith("/artifact"):
                    message = BytesParser(policy=default).parsebytes(
                        (
                            "Content-Type: "
                            + self.headers["Content-Type"]
                            + "\r\nMIME-Version: 1.0\r\n\r\n"
                        ).encode()
                        + body
                    )
                    parts = {
                        part.get_param("name", header="content-disposition"): part
                        for part in message.iter_parts()
                    }
                    received["file"] = parts["file"].get_payload(decode=True)
                    received["name"] = parts["file"].get_filename()
                    data = fake.request(
                        "POST",
                        route,
                        artifact=ART,
                        revision=int(parts["revision"].get_payload(decode=True)),
                    )
                    self.respond(200, data)
                else:
                    data = fake.request(
                        "POST",
                        route,
                        metadata=json.loads(body),
                        key=self.headers["Idempotency-Key"],
                    )
                    self.respond(201, data)

            def respond(self, status, data):
                payload = json.dumps({"data": data}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.redirect = False
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        real_run = subprocess.run

        def loopback_run(args, **kwargs):
            args = list(args)
            args[args.index("--proto") + 1] = "=http"
            for index, arg in enumerate(args):
                if arg.startswith("https://update.honklegion.cz/api/v1"):
                    args[index] = arg.replace(
                        "https://update.honklegion.cz",
                        f"http://127.0.0.1:{server.server_port}",
                        1,
                    )
            return real_run(args, **kwargs)

        try:
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "HonkPass.dmg"
                path.write_bytes(b"x" * 123)
                artifact = {**ART, "path": path}
                with patch("upload_release.subprocess.run", side_effect=loopback_run):
                    self.assertEqual(
                        upload(
                            CurlAPI("hlu_SYNTHETIC"),
                            INFO,
                            META,
                            artifact,
                            sleep=lambda _: None,
                        )[1]["state"],
                        "draft",
                    )
                    server.redirect = True
                    with self.assertRaises(ApiError) as caught:
                        CurlAPI("hlu_SYNTHETIC").request("GET", "/apps")
                    self.assertEqual(caught.exception.status, 302)
                self.assertEqual(received["file"], b"x" * 123)
                self.assertEqual(received["name"], "HonkPass.dmg")
                self.assertEqual(
                    received["authorization"], "Bearer hlu_SYNTHETIC"
                )
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == "__main__":
    unittest.main()
