#!/usr/bin/env python3
"""Prepare a fixed native evaluation; never dispatch a model or run checks."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    path.chmod(0o600)


def prepare(args):
    repository = args.repository.resolve(strict=True)
    fixtures = repository / "harness/evaluations/native-unsubscribe"
    protocol = json.loads((fixtures / "protocol.json").read_text())
    patch = fixtures / "seed.patch"
    if sha256(patch) != protocol["seedPatchSHA256"]:
        raise ValueError("seed patch hash mismatch")
    binary = args.harness_binary.resolve(strict=True)
    codex = args.codex_binary.resolve(strict=True)
    home = args.codex_home.resolve(strict=True)
    output = args.output.resolve()
    # Refuse an existing directory, including a symlink, without touching it.
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("output already exists")
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    for name in list(environment):
        if name.startswith("GIT_") and name not in {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"}:
            del environment[name]

    def command(argv, cwd):
        return subprocess.check_output(argv, cwd=cwd, env=environment, stderr=subprocess.PIPE, timeout=60)

    command(["git", "cat-file", "-e", protocol["baseCommit"] + "^{commit}"], repository)
    output.mkdir(mode=0o700)
    workspace = output / "workspace"
    workspace.mkdir(mode=0o700)
    archive = output / "source.tar"
    command(["git", "-c", "tar.umask=0022", "archive", "--format=tar", "--output", str(archive), protocol["baseCommit"]], repository)
    # Extract only regular files/directories from the pinned trusted source.
    # The fixture deliberately has no links, .git metadata, or inherited history.
    with tarfile.open(archive) as stream:
        for member in stream.getmembers():
            target = Path(member.name)
            if target.is_absolute() or ".." in target.parts or ".git" in target.parts:
                raise ValueError("unsafe archive path")
            if not (member.isfile() or member.isdir()):
                raise ValueError("unsupported archive entry")
        stream.extractall(workspace)
    archive.unlink()
    command(["git", "init", "-q"], workspace)
    command(["git", "apply", "--check", str(patch)], workspace)
    command(["git", "apply", str(patch)], workspace)
    for control in protocol["controls"]:
        path = workspace / control["path"]
        if sha256(path) != control["sha256"] or path.stat().st_mode & 0o777 != control["mode"]:
            raise ValueError("seed control mismatch: " + control["path"])
    command(["git", "add", "."], workspace)
    command(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-c", "user.name=Evaluation Fixture", "-c", "user.email=fixture@example.invalid",
             "commit", "-qm", "Fixed faulty candidate; no solution history"], workspace)

    task = json.loads((fixtures / (args.variant + ".template.json")).read_text())
    task["workspace"] = str(workspace)
    for role in ["review", "repair"]:
        if role in task:
            task[role]["codex"].update(binary=str(codex), home=str(home), model=args.model)
    source = output / "task.source.json"
    frozen = output / "task.json"
    write_json(source, task)
    controls = [workspace / c["path"] for c in protocol["controls"]
                if args.variant != "recovery" or c["path"] != "apple/Sources/TextbookUI/FeedReaderModel.swift"]
    argv = [str(binary), "prepare-product" if args.variant == "recovery" else "freeze-task",
            "-task", str(source), "-output", str(frozen)]
    if args.variant == "recovery":
        argv += ["-profile", "apple-tests", "-check-timeout", "600"]
    for path in controls:
        argv += ["-file", str(path)]
    command(argv, repository)
    write_json(output / "manifest.json", {
        "protocol": "snapshot-only-v2", "variant": args.variant,
        "baseCommit": protocol["baseCommit"], "expectedSeedCodeHash": protocol["seedCodeHash"],
        "fixtureCommit": command(["git", "rev-parse", "HEAD"], workspace).decode().strip(),
        "seedPatchSHA256": sha256(patch), "taskSHA256": sha256(frozen),
        "templateSHA256": sha256(fixtures / (args.variant + ".template.json")),
        "protocolSHA256": sha256(fixtures / "protocol.json"),
        "modelDispatched": False,
    })
    return frozen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", choices=["detection", "focused", "recovery"], required=True)
    parser.add_argument("--harness-binary", type=Path, required=True)
    parser.add_argument("--codex-binary", type=Path, required=True)
    parser.add_argument("--codex-home", type=Path, required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    try:
        print(prepare(args))
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
