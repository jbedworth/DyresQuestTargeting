"""Offline tests for the CurseForge version lookup; no network or real token."""

import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import curseforge_versions as lookup
import publish_curseforge as publisher


DUMMY_TOKEN = "dummy-token-for-tests"


class Response:
    def __init__(self, body, status=200):
        self.body, self.status = body, status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def getcode(self):
        return self.status

    def read(self, limit):
        return self.body[:limit]


class VersionLookupTests(unittest.TestCase):
    def opener(self, versions):
        opener = mock.Mock()
        opener.open.return_value = Response(json.dumps(versions).encode("utf-8"))
        return opener

    def test_lists_only_forever_versions_sorted(self):
        opener = self.opener([
            {"id": 3, "name": "1.60.1", "gameVersionTypeID": 88568},
            {"id": 1, "name": "1.60.0", "gameVersionTypeID": 88568},
            {"id": 2, "name": "1.15.7", "gameVersionTypeID": 67408},
            {"id": "4", "name": "1.60.2", "gameVersionTypeID": 88568},
            {"id": 5, "name": 1602, "gameVersionTypeID": 88568},
            "not an object",
        ])
        self.assertEqual(lookup.list_versions(DUMMY_TOKEN, opener), [(1, "1.60.0"), (3, "1.60.1")])
        request = opener.open.call_args[0][0]
        self.assertEqual(request.full_url, publisher.VERSIONS_URL)
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.get_header("X-api-token"), DUMMY_TOKEN)
        self.assertNotIn(DUMMY_TOKEN, request.full_url)

    def test_rejects_non_array_response(self):
        with self.assertRaises(publisher.PublishError):
            lookup.list_versions(DUMMY_TOKEN, self.opener({"versions": []}))

    def test_token_from_environment_or_hidden_prompt(self):
        with mock.patch.dict("os.environ", {"CF_API_TOKEN": " " + DUMMY_TOKEN + "\n"}):
            self.assertEqual(lookup.read_token(), DUMMY_TOKEN)
        with mock.patch.dict("os.environ", {}, clear=True), \
                mock.patch.object(lookup.getpass, "getpass", return_value=DUMMY_TOKEN) as prompt:
            self.assertEqual(lookup.read_token(), DUMMY_TOKEN)
            prompt.assert_called_once()
        for bad in ("", "   ", "bad token"):
            with self.subTest(bad=bad), mock.patch.dict("os.environ", {}, clear=True), \
                    mock.patch.object(lookup.getpass, "getpass", return_value=bad), \
                    self.assertRaises(publisher.PublishError):
                lookup.read_token()

    def test_main_marks_the_target_version_and_never_prints_token(self):
        versions = [(3, "1.60.1"), (1, "1.60.0")]
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(lookup, "read_token", return_value=DUMMY_TOKEN), \
                mock.patch.object(lookup, "list_versions", return_value=sorted(versions)), \
                mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            self.assertEqual(lookup.main([]), 0)
        self.assertIn("id=3  name=1.60.1  <- CURSEFORGE_GAME_VERSION_ID", out.getvalue())
        self.assertNotIn("<-", out.getvalue().splitlines()[1])
        self.assertNotIn(DUMMY_TOKEN, out.getvalue() + err.getvalue())

    def test_main_reports_failures_without_token(self):
        err = io.StringIO()
        with mock.patch.object(lookup, "read_token", return_value=DUMMY_TOKEN), \
                mock.patch.object(lookup, "list_versions",
                                  side_effect=publisher.PublishError("CurseForge request failed (HTTP 403)")), \
                mock.patch("sys.stderr", err):
            self.assertEqual(lookup.main([]), 1)
        self.assertIn("HTTP 403", err.getvalue())
        self.assertNotIn(DUMMY_TOKEN, err.getvalue())

    def test_main_fails_when_no_forever_versions(self):
        with mock.patch.object(lookup, "read_token", return_value=DUMMY_TOKEN), \
                mock.patch.object(lookup, "list_versions", return_value=[]), \
                mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(lookup.main([]), 1)


if __name__ == "__main__":
    unittest.main()
