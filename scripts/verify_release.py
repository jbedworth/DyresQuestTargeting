"""Verify artifact provenance and the remote tag before publication; no uploads."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

from publish_curseforge import PublishError, load_artifact


SHA_PATTERN = re.compile(r"[0-9a-f]{40}", re.ASCII)
REPO_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", re.ASCII)


def github_object(endpoint):
    try:
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com", endpoint],
            check=True, capture_output=True, text=True, timeout=30,
        )
        data = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise PublishError("Cannot verify the remote GitHub tag") from None
    if not isinstance(data, dict) or not isinstance(data.get("object"), dict):
        raise PublishError("Invalid remote GitHub tag response")
    return data["object"]


def verify_release(artifact_dir, tag, commit, repo):
    if not isinstance(commit, str) or SHA_PATTERN.fullmatch(commit) is None:
        raise PublishError("Expected source commit must be a full lowercase SHA")
    if not isinstance(repo, str) or REPO_PATTERN.fullmatch(repo) is None:
        raise PublishError("Expected repository must be owner/name")
    manifest, _, _ = load_artifact(Path(artifact_dir), tag)
    if manifest.get("source_commit") != commit:
        raise PublishError("Artifact source commit does not match this workflow")
    obj = github_object(f"repos/{repo}/git/ref/tags/{quote(tag, safe='')}")
    for _ in range(8):
        sha = obj.get("sha")
        if not isinstance(sha, str) or SHA_PATTERN.fullmatch(sha) is None:
            raise PublishError("Invalid remote GitHub object SHA")
        if obj.get("type") == "commit":
            if sha != commit:
                raise PublishError("Remote tag moved away from the tested commit; refusing publication")
            return manifest
        if obj.get("type") != "tag":
            raise PublishError("Remote tag does not point to a commit")
        obj = github_object(f"repos/{repo}/git/tags/{sha}")
    raise PublishError("Remote tag chain is too deep")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args(argv)
    try:
        verify_release(args.artifact_dir, args.tag, args.commit, args.repo)
    except PublishError as error:
        parser.exit(1, f"Release verification failed: {error}\n")
    print("Artifact, checksum, source commit, and remote tag verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
