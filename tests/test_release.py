"""Release contract tests. Run: python3 -m unittest discover -s tests -p test_release.py

Fixtures copy the real TOC/license and use minimal Lua text. They do not need Git,
WoW, credentials, third-party packages or the current runtime Lua implementation.
"""

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BUILDER_PATH = ROOT / "scripts" / "build_release.py"
SPEC = importlib.util.spec_from_file_location("build_release", BUILDER_PATH)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        for name in ("DyresQuestTargeting.toc", "LICENSE"):
            # Git may check these templates out as CRLF on Windows. Fixture-only
            # conversion gives valid LF input without changing the real sources.
            (self.source / name).write_bytes((ROOT / name).read_bytes().replace(b"\r\n", b"\n"))
        for name in builder.RUNTIME_FILES:
            (self.source / name).write_bytes(b"local addonName, DQT = ...\n")
        (self.source / builder.CHANGELOG_NAME).write_bytes(
            (ROOT / builder.CHANGELOG_NAME).read_bytes().replace(b"\r\n", b"\n"))
        self.version = builder._validate_files(self.files())
        self.output = self.base / "dist"

    def files(self):
        return {name: (self.source / name).read_bytes() for name in builder.PACKAGE_FILES}

    def build(self, **kwargs):
        manifest = builder.build_release(self.source, self.output, **kwargs)
        return self.output / manifest["archive_name"], manifest

    def archive(self, entries=None, files=None):
        files = self.files() if files is None else files
        if entries is None:
            entries = [("DyresQuestTargeting/" + name, files[name], builder.FILE_MODE)
                       for name in builder.PACKAGE_FILES]
        path = self.base / "candidate.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                for name, data, mode in entries:
                    entry = zipfile.ZipInfo(name, builder.ZIP_TIMESTAMP)
                    entry.create_system = 3
                    entry.external_attr = mode << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(entry, data)
        return path

    def reject_files(self, files):
        with self.assertRaises(ValueError):
            builder.validate_archive(self.archive(files=files), self.version)

    def test_build_contract_and_sidecars(self):
        path, manifest = self.build(tag="v" + self.version)
        self.assertEqual(manifest, json.loads((self.output / "release-manifest.json").read_text()))
        self.assertEqual(manifest["tag"], "v" + self.version)
        self.assertEqual(manifest["interface"], 16001)
        self.assertEqual(manifest["game_version"], "1.60.1")
        self.assertEqual(manifest["target_build"], 70450)
        self.assertEqual(manifest["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual((self.output / (path.name + ".sha256")).read_text(),
                         f"{manifest['sha256']}  {path.name}\n")
        checked = builder.validate_archive(path, self.version)
        self.assertEqual(checked, dict(manifest, tag=""))
        notes = " ".join((self.output / "release-notes.md").read_text().split())
        for text in ("Forever beta 1.60.1", "70450", "the APIs it needs", "! Target (DQT)",
                     "QuestieDB", "`/dqt list`"):
            self.assertIn(text, notes)
        with zipfile.ZipFile(path) as archive:
            self.assertEqual(archive.namelist(), ["DyresQuestTargeting/" + name
                                                for name in builder.PACKAGE_FILES])
            for entry in archive.infolist():
                self.assertEqual(entry.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(entry.create_system, 3)
                self.assertEqual(entry.external_attr >> 16, stat.S_IFREG | 0o644)
                self.assertEqual(entry.compress_type, zipfile.ZIP_DEFLATED)
                name = entry.filename.split("/", 1)[1]
                self.assertEqual(archive.read(entry), (self.source / name).read_bytes())
        for artifact in self.output.iterdir():
            if artifact.suffix != ".zip":
                self.assertNotIn(b"\r", artifact.read_bytes())

    def test_deterministic_hash_and_allowlist(self):
        first, manifest = self.build()
        original = first.read_bytes()
        (self.source / "secret.txt").write_text("not in archive")
        (self.source / "docs").mkdir()
        (self.source / "docs" / "extra.lua").write_text("ignored")
        for name in builder.PACKAGE_FILES:
            os.utime(self.source / name, (1700000000, 1700000000))
        second = builder.build_release(self.source, self.base / "second", "v" + self.version)
        self.assertEqual(original, (self.base / "second" / second["archive_name"]).read_bytes())
        self.assertEqual(manifest["sha256"], second["sha256"])
        self.assertEqual(manifest["tag"], "")

    def test_source_commit_is_external_provenance_only(self):
        original_path, original = self.build()
        original_bytes = original_path.read_bytes()
        self.assertNotIn("source_commit", original)
        commit = "0123456789abcdef" * 2 + "01234567"
        github_output = self.base / "github-output"
        # All four existing positional arguments retain their meaning.
        manifest = builder.build_release(self.source, self.base / "with-commit",
                                         "v" + self.version, github_output, source_commit=commit)
        path = self.base / "with-commit" / manifest["archive_name"]
        self.assertEqual(manifest["source_commit"], commit)
        self.assertEqual(manifest, json.loads((path.parent / "release-manifest.json").read_text()))
        self.assertEqual(original_bytes, path.read_bytes())
        self.assertEqual(original["sha256"], manifest["sha256"])
        verified = builder.validate_archive(path, self.version)
        self.assertNotIn("source_commit", verified)
        self.assertEqual(set(verified), set(original))
        self.assertEqual(verified, original)
        self.assertNotIn("source_commit", github_output.read_text())

    def test_invalid_source_commit_rejected_before_output(self):
        commit = "0123456789abcdef" * 2 + "01234567"
        for invalid in ("", commit[:-1], commit + "0", commit.upper(),
                        "g" * 40, "v" + commit, commit + "\n", commit + "\r\n",
                        " " + commit, commit + " ", commit + ";echo bad",
                        commit + "\nsource_commit=bad", "é" * 40, 123, False):
            with self.subTest(commit=invalid), self.assertRaisesRegex(ValueError, "Source commit"):
                self.build(source_commit=invalid)
            self.assertFalse(self.output.exists())

    def test_channels_and_semver_metadata(self):
        for version, channel in (("1.2.3", "release"), ("1.2.3-alpha", "alpha"),
                                 ("1.2.3-beta.2", "beta"), ("1.2.3-beta.1+build.007", "beta"),
                                 ("1.2.3+beta-build", "release")):
            with self.subTest(version=version):
                toc = (ROOT / "DyresQuestTargeting.toc").read_bytes().replace(b"\r\n", b"\n")
                toc = toc.replace(self.version.encode(), version.encode())
                (self.source / "DyresQuestTargeting.toc").write_bytes(toc)
                (self.source / builder.CHANGELOG_NAME).write_bytes(
                    f"## {version}\n\n- Test change.\n".encode("utf-8"))
                path, manifest = self.build(tag="v" + version)
                self.assertEqual(manifest["channel"], channel)
                self.assertEqual(manifest["prerelease"], channel != "release")
                self.assertEqual(builder.validate_archive(path, version)["version"], version)

    def test_reject_invalid_versions(self):
        for version in ("", "1.2", "01.2.3", "1.02.3", "1.2.03", "v1.2.3",
                        "1.2.3-rc.1", "1.2.3-beta.01", "1.2.3-beta1", "1.2.3+",
                        "1.2.3;echo", "1.2.3\n", "1.2.3 beta", "1.2.3$(id)",
                        "1.2.3`id`", "1.2.3+foo/bar", "١.2.3", None):
            with self.subTest(version=version), self.assertRaises(ValueError):
                builder.validate_version(version)

    def test_reject_mismatched_and_unsafe_tags_before_output(self):
        for tag in ("v9.8.7", "vv" + self.version, "v" + self.version + "\nkey=bad",
                    "v" + self.version + ";echo bad", "v" + self.version + "$(id)", ""):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.build(tag=tag)
            self.assertFalse(self.output.exists())
        self.assertEqual(builder.validate_tag(self.version, self.version), self.version)

    def test_github_output_appends_only_safe_keys(self):
        output = self.base / "github-output"
        output.write_bytes(b"previous=value\n")
        _, manifest = self.build(github_output=output)
        self.assertEqual(output.read_bytes(), (
            f"previous=value\nversion={self.version}\narchive_name={manifest['archive_name']}\n"
            f"prerelease={str(manifest['prerelease']).lower()}\nchannel={manifest['channel']}\n"
        ).encode())

    def test_missing_and_nonregular_sources(self):
        for name in builder.PACKAGE_FILES:
            with self.subTest(name=name):
                content = (self.source / name).read_bytes()
                (self.source / name).unlink()
                with self.assertRaises(ValueError):
                    self.build()
                (self.source / name).mkdir()
                with self.assertRaises(ValueError):
                    self.build()
                (self.source / name).rmdir()
                (self.source / name).write_bytes(content)

    def test_empty_crlf_bom_and_invalid_text(self):
        for name in builder.PACKAGE_FILES:
            for data in (b"", b" \n", b"text\r\n", b"text\r", b"\xef\xbb\xbftext\n",
                         b"\xff\xfet\x00", b"text\x00\n", b"\xff\n", b"text\xef\xbb\xbf\n"):
                with self.subTest(name=name, data=data):
                    files = self.files()
                    files[name] = data
                    self.reject_files(files)
        (self.source / "Commands.lua").write_bytes(b"bad\r\n")
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_toc_metadata_and_load_order(self):
        toc = self.files()["DyresQuestTargeting.toc"]
        changes = (
            (b"## Interface: 16001", b"## Interface: 16000"),
            (b"## Interface: 16001", b"## Interface: 16001, 16000"),
            (b"## Interface: 16001", b"## Interface: 16001\n## Interface: 16001"),
            (b"## Version: " + self.version.encode(), b"## Version: "),
            (b"## Version: " + self.version.encode(), b"## Version: 1.2.3;bad"),
            (b"Commands.lua\nCore.lua", b"Core.lua\nCommands.lua"),
            (b"Options.lua", b"Options.lua\nLICENSE"),
            (b"Options.lua", b""),
            (b"Core.lua", b"./Core.lua"),
            (b"Core.lua", b"Core.lua\nCore.lua"),
        )
        for before, after in changes:
            with self.subTest(after=after):
                files = self.files()
                files["DyresQuestTargeting.toc"] = toc.replace(before, after)
                self.reject_files(files)
        files = self.files()
        files["DyresQuestTargeting.toc"] += b"\n## Version: " + self.version.encode() + b"\n"
        self.reject_files(files)

    def test_release_notes_start_with_the_versions_changelog_section(self):
        changelog = self.source / builder.CHANGELOG_NAME
        changelog.write_text(
            "# Changelog\n\n## " + self.version + "\n\n- Fixed the thing.\n- Added the other.\n\n"
            "## 0.0.1-beta\n\n- Older entry.\n", encoding="utf-8", newline="\n")
        self.build()
        notes = (self.output / "release-notes.md").read_text(encoding="utf-8")
        self.assertTrue(notes.startswith(
            f"# Dyre's Quest Targeting {self.version}\n\n## Changes\n\n"
            "- Fixed the thing.\n- Added the other.\n\n## Notes\n\n- For WoW: Forever."))
        self.assertNotIn("Older entry", notes)

    def test_build_refuses_missing_empty_or_duplicate_changelog_section(self):
        changelog = self.source / builder.CHANGELOG_NAME
        heading = "## " + self.version
        cases = (
            None, "", "# Changelog\n",
            "# Changelog\n\n## 9.9.9-beta\n\n- Other version.\n",
            f"# Changelog\n\n{heading}\n\n\n## 0.0.1-beta\n\n- Older.\n",
            f"{heading}\n\n- One.\n\n{heading}\n\n- Two.\n",
            f"{heading}\r\n\r\n- CRLF.\r\n",
        )
        for text in cases:
            with self.subTest(text=text):
                if changelog.exists():
                    changelog.unlink()
                if text is not None:
                    changelog.write_bytes(text.encode("utf-8"))
                with self.assertRaises(ValueError):
                    self.build()
                self.assertFalse(self.output.exists(), "nothing is written without notes")

    def test_changelog_never_enters_the_package(self):
        path, _ = self.build()
        with zipfile.ZipFile(path) as archive:
            self.assertNotIn("DyresQuestTargeting/CHANGELOG.md", archive.namelist())

    def test_repository_changelog_has_the_toc_version(self):
        text = (ROOT / builder.CHANGELOG_NAME).read_text(encoding="utf-8")
        self.assertTrue(builder.changelog_section(text, self.version))

    def test_license_terms_and_copyright(self):
        for before, after in ((b"John Bedworth", b"Someone Else"), (b"2026", b"2025"),
                              (b"Permission is hereby granted", b"No permission"),
                              (b'THE SOFTWARE IS PROVIDED "AS IS"', b"WARRANTY"),
                              (b"copies or substantial portions of the Software.", b"")):
            with self.subTest(before=before):
                files = self.files()
                files["LICENSE"] = files["LICENSE"].replace(before, after)
                self.reject_files(files)

    def test_extra_traversal_absolute_and_symlink_entries(self):
        entries = [("DyresQuestTargeting/" + name, data, builder.FILE_MODE)
                   for name, data in self.files().items()]
        for name, mode in (("DyresQuestTargeting/extra.txt", builder.FILE_MODE),
                           ("DyresQuestTargeting/../Commands.lua", builder.FILE_MODE),
                           ("../Commands.lua", builder.FILE_MODE),
                           ("/DyresQuestTargeting/Commands.lua", builder.FILE_MODE),
                           ("C:/Commands.lua", builder.FILE_MODE),
                           ("DyresQuestTargeting\\Commands.lua", builder.FILE_MODE),
                           ("Other/Commands.lua", builder.FILE_MODE),
                           ("DyresQuestTargeting/subdir/", stat.S_IFDIR | 0o755),
                           ("DyresQuestTargeting/link", stat.S_IFLNK | 0o777)):
            with self.subTest(name=name), self.assertRaises(ValueError):
                builder.validate_archive(self.archive(entries + [(name, b"target", mode)]), self.version)
        symlink = list(entries)
        symlink[1] = (symlink[1][0], b"target", stat.S_IFLNK | 0o777)
        with self.assertRaises(ValueError):
            builder.validate_archive(self.archive(symlink), self.version)

    def test_duplicate_missing_and_wrong_mode(self):
        entries = [("DyresQuestTargeting/" + name, data, builder.FILE_MODE)
                   for name, data in self.files().items()]
        wrong_mode = list(entries)
        wrong_mode[1] = (wrong_mode[1][0], wrong_mode[1][1], stat.S_IFREG | 0o755)
        for candidate in (entries + [entries[0]], entries[:-1], wrong_mode):
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                builder.validate_archive(self.archive(candidate), self.version)

    def test_optional_root_directory(self):
        entries = [("DyresQuestTargeting/" + name, data, builder.FILE_MODE)
                   for name, data in self.files().items()]
        directory = ("DyresQuestTargeting/", b"", stat.S_IFDIR | 0o755)
        builder.validate_archive(self.archive([directory] + entries), self.version)
        with self.assertRaises(ValueError):
            builder.validate_archive(self.archive([directory, directory] + entries), self.version)
        with self.assertRaises(ValueError):
            builder.validate_archive(self.archive([(directory[0], b"bad", directory[2])] + entries),
                                     self.version)

    def test_bad_crc_corrupt_and_missing_archive(self):
        path = self.archive()
        data = bytearray(path.read_bytes())
        central = data.index(b"PK\x01\x02")
        crc = struct.unpack_from("<I", data, central + 16)[0]
        struct.pack_into("<I", data, central + 16, crc ^ 1)
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "CRC"):
            builder.validate_archive(path, self.version)
        for corrupt in (b"", b"not a ZIP", bytes(data[:50]), bytes(data[:-30])):
            path.write_bytes(corrupt)
            with self.subTest(data=corrupt[:20]), self.assertRaises(ValueError):
                builder.validate_archive(path, self.version)
        with self.assertRaises(ValueError):
            builder.validate_archive(self.base / "missing.zip", self.version)

    def test_expected_version_mismatch_and_renamed_archive(self):
        path, manifest = self.build()
        with self.assertRaises(ValueError):
            builder.validate_archive(path, "9.8.7")
        renamed = self.base / "download.zip"
        shutil.copyfile(path, renamed)
        self.assertEqual(builder.validate_archive(renamed, self.version), manifest)

    def test_reject_stored_compression(self):
        path = self.base / "stored.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in self.files().items():
                entry = zipfile.ZipInfo("DyresQuestTargeting/" + name, builder.ZIP_TIMESTAMP)
                entry.create_system = 3
                entry.external_attr = builder.FILE_MODE << 16
                archive.writestr(entry, data)
        with self.assertRaises(ValueError):
            builder.validate_archive(path, self.version)

    def cli(self, *arguments):
        scripts = self.source / "scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copyfile(BUILDER_PATH, scripts / "build_release.py")
        return subprocess.run([sys.executable, str(scripts / "build_release.py"), *arguments],
                              cwd=self.source, capture_output=True, text=True, timeout=30, check=False)

    def test_cli_success(self):
        result = self.cli("--output", "dist", "--tag", "v" + self.version,
                          "--github-output", "github-output")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertEqual(manifest["tag"], "v" + self.version)
        builder.validate_archive(self.source / "dist" / manifest["archive_name"], self.version)
        self.assertIn("archive_name=" + manifest["archive_name"],
                      (self.source / "github-output").read_text())

    def test_cli_source_commit(self):
        commit = "0123456789abcdef" * 2 + "01234567"
        result = self.cli("--output", "dist", "--tag", "v" + self.version,
                          "--source-commit", commit)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertEqual(manifest["source_commit"], commit)
        self.assertEqual(manifest, json.loads((self.source / "dist" / "release-manifest.json").read_text()))
        self.assertNotIn("source_commit", builder.validate_archive(
            self.source / "dist" / manifest["archive_name"], self.version))

    def test_cli_invalid_source_commit(self):
        for commit in ("a" * 39, "A" * 40, "a" * 40 + "\n", "", "a" * 40 + ";bad"):
            with self.subTest(commit=commit):
                result = self.cli("--output", "dist", "--source-commit", commit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Source commit", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse((self.source / "dist").exists())

    def test_cli_failure(self):
        for arguments in (("--output", "dist", "--tag", "v9.8.7"), (),
                          ("--output", "dist", "--tag", "v" + self.version + "\nunsafe=yes")):
            with self.subTest(arguments=arguments):
                result = self.cli(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse((self.source / "dist").exists())


if __name__ == "__main__":
    unittest.main()
