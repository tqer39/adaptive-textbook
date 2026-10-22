#!/usr/bin/env python3
"""Opt-in two-run live smoke against a public, isolated Go grading fixture.

No login, token inspection, subscription change, or automatic model retry.
Use --prepare-only to prepare inputs without dispatching any inference.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


GO_MOD = "module example.invalid/textbook-grading-smoke\n\ngo 1.24\n"
GRADE_STUB = "package grading\n\nfunc Grade(answer, expected string) bool {\n\treturn false\n}\n"
NORMALIZE = '''package grading

import "strings"

func normalize(value string) string {
	return strings.TrimSpace(value)
}
'''
FAULT_FROM = "return strings.TrimSpace(value)"
FAULT_TO = 'return strings.Trim(value, " \\t\\r\\n")'
BASIC_TESTS = r'''package grading

import "testing"

func TestGradeBasic(t *testing.T) {
	cases := []struct { answer, expected string; want bool } {
		{"回答", "回答", true}, {"別の回答", "回答", false},
		{" \t回答\r\n", " 回答 ", true}, {"", "", false},
		{" \t\n", "", false}, {"回答", "", false},
		{"HTTP", "http", false},
	}
	for _, c := range cases {
		if got := Grade(c.answer, c.expected); got != c.want {
			t.Errorf("Grade(%q, %q) = %v, want %v", c.answer, c.expected, got, c.want)
		}
	}
}
'''
EDGE_TESTS = r'''package grading

import "testing"

func TestGradeUnicodeEdge(t *testing.T) {
	cases := []struct { answer, expected string; want bool } {
		{"　回答　", "回答", true}, {"回答", "　回答　", true},
		{"\u00a0回答\u00a0", "回答", true}, {"　", "　", false},
		{"　HTTP　", "http", false},
	}
	for _, c := range cases {
		if got := Grade(c.answer, c.expected); got != c.want {
			t.Errorf("Grade(%q, %q) = %v, want %v", c.answer, c.expected, got, c.want)
		}
	}
}
'''
ACCEPTANCE = [
    "Implement package grading: Grade(answer, expected string) bool. Normalize both inputs with normalize(value).",
    "Ignore surrounding Unicode whitespace, including U+3000 ideographic space and U+00A0 non-breaking space. Internal whitespace remains significant.",
    "Return false when either normalized value is empty. Otherwise compare exactly, case-sensitively.",
    "Only grade.go and normalize.go may change. Do not modify go.mod or grading_test.go, add dependencies/files, use network, or modify Git metadata.",
    "Basic checks intentionally cover ASCII whitespace only. Independently examine all acceptance criteria, including Unicode edges; passing basic tests alone is insufficient.",
]


class SmokeFailure(RuntimeError):
    pass


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_private(path: Path, text: str) -> None:
    with path.open("x", encoding="utf-8") as output:
        output.write(text)
    path.chmod(0o600)


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write("\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def tool_environment(output: Path) -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(output / "tool-home"),
        "TMPDIR": str(output / "tmp"), "GOTMPDIR": str(output / "tmp"),
        "GOCACHE": str(output / "go-cache"), "GOTOOLCHAIN": "local",
        "GOPROXY": "off", "GOSUMDB": "off", "GOENV": "off", "GOWORK": "off",
        "GOFLAGS": "", "LC_ALL": "C", "LANG": "C",
    }


def await_process(process: subprocess.Popen, timeout: int, label: str) -> int:
    try:
        return process.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        # Give the harness time to cancel its independently grouped children.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SmokeFailure(label + ": interrupted; inspect state, never automatically replay")


def run_command(command: list[str], cwd: Path, output: Path, label: str,
                timeout: int, env: dict[str, str]) -> tuple[int, Path]:
    log = output / (label + ".log")
    with log.open("xb") as stream:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        code = await_process(process, timeout, label)
    log.chmod(0o600)
    return code, log


def run_harness(args: argparse.Namespace, task: Path, state: Path, output: Path,
                label: str, env: dict[str, str]) -> dict:
    stdout = output / (label + ".json")
    stderr = output / (label + ".stderr.log")
    with stdout.open("xb") as result, stderr.open("xb") as diagnostics:
        process = subprocess.Popen(
            [args.harness_binary, "run", "-task", str(task), "-state", str(state), "-allow-codex"],
            cwd=output, env=env, stdin=subprocess.DEVNULL, stdout=result, stderr=diagnostics,
            start_new_session=True,
        )
        code = await_process(process, 1230, label)
    stdout.chmod(0o600)
    stderr.chmod(0o600)
    if stdout.stat().st_size > 1024 * 1024:
        raise SmokeFailure(label + ": result too large")
    try:
        run = json.loads(stdout.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise SmokeFailure(label + ": no confirmed harness result; inspect private logs") from error
    if code != 0 or run.get("status") != "accepted":
        raise SmokeFailure(label + ": not accepted; inspect private result and state")
    return run


def reviews(run: dict, state: Path) -> list[dict]:
    answers = []
    for evidence in run.get("evidence", []):
        if evidence["phase"] != "review":
            continue
        log = (state / evidence["log"]).resolve()
        if not log.is_relative_to(state) or digest(log) != evidence["logHash"]:
            raise SmokeFailure("review evidence hash/path mismatch")
        review = json.loads(json.loads(log.read_text(encoding="utf-8"))["stdout"])
        if review.get("codeHash") != evidence["codeHash"]:
            raise SmokeFailure("review is for a different code hash")
        answers.append(review)
    return answers


def audit_models(runs: list[dict], model: str, expected_count: int) -> list[dict]:
    confirmed = []
    for run in runs:
        for evidence in run.get("evidence", []):
            if evidence.get("phase") not in ("implement", "repair", "review"):
                continue
            metadata = evidence.get("model")
            if not isinstance(metadata, dict):
                raise SmokeFailure("completed model operation has no model audit metadata")
            if (
                evidence.get("outcome") != "complete" or evidence.get("exitCode") != 0
                or metadata.get("role") != evidence["phase"]
                or metadata.get("requestedModel") != model
                or metadata.get("resolvedModel") != model
                or metadata.get("provider") != "openai"
                or metadata.get("serviceTier") != "default"
                or metadata.get("reportedServiceTier") not in (None, "default")
                or not isinstance(metadata.get("threadId"), str) or not metadata["threadId"]
                or not isinstance(metadata.get("turnId"), str) or not metadata["turnId"]
            ):
                raise SmokeFailure("model/provider/tier/completion metadata mismatch")
            confirmed.append({"runID": run["id"], "operation": evidence["operation"], **metadata})
    if len(confirmed) != expected_count:
        raise SmokeFailure("unexpected number of confirmed model operations")
    if len({item["threadId"] for item in confirmed}) != expected_count:
        raise SmokeFailure("implementation, repair and independent reviews reused a thread")
    return confirmed


def validate_fixture(fixture: Path, immutable: dict[str, str]) -> None:
    expected = {"go.mod", "grade.go", "normalize.go", "grading_test.go"}
    actual = {entry.name for entry in fixture.iterdir() if entry.name != ".git"}
    if actual != expected:
        raise SmokeFailure("fixture file set changed")
    for name in expected:
        if not (fixture / name).is_file() or (fixture / name).is_symlink():
            raise SmokeFailure("fixture contains non-regular source")
    for name, sha in immutable.items():
        if digest(fixture / name) != sha:
            raise SmokeFailure("fixed acceptance test or module was changed")


def edge_check(fixture: Path, output: Path, go: str, label: str,
               env: dict[str, str], expect_pass: bool) -> dict:
    snapshot = output / (label + "-fixture")
    snapshot.mkdir(mode=0o700)
    for name in ("go.mod", "grade.go", "normalize.go", "grading_test.go"):
        shutil.copyfile(fixture / name, snapshot / name)
    write_private(snapshot / "unicode_edge_test.go", EDGE_TESTS)
    code, log = run_command([go, "test", "-count=1", "./..."], snapshot, output, label, 120, env)
    text = log.read_text(encoding="utf-8", errors="replace")
    if expect_pass and code != 0:
        raise SmokeFailure(label + ": fixed Unicode tests failed")
    if not expect_pass and (code == 0 or "--- FAIL: TestGradeUnicodeEdge" not in text):
        raise SmokeFailure(label + ": injected fault was not demonstrated by fixed edge tests")
    return {"passed": code == 0, "exitCode": code, "log": str(log),
            "logHash": digest(log), "expectedPass": expect_pass}


def prepare(args: argparse.Namespace, output: Path) -> tuple[Path, dict[str, str], dict[str, str]]:
    env = tool_environment(output)
    for name in ("tool-home", "tmp", "go-cache", "tasks", "tools"):
        (output / name).mkdir(mode=0o700)
    fixture = output / "public-fixture"
    fixture.mkdir(mode=0o700)
    for name, text in {"go.mod": GO_MOD, "grade.go": GRADE_STUB,
                       "normalize.go": NORMALIZE, "grading_test.go": BASIC_TESTS}.items():
        write_private(fixture / name, text)
    code, _ = run_command(["/usr/bin/git", "init", "--quiet", str(fixture)],
                          output, output, "git-init", 30, env)
    if code:
        raise SmokeFailure("could not initialize isolated public fixture")
    immutable = {name: digest(fixture / name) for name in ("go.mod", "grading_test.go")}
    helper = output / "tools/check.py"
    write_private(helper, """import subprocess, sys
environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": sys.argv[3],
 "GOCACHE": sys.argv[2], "GOTMPDIR": sys.argv[4], "GOTOOLCHAIN": "local",
 "GOPROXY": "off", "GOSUMDB": "off", "GOENV": "off", "GOWORK": "off", "GOFLAGS": ""}
sys.stdin.read()
raise SystemExit(subprocess.run([sys.argv[1], "test", "-count=1", "./..."], env=environment).returncode)
""")
    codex = {"enabled": True, "binary": args.codex_binary, "home": args.codex_home, "model": args.model}
    action = {
        "kind": "codex", "codex": codex, "timeoutSeconds": 240,
        "instructions": "Implement only the specified public fixture. Use normalize(value) for both inputs. Do not modify tests, module, Git metadata, or files outside this fixture. Run no network operations. Do not claim tests were run if they were not.",
    }
    common = {
        "version": 1, "workspace": str(fixture),
        "goal": "Implement and independently review a small Go grading function for a Japanese textbook. This is a bounded public live integration fixture, not a production change.",
        "acceptance": ACCEPTANCE,
        "checks": [{"command": [str(Path(sys.executable).resolve()), str(helper), args.go_binary,
                                str(output / "go-cache"), str(output / "tool-home"), str(output / "tmp")],
                    "timeoutSeconds": 120}],
        "review": {"kind": "codex", "codex": codex, "timeoutSeconds": 240},
        "timeoutSeconds": 1200, "logLimitBytes": 262144, "maxOperations": 8,
    }
    write_json(output / "tasks/run-a.json", dict(common, name="public-grade-implementation",
                                               implement=action, maxRepairCycles=0))
    write_json(output / "tasks/run-b.json", dict(common, name="public-grade-fault-review-repair",
                                               repair=action, maxRepairCycles=1))
    return fixture, immutable, env


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("harness-binary", "codex-binary", "codex-home", "model", "go-binary", "output"):
        parser.add_argument("--" + flag, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    output = Path(args.output)
    if not output.is_absolute() or output.resolve() != output or output.exists():
        parser.error("--output must be a new canonical absolute path; existing directories are never overwritten")
    root = Path(__file__).resolve().parents[1]
    if output.is_relative_to(root):
        relative = output.relative_to(root)
        ignored = subprocess.run(["/usr/bin/git", "check-ignore", "-q", "--", str(relative)], cwd=root)
        if ignored.returncode != 0:
            parser.error("--output inside the checkout must be Git-ignored")
    for flag in ("harness_binary", "codex_binary", "go_binary"):
        path = Path(getattr(args, flag))
        if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
            parser.error("--" + flag.replace("_", "-") + " must name an absolute executable")
        setattr(args, flag, str(path.resolve()))
    if not Path(args.codex_home).is_absolute() or not Path(args.codex_home).is_dir():
        parser.error("--codex-home must name an existing configured absolute directory")
    args.codex_home = str(Path(args.codex_home).resolve())
    output.mkdir(mode=0o700, parents=True)
    report = {
        "version": 1, "status": "preparing", "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "model": args.model, "modelInference": False, "liveDispatchAttempted": False,
        "testOnlyFaultInjection": True,
        "note": "A known Unicode-whitespace fault is injected between separate runs. This is integration evidence, not a general review-quality benchmark.",
    }
    started = time.monotonic()
    try:
        fixture, immutable, env = prepare(args, output)
        report.update(fixture=str(fixture), fixedInputHashes=immutable, status="prepared")
        write_json(output / "report.json", report)
        if args.prepare_only:
            print(json.dumps({"status": "prepared", "report": str(output / "report.json")}))
            return 0
        report["liveDispatchAttempted"] = True
        # A failed/unknown turn may still have consumed plan allowance.
        report["modelInference"] = None
        write_json(output / "report.json", report)
        first = run_harness(args, output / "tasks/run-a.json", output / "state-a", output, "run-a", env)
        validate_fixture(fixture, immutable)
        if [item["phase"] for item in first["evidence"]] != ["implement", "checks", "review"]:
            raise SmokeFailure("run-a sequence mismatch")
        if [item["decision"] for item in reviews(first, output / "state-a")] != ["approve"]:
            raise SmokeFailure("run-a independent review did not approve")
        report["confirmedModelOperations"] = audit_models([first], args.model, 2)
        report["modelInference"] = True
        report["runA"] = {"id": first["id"], "status": first["status"], "codeHash": first["codeHash"],
                          "evidence": first["evidence"]}
        report["runIDs"] = [first["id"]]
        report["baselineEdgeCheck"] = edge_check(fixture, output, args.go_binary, "baseline", env, True)
        before = (fixture / "normalize.go").read_text(encoding="utf-8")
        if before.count(FAULT_FROM) != 1:
            raise SmokeFailure("helper differs from the known one-line fault-injection target")
        original_hash = digest(fixture / "normalize.go")
        (fixture / "normalize.go").write_text(before.replace(FAULT_FROM, FAULT_TO), encoding="utf-8")
        report["injection"] = {
            "file": "normalize.go", "beforeHash": original_hash,
            "afterHash": digest(fixture / "normalize.go"),
            "kind": "test-only-Unicode-TrimSpace-to-ASCII-Trim",
        }
        report["runAInvalidatedByFaultInjection"] = True
        report["beforeRepairEdgeCheck"] = edge_check(fixture, output, args.go_binary, "injected", env, False)
        write_json(output / "report.json", report)
        second = run_harness(args, output / "tasks/run-b.json", output / "state-b", output, "run-b", env)
        validate_fixture(fixture, immutable)
        if [item["phase"] for item in second["evidence"]] != ["checks", "review", "repair", "checks", "review"] or second["cycle"] != 1:
            raise SmokeFailure("run-b did not execute exactly one independent review/repair cycle")
        verdicts = reviews(second, output / "state-b")
        if [item["decision"] for item in verdicts] != ["revise", "approve"]:
            raise SmokeFailure("review failed to request and then approve a repair")
        report["runB"] = {
            "id": second["id"], "status": second["status"], "codeHash": second["codeHash"],
            "decisions": [item["decision"] for item in verdicts], "reviews": verdicts,
            "cycle": second["cycle"], "evidence": second["evidence"],
        }
        report["runIDs"].append(second["id"])
        report["afterRepairEdgeCheck"] = edge_check(fixture, output, args.go_binary, "after-repair", env, True)
        confirmed = audit_models([first, second], args.model, 5)
        report.update(confirmedModelOperations=confirmed, modelThreadsDistinct=True,
                      harnessModelOperations=len(confirmed), status="passed")
    except (SmokeFailure, OSError, ValueError, KeyError) as error:
        report.update(status="failed", failure=str(error))
    finally:
        report["elapsedSeconds"] = round(time.monotonic() - started, 3)
        write_json(output / "report.json", report)
    print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
