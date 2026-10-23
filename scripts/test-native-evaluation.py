#!/usr/bin/env python3
"""Preparation regressions using the real CLI, without model or native test calls."""

import difflib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("preparation", ROOT / "scripts/prepare-native-evaluation.py")
PREPARATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARATION)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-evaluation-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "source"
        self.repository.mkdir()
        self.fixtures = self.repository / "harness/evaluations/native-unsubscribe"
        shutil.copytree(ROOT / "harness/evaluations/native-unsubscribe", self.fixtures)
        self.protocol = json.loads((self.fixtures / "protocol.json").read_text())
        files = {entry["path"] for entry in self.protocol["controls"]}
        files.update([
            "scripts/product-check.sh", "apple/scripts/build-macos-app.sh",
            "apple/scripts/check-native.sh", "apple/scripts/test-macos-bundle.sh",
            ".agents/skills/apple-native-validation/SKILL.md",
            ".agents/skills/harness-development/SKILL.md", ".agents/skills/independent-review/SKILL.md",
        ])
        for name in files:
            target = self.repository / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        # Exercise preparation independently of future product-source edits or a
        # shallow CI checkout. The real pinned product case is a separate probe.
        model_path = "apple/Sources/TextbookUI/FeedReaderModel.swift"
        correct = "// correct implementation\nlet reconcilesSnapshots = true\n"
        faulty = "// faulty candidate\nlet reconcilesSnapshots = false\n"
        (self.repository / model_path).write_text(correct)
        patch = "".join(difflib.unified_diff(correct.splitlines(True), faulty.splitlines(True),
                                           fromfile="a/" + model_path, tofile="b/" + model_path))
        (self.fixtures / "seed.patch").write_text(patch)
        self.protocol["seedPatchSHA256"] = PREPARATION.sha256(self.fixtures / "seed.patch")
        for control in self.protocol["controls"]:
            path = self.repository / control["path"]
            control["sha256"] = (PREPARATION.hashlib.sha256(faulty.encode()).hexdigest()
                                 if control["path"] == model_path else PREPARATION.sha256(path))
            control["mode"] = path.stat().st_mode & 0o777
        # The test's source repository has a correct solution and history.
        # Its export must not make that history reachable in the model workspace.
        self.git(self.repository, "init", "-q")
        self.git(self.repository, "add", ".")
        self.git(self.repository, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                 "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", "Correct original solution")
        self.base = self.git(self.repository, "rev-parse", "HEAD").decode().strip()
        self.protocol["baseCommit"] = self.base
        (self.fixtures / "protocol.json").write_text(json.dumps(self.protocol))
        self.fake_codex = self.root / "codex-must-not-run"
        self.marker = self.root / "model-was-dispatched"
        self.fake_codex.write_text('#!/bin/sh\ntouch "' + str(self.marker) + '"\nexit 1\n')
        self.fake_codex.chmod(0o700)
        self.binary = Path(os.environ["EVALUATION_HARNESS_BINARY"])

    @staticmethod
    def git(cwd, *args):
        return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE,
                                       env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1"))

    def arguments(self, variant):
        return SimpleNamespace(repository=self.repository, output=self.root / variant, variant=variant,
                               harness_binary=self.binary, codex_binary=self.fake_codex,
                               codex_home=self.root, model="evaluation-model")

    def test_variants_have_faulty_only_history_and_fixed_contracts(self):
        acceptance = None
        for variant in ["detection", "focused", "recovery"]:
            with self.subTest(variant=variant):
                args = self.arguments(variant)
                task_path = PREPARATION.prepare(args)
                workspace = args.output / "workspace"
                task = json.loads(task_path.read_text())
                self.assertEqual(self.git(workspace, "rev-list", "--count", "HEAD").strip(), b"1")
                self.assertEqual(self.git(workspace, "diff", "HEAD"), b"")
                self.assertEqual(self.git(workspace, "remote"), b"")
                with self.assertRaises(subprocess.CalledProcessError):
                    self.git(workspace, "cat-file", "-e", self.base)
                for control in self.protocol["controls"]:
                    self.assertEqual(PREPARATION.sha256(workspace / control["path"]), control["sha256"])
                if acceptance is None:
                    acceptance = task["acceptance"]
                self.assertEqual(task["acceptance"], acceptance)
                protected = {Path(c["path"]).relative_to(workspace).as_posix() for c in task["protectedFiles"]}
                expected = {c["path"] for c in self.protocol["controls"]}
                model_file = "apple/Sources/TextbookUI/FeedReaderModel.swift"
                if variant == "recovery":
                    expected.remove(model_file)
                    self.assertNotIn(model_file, protected)
                    self.assertEqual(task["checks"][1]["command"][-2:], ["check", "apple-tests"])
                    self.assertEqual(task["maxRepairCycles"], 1)
                else:
                    self.assertEqual(len(task["checks"]), 1)
                    self.assertEqual(task["maxRepairCycles"], 0)
                self.assertTrue(expected <= protected)
                self.assertEqual(task["review"]["codex"]["model"], "evaluation-model")
                self.assertFalse(self.marker.exists())

    def test_existing_output_is_preserved(self):
        args = self.arguments("detection")
        args.output.mkdir()
        marker = args.output / "keep"
        marker.write_text("existing evidence")
        with self.assertRaisesRegex(ValueError, "already exists"):
            PREPARATION.prepare(args)
        self.assertEqual(list(args.output.iterdir()), [marker])
        self.assertEqual(marker.read_text(), "existing evidence")

    def test_changed_patch_is_refused_before_writes(self):
        args = self.arguments("detection")
        with (self.fixtures / "seed.patch").open("a") as stream:
            stream.write("changed")
        with self.assertRaisesRegex(ValueError, "patch hash mismatch"):
            PREPARATION.prepare(args)
        self.assertFalse(args.output.exists())

    def test_changed_control_never_yields_frozen_task(self):
        args = self.arguments("recovery")
        self.protocol["controls"][0]["sha256"] = "0" * 64
        (self.fixtures / "protocol.json").write_text(json.dumps(self.protocol))
        with self.assertRaisesRegex(ValueError, "control mismatch"):
            PREPARATION.prepare(args)
        self.assertFalse((args.output / "task.json").exists())
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
