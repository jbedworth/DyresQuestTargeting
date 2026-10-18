"""Upload an already validated release to CurseForge (Python 3 stdlib only).

Workflow authorization/gating belongs to the caller. CF_API_TOKEN is read only
from the environment. An accepted upload is not a claim of moderator approval.
Never automatically retry an upload: a failed response may still mean acceptance.
"""

import argparse
import hashlib
import http.client
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import build_release


VERSIONS_URL = "https://wow.curseforge.com/api/game/wow/versions"
UPLOAD_URL = "https://wow.curseforge.com/api/projects/{project_id}/upload-file"
FOREVER_TYPE_ID = 88568
TIMEOUT = 30
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
RECEIPT_NAME = "curseforge-upload.json"


class PublishError(Exception):
    """Safe, deliberately non-secret diagnostic for CLI output."""


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Block even same-host redirects: do not replay a POST or forward a token.
        raise PublishError("CurseForge redirect refused")


def make_opener():
    return urllib.request.build_opener(NoRedirects())


def numeric_id(value):
    if not isinstance(value, str) or re.fullmatch(r"[1-9][0-9]*", value, re.ASCII) is None:
        raise PublishError("IDs must be explicit positive decimal integers")
    try:
        return int(value)
    except ValueError:
        raise PublishError("Invalid numeric ID") from None


def positive_id(value):
    return type(value) is int and value > 0


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def decode_json(data, label):
    try:
        return json.loads(data, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        raise PublishError(f"Invalid {label} JSON") from None


def read_json(path, label):
    try:
        data = path.read_bytes()
    except OSError:
        raise PublishError(f"Cannot read {label}") from None
    return decode_json(data, label)


def load_artifact(artifact_dir, tag):
    manifest = read_json(artifact_dir / "release-manifest.json", "release manifest")
    if not isinstance(manifest, dict):
        raise PublishError("Release manifest must be an object")
    version = manifest.get("version")
    try:
        build_release.validate_version(version)
        build_release.validate_tag(tag, version)
    except ValueError:
        raise PublishError("Requested tag must match the release version") from None
    if tag != "v" + version or manifest.get("tag") != tag:
        raise PublishError("Manifest tag must match the requested strict vVERSION tag")
    archive_name = build_release.archive_filename(version)
    if manifest.get("archive_name") != archive_name:
        raise PublishError("Manifest archive name mismatch")
    archive_path = artifact_dir / archive_name
    try:
        verified = build_release.validate_archive(archive_path, version)
        archive_bytes = archive_path.read_bytes()
    except (ValueError, OSError):
        raise PublishError("Release ZIP validation failed") from None
    for key, value in verified.items():
        if key == "tag":
            continue
        supplied = manifest.get(key)
        if type(supplied) is not type(value) or supplied != value:
            raise PublishError(f"Release manifest {key} mismatch")
    if (verified["interface"] != 16001 or verified["game_version"] != "1.60.1"
            or verified["target_build"] != 70338):
        raise PublishError("Only Forever beta 1.60.1 / Interface 16001 / build 70338 is supported")
    # Upload the held bytes, not a later read of a possibly replaced artifact.
    digest = hashlib.sha256(archive_bytes).hexdigest()
    if digest != verified["sha256"]:
        raise PublishError("Release ZIP changed during validation")
    try:
        # Decode raw bytes so universal-newline handling cannot accept CRLF.
        checksum = (artifact_dir / (archive_name + ".sha256")).read_bytes().decode("utf-8")
    except (OSError, UnicodeError):
        raise PublishError("Cannot read UTF-8 checksum sidecar") from None
    if checksum != f"{digest}  {archive_name}\n":
        raise PublishError("Checksum sidecar must exactly match the ZIP hash and filename with one LF newline")
    try:
        changelog = (artifact_dir / "release-notes.md").read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        raise PublishError("Cannot read UTF-8 release notes") from None
    if not changelog.strip() or "\x00" in changelog:
        raise PublishError("Release notes must be non-empty Markdown text")
    # WowUp reads this asset to find the Forever ZIP; it must name the verified archive.
    metadata_path = artifact_dir / build_release.WOWUP_METADATA_NAME
    supplied = read_json(metadata_path, "WowUp release metadata")
    # Canonical JSON comparison keeps false distinct from 0.
    if (json.dumps(supplied, sort_keys=True)
            != json.dumps(build_release.wowup_metadata(version), sort_keys=True)):
        raise PublishError("WowUp release.json must name the verified Forever ZIP")
    return manifest, archive_bytes, changelog


def check_receipt(path, expected):
    if not path.exists() and not path.is_symlink():
        return
    receipt = read_json(path, "upload receipt")
    if (not isinstance(receipt, dict) or set(receipt) != set(expected) | {"file_id"}
            or not positive_id(receipt.get("file_id"))):
        raise PublishError("Invalid existing upload receipt; refusing upload")
    for key, value in expected.items():
        if type(receipt.get(key)) is not type(value) or receipt[key] != value:
            raise PublishError("Existing upload receipt is inconsistent; refusing upload")
    raise PublishError(f"File already recorded as CurseForge file {receipt['file_id']}; refusing duplicate upload")


def request_json(opener, request):
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            status = response.getcode()
            if type(status) is not int or not 200 <= status < 300:
                raise PublishError("CurseForge returned an unsuccessful status")
            data = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        # Never echo reason, URL, headers or response body: these may contain keys.
        status = error.code
        suffix = f" (HTTP {status})" if type(status) is int else ""
        raise PublishError("CurseForge request failed" + suffix) from None
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError, http.client.HTTPException):
        raise PublishError("CurseForge network request failed or timed out") from None
    if len(data) > MAX_RESPONSE_BYTES:
        raise PublishError("CurseForge response is too large")
    return decode_json(data, "CurseForge response")


def verify_server_version(versions, game_version_id):
    if not isinstance(versions, list):
        raise PublishError("CurseForge versions response must be an array")
    matches = [entry for entry in versions if isinstance(entry, dict)
               and type(entry.get("id")) is int and entry["id"] == game_version_id]
    if len(matches) != 1:
        raise PublishError("Requested game-version ID is absent or ambiguous on CurseForge")
    entry = matches[0]
    if (entry.get("name") != "1.60.1"
            or type(entry.get("gameVersionTypeID")) is not int
            or entry["gameVersionTypeID"] != FOREVER_TYPE_ID):
        raise PublishError("Requested game-version ID is not Forever 1.60.1 (type 88568)")


def multipart(metadata, archive_name, archive_bytes):
    metadata_bytes = json.dumps(metadata, ensure_ascii=True).encode("utf-8")
    boundary = "wtf-" + uuid.uuid4().hex
    while boundary.encode("ascii") in metadata_bytes or boundary.encode("ascii") in archive_bytes:
        boundary = "wtf-" + uuid.uuid4().hex
    marker = boundary.encode("ascii")
    body = (b"--" + marker + b"\r\n"
            b'Content-Disposition: form-data; name="metadata"\r\n'
            b"Content-Type: application/json; charset=utf-8\r\n\r\n"
            + metadata_bytes + b"\r\n--" + marker + b"\r\n"
            + f'Content-Disposition: form-data; name="file"; filename="{archive_name}"\r\n'.encode("ascii")
            + b"Content-Type: application/zip\r\n\r\n" + archive_bytes
            + b"\r\n--" + marker + b"--\r\n")
    return body, "multipart/form-data; boundary=" + boundary


def publish(artifact_dir, project_id, game_version_id, tag):
    project_id = numeric_id(project_id)
    game_version_id = numeric_id(game_version_id)
    artifact_dir = Path(artifact_dir)
    manifest, archive_bytes, changelog = load_artifact(artifact_dir, tag)
    expected_receipt = {"project_id": project_id, "tag": tag,
                        "archive_name": manifest["archive_name"], "sha256": manifest["sha256"]}
    receipt_path = artifact_dir / RECEIPT_NAME
    check_receipt(receipt_path, expected_receipt)
    token = os.environ.get("CF_API_TOKEN", "")
    if not token or not token.strip():
        raise PublishError("CF_API_TOKEN environment variable is required")
    if any(ord(char) < 33 or ord(char) > 126 for char in token):
        raise PublishError("CF_API_TOKEN has an invalid header format")
    opener = make_opener()
    headers = {"X-Api-Token": token, "Accept": "application/json"}
    versions = request_json(opener, urllib.request.Request(VERSIONS_URL, headers=headers))
    verify_server_version(versions, game_version_id)
    metadata = {"gameVersions": [game_version_id], "releaseType": manifest["channel"],
                "changelog": changelog, "changelogType": "markdown"}
    body, content_type = multipart(metadata, manifest["archive_name"], archive_bytes)
    upload_headers = dict(headers, **{"Content-Type": content_type})
    request = urllib.request.Request(UPLOAD_URL.format(project_id=project_id),
                                     data=body, headers=upload_headers, method="POST")
    try:
        result = request_json(opener, request)
        if not isinstance(result, dict) or not positive_id(result.get("id")):
            raise PublishError("CurseForge upload response has no valid file ID")
        receipt = dict(expected_receipt, file_id=result["id"])
        # Do not overwrite a receipt created by another run. The workflow must
        # serialize publishers; the local receipt is not a distributed lock.
        try:
            with receipt_path.open("x", encoding="utf-8", newline="\n") as stream:
                stream.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        except OSError:
            raise PublishError("Cannot write upload receipt") from None
    except PublishError as error:
        raise PublishError(f"{error}. Upload may have been accepted; check CurseForge before any retry") from None
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--game-version-id", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args(argv)
    try:
        receipt = publish(args.artifact_dir, args.project_id, args.game_version_id, args.tag)
    except (PublishError, OSError, ValueError) as error:
        # Only PublishError messages are safe to show; other exception strings
        # may include server content or credentials.
        message = str(error) if isinstance(error, PublishError) else "Local publishing error"
        print("CurseForge upload failed: " + message, file=sys.stderr)
        return 1
    print(f"CurseForge upload accepted: file {receipt['file_id']}. Moderation may still be pending.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
