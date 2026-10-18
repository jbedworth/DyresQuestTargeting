"""Offline publisher tests: python3 -m unittest discover -s tests -p test_curseforge.py

All requests use a mocked urllib opener and a dummy token; no live upload occurs.
"""

import contextlib
import email.policy
import hashlib

import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
import zipfile
from email.parser import BytesParser
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
# Match direct script execution without depending on tests being a package.
sys.path.insert(0, str(ROOT / "scripts"))
try:
    import build_release as builder
    import publish_curseforge as publisher
finally:
    sys.path.pop(0)

DUMMY_TOKEN = "dummy-token-for-offline-tests"
REAL_MAKE_OPENER = publisher.make_opener


class CurseForgeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        source = self.base / "source"
        source.mkdir()
        version = "0.1.0-beta"
        (source / "DyresQuestTargeting.toc").write_bytes(
            (f"## Interface: 16001\n## Version: {version}\n"
             + "\n".join(builder.RUNTIME_FILES) + "\n").encode("utf-8"))
        (source / "LICENSE").write_bytes(builder.MIT_NOTICE.encode("utf-8"))
        for name in builder.RUNTIME_FILES:
            (source / name).write_bytes(b"local addonName, DQT = ...\n")
        (source / builder.CHANGELOG_NAME).write_bytes(
            f"## {version}\n\n- Test change.\n".encode("utf-8"))
        self.dist = self.base / "dist"
        self.tag = "v" + version
        self.manifest = builder.build_release(source, self.dist, tag=self.tag)
        self.archive = self.dist / self.manifest["archive_name"]
        self.manifest_path = self.dist / "release-manifest.json"
        self.receipt_path = self.dist / publisher.RECEIPT_NAME
        self.versions = [{"id": 12345, "name": "1.60.1", "gameVersionTypeID": 88568}]
        self.opener = mock.Mock()
        patch = mock.patch.object(publisher, "make_opener", return_value=self.opener)
        self.opener_factory = patch.start()
        self.addCleanup(patch.stop)
        env = mock.patch.dict(os.environ, {"CF_API_TOKEN": DUMMY_TOKEN}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.responses(self.versions, {"id": 98765})

    def response(self, value, raw=False, status=200):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.getcode.return_value = status
        response.read.return_value = value if raw else json.dumps(value).encode("utf-8")
        return response

    def responses(self, versions, result):
        self.opener.open.side_effect = [self.response(versions), self.response(result)]

    def publish(self, **kwargs):
        arguments = {"artifact_dir": self.dist, "project_id": "123",
                     "game_version_id": "12345", "tag": self.tag}
        arguments.update(kwargs)
        return publisher.publish(**arguments)

    def write_manifest(self, value):
        self.manifest_path.write_text(json.dumps(value), encoding="utf-8")

    def receipt(self):
        return {"project_id": 123, "file_id": 98765, "tag": self.tag,
                "archive_name": self.manifest["archive_name"], "sha256": self.manifest["sha256"]}

    def assert_no_network(self):
        self.opener_factory.assert_not_called()
        self.opener.open.assert_not_called()

    def test_wowup_metadata_names_the_forever_archive(self):
        self.assertEqual(self.archive.name, "DyresQuestTargeting-0.1.0-beta-forever.zip")
        metadata = json.loads((self.dist / "release.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata, {"releases": [{
            "name": "DyresQuestTargeting", "version": "0.1.0-beta",
            "filename": "DyresQuestTargeting-0.1.0-beta-forever.zip", "nolib": False,
            "metadata": [{"flavor": "forever", "interface": 16001}],
        }]})

    def test_wowup_metadata_must_match_before_upload(self):
        path = self.dist / "release.json"
        original = json.loads(path.read_text(encoding="utf-8"))
        release = original["releases"][0]
        variants = (
            None, "[]", {"releases": []},
            {"releases": [dict(release, filename="DyresQuestTargeting-0.1.0-beta.zip")]},
            {"releases": [dict(release, nolib=0)]},
            {"releases": [dict(release, metadata=[{"flavor": "classic", "interface": 16001}])]},
            {"releases": [dict(release, version="0.2.0-beta")]},
        )
        for value in variants:
            with self.subTest(value=value):
                if value is None:
                    path.unlink()
                else:
                    path.write_text(value if isinstance(value, str) else json.dumps(value),
                                    encoding="utf-8")
                with self.assertRaises(publisher.PublishError):
                    publisher.load_artifact(artifact_dir=self.dist, tag=self.tag)
                path.write_text(json.dumps(original), encoding="utf-8")
        self.assert_no_network()

    def test_upload_exact_metadata_changelog_bytes_and_receipt(self):
        notes = "# Beta notes\n\nUnicode: café. Native `/equipset` guidance.\n"
        (self.dist / "release-notes.md").write_bytes(notes.encode("utf-8"))
        result = self.publish()
        self.assertEqual(result, self.receipt())
        self.assertEqual(json.loads(self.receipt_path.read_text(encoding="utf-8")), result)
        self.assertEqual(self.opener.open.call_count, 2)
        get_request = self.opener.open.call_args_list[0].args[0]
        self.assertEqual(get_request.full_url, publisher.VERSIONS_URL)
        self.assertEqual(get_request.get_method(), "GET")
        request = self.opener.open.call_args_list[1].args[0]
        self.assertEqual(request.full_url, "https://wow.curseforge.com/api/projects/123/upload-file")
        self.assertEqual(request.get_method(), "POST")
        for call in self.opener.open.call_args_list:
            self.assertEqual(call.kwargs, {"timeout": 30})
            self.assertEqual(call.args[0].get_header("X-api-token"), DUMMY_TOKEN)
            self.assertNotIn(DUMMY_TOKEN, call.args[0].full_url)
        message = BytesParser(policy=email.policy.default).parsebytes(
            ("Content-Type: " + request.get_header("Content-type") + "\r\n\r\n").encode("ascii")
            + request.data)
        parts = list(message.iter_parts())
        self.assertEqual(len(parts), 2)
        self.assertEqual([part.get_param("name", header="content-disposition") for part in parts],
                         ["metadata", "file"])
        metadata = json.loads(parts[0].get_payload(decode=True))
        self.assertEqual(metadata, {"gameVersions": [12345], "releaseType": "beta",
                                   "changelog": notes, "changelogType": "markdown",
                                   "relations": {"projects": [{"slug": "questie", "projectID": 334372,
                                                               "type": "optionalDependency"}]}})
        self.assertEqual(parts[1].get_filename(), self.archive.name)
        self.assertEqual(parts[1].get_content_type(), "application/zip")
        uploaded = parts[1].get_payload(decode=True)
        self.assertEqual(uploaded, self.archive.read_bytes())
        self.assertEqual(hashlib.sha256(uploaded).hexdigest(), result["sha256"])
        self.assertNotIn(DUMMY_TOKEN.encode("ascii"), request.data)
        self.assertNotIn(DUMMY_TOKEN, self.receipt_path.read_text(encoding="utf-8"))

    def test_manifest_every_derived_field_checked_before_network(self):
        mismatches = {"version": "0.2.0-beta", "tag": "v0.2.0-beta", "channel": "release",
                      "prerelease": False, "interface": 16002, "game_version": "1.60.2",
                      "target_build": 70339, "archive_name": "../escape.zip", "sha256": "0" * 64}
        for key, value in mismatches.items():
            with self.subTest(key=key):
                self.write_manifest(dict(self.manifest, **{key: value}))
                with self.assertRaises(publisher.PublishError):
                    self.publish()
                self.assert_no_network()
        self.write_manifest(dict(self.manifest, prerelease=1))
        with self.assertRaises(publisher.PublishError):
            self.publish()
        self.assert_no_network()

    def test_missing_manifest_fields_before_network(self):
        for key in self.manifest:
            with self.subTest(key=key):
                changed = dict(self.manifest)
                del changed[key]
                self.write_manifest(changed)
                with self.assertRaises(publisher.PublishError):
                    self.publish()
                self.assert_no_network()

    def test_questie_is_the_only_relation_and_optional(self):
        # A required Questie would make CurseForge install it for every player.
        projects = publisher.RELATIONS["projects"]
        self.assertEqual([(p["slug"], p["projectID"]) for p in projects], [("questie", 334372)])
        self.assertTrue(all(p["type"] == "optionalDependency" for p in projects))

    def test_strict_tag(self):
        for tag in ("0.1.0-beta", "v0.1.0", "vv0.1.0-beta", "v0.1.0-beta\n", "v../bad"):
            with self.subTest(tag=tag), self.assertRaises(publisher.PublishError):
                self.publish(tag=tag)
        self.assert_no_network()

    def test_ids_are_explicit_positive_decimal(self):
        for value in ("", "0", "-1", "1.0", "+123", " 123", "123\n", "１２３", "01", True, 123):
            for key in ("project_id", "game_version_id"):
                with self.subTest(key=key, value=value), self.assertRaises(publisher.PublishError):
                    self.publish(**{key: value})
        self.assert_no_network()

    def test_all_zip_files_validated_even_if_hash_updated(self):
        original = self.archive.read_bytes()
        for name in builder.PACKAGE_FILES:
            with self.subTest(name=name):
                with zipfile.ZipFile(io.BytesIO(original)) as archive:
                    entries = [(entry, archive.read(entry)) for entry in archive.infolist()]
                with zipfile.ZipFile(self.archive, "w") as archive:
                    for entry, data in entries:
                        archive.writestr(entry, b"" if entry.filename.endswith("/" + name) else data)
                changed = dict(self.manifest, sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest())
                self.write_manifest(changed)
                with self.assertRaises(publisher.PublishError):
                    self.publish()
                self.assert_no_network()

    def test_hash_mismatch_and_changed_bytes_before_upload(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"different bytes")
        with self.assertRaisesRegex(publisher.PublishError, "sha256 mismatch"):
            self.publish()
        self.assert_no_network()

    def assert_checksum_rejected(self):
        with self.assertRaisesRegex(publisher.PublishError, "[Cc]hecksum"):
            publisher.load_artifact(artifact_dir=self.dist, tag=self.tag)
        with self.assertRaisesRegex(publisher.PublishError, "[Cc]hecksum"):
            self.publish()
        self.assert_no_network()

    def test_missing_checksum_sidecar(self):
        (self.dist / (self.archive.name + ".sha256")).unlink()
        self.assert_checksum_rejected()

    def test_corrupt_checksum_encoding_and_bom(self):
        checksum_path = self.dist / (self.archive.name + ".sha256")
        original = checksum_path.read_bytes()
        for content in (b"\xff", b"\xef\xbb\xbf" + original, b"\xff\xfe" + original, b"", b"not a checksum\n"):
            with self.subTest(content=content):
                checksum_path.write_bytes(content)
                self.assert_checksum_rejected()

    def test_mismatched_checksum_hash(self):
        checksum_path = self.dist / (self.archive.name + ".sha256")
        original = checksum_path.read_bytes()
        for digest in ("0" * 64, self.manifest["sha256"].upper(), self.manifest["sha256"][:-1]):
            with self.subTest(digest=digest):
                checksum_path.write_bytes(f"{digest}  {self.archive.name}\n".encode("utf-8"))
                self.assert_checksum_rejected()
        checksum_path.write_bytes(original.replace(b"  ", b" ", 1))
        self.assert_checksum_rejected()

    def test_checksum_filename_and_path_tricks(self):
        checksum_path = self.dist / (self.archive.name + ".sha256")
        for name in ("other.zip", "./" + self.archive.name, "../" + self.archive.name,
                     "dist/" + self.archive.name, "dist\\" + self.archive.name,
                     "/" + self.archive.name, "C:\\dist\\" + self.archive.name,
                     "*" + self.archive.name, self.archive.name + " ", self.archive.name + "\x00"):
            with self.subTest(name=name):
                checksum_path.write_bytes(f"{self.manifest['sha256']}  {name}\n".encode("utf-8"))
                self.assert_checksum_rejected()

    def test_checksum_requires_exact_single_lf_line(self):
        checksum_path = self.dist / (self.archive.name + ".sha256")
        original = checksum_path.read_bytes()
        for content in (original[:-1], original[:-1] + b"\r\n", original[:-1] + b"\r",
                        original + b"\n", original + original, b"\n" + original,
                        original[:-1] + b" \n", original.replace(b"  ", b"\n  ", 1)):
            with self.subTest(content=content):
                checksum_path.write_bytes(content)
                self.assert_checksum_rejected()

    def test_stale_sidecar_rejected_even_with_updated_manifest(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"changed ZIP bytes")
        self.write_manifest(dict(self.manifest, sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest()))
        self.assert_checksum_rejected()

    def test_loader_preserves_tuple_kwargs_and_additional_manifest_keys(self):
        manifest = dict(self.manifest, source_commit="a" * 40)
        self.write_manifest(manifest)
        result = publisher.load_artifact(artifact_dir=self.dist, tag=self.tag)
        self.assertIsInstance(result, tuple)
        self.assertEqual(result, (manifest, self.archive.read_bytes(),
                                 (self.dist / "release-notes.md").read_text(encoding="utf-8")))
        self.assert_no_network()

    def test_archive_changed_between_validation_and_read(self):
        real_validate = builder.validate_archive
        def change_after_validation(path, version):
            verified = real_validate(path, version)
            path.write_bytes(path.read_bytes() + b"changed")
            return verified
        with mock.patch.object(builder, "validate_archive", side_effect=change_after_validation):
            with self.assertRaisesRegex(publisher.PublishError, "changed during validation"):
                self.publish()
        self.assert_no_network()

    def test_bad_manifest_json_and_duplicate_keys(self):
        for data in (b"not JSON", b"[]", b'{"tag":"v1","tag":"v2"}', b"\xff"):
            with self.subTest(data=data):
                self.manifest_path.write_bytes(data)
                with self.assertRaises(publisher.PublishError):
                    self.publish()
                self.assert_no_network()

    def test_missing_token_and_invalid_header(self):
        for token in (None, "", "   ", "dummy\r\nInjected: value", "dummy☃"):
            with self.subTest(token=token):
                environment = {} if token is None else {"CF_API_TOKEN": token}
                with mock.patch.dict(os.environ, environment, clear=True):
                    with self.assertRaises(publisher.PublishError):
                        self.publish()
                self.assert_no_network()

    def test_missing_empty_and_non_utf8_notes(self):
        notes = self.dist / "release-notes.md"
        notes.unlink()
        with self.assertRaises(publisher.PublishError):
            self.publish()
        for content in (b"  \n", b"\xff", b"bad\x00notes"):
            notes.write_bytes(content)
            with self.assertRaises(publisher.PublishError):
                self.publish()
        self.assert_no_network()

    def test_wrong_server_version_or_type_never_uploads(self):
        invalid = [[], {}, {"data": self.versions},
                   [{"id": 54321, "name": "1.60.1", "gameVersionTypeID": 88568}],
                   [{"id": "12345", "name": "1.60.1", "gameVersionTypeID": 88568}],
                   [{"id": 12345, "name": "1.60.2", "gameVersionTypeID": 88568}],
                   [{"id": 12345, "name": "1.60.1", "gameVersionTypeID": 1}],
                   [{"id": 12345, "name": "1.60.1", "gameVersionTypeID": "88568"}],
                   [{"id": 12345, "name": "1.60.1"}], self.versions * 2]
        for versions in invalid:
            with self.subTest(versions=versions):
                self.opener.open.reset_mock()
                self.responses(versions, {"id": 98765})
                with self.assertRaises(publisher.PublishError):
                    self.publish()
                self.assertEqual(self.opener.open.call_count, 1)
                self.assertFalse(self.receipt_path.exists())

    def test_exact_version_id_selected_not_first_matching_name(self):
        versions = [{"id": 444, "name": "1.60.1", "gameVersionTypeID": 1}] + self.versions
        self.responses(versions, {"id": 98765})
        self.assertEqual(self.publish()["file_id"], 98765)

    def test_duplicate_receipt_refuses_without_network_even_without_token(self):
        self.receipt_path.write_text(json.dumps(self.receipt()), encoding="utf-8")
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(publisher.PublishError, "File already recorded"):
                self.publish()
        self.assert_no_network()

    def test_inconsistent_receipts_refuse_without_network(self):
        invalid = [[], {}, dict(self.receipt(), project_id=124),
                   dict(self.receipt(), project_id="123"), dict(self.receipt(), tag="v0.2.0-beta"),
                   dict(self.receipt(), archive_name="other.zip"), dict(self.receipt(), sha256="0" * 64),
                   dict(self.receipt(), file_id=0), dict(self.receipt(), file_id=True),
                   dict(self.receipt(), file_id="98765"), dict(self.receipt(), extra="unknown")]
        for receipt in invalid:
            with self.subTest(receipt=receipt):
                self.receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
                with self.assertRaises(publisher.PublishError):
                    self.publish()
                self.assert_no_network()
        for data in ('not JSON', '{"file_id":1,"file_id":2}'):
            self.receipt_path.write_text(data, encoding="utf-8")
            with self.assertRaises(publisher.PublishError):
                self.publish()
            self.assert_no_network()

    def test_bad_upload_response_no_receipt_no_retry(self):
        for value in ({}, [], {"id": 0}, {"id": -1}, {"id": True}, {"id": "98765"}, {"id": 1.5}):
            with self.subTest(value=value):
                self.opener.open.reset_mock()
                self.responses(self.versions, value)
                with self.assertRaisesRegex(publisher.PublishError, "may have been accepted"):
                    self.publish()
                self.assertEqual(self.opener.open.call_count, 2)
                self.assertFalse(self.receipt_path.exists())
        for data in (b"bad JSON " + DUMMY_TOKEN.encode(), b'{"id":1,"id":2}'):
            self.opener.open.reset_mock()
            self.opener.open.side_effect = [self.response(self.versions), self.response(data, raw=True)]
            with self.assertRaises(publisher.PublishError) as caught:
                self.publish()
            self.assertNotIn(DUMMY_TOKEN, str(caught.exception))
            self.assertEqual(self.opener.open.call_count, 2)
            self.assertFalse(self.receipt_path.exists())

    def test_http_and_timeout_errors_generic_and_never_retry(self):
        errors = [urllib.error.HTTPError(publisher.UPLOAD_URL, 403, DUMMY_TOKEN,
                                        {"X-Secret": DUMMY_TOKEN}, io.BytesIO(DUMMY_TOKEN.encode())),
                  urllib.error.URLError(DUMMY_TOKEN), TimeoutError(DUMMY_TOKEN), OSError(DUMMY_TOKEN),
                  publisher.http.client.IncompleteRead(b"dummy-response", 100)]
        for error in errors:
            for upload in (False, True):
                with self.subTest(error=type(error), upload=upload):
                    self.opener.open.reset_mock()
                    self.opener.open.side_effect = [self.response(self.versions), error] if upload else error
                    with self.assertRaises(publisher.PublishError) as caught:
                        self.publish()
                    message = str(caught.exception)
                    self.assertNotIn(DUMMY_TOKEN, message)
                    if isinstance(error, urllib.error.HTTPError):
                        self.assertIn("HTTP 403", message)
                    self.assertEqual(self.opener.open.call_count, 2 if upload else 1)
                    self.assertFalse(self.receipt_path.exists())

    def test_redirect_handler_blocks_cross_host_downgrades_and_post_replay(self):
        handler = publisher.NoRedirects()
        for method in ("GET", "POST"):
            request = urllib.request.Request(publisher.VERSIONS_URL,
                                             headers={"X-Api-Token": DUMMY_TOKEN}, method=method)
            for destination in ("https://other.example/steal", "http://wow.curseforge.com/insecure",
                                publisher.VERSIONS_URL + "/redirected"):
                for status in (301, 302, 303, 307, 308):
                    with self.subTest(method=method, destination=destination, status=status):
                        with self.assertRaises(publisher.PublishError):
                            handler.redirect_request(request, None, status, "redirect", {}, destination)
        with mock.patch.object(urllib.request, "build_opener") as build:
            REAL_MAKE_OPENER()
            self.assertIsInstance(build.call_args.args[0], publisher.NoRedirects)

    def test_response_size_and_status_fail_safely(self):
        for response in (self.response(b"x" * (publisher.MAX_RESPONSE_BYTES + 1), raw=True),
                         self.response({"secret": DUMMY_TOKEN}, status=500)):
            self.opener.open.side_effect = [response]
            with self.assertRaises(publisher.PublishError) as caught:
                self.publish()
            self.assertNotIn(DUMMY_TOKEN, str(caught.exception))
        self.assertFalse(self.receipt_path.exists())

    def test_cli_success_and_duplicate_failure(self):
        arguments = ["--artifact-dir", str(self.dist), "--project-id", "123",
                     "--game-version-id", "12345", "--tag", self.tag]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(publisher.main(arguments), 0)
            self.assertEqual(publisher.main(arguments), 1)
        self.assertIn("file 98765", stdout.getvalue())
        self.assertIn("Moderation may still be pending", stdout.getvalue())
        self.assertIn("already recorded", stderr.getvalue())
        self.assertNotIn(DUMMY_TOKEN, stdout.getvalue() + stderr.getvalue())
        self.assertEqual(self.opener.open.call_count, 2)

    def test_receipt_write_failure_warns_after_single_upload(self):
        original_open = Path.open
        receipt_path = self.receipt_path
        def fail_receipt(path, *args, **kwargs):
            if path == receipt_path and args and args[0] == "x":
                raise OSError(DUMMY_TOKEN)
            return original_open(path, *args, **kwargs)
        with mock.patch.object(Path, "open", fail_receipt):
            with self.assertRaises(publisher.PublishError) as caught:
                self.publish()
        self.assertIn("Cannot write upload receipt", str(caught.exception))
        self.assertIn("may have been accepted", str(caught.exception))
        self.assertNotIn(DUMMY_TOKEN, str(caught.exception))
        self.assertEqual(self.opener.open.call_count, 2)
        self.assertFalse(self.receipt_path.exists())

    def test_cli_network_error_nonzero_and_no_secret_echo(self):
        self.opener.open.side_effect = [self.response(self.versions),
                                       urllib.error.URLError(DUMMY_TOKEN)]
        arguments = ["--artifact-dir", str(self.dist), "--project-id", "123",
                     "--game-version-id", "12345", "--tag", self.tag]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(publisher.main(arguments), 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("may have been accepted", stderr.getvalue())
        self.assertNotIn(DUMMY_TOKEN, stderr.getvalue())
        self.assertEqual(self.opener.open.call_count, 2)
        self.assertFalse(self.receipt_path.exists())

    def test_cli_rejects_token_argument(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                publisher.main(["--artifact-dir", str(self.dist), "--project-id", "123",
                                "--game-version-id", "12345", "--tag", self.tag, "--token", "dummy"])
        self.assertNotEqual(caught.exception.code, 0)
        self.assert_no_network()


if __name__ == "__main__":
    unittest.main()
