"""Test release versioning and workflow guards without remote writes or signing."""

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import yaml

ROOT = Path(__file__).resolve().parent.parent
GIT = shutil.which("git")
BATCH = ".changenote/releases.json"


class TemporaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="display-loom-release-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.environment = {
            **os.environ,
            "GIT_AUTHOR_NAME": "Release Test",
            "GIT_AUTHOR_EMAIL": "release-test@example.invalid",
            "GIT_COMMITTER_NAME": "Release Test",
            "GIT_COMMITTER_EMAIL": "release-test@example.invalid",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }

    def run_command(self, *arguments, check=True):
        return subprocess.run(
            arguments,
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
            check=check,
            timeout=60,
        )


class ChangenoteTests(TemporaryTests):
    def setUp(self):
        super().setUp()
        for directory in ("Configuration", "DisplayLoom.xcodeproj"):
            shutil.copytree(ROOT / directory, self.root / directory)
        for filename in (".changenote/config.json", "CHANGELOG.md", "project.yml"):
            destination = self.root / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / filename, destination)
        self.version_file = self.root / "Configuration/Version.xcconfig"
        self.version = self.version_file.read_text().split("=", 1)[1].strip()
        major, minor, patch = map(int, self.version.split("."))
        self.next_version = f"{major}.{minor}.{patch + 1}"

    def add_note(self):
        self.run_command(
            "changenote",
            "add",
            "regression-check",
            "--package",
            "display-loom",
            "--bump",
            "patch",
            "--message",
            "Improve display recovery.\n\nKeep saved settings.",
        )

    def snapshot(self, directory):
        return {
            path.relative_to(directory): path.read_bytes()
            for path in directory.rglob("*")
            if path.is_file()
        }

    def test_no_notes_do_not_change_release_files(self):
        before = self.snapshot(self.root)
        self.assertEqual(
            json.loads(self.run_command("changenote", "status").stdout), []
        )
        self.run_command("changenote", "version")
        self.assertEqual(self.snapshot(self.root), before)

    def test_patch_updates_version_changelog_and_batch_only(self):
        project = self.snapshot(self.root / "DisplayLoom.xcodeproj")
        spec = (self.root / "project.yml").read_bytes()
        self.add_note()
        plan = json.loads(self.run_command("changenote", "status").stdout)
        self.assertEqual(plan[0]["version"], self.next_version)
        self.run_command("changenote", "version")
        self.assertEqual(
            self.version_file.read_text(),
            f"MARKETING_VERSION = {self.next_version}\n",
        )
        self.assertFalse((self.root / ".changenote/regression-check.md").exists())
        batch = json.loads((self.root / BATCH).read_text())
        self.assertEqual(batch[0]["tag"], f"v{self.next_version}")
        notes = self.run_command(
            "changenote",
            "release-notes",
            "--package",
            "display-loom",
            "--version",
            self.next_version,
        ).stdout
        self.assertIn("Improve display recovery.", notes)
        self.assertIn("  Keep saved settings.", notes)
        self.assertNotIn(f"## {self.next_version}", notes)
        self.assertEqual(self.snapshot(self.root / "DisplayLoom.xcodeproj"), project)
        self.assertEqual((self.root / "project.yml").read_bytes(), spec)
        after = self.snapshot(self.root)
        self.run_command("changenote", "version")
        self.assertEqual(self.snapshot(self.root), after)

    def test_version_bump_does_not_change_xcodegen_output(self):
        for directory in ("DisplayLoom", "DisplayLoomTests"):
            shutil.copytree(ROOT / directory, self.root / directory)
        self.run_command("xcodegen", "generate")
        before = self.snapshot(self.root / "DisplayLoom.xcodeproj")
        self.add_note()
        self.run_command("changenote", "version")
        self.run_command("xcodegen", "generate")
        self.assertEqual(self.snapshot(self.root / "DisplayLoom.xcodeproj"), before)


class WorkflowTests(TemporaryTests):
    def setUp(self):
        super().setUp()
        self.workflow = yaml.load(
            (ROOT / ".github/workflows/release.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        self.jobs = self.workflow["jobs"]
        self.output = self.root / "github-output"
        self.remote_writes = self.root / "remote-writes.log"
        self.environment["GITHUB_OUTPUT"] = str(self.output)

    def step(self, job, name):
        return next(step for step in self.jobs[job]["steps"] if step.get("name") == name)

    def operation(self, job, operation):
        return next(
            step for step in self.jobs[job]["steps"]
            if step.get("with", {}).get("operation") == operation
        )

    def expression(self, value):
        return " ".join(value.removeprefix("${{").removesuffix("}}").split())

    def assert_no_output_or_remote_writes(self):
        self.assertFalse(self.remote_writes.exists())
        self.assertEqual(self.output.read_text() if self.output.exists() else "", "")

    def prepare_git(self):
        self.run_command(GIT, "init", "--quiet", "--initial-branch=main", "--template=")
        commit = self.commit_file(BATCH, "[]\n")
        commands = self.root / "mock-bin"
        commands.mkdir()
        log = shlex.quote(str(self.remote_writes))
        (commands / "git").write_text(f"""#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  diff|merge-base|rev-parse) exec {shlex.quote(GIT)} "$@" ;;
  *) printf 'Unexpected git command: %s\\n' "$*" >>{log}; exit 99 ;;
esac
""")
        (commands / "gh").write_text(f"""#!/usr/bin/env bash
printf 'Unexpected gh command: %s\\n' "$*" >>{log}
exit 99
""")
        for command in commands.iterdir():
            command.chmod(0o755)
        self.environment["PATH"] = f"{commands}{os.pathsep}{os.environ['PATH']}"
        return commit

    def commit_file(self, filename, content):
        path = self.root / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        self.run_command(GIT, "add", "--", filename)
        self.run_command(
            GIT, "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", filename
        )
        return self.run_command(GIT, "rev-parse", "HEAD").stdout.strip()

    def test_main_push_and_manual_operations_route_separately(self):
        self.assertEqual(set(self.workflow["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(self.workflow["on"]["push"]["branches"], ["main"])
        operation = self.workflow["on"]["workflow_dispatch"]["inputs"]["operation"]
        self.assertEqual(operation["type"], "choice")
        self.assertEqual(operation["default"], "manage-pr")
        self.assertEqual(set(operation["options"]), {"manage-pr", "retry-publication"})
        self.assertEqual(set(self.jobs), {"release-pr", "select", "package", "publish"})
        cases = (
            ("push", "main", "", {"release-pr", "select"}),
            ("push", "topic", "", set()),
            ("workflow_dispatch", "main", "manage-pr", {"release-pr"}),
            ("workflow_dispatch", "main", "retry-publication", {"select"}),
            ("workflow_dispatch", "topic", "manage-pr", set()),
            ("workflow_dispatch", "topic", "retry-publication", set()),
            ("workflow_dispatch", "main", "unknown", set()),
            ("pull_request", "main", "", set()),
            ("pull_request_target", "main", "", set()),
        )
        for event, branch, operation, expected in cases:
            with self.subTest(event=event, branch=branch, operation=operation):
                context = {
                    "github": SimpleNamespace(event_name=event, ref=f"refs/heads/{branch}"),
                    "inputs": SimpleNamespace(operation=operation),
                }
                selected = set()
                for job in ("release-pr", "select"):
                    condition = self.expression(self.jobs[job]["if"])
                    condition = condition.replace("&&", "and").replace("||", "or")
                    if eval(f"({condition})", {"__builtins__": {}}, context):
                        selected.add(job)
                self.assertEqual(selected, expected)

    def test_permissions_do_not_require_apple_secrets_or_environments(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn("environment", self.workflow)
        self.assertNotIn("secrets.", json.dumps(self.workflow))
        expected = {
            "release-pr": {"contents": "write", "pull-requests": "write"},
            "select": {"contents": "read"},
            "package": {"contents": "read"},
            "publish": {"contents": "write"},
        }
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertEqual(job.get("permissions", self.workflow["permissions"]), expected[name])
                self.assertNotIn("environment", job)
                for step in job["steps"]:
                    self.assertNotIn("environment", step)
        for name in ("release-pr", "publish"):
            self.assertEqual(self.jobs[name]["concurrency"]["cancel-in-progress"], "false")

    def test_all_changenote_operations_use_config_pin_on_ubuntu(self):
        config = json.loads((ROOT / ".changenote/config.json").read_text())
        pin = re.search(r"/changenote/([0-9a-f]{40})/schema\.json$", config["$schema"])
        self.assertIsNotNone(pin)
        expected_action = f"narumiruna/changenote/release@{pin.group(1)}"
        operations = []
        for name, job in self.jobs.items():
            for step in job["steps"]:
                if step.get("uses", "").startswith("narumiruna/changenote/"):
                    self.assertEqual(step["uses"], expected_action)
                    self.assertEqual(job["runs-on"], "ubuntu-latest")
                    self.assertEqual(step["with"]["base-branch"], "main")
                    operations.append((name, step["with"]["operation"]))
        self.assertCountEqual(
            operations,
            [("release-pr", "manage-pr"), ("select", "select"), ("publish", "publish")],
        )
        preparation = self.step("release-pr", "Check out main")
        self.assertEqual(preparation["with"]["ref"], "main")
        request = self.step("select", "Check release request")
        self.assertEqual(request["id"], "request")
        self.assertEqual(self.expression(request["env"]["BEFORE"]), "github.event.before")
        selection = self.operation("select", "select")
        self.assertEqual(selection["id"], "select")
        self.assertEqual(self.expression(selection["if"]), "steps.request.outputs.publish == 'true'")
        self.assertEqual(
            self.expression(selection["with"]["retry"]),
            "github.event_name == 'workflow_dispatch' && inputs.operation == 'retry-publication'",
        )
        guard = self.step("select", "Check automatic release selection")
        self.assertEqual(
            self.expression(guard["if"]),
            "github.event_name == 'push' && steps.select.outputs.release-commit != ''",
        )
        self.assertEqual(self.expression(guard["env"]["BEFORE"]), "github.event.before")
        self.assertEqual(self.expression(guard["env"]["RELEASE_COMMIT"]), "steps.select.outputs.release-commit")

    def test_build_and_publish_use_the_exact_selected_commit(self):
        selection = self.jobs["select"]
        for output in ("release-commit", "releases"):
            self.assertEqual(self.expression(selection["outputs"][output]), f"steps.select.outputs.{output}")
        checkout = self.step("select", "Check out triggering commit")["with"]
        self.assertEqual(checkout["fetch-depth"], "0")
        self.assertEqual(self.expression(checkout.get("ref", "github.sha")), "github.sha")
        package = self.jobs["package"]
        self.assertEqual(package["needs"], "select")
        self.assertEqual(self.expression(package["if"]), "needs.select.outputs.release-commit != ''")
        self.assertTrue(package["runs-on"].startswith("macos-"))
        for job in ("package", "publish"):
            checkout = self.step(job, "Check out release commit")["with"]
            self.assertEqual(self.expression(checkout["ref"]), "needs.select.outputs.release-commit")
            self.assertEqual(checkout["fetch-depth"], "0")
        publication = self.jobs["publish"]
        self.assertEqual(set(publication["needs"]), {"select", "package"})
        self.assertEqual(self.expression(publication.get("if", "success()")), "success()")
        self.assertNotEqual(package.get("continue-on-error"), "true")
        publish = self.operation("publish", "publish")
        self.assertEqual(
            self.expression(publish["with"]["expected-release-commit"]),
            "needs.select.outputs.release-commit",
        )
        verify = self.step("publish", "Verify downloaded package")
        self.assertEqual(verify["id"], "package")
        upload = self.step("publish", "Upload DMG and checksum")
        steps = publication["steps"]
        self.assertLess(steps.index(verify), steps.index(publish))
        self.assertLess(steps.index(publish), steps.index(upload))
        for step in (verify, publish, upload):
            self.assertNotEqual(step.get("continue-on-error"), "true")
            self.assertEqual(self.expression(step.get("if", "success()")), "success()")
        for job, name in (("package", "Build DMG"), ("publish", "Verify downloaded package")):
            self.assertEqual(
                self.expression(self.step(job, name)["env"]["RELEASES"]),
                "needs.select.outputs.releases",
            )
        build = self.step("package", "Build DMG")["run"]
        self.assertIn('./scripts/package-release.sh "$version"', build)

    def test_package_is_universal_ad_hoc_and_tests_skip_live_displays(self):
        package = (ROOT / "scripts/package-release.sh").read_text().replace("\\\n", "")
        commands = [
            shlex.split(line) for line in package.splitlines()
            if re.match(r"^\s*(?:xcodebuild|codesign)\s", line)
        ]
        build = next(command for command in commands if command[0] == "xcodebuild")
        for argument in ("ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO"):
            self.assertIn(argument, build)
        signing = next(command for command in commands if "--sign" in command)
        self.assertEqual(signing[signing.index("--sign") + 1], "-")
        self.assertIn("--timestamp=none", signing)
        self.assertEqual(signing[signing.index("--options") + 1], "runtime")
        self.assertIn("--entitlements", signing)
        tests = shlex.split(self.step("package", "Run unit tests without live displays")["run"].replace("\\\n", ""))
        for argument in ("xcodebuild", "test", "CODE_SIGNING_ALLOWED=NO", "RUN_VIRTUAL_DISPLAY_TESTS=0"):
            self.assertIn(argument, tests)
        self.assertNotIn("RUN_VIRTUAL_DISPLAY_TESTS=1", tests)
        script_tests = self.step("package", "Run release script tests")["run"]
        self.assertIn("uv run", script_tests)
        self.assertIn("scripts/tests/test_release.py", script_tests)

    def test_private_artifact_has_provenance_but_uploader_does_not_create_tags(self):
        retain = self.step("package", "Retain release package")["with"]
        self.assertEqual(
            set(retain["path"].splitlines()),
            {".release/*.dmg", ".release/*.dmg.sha256", ".release/*.dmg.commit"},
        )
        self.assertEqual(retain["include-hidden-files"], "true")
        self.assertEqual(retain["if-no-files-found"], "error")
        download = self.step("publish", "Download release package")["with"]
        self.assertEqual(download["name"], retain["name"])
        self.assertEqual(download["path"], ".release")
        upload = self.step("publish", "Upload DMG and checksum")
        self.assertEqual(self.expression(upload["env"]["VERSION"]), "steps.package.outputs.version")
        self.assertIn('./scripts/publish-release.sh "$VERSION"', upload["run"])
        self.assertIn('CONFIRM_PUBLISH="v$VERSION"', upload["run"])
        uploader = (ROOT / "scripts/publish-release.sh").read_text()
        self.assertNotRegex(uploader, r"\bgit\s+(?:tag|push)\b")
        self.assertNotRegex(uploader, r"\bgh\s+release\s+(?:create|edit)\b")
        self.assertNotIn("RELEASE_TAG_MODE", json.dumps(self.workflow))

    def test_release_request_only_selects_batch_changing_pushes_or_manual_retry(self):
        before = self.prepare_git()
        ordinary = self.commit_file("app.txt", "Ordinary change.\n")
        release = self.commit_file(BATCH, '[{"package":"display-loom","version":"1.2.3"}]\n')
        after = self.commit_file("README.md", "Documentation change.\n")
        reverted = self.commit_file(BATCH, "[]\n")
        cases = (
            ("ordinary push", "push", before, ordinary, "false"),
            ("batch push", "push", ordinary, release, "true"),
            ("multi-commit push", "push", before, after, "true"),
            ("unchanged batch", "push", release, after, "false"),
            ("reverted batch", "push", before, reverted, "false"),
            ("initial push", "push", "0" * 40, release, "false"),
            ("manual retry", "workflow_dispatch", "", after, "true"),
        )
        command = self.step("select", "Check release request")["run"]
        for name, event, previous, current, expected in cases:
            with self.subTest(request=name):
                self.output.unlink(missing_ok=True)
                self.environment.update(GITHUB_EVENT_NAME=event, BEFORE=previous, GITHUB_SHA=current)
                self.run_command("bash", "-c", command)
                self.assertEqual(self.output.read_text(), f"publish={expected}\n")
                self.assertFalse(self.remote_writes.exists())

    def test_release_request_fails_closed_on_invalid_diff_objects(self):
        current = self.prepare_git()
        command = self.step("select", "Check release request")["run"]
        for before, after in (("missing-before", current), (current, "f" * 40), ("", current)):
            with self.subTest(before=before, after=after):
                self.environment.update(GITHUB_EVENT_NAME="push", BEFORE=before, GITHUB_SHA=after)
                result = self.run_command("bash", "-c", command, check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assert_no_output_or_remote_writes()

    def test_automatic_selection_stays_inside_the_triggering_push_range(self):
        ancestor = self.prepare_git()
        before = self.commit_file("before.txt", "Before the push.\n")
        release = self.commit_file(BATCH, '[{"version":"1.2.3"}]\n')
        trigger = self.commit_file("after.txt", "End of the triggering push.\n")
        newer = self.commit_file(BATCH, '[{"version":"1.2.4"}]\n')
        self.run_command(GIT, "update-ref", "refs/remotes/origin/main", newer)
        self.run_command(GIT, "checkout", "--quiet", "-b", "side", before)
        divergent = self.commit_file("side.txt", "Not part of main.\n")
        self.run_command(GIT, "checkout", "--quiet", "main")
        command = self.step("select", "Check automatic release selection")["run"]
        cases = (
            ("release within push", before, release, trigger, True),
            ("release at push tip", before, release, release, True),
            ("unchanged release", before, before, trigger, False),
            ("older ancestor", before, ancestor, trigger, False),
            ("newer release on main", before, newer, trigger, False),
            ("divergent release", before, divergent, trigger, False),
            ("missing release", before, "f" * 40, trigger, False),
            ("invalid push base", "missing-before", release, trigger, False),
        )
        for name, previous, selected, current, valid in cases:
            with self.subTest(selection=name):
                self.environment.update(BEFORE=previous, RELEASE_COMMIT=selected, GITHUB_SHA=current)
                result = self.run_command("bash", "-c", command, check=False)
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                self.assert_no_output_or_remote_writes()

    def prepare_package(self):
        self.output.unlink(missing_ok=True)
        directory = self.root / ".release"
        directory.mkdir(exist_ok=True)
        artifact = directory / "Display-Loom-1.2.3.dmg"
        artifact.write_bytes(b"Fixture DMG; not an app or disk image.\n")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        artifact.with_suffix(".dmg.sha256").write_text(f"{digest}  {artifact.name}\n")
        head = self.run_command(GIT, "rev-parse", "HEAD").stdout.strip()
        artifact.with_suffix(".dmg.commit").write_text(f"{head}\n")
        self.environment["RELEASES"] = json.dumps([
            {"package": "other-package", "version": "9.9.9"},
            {"package": "display-loom", "version": "1.2.3"},
        ])
        return artifact

    def test_downloaded_package_verifies_checksum_and_head_before_output(self):
        self.prepare_git()
        self.prepare_package()
        self.environment["GITHUB_SHA"] = "f" * 40
        command = self.step("publish", "Verify downloaded package")["run"]
        self.run_command("bash", "-c", command)
        self.assertEqual(self.output.read_text(), "version=1.2.3\n")
        self.assertFalse(self.remote_writes.exists())

    def test_invalid_downloaded_package_stops_before_output_or_remote_writes(self):
        self.prepare_git()
        command = self.step("publish", "Verify downloaded package")["run"]
        cases = (
            "missing DMG", "missing checksum", "missing provenance", "mismatched provenance",
            "empty provenance", "empty checksum", "mismatched checksum", "corrupt DMG",
            "checksum for another file", "invalid version", "missing package",
        )
        for failure in cases:
            with self.subTest(package=failure):
                artifact = self.prepare_package()
                checksum = artifact.with_suffix(".dmg.sha256")
                provenance = artifact.with_suffix(".dmg.commit")
                if failure == "missing DMG":
                    artifact.unlink()
                elif failure == "missing checksum":
                    checksum.unlink()
                elif failure == "missing provenance":
                    provenance.unlink()
                elif failure == "mismatched provenance":
                    provenance.write_text(f"{'f' * 40}\n")
                elif failure == "empty provenance":
                    provenance.write_text("")
                elif failure == "empty checksum":
                    checksum.write_text("")
                elif failure == "mismatched checksum":
                    checksum.write_text(f"{'0' * 64}  {artifact.name}\n")
                elif failure == "corrupt DMG":
                    artifact.write_bytes(b"Corrupt DMG.\n")
                elif failure == "checksum for another file":
                    other = artifact.with_name("another.dmg")
                    other.write_bytes(artifact.read_bytes())
                    digest = hashlib.sha256(other.read_bytes()).hexdigest()
                    checksum.write_text(f"{digest}  {other.name}\n")
                    artifact.write_bytes(b"Corrupt DMG.\n")
                elif failure == "invalid version":
                    self.environment["RELEASES"] = '[{"package":"display-loom","version":"../bad"}]'
                elif failure == "missing package":
                    self.environment["RELEASES"] = '[]'
                result = self.run_command("bash", "-c", command, check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assert_no_output_or_remote_writes()


if __name__ == "__main__":
    for command in ("changenote", "xcodegen", "bash", "git", "jq", "shasum"):
        if shutil.which(command) is None:
            raise SystemExit(f"Required command not found: {command}")
    unittest.main(verbosity=2)
