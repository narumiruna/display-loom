"""Test release versioning and publication without remote writes or signing."""

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


class ChangenoteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="display-loom-release-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        for directory in ("Configuration", "DisplayLoom.xcodeproj"):
            shutil.copytree(ROOT / directory, self.root / directory)
        for filename in (
            ".changenote/config.json",
            "CHANGELOG.md",
            "project.yml",
            "scripts/publish-release.sh",
        ):
            destination = self.root / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / filename, destination)
        self.version_file = self.root / "Configuration/Version.xcconfig"
        self.version = self.version_file.read_text().split("=", 1)[1].strip()
        major, minor, patch = map(int, self.version.split("."))
        self.next_version = f"{major}.{minor}.{patch + 1}"
        self.environment = os.environ.copy()

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
        batch = json.loads((self.root / ".changenote/releases.json").read_text())
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

    def prepare_publication(self):
        release = self.root / ".release"
        release.mkdir()
        artifact = release / f"Display-Loom-{self.version}.zip"
        artifact.write_bytes(b"Test artifact; not a signed app.\n")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        artifact.with_suffix(".zip.sha256").write_text(f"{digest}  {artifact.name}\n")
        commands = self.root / "mock-bin"
        commands.mkdir()
        log = shlex.quote(str(self.root / "remote-writes.log"))
        arguments = shlex.quote(str(self.root / "release-arguments.txt"))
        commit = "1" * 40
        artifact.with_suffix(".zip.commit").write_text(f"{commit}\n")
        git = commands / "git"
        git.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  branch) echo main ;;
  status|fetch) ;;
  rev-parse)
    if [[ "$2" == HEAD || "$2" == origin/main || "$2" == refs/remotes/origin/main ]]; then
      echo {commit}
    else
      exit 1
    fi ;;
  ls-remote)
    if [[ "$2" == origin ]]; then
      printf '%s\\t%s\\n' {commit} "$3"
    fi ;;
  tag|push) printf 'git %s\\n' "$*" >>{log} ;;
  *) echo "Unexpected Git command: $*" >&2; exit 99 ;;
esac
""")
        gh = commands / "gh"
        gh.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'release view')
    case "${{*:4}}" in
      '--json assets --jq .assets | length') echo 2 ;;
      '--json url --jq .url') echo https://example.invalid/release ;;
      '') exit 1 ;;
      *) echo "Unexpected release view: $*" >&2; exit 99 ;;
    esac ;;
  'release create')
    printf '%s\\n' "$@" >{arguments}
    printf 'gh release create\\n' >>{log} ;;
  'release edit') printf 'gh release edit\\n' >>{log} ;;
  *) echo "Unexpected GitHub command: $*" >&2; exit 99 ;;
esac
""")
        git.chmod(0o755)
        gh.chmod(0o755)
        self.environment.update(
            PATH=f"{commands}{os.pathsep}{os.environ['PATH']}",
            CONFIRM_PUBLISH=f"v{self.version}",
            RELEASE_TAG_MODE="annotated",
        )

    def test_release_workflow_routes_pr_preparation_and_publication_separately(self):
        workflow = yaml.load(
            (ROOT / ".github/workflows/release.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        self.assertEqual(set(workflow["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(workflow["on"]["push"]["branches"], ["main"])
        self.assertEqual(workflow["on"]["workflow_dispatch"], "")
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertNotIn("concurrency", workflow)
        self.assertEqual(set(workflow["jobs"]), {"release-pr", "release"})
        preparation = workflow["jobs"]["release-pr"]
        publication = workflow["jobs"]["release"]
        self.assertEqual(
            preparation["if"],
            "github.event_name == 'push' && github.ref == 'refs/heads/main'",
        )
        self.assertEqual(
            publication["if"],
            "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'",
        )
        self.assertEqual(
            preparation["permissions"],
            {"contents": "write", "pull-requests": "write"},
        )
        self.assertEqual(publication["permissions"], {"contents": "write"})
        self.assertNotIn("environment", preparation)
        self.assertEqual(publication["environment"], "release")
        self.assertEqual(
            preparation["concurrency"],
            {"group": "changenote-release-main", "cancel-in-progress": "false"},
        )
        self.assertEqual(
            publication["concurrency"],
            {"group": "release", "cancel-in-progress": "false"},
        )
        self.assertEqual(preparation["steps"][-1]["with"]["operation"], "manage-pr")
        self.assertNotIn("needs", publication)
        self.assertFalse((ROOT / ".github/workflows/changenote.yml").exists())

    def test_release_workflow_reads_the_bumped_version_without_input(self):
        self.prepare_publication()
        self.add_note()
        self.run_command("changenote", "version")
        workflow = yaml.load(
            (ROOT / ".github/workflows/release.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        self.assertEqual(workflow["on"]["workflow_dispatch"], "")
        command = next(
            step["run"]
            for step in workflow["jobs"]["release"]["steps"]
            if step.get("name") == "Validate release request"
        )
        environment_file = self.root / "github-env"
        self.environment.update(
            GITHUB_REF="refs/heads/main",
            GITHUB_ENV=str(environment_file),
        )
        self.run_command("bash", "-c", command)
        self.assertEqual(
            environment_file.read_text(),
            f"VERSION={self.next_version}\n",
        )
        self.assertFalse((self.root / "remote-writes.log").exists())

    def test_publication_uses_the_requested_changelog_entry(self):
        self.prepare_publication()
        expected = self.run_command(
            "changenote",
            "release-notes",
            "--package",
            "display-loom",
            "--version",
            self.version,
        ).stdout
        self.run_command("bash", "scripts/publish-release.sh", self.version)
        notes_path = self.root / ".release/release-notes.md"
        self.assertEqual(notes_path.read_text(), expected)
        arguments = (self.root / "release-arguments.txt").read_text().splitlines()
        self.assertEqual(
            arguments[arguments.index("--notes-file") + 1], str(notes_path)
        )
        self.assertIn("gh release edit", (self.root / "remote-writes.log").read_text())

    def test_invalid_release_notes_stop_before_remote_writes(self):
        self.prepare_publication()
        for content in (
            "# Changelog\n",
            f"# Changelog\n\n## {self.version}\n",
            f"## {self.version}\n\nFirst.\n\n## {self.version}\n\nDuplicate.\n",
        ):
            with self.subTest(changelog=content):
                (self.root / "CHANGELOG.md").write_text(content)
                result = self.run_command(
                    "bash",
                    "scripts/publish-release.sh",
                    self.version,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "remote-writes.log").exists())

    def test_version_mismatch_stops_before_remote_writes(self):
        self.prepare_publication()
        self.environment["CONFIRM_PUBLISH"] = f"v{self.next_version}"
        result = self.run_command(
            "bash",
            "scripts/publish-release.sh",
            self.next_version,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"project version is {self.version}", result.stderr)
        self.assertFalse((self.root / "remote-writes.log").exists())


if __name__ == "__main__":
    for command in ("changenote", "xcodegen", "bash", "shasum"):
        if shutil.which(command) is None:
            raise SystemExit(f"Required command not found: {command}")
    unittest.main(verbosity=2)
