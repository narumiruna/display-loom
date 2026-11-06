"""Run release scripts with command mocks in temporary checkouts.

PATH contains only mocks. No Git, signing, keychain, notarization, network, or
release command runs against the host. Bash only executes the copied scripts
and the workflow shell blocks under test.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
VERSION = "1.2.3"
COMMIT = "a" * 40
NEW_COMMIT = "b" * 40
RELEASE_NOTES = "Mock release notes\n"
MOCK_COMMANDS = (
    "awk", "base64", "cat", "changenote", "chmod", "codesign", "dirname", "ditto", "gh", "git",
    "grep", "lipo", "mkdir", "openssl", "plutil", "rm", "security", "shasum",
    "spctl", "xcodebuild", "xcrun",
)


def workflow_steps(job="release"):
    """Extract run/if values from named steps in the selected workflow job."""
    lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
    start = lines.index(f"  {job}:") + 1
    end = next(
        (index for index in range(start, len(lines))
         if lines[index].startswith("  ") and not lines[index].startswith("    ")),
        len(lines),
    )
    lines = lines[start:end]
    steps = {}
    current = None
    for index, line in enumerate(lines):
        if line.startswith("      - name: "):
            current = steps.setdefault(line.removeprefix("      - name: "), {})
        elif current is not None and line.startswith("        if: "):
            current["if"] = line.removeprefix("        if: ")
        elif current is not None and line.startswith("        run: "):
            value = line.removeprefix("        run: ")
            if value == "|":
                block = []
                for following in lines[index + 1:]:
                    if following and not following.startswith("          "):
                        break
                    block.append(following[10:])
                value = "\n".join(block) + "\n"
            current["run"] = value
    return steps


def mock_command():
    """Implement external commands without starting another process."""
    name = Path(sys.argv[0]).name
    args = sys.argv[1:]
    state_path = Path(os.environ["MOCK_STATE"])
    state = json.loads(state_path.read_text())
    with Path(os.environ["MOCK_LOG"]).open("a") as log:
        log.write(json.dumps([name, *args]) + "\n")

    def save():
        state_path.write_text(json.dumps(state))

    def fixture_path(value):
        path = Path(value).resolve()
        if not path.is_relative_to(Path(os.environ["MOCK_ROOT"]).resolve()):
            raise AssertionError(f"mock attempted access outside fixture: {path}")
        return path

    if name == "dirname":
        print(Path(args[0]).parent)
    elif name == "git":
        if args == ["branch", "--show-current"]:
            print("main")
        elif args == ["status", "--porcelain"]:
            if state.get("dirty"):
                print(" M source.swift")
        elif args == ["rev-parse", "HEAD"]:
            print(state["head"])
        elif args in (["rev-parse", "origin/main"], ["rev-parse", "refs/remotes/origin/main"]):
            print(state["origin"])
        elif args[:3] == ["rev-parse", "--quiet", "--verify"]:
            return 0 if state.get("local_tag") else 1
        elif args == ["fetch", "--quiet", "origin", "main", "--tags"]:
            if state.get("change_on_fetch"):
                state.update(head=NEW_COMMIT, origin=NEW_COMMIT)
                save()
        elif args[0] == "ls-remote":
            if state.get("remote_tag"):
                print(f"{state['remote_tag']}\trefs/tags/v{VERSION}^{{}}")
        elif args[:2] in (["tag", "-s"], ["tag", "-a"]):
            state["local_tag"] = args[-1]
            save()
        elif args == ["push", "origin", f"refs/tags/v{VERSION}"]:
            state["remote_tag"] = state["local_tag"]
            save()
        else:
            raise AssertionError(f"unexpected git arguments: {args}")
    elif name == "gh":
        if args[:2] == ["release", "view"]:
            if not state.get("release"):
                return 1
            print("2" if "assets" in args else "https://example.invalid/release")
        elif args[:2] == ["release", "create"]:
            state["release"] = True
            save()
        elif args[:2] != ["release", "edit"]:
            raise AssertionError(f"unexpected gh arguments: {args}")
    elif name == "awk":
        if args == ["{ print $1 }"]:
            print(sys.stdin.read().split()[0])
        elif args == [
            '$1 == "MARKETING_VERSION" && $2 == "=" { print $3; exit }',
            "Configuration/Version.xcconfig",
        ]:
            line = Path(args[1]).read_text().splitlines()[0]
            print(line.split("=", 1)[1].strip())
        elif args == ['-F"', '/CURRENT_PROJECT_VERSION:/ { print $2; exit }', "project.yml"]:
            line = next(
                line for line in Path("project.yml").read_text().splitlines()
                if "CURRENT_PROJECT_VERSION:" in line
            )
            print(line.split('"')[1])
        else:
            raise AssertionError(f"unexpected awk arguments: {args}")
    elif name == "changenote":
        if args != ["release-notes", "--package", "display-loom", "--version", VERSION]:
            raise AssertionError(f"unexpected changenote arguments: {args}")
        notes = Path("CHANGELOG.md").read_text().split(f"## {VERSION}\n\n", 1)[1]
        print(notes, end="")
    elif name == "shasum":
        if args[:3] == ["-a", "256", "-c"]:
            digest, filename = Path(args[3]).read_text().split()
            valid = hashlib.sha256(Path(filename).read_bytes()).hexdigest() == digest
            print(f"{filename}: {'OK' if valid else 'FAILED'}")
            return 0 if valid else 1
        if args[:2] != ["-a", "256"]:
            raise AssertionError(f"unexpected shasum arguments: {args}")
        print(f"{hashlib.sha256(Path(args[2]).read_bytes()).hexdigest()}  {args[2]}")
        if state.get("change_during_packaging") == "head":
            state["head"] = NEW_COMMIT
            save()
        elif state.get("change_during_packaging") == "source":
            state["dirty"] = True
            save()
    elif name == "security":
        if args[0] == "create-keychain":
            fixture_path(args[-1]).touch()
        elif args[0] == "delete-keychain":
            if state.get("fail_delete"):
                return 1
            fixture_path(args[-1]).unlink(missing_ok=True)
        elif state.get("fail_security") == args[0]:
            return 1
        elif args[0] == "find-identity":
            print('1) MOCK "Developer ID Application: Mock (A4YQL6FFTK)"')
        elif args[0] not in (
            "set-keychain-settings", "unlock-keychain", "import",
            "set-key-partition-list", "list-keychains", "default-keychain",
        ):
            raise AssertionError(f"unexpected security arguments: {args}")
    elif name == "xcodebuild":
        if "-exportArchive" in args:
            export = fixture_path(args[args.index("-exportPath") + 1])
            contents = export / "Display Loom.app/Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "MacOS/Display Loom").write_bytes(b"mock executable")
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": "7",
            }))
        elif args[-1] != "archive":
            raise AssertionError(f"unexpected xcodebuild arguments: {args}")
    elif name == "plutil":
        path = Path(args[-1])
        data = json.loads(path.read_text()) if path.suffix == ".json" else plistlib.loads(path.read_bytes())
        print(data[args[1]])
    elif name == "xcrun":
        if args[:2] == ["notarytool", "submit"]:
            print(json.dumps({"status": "Accepted"}))
        elif args[:2] not in (["notarytool", "history"], ["stapler", "staple"], ["stapler", "validate"]):
            raise AssertionError(f"unexpected xcrun arguments: {args}")
    elif name == "codesign":
        if args[0] == "--display":
            print("Authority=Developer ID Application: Mock\nTeamIdentifier=A4YQL6FFTK")
        elif args[0] != "--verify":
            raise AssertionError(f"unexpected codesign arguments: {args}")
    elif name == "lipo":
        print("arm64 x86_64")
    elif name == "ditto":
        fixture_path(args[-1]).write_bytes(b"mock ZIP contents\n")
    elif name == "spctl":
        pass
    elif name == "grep":
        if args[0] != "-F":
            raise AssertionError(f"unexpected grep arguments: {args}")
        matches = [line for line in sys.stdin.read().splitlines() if args[1] in line]
        if matches:
            print("\n".join(matches))
        return 0 if matches else 1
    elif name == "mkdir":
        fixture_path(args[-1]).mkdir(parents=True, exist_ok=True)
    elif name == "rm":
        for value in args:
            if value.startswith("-"):
                continue
            path = fixture_path(value)
            if path.is_dir():
                if not any("r" in arg for arg in args if arg.startswith("-")):
                    raise AssertionError("rm mock requires -r for directories")
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
    elif name == "openssl":
        if args != ["rand", "-hex", "32"]:
            raise AssertionError(f"unexpected openssl arguments: {args}")
        print("0" * 64)
    elif name == "base64":
        if args != ["--decode"]:
            raise AssertionError(f"unexpected base64 arguments: {args}")
        sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))
    elif name == "cat":
        if args:
            raise AssertionError(f"unexpected cat arguments: {args}")
        sys.stdout.write(sys.stdin.read())
    elif name == "chmod":
        fixture_path(args[1]).chmod(int(args[0], 8))
    else:
        raise AssertionError(f"unmocked command: {name}")
    return 0


class ReleaseFixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="display-loom-release-test-")
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        scripts = self.checkout / "scripts"
        scripts.mkdir(parents=True)
        for name in ("package-release.sh", "publish-release.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        configuration = self.checkout / "Configuration"
        configuration.mkdir()
        (configuration / "Version.xcconfig").write_text(f"MARKETING_VERSION = {VERSION}\n")
        (self.checkout / "project.yml").write_text('CURRENT_PROJECT_VERSION: "7"\n')
        (self.checkout / "CHANGELOG.md").write_text(f"# Changelog\n\n## {VERSION}\n\n{RELEASE_NOTES}")
        self.state_path = self.root / "state.json"
        self.state_path.write_text(json.dumps({"head": COMMIT, "origin": COMMIT}))
        self.log_path = self.root / "commands.jsonl"
        self.log_path.touch()
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        dispatcher = mock_bin / "mock-command"
        dispatcher.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            "sys.dont_write_bytecode = True\n"
            f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
            "from test_release import mock_command\n"
            "sys.exit(mock_command())\n"
        )
        dispatcher.chmod(0o755)
        for name in MOCK_COMMANDS:
            (mock_bin / name).symlink_to(dispatcher.name)
        runner_temp = self.root / "runner-temp"
        runner_temp.mkdir()
        github_env = self.root / "github-env"
        github_env.touch()
        self.env = {
            "PATH": str(mock_bin),
            "HOME": str(self.root),
            "MOCK_ROOT": str(self.root),
            "MOCK_STATE": str(self.state_path),
            "MOCK_LOG": str(self.log_path),
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_ENV": str(github_env),
            "DEVELOPMENT_TEAM": "A4YQL6FFTK",
            "CERTIFICATE_P12": base64.b64encode(b"mock certificate, not a PKCS#12 file").decode(),
            "CERTIFICATE_PASSWORD": "mock-password",
            "CONFIRM_PUBLISH": f"v{VERSION}",
        }
        self.artifact = self.checkout / f".release/Display-Loom-{VERSION}.zip"
        self.provenance = Path(f"{self.artifact}.commit")
        self.certificate = runner_temp / "developer-id-application.p12"
        self.keychain = runner_temp / "display-loom-signing.keychain-db"

    def update_state(self, **updates):
        state = json.loads(self.state_path.read_text())
        state.update(updates)
        self.state_path.write_text(json.dumps(state))

    def commands(self):
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]

    def run(self, *args, shell=None):
        command = [BASH, "-c", shell] if shell is not None else [BASH, *map(str, args)]
        return subprocess.run(
            command, cwd=self.checkout, env=self.env, text=True,
            capture_output=True, timeout=30,
        )

    def package(self):
        return self.run(self.checkout / "scripts/package-release.sh", VERSION)

    def publish(self):
        return self.run(self.checkout / "scripts/publish-release.sh", VERSION)

    def seed_artifact(self):
        self.artifact.parent.mkdir()
        self.artifact.write_bytes(b"mock completed release\n")
        digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        Path(f"{self.artifact}.sha256").write_text(f"{digest}  {self.artifact.name}\n")
        self.provenance.write_text(f"{COMMIT}\n")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ReleaseFixture()
        self.addCleanup(self.fixture.temp.cleanup)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_rejected_without_publication(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)
        for command in self.fixture.commands():
            self.assertNotIn(command[:2], (["git", "tag"], ["git", "push"]))
            self.assertNotEqual(command[0], "gh", f"rejection must precede GitHub access: {command}")
        state = json.loads(self.fixture.state_path.read_text())
        for key in ("local_tag", "remote_tag", "release"):
            self.assertNotIn(key, state)

    def test_matching_commit_packages_and_publishes_only_two_public_assets(self):
        self.assert_success(self.fixture.package())
        self.assertEqual(self.fixture.provenance.read_text(), f"{COMMIT}\n")
        self.assert_success(self.fixture.publish())
        commands = self.fixture.commands()
        self.assertIn(["git", "tag", "-s", f"v{VERSION}", "-m", f"Display Loom {VERSION}", COMMIT], commands)
        self.assertIn(["git", "push", "origin", f"refs/tags/v{VERSION}"], commands)
        create = next(command for command in commands if command[:3] == ["gh", "release", "create"])
        self.assertEqual(create[4:6], [str(self.fixture.artifact), f"{self.fixture.artifact}.sha256"])
        self.assertTrue(create[6].startswith("--"))
        self.assertNotIn(str(self.fixture.provenance), create)
        notes_path = self.fixture.checkout / ".release/release-notes.md"
        self.assertEqual(notes_path.read_text(), RELEASE_NOTES)
        self.assertEqual(create[create.index("--notes-file") + 1], str(notes_path))
        self.assertIn(
            ["changenote", "release-notes", "--package", "display-loom", "--version", VERSION],
            commands,
        )
        self.assertIn(["gh", "release", "edit", f"v{VERSION}", "--draft=false", "--latest"], commands)

    def test_workflow_validation_rejects_a_merge_commit_behind_main(self):
        self.fixture.env["GITHUB_REF"] = "refs/heads/main"
        self.fixture.update_state(origin=NEW_COMMIT)
        step = workflow_steps()["Validate release request"]
        self.assert_rejected_without_publication(
            self.fixture.run(shell=step["run"]),
            "Checked-out commit does not match origin/main",
        )
        self.assertEqual(Path(self.fixture.env["GITHUB_ENV"]).read_text(), "")

    def test_packaging_rejects_a_merge_commit_behind_main(self):
        self.fixture.update_state(origin=NEW_COMMIT)
        self.assert_rejected_without_publication(self.fixture.package(), "main must match origin/main")
        self.assertFalse(self.fixture.artifact.exists())

    def test_publication_rejects_a_merge_commit_behind_main(self):
        self.fixture.seed_artifact()
        self.fixture.update_state(origin=NEW_COMMIT)
        self.assert_rejected_without_publication(self.fixture.publish(), "main must match origin/main")

    def test_old_artifact_with_new_main_and_same_version_is_rejected(self):
        self.assert_success(self.fixture.package())
        self.fixture.update_state(head=NEW_COMMIT, origin=NEW_COMMIT)
        self.assert_rejected_without_publication(self.fixture.publish(), "not packaged from HEAD")

    def test_missing_provenance_is_rejected(self):
        self.fixture.seed_artifact()
        self.fixture.provenance.unlink()
        self.assert_rejected_without_publication(self.fixture.publish(), "commit provenance not found")

    def test_empty_provenance_is_rejected(self):
        self.fixture.seed_artifact()
        self.fixture.provenance.write_text("")
        self.assert_rejected_without_publication(self.fixture.publish(), "not packaged from HEAD")

    def test_checksum_mismatch_is_rejected(self):
        self.fixture.seed_artifact()
        self.fixture.artifact.write_bytes(b"changed after packaging\n")
        self.assert_rejected_without_publication(self.fixture.publish(), "FAILED")

    def test_head_change_during_publish_fetch_is_rejected(self):
        self.fixture.seed_artifact()
        self.fixture.update_state(change_on_fetch=True)
        self.assert_rejected_without_publication(self.fixture.publish(), "HEAD changed during publication")

    def test_head_change_during_packaging_does_not_record_provenance(self):
        self.fixture.update_state(change_during_packaging="head")
        result = self.fixture.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HEAD changed during packaging", result.stderr)
        self.assertTrue(self.fixture.artifact.exists())
        self.assertFalse(self.fixture.provenance.exists())

    def test_source_change_during_packaging_removes_old_provenance(self):
        self.assert_success(self.fixture.package())
        self.fixture.update_state(change_during_packaging="source")
        result = self.fixture.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("working tree changed during packaging", result.stderr)
        self.assertTrue(self.fixture.artifact.exists())
        self.assertFalse(self.fixture.provenance.exists())

    def check_credential_cleanup(self, failure=None, fail_delete=False):
        self.fixture.update_state(fail_security=failure, fail_delete=fail_delete)
        steps = workflow_steps()
        result = self.fixture.run(shell=steps["Import Developer ID certificate"]["run"])
        if failure:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(Path(self.fixture.env["GITHUB_ENV"]).read_text(), "")
        else:
            self.assert_success(result)
            exported = dict(
                line.split("=", 1) for line in Path(self.fixture.env["GITHUB_ENV"]).read_text().splitlines()
            )
            self.assertEqual(exported["RELEASE_KEYCHAIN_PATH"], str(self.fixture.keychain))
            self.fixture.env.update(exported)
        self.assertTrue(self.fixture.certificate.is_file())
        self.assertTrue(self.fixture.keychain.is_file())
        self.fixture.log_path.write_text("")
        cleanup = steps["Delete temporary credentials"]
        self.assertEqual(cleanup["if"], "always()")
        self.assert_success(self.fixture.run(shell=cleanup["run"]))
        self.assertIn(["security", "delete-keychain", str(self.fixture.keychain)], self.fixture.commands())
        self.assertIn(["rm", "-f", str(self.fixture.certificate), str(self.fixture.keychain)], self.fixture.commands())
        self.assertFalse(self.fixture.certificate.exists())
        self.assertFalse(self.fixture.keychain.exists())

    def test_workflow_cleanup_after_import_failure_before_env_export(self):
        self.check_credential_cleanup(failure="import")

    def test_workflow_cleanup_after_identity_failure_before_env_export(self):
        self.check_credential_cleanup(failure="find-identity")

    def test_workflow_cleanup_after_success(self):
        self.check_credential_cleanup()

    def test_workflow_cleanup_removes_files_when_keychain_delete_fails(self):
        self.check_credential_cleanup(failure="import", fail_delete=True)

    def test_shell_syntax(self):
        for name in ("package-release.sh", "publish-release.sh"):
            with self.subTest(script=name):
                self.assert_success(self.fixture.run("-n", self.fixture.checkout / "scripts" / name))
        for job in ("release-pr", "release"):
            for name, step in workflow_steps(job).items():
                if "run" in step:
                    with self.subTest(workflow_job=job, workflow_step=name):
                        self.assert_success(self.fixture.run("-n", "-c", step["run"]))


if __name__ == "__main__":
    unittest.main()
