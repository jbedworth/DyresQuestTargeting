"""Offline regressions for immutable release provenance; no GitHub calls."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import build_release
import verify_release
from publish_curseforge import PublishError


COMMIT = "a" * 40
TAG = "v1.2.3-beta"
REPO = "jbedworth/DyresQuestTargeting"


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        source = root / "source"
        source.mkdir()
        (source / "DyresQuestTargeting.toc").write_text(
            "## Interface: 16001\n## Version: 1.2.3-beta\n"
            + "\n".join(build_release.RUNTIME_FILES) + "\n",
            encoding="utf-8", newline="\n",
        )
        for name in build_release.RUNTIME_FILES:
            (source / name).write_text("local value = true\n", encoding="utf-8", newline="\n")
        (source / "LICENSE").write_text(build_release.MIT_NOTICE + "\n", encoding="utf-8", newline="\n")
        (source / build_release.CHANGELOG_NAME).write_text(
            "## 1.2.3-beta\n\n- Test change.\n", encoding="utf-8", newline="\n")
        self.dist = root / "dist"
        build_release.build_release(source, self.dist, TAG, source_commit=COMMIT)

    def verify(self):
        return verify_release.verify_release(self.dist, TAG, COMMIT, REPO)

    def test_lightweight_tag_matches_tested_commit(self):
        with patch.object(verify_release, "github_object", return_value={"type": "commit", "sha": COMMIT}):
            self.assertEqual(self.verify()["source_commit"], COMMIT)

    def test_annotated_tag_is_peeled(self):
        objects = [{"type": "tag", "sha": "b" * 40}, {"type": "commit", "sha": COMMIT}]
        with patch.object(verify_release, "github_object", side_effect=objects) as remote:
            self.verify()
            self.assertEqual(remote.call_args_list[1].args[0], f"repos/{REPO}/git/tags/" + "b" * 40)

    def test_moved_tag_is_rejected(self):
        with patch.object(verify_release, "github_object", return_value={"type": "commit", "sha": "b" * 40}):
            with self.assertRaisesRegex(PublishError, "Remote tag moved"):
                self.verify()

    def test_missing_or_different_manifest_commit_is_rejected_before_network(self):
        path = self.dist / "release-manifest.json"
        manifest = json.loads(path.read_text())
        for value in (None, "b" * 40):
            manifest["source_commit"] = value
            path.write_text(json.dumps(manifest), encoding="utf-8", newline="\n")
            with patch.object(verify_release, "github_object") as remote:
                with self.assertRaisesRegex(PublishError, "Artifact source commit"):
                    self.verify()
                remote.assert_not_called()

    def test_missing_sidecar_is_rejected_before_network(self):
        next(self.dist.glob("*.sha256")).unlink()
        with patch.object(verify_release, "github_object") as remote:
            with self.assertRaises(PublishError):
                self.verify()
            remote.assert_not_called()

    def test_invalid_remote_objects_fail_closed(self):
        for obj in ({"type": "tree", "sha": COMMIT}, {"type": "commit", "sha": "bad"}):
            with self.subTest(obj=obj), patch.object(verify_release, "github_object", return_value=obj):
                with self.assertRaises(PublishError):
                    self.verify()

    def test_recursive_tag_chain_is_bounded(self):
        with patch.object(verify_release, "github_object", return_value={"type": "tag", "sha": COMMIT}):
            with self.assertRaisesRegex(PublishError, "too deep"):
                self.verify()

    def test_invalid_expected_commit_or_repo_never_calls_network(self):
        for commit, repo in (("bad", REPO), (COMMIT, "owner/repo\nother")):
            with patch.object(verify_release, "github_object") as remote:
                with self.assertRaises(PublishError):
                    verify_release.verify_release(self.dist, TAG, commit, repo)
                remote.assert_not_called()

    def test_github_transport_failure_is_sanitized(self):
        failure = subprocess.CalledProcessError(1, "gh", stderr="private token should never appear")
        with patch.object(verify_release.subprocess, "run", side_effect=failure):
            with self.assertRaisesRegex(PublishError, "Cannot verify") as error:
                verify_release.github_object("repos/owner/repo/git/ref/tags/v1")
            self.assertNotIn("private token", str(error.exception))

    def test_github_response_shape_and_json_are_checked(self):
        for output in ("not JSON", "[]", '{"object": null}'):
            with patch.object(verify_release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output)):
                with self.assertRaises(PublishError):
                    verify_release.github_object("repos/owner/repo/git/ref/tags/v1")


if __name__ == "__main__":
    unittest.main()
