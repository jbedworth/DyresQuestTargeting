"""Build and verify the installable release package. Python 3, standard library only.

Publishers must call validate_archive on the existing ZIP and compare its returned
metadata and sha256 with release-manifest.json before uploading those same bytes.
Optional source_commit provenance is caller-supplied, not derived from the ZIP.
Publishers must compare it separately with the immutable workflow commit.
This does not run Lua syntax checks or certify in-client compatibility.
"""

import argparse
import hashlib
import io
import json
import re
import stat
import sys
import zipfile
import zlib
from pathlib import Path


ADDON = "DyresQuestTargeting"
RUNTIME_FILES = ("Commands.lua", "Core.lua", "Quest.lua", "Macro.lua", "Options.lua")
TEXT_FILES = (ADDON + ".toc",) + RUNTIME_FILES + ("LICENSE",)
PACKAGE_FILES = TEXT_FILES
# Release metadata: the TOC Interface, CurseForge game version, and the build last
# targeted. The runtime itself detects features, not builds.
INTERFACE = 16001
GAME_VERSION = "1.60.1"
TARGET_BUILD = 70338
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
FILE_MODE = stat.S_IFREG | 0o644
SOURCE_COMMIT_RE = re.compile(r"[0-9a-f]{40}", re.ASCII)
NUMBER = r"(?:0|[1-9][0-9]*)"
VERSION_RE = re.compile(
    rf"{NUMBER}\.{NUMBER}\.{NUMBER}"
    rf"(?:-(?:alpha|beta)(?:\.{NUMBER})*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
    re.ASCII,
)
MIT_NOTICE = '''MIT License

Copyright (c) 2026 John Bedworth

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.'''


def validate_version(version):
    """Accept release, alpha and beta SemVer, with optional build metadata."""
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
        raise ValueError("Version must be SemVer with an optional alpha/beta suffix")
    return version


def validate_tag(tag, version):
    if tag is None:
        return ""
    if not isinstance(tag, str):
        raise ValueError("Tag must be a string")
    candidate = tag[1:] if tag.startswith("v") else tag
    validate_version(candidate)
    if candidate != version:
        raise ValueError("Tag does not match the TOC version")
    return tag


def _text(name, data):
    if not data or not data.strip():
        raise ValueError(f"{name}: file is empty")
    if b"\r" in data or data.startswith((b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff", b"\x00\x00\xfe\xff")):
        raise ValueError(f"{name}: require LF text without a BOM")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{name}: require UTF-8 text") from error
    if "\x00" in text or "\ufeff" in text:
        raise ValueError(f"{name}: NUL or BOM is not permitted")
    return text


def _validate_files(files, expected_version=None):
    texts = {name: _text(name, files[name]) for name in TEXT_FILES}
    metadata = {}
    loads = []
    for line in texts[ADDON + ".toc"].splitlines():
        line = line.strip()
        if line.startswith("##"):
            match = re.fullmatch(r"##\s*([^:]+):\s*(.*)", line)
            if not match:
                raise ValueError("Malformed TOC metadata")
            key, value = match.groups()
            key = key.strip()
            if key in metadata:
                raise ValueError(f"Duplicate TOC metadata: {key}")
            metadata[key] = value.strip()
        elif line and not line.startswith("#"):
            loads.append(line)
    if metadata.get("Interface") != str(INTERFACE):
        raise ValueError(f"TOC Interface must be {INTERFACE}")
    version = validate_version(metadata.get("Version", ""))
    if expected_version is not None and version != validate_version(expected_version):
        raise ValueError("Archive version does not match expected version")
    if loads != list(RUNTIME_FILES):
        raise ValueError("TOC must load " + ", ".join(RUNTIME_FILES) + " in that exact order")
    if " ".join(texts["LICENSE"].split()) != " ".join(MIT_NOTICE.split()):
        raise ValueError("LICENSE must preserve the MIT terms and 2026 John Bedworth notice")
    # Category and icon are preserved byte-for-byte; they are not client support gates.
    return version


WOWUP_METADATA_NAME = "release.json"


def archive_filename(version):
    """WowUp 2.24.0 matches GitHub assets named *-forever.zip to Forever installs."""
    return f"{ADDON}-{version}-forever.zip"


def wowup_metadata(version):
    """BigWigs-format release.json; WowUp maps its "forever" flavor to Forever installs."""
    return {
        "releases": [{
            "name": ADDON,
            "version": version,
            "filename": archive_filename(version),
            "nolib": False,
            "metadata": [{"flavor": "forever", "interface": INTERFACE}],
        }],
    }


def _manifest(version, archive_name, digest, tag=""):
    prerelease = version.split("+", 1)[0].partition("-")[2]
    channel = prerelease.split(".", 1)[0] if prerelease else "release"
    return {
        "version": version,
        "tag": tag,
        "channel": channel,
        "prerelease": bool(prerelease),
        "archive_name": archive_name,
        "sha256": digest,
        "interface": INTERFACE,
        "game_version": GAME_VERSION,
        "target_build": TARGET_BUILD,
    }


def validate_archive(path, expected_version):
    """Return independently derived metadata/hash, or raise ValueError.

    The ZIP has no tag field. The returned tag is empty. Publishers must validate
    the external manifest's tag separately with validate_tag. Commit provenance
    is not returned because it cannot be derived from the ZIP. No extraction occurs.
    One optional root directory entry is allowed; all package files are required.
    """
    validate_version(expected_version)
    path = Path(path)
    try:
        archive_bytes = path.read_bytes()
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
            allowed = {f"{ADDON}/{name}" for name in PACKAGE_FILES}
            seen = set()
            files = {}
            for entry in archive.infolist():
                name = entry.filename
                if entry.orig_filename != name:
                    raise ValueError(f"Malformed ZIP path: {name}")
                if name in seen:
                    raise ValueError(f"Duplicate ZIP entry: {name}")
                seen.add(name)
                mode = entry.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValueError(f"ZIP symlink is not permitted: {name}")
                if name == ADDON + "/" and entry.is_dir():
                    if entry.file_size != 0:
                        raise ValueError("Root directory entry must be empty")
                    archive.read(entry)
                    continue
                # Exact matching rejects traversal, backslashes, absolute paths and extras.
                if name not in allowed:
                    raise ValueError(f"Unexpected ZIP path: {name}")
                if entry.create_system != 3 or mode != FILE_MODE:
                    raise ValueError(f"ZIP entry must be a Unix regular 0644 file: {name}")
                if entry.compress_type != zipfile.ZIP_DEFLATED:
                    raise ValueError(f"ZIP entry must use DEFLATE: {name}")
                files[name.split("/", 1)[1]] = archive.read(entry)
            if set(files) != set(PACKAGE_FILES):
                raise ValueError("ZIP must contain exactly the package files")
            version = _validate_files(files, expected_version)
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError,
            NotImplementedError, EOFError, zlib.error) as error:
        raise ValueError(f"Cannot validate ZIP: {error}") from error
    digest = hashlib.sha256(archive_bytes).hexdigest()
    return _manifest(version, archive_filename(version), digest)


CHANGELOG_NAME = "CHANGELOG.md"


def changelog_section(text, version):
    """Return the body of the `## <version>` section; every release needs one."""
    lines = text.splitlines()
    heading = "## " + version
    starts = [index for index, line in enumerate(lines) if line.strip() == heading]
    if len(starts) != 1:
        raise ValueError(f"{CHANGELOG_NAME} must have exactly one '{heading}' section")
    body = []
    for line in lines[starts[0] + 1:]:
        if line.startswith("## "):
            break
        body.append(line)
    section = "\n".join(body).strip()
    if not section:
        raise ValueError(f"{CHANGELOG_NAME} section '{heading}' is empty")
    return section


def _release_notes(version, changes):
    return f'''# Dyre's Quest Targeting {version}

## Changes

{changes}

## Notes

- Beta for WoW: Forever. Built for Forever beta {GAME_VERSION}, build {TARGET_BUILD},
  Interface {INTERFACE}. DQT runs on later beta builds while the client provides
  the APIs it needs, and says so in chat if they are missing.
- Keeps the character macro "! Target (DQT)" up to date with the mobs and NPCs
  your focused quest needs, and marks what it finds.
- With QuestieDB installed, it also targets the mobs that drop quest items and
  the NPC you turn the quest in to.
- `/dqt add <name>` and `/dqt add_exact <name>` add your own targets; settings
  in Options > AddOns, or `/dqt`; `/dqt list` shows what the macro targets.
'''


def _write_text(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(text)


def build_release(source_root, output, tag=None, github_output=None, source_commit=None):
    """Build locally; optional commit provenance must be checked by the publisher."""
    if source_commit is not None and (
            not isinstance(source_commit, str) or
            SOURCE_COMMIT_RE.fullmatch(source_commit) is None):
        raise ValueError("Source commit must be exactly 40 lowercase hexadecimal characters")
    source_root = Path(source_root)
    files = {}
    for name in PACKAGE_FILES:
        source = source_root / name
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Source must be a regular file: {name}")
        files[name] = source.read_bytes()
    version = _validate_files(files)
    tag = validate_tag(tag, version)
    # Checked before writing anything, so a release can never ship without notes.
    changelog = source_root / CHANGELOG_NAME
    if changelog.is_symlink() or not changelog.is_file():
        raise ValueError(f"Source must be a regular file: {CHANGELOG_NAME}")
    changes = changelog_section(_text(CHANGELOG_NAME, changelog.read_bytes()), version)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / archive_filename(version)
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for name in PACKAGE_FILES:
            entry = zipfile.ZipInfo(f"{ADDON}/{name}", ZIP_TIMESTAMP)
            entry.create_system = 3
            entry.external_attr = FILE_MODE << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, files[name], compresslevel=9)
    manifest = validate_archive(archive_path, version)
    manifest["tag"] = tag
    if source_commit is not None:
        manifest["source_commit"] = source_commit
    _write_text(output / (archive_path.name + ".sha256"),
                f"{manifest['sha256']}  {archive_path.name}\n")
    _write_text(output / "release-manifest.json",
                json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    _write_text(output / "release-notes.md", _release_notes(version, changes))
    _write_text(output / WOWUP_METADATA_NAME,
                json.dumps(wowup_metadata(version), indent=2) + "\n")
    if github_output is not None:
        # Values come only from validated versions and fixed enum/filename fields.
        with Path(github_output).open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(f"version={version}\narchive_name={archive_path.name}\n"
                         f"prerelease={str(manifest['prerelease']).lower()}\n"
                         f"channel={manifest['channel']}\n")
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--source-commit", help="Full lowercase 40-character source commit SHA")
    args = parser.parse_args(argv)
    try:
        manifest = build_release(Path(__file__).resolve().parent.parent,
                                 args.output, args.tag, args.github_output,
                                 source_commit=args.source_commit)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Release build failed: {error}\n")
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
