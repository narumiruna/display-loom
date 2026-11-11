"""Test release scripts with PATH-only mocks in temporary checkouts.

Only Bash and the Python mock dispatcher run as host processes. The mocks do
not start Git, GitHub, Xcode, signing, keychain, display, or network commands.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
VERSION = "1.2.3"
COMMIT = "a" * 40
NEW_COMMIT = "b" * 40
MOCK_COMMANDS = (
    "awk", "cmp", "codesign", "dirname", "ditto", "gh", "git", "hdiutil",
    "jq", "lipo", "ln", "mkdir", "mktemp", "plutil", "rm", "shasum", "xcodebuild",
)


def workflow_run_steps(job):
    """Read shell blocks without executing workflow expressions or actions."""
    lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
    start = lines.index(f"  {job}:") + 1
    end = next(
        (index for index in range(start, len(lines))
         if lines[index].strip() and lines[index].startswith("  ")
         and not lines[index].startswith("    ")),
        len(lines),
    )
    steps = []
    name = job
    for index in range(start, end):
        line = lines[index]
        if line.startswith("      - name: "):
            name = line.removeprefix("      - name: ")
        elif line.startswith("        run: "):
            value = line.removeprefix("        run: ")
            if value in ("|", "|-", ">", ">-"):
                block = []
                for following in lines[index + 1:end]:
                    if following.strip() and not following.startswith("          "):
                        break
                    block.append(following[10:])
                value = "\n".join(block) + "\n"
            steps.append((name, value))
    return steps


def mock_command():
    """Implement each command in Python; reject unsupported command calls."""
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

    def fail(message):
        print(message, file=sys.stderr)
        return 1

    def option(flag):
        return args[args.index(flag) + 1]

    if name == "dirname":
        print(Path(args[0]).parent)
    elif name == "git":
        if args == ["branch", "--show-current"]:
            print(state.get("branch", "main"))
        elif args == ["status", "--porcelain"]:
            if state.get("dirty"):
                print(" M source.swift")
        elif args == ["rev-parse", "HEAD"]:
            print(state["head"])
        elif args in (["rev-parse", "origin/main"], ["rev-parse", "refs/remotes/origin/main"]):
            print(state["origin"])
        elif args[:2] == ["merge-base", "--is-ancestor"]:
            assert args[2] == state["head"], args
            assert args[3] in ("origin/main", "refs/remotes/origin/main"), args
            return 0 if state.get("ancestor", True) else 1
        elif args[:4] == ["fetch", "--quiet", "origin", "main"]:
            assert args[4:] in ([], ["--tags"]), args
            if state.get("fetch_error"):
                return fail("mock fetch failed")
            if state.get("change_on_fetch"):
                state["head"] = NEW_COMMIT
            if state.get("dirty_on_fetch"):
                state["dirty"] = True
            save()
        elif args[:3] == ["ls-remote", "--tags", "origin"]:
            tag = f"refs/tags/v{state['version']}"
            assert args[3:] == [tag, f"{tag}^{{}}"], args
            if state.get("tag_query_error"):
                return fail("mock tag lookup failed")
            commit = state.get("remote_tag")
            if commit:
                if state.get("lightweight_tag"):
                    print(f"{commit}\t{tag}")
                else:
                    print(f"{'c' * 40}\t{tag}\n{commit}\t{tag}^{{}}")
        else:
            raise AssertionError(f"unexpected or write-capable git arguments: {args}")
    elif name == "gh":
        assert args[:1] == ["release"], args
        assert args[2] == f"v{state['version']}", args
        if args[1] == "view":
            if state.get("view_error") or not state.get("release", True):
                return fail(state.get("view_error", "HTTP 404: release not found"))
            assert args[3:] == ["--json", "isDraft,assets,url"], args
            if "release_response" in state:
                print(state["release_response"])
            else:
                assets = state.get("assets", [])
                if isinstance(assets, list):
                    assets = [
                        {key: value for key, value in asset.items() if key != "content"}
                        for asset in assets
                    ]
                print(json.dumps({
                    "isDraft": state.get("draft", False),
                    "assets": assets,
                    "url": "https://example.invalid/release",
                }))
        elif args[1] == "download":
            assert len(args) == 7 and args[3] == "--pattern" and args[5] == "--dir", args
            if state.get("download_error"):
                return fail("mock download failed")
            asset = next(asset for asset in state["assets"] if asset["name"] == args[4])
            fixture_path(Path(args[6]) / asset["name"]).write_bytes(base64.b64decode(asset["content"]))
        elif args[1] == "upload":
            assert len(args) > 3 and all(not arg.startswith("--") for arg in args[3:]), args
            for index, value in enumerate(args[3:]):
                if state.get("upload_fail_after") == index:
                    save()
                    return fail("mock upload interrupted; retry with the same files")
                path = fixture_path(value)
                assert path.name not in [asset["name"] for asset in state["assets"]], args
                content = path.read_bytes()
                state["assets"].append({
                    "name": path.name, "content": base64.b64encode(content).decode(), "size": len(content),
                })
            save()
        else:
            raise AssertionError(f"unexpected release write: {args}")
    elif name == "jq":
        variables = {}
        flags = []
        while args and args[0].startswith("-"):
            flag = args.pop(0)
            if flag == "--arg":
                key, value = args[:2]
                del args[:2]
                variables[key] = value
            else:
                assert flag in ("-e", "-r"), flag
                flags.append(flag)
        assert len(args) == 1, args
        program = " ".join(args[0].split())
        try:
            data = json.load(sys.stdin)
        except ValueError:
            return fail("mock jq: invalid JSON")
        if program == ".isDraft == false":
            value = data.get("isDraft") is False
        elif program == (
            '(.assets | type == "array") and '
            'all(.assets[]; .name == $artifact or .name == $checksum) and '
            '(([.assets[].name] | unique | length) == (.assets | length))'
        ):
            assets = data.get("assets")
            names = [asset.get("name") for asset in assets] if isinstance(assets, list) else []
            value = (
                isinstance(assets, list)
                and all(name in (variables["artifact"], variables["checksum"]) for name in names)
                and len(set(names)) == len(names)
            )
        elif program == "any(.assets[]; .name == $name)":
            value = any(asset.get("name") == variables["name"] for asset in data["assets"])
        elif program == ".isDraft == false and (.assets | length == 2)":
            value = data.get("isDraft") is False and len(data["assets"]) == 2
        elif program == ".url":
            value = data["url"]
        else:
            raise AssertionError(f"unexpected jq program: {program}")
        print(value if "-r" in flags and isinstance(value, str) else json.dumps(value))
        return 1 if "-e" in flags and value in (False, None) else 0
    elif name == "awk":
        if args == [
            '$1 == "MARKETING_VERSION" && $2 == "=" { print $3; exit }',
            "Configuration/Version.xcconfig",
        ]:
            for line in fixture_path(args[-1]).read_text().splitlines():
                if line.split()[:2] == ["MARKETING_VERSION", "="]:
                    print(line.split()[2])
                    break
        elif args == ['-F"', '/CURRENT_PROJECT_VERSION:/ { print $2; exit }', "project.yml"]:
            for line in fixture_path(args[-1]).read_text().splitlines():
                if "CURRENT_PROJECT_VERSION:" in line:
                    print(line.split('"')[1])
                    break
        else:
            raise AssertionError(f"unexpected awk arguments: {args}")
    elif name == "shasum":
        assert args[:2] == ["-a", "256"], args
        if state.get("fail_checksum"):
            return fail("mock checksum failed")
        assert len(args) == 3, args
        print(f"{hashlib.sha256(fixture_path(args[2]).read_bytes()).hexdigest()}  {args[2]}")
        if state.get("change_during_packaging") == "head":
            state["head"] = NEW_COMMIT
        elif state.get("change_during_packaging") == "source":
            state["dirty"] = True
        save()
    elif name == "xcodebuild":
        assert args[-1] == "build" and "-exportArchive" not in args and "-archivePath" not in args, args
        state["clean_at_build"] = not (Path(".release") / "stale.txt").exists()
        save()
        if state.get("fail_build"):
            return fail("mock build failed")
        if not state.get("missing_app"):
            contents = fixture_path(option("-derivedDataPath")) / "Build/Products/Release/Display Loom.app/Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "MacOS/Display Loom").write_bytes(b"mock executable")
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": state.get("bundle_version", state["version"]),
                "CFBundleVersion": state.get("bundle_build", "7"),
            }))
    elif name == "plutil":
        assert args[0] == "-extract" and args[2] == "raw", args
        print(plistlib.loads(fixture_path(args[-1]).read_bytes())[args[1]])
    elif name == "codesign":
        fixture_path(args[-1])
        if args[0] == "--force":
            assert option("--sign") == "-", args
            assert "--timestamp=none" in args, args
            fixture_path(option("--entitlements"))
            if state.get("fail_sign"):
                return fail("mock ad-hoc signing failed")
        elif args[0] == "--verify":
            if state.get("fail_signature"):
                return fail("mock signature verification failed")
        else:
            raise AssertionError(f"unexpected codesign arguments: {args}")
    elif name == "lipo":
        assert args[0] == "-archs", args
        fixture_path(args[-1])
        print(state.get("architectures", "arm64 x86_64"))
    elif name == "ditto":
        assert len(args) == 2, args
        if state.get("fail_copy"):
            return fail("mock copy failed")
        shutil.copytree(fixture_path(args[0]), fixture_path(args[1]), dirs_exist_ok=True)
    elif name == "hdiutil":
        assert args[0] in ("create", "verify"), args
        null_input = stat.S_ISCHR(os.fstat(0).st_mode) and os.fstat(0).st_rdev == os.stat(os.devnull).st_rdev
        state[f"{args[0]}_stdin_null"] = null_input
        save()
        if state.get(f"fail_dmg_{args[0]}"):
            return fail(f"mock DMG {args[0]} failed")
        if args[0] == "create":
            staging = fixture_path(option("-srcfolder"))
            state["staged_app"] = (staging / "Display Loom.app/Contents/Info.plist").is_file()
            state["applications_target"] = os.readlink(staging / "Applications")
            save()
            fixture_path(args[-1]).write_bytes(b"mock DMG contents\n")
        else:
            assert fixture_path(args[-1]).is_file(), args
    elif name == "ln":
        assert args[:2] == ["-s", "/Applications"], args
        fixture_path(args[-1]).symlink_to(args[1], target_is_directory=True)
    elif name == "mkdir":
        assert args[0] == "-p", args
        for value in args[1:]:
            fixture_path(value).mkdir(parents=True, exist_ok=True)
    elif name == "rm":
        for value in args:
            if value.startswith("-"):
                continue
            path = fixture_path(value)
            if path.is_dir():
                assert any("r" in arg for arg in args if arg.startswith("-")), args
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
    elif name == "cmp":
        assert args[0] == "-s" and len(args) == 3, args
        first = sys.stdin.buffer.read() if args[1] == "-" else fixture_path(args[1]).read_bytes()
        try:
            second = fixture_path(args[2]).read_bytes()
        except FileNotFoundError:
            return 2
        return 0 if first == second else 1
    elif name == "mktemp":
        assert args[0] == "-d" and len(args) == 2, args
        template = fixture_path(args[1])
        assert template.name.endswith("XXXXXX"), args
        print(tempfile.mkdtemp(prefix=template.name[:-6], dir=template.parent))
    else:
        raise AssertionError(f"unmocked command: {name}")
    return 0


class ReleaseFixture:
    def __init__(self, version=VERSION):
        self.temp = tempfile.TemporaryDirectory(prefix="display-loom-release-test-")
        self.root = Path(self.temp.name).resolve()
        self.checkout = self.root / "checkout"
        scripts = self.checkout / "scripts"
        scripts.mkdir(parents=True)
        for name in ("package-release.sh", "publish-release.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        configuration = self.checkout / "Configuration"
        configuration.mkdir()
        (configuration / "Version.xcconfig").write_text(f"MARKETING_VERSION = {version}\n")
        (self.checkout / "project.yml").write_text('CURRENT_PROJECT_VERSION: "7"\n')
        resources = self.checkout / "DisplayLoom/Resources"
        resources.mkdir(parents=True)
        (resources / "DisplayLoom.entitlements").write_bytes(plistlib.dumps({}))
        self.state_path = self.root / "state.json"
        self.state_path.write_text(json.dumps({
            "head": COMMIT, "origin": COMMIT, "version": version,
            "remote_tag": COMMIT, "release": True, "assets": [],
        }))
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
        self.env = {
            "PATH": str(mock_bin), "HOME": str(self.root),
            "MOCK_ROOT": str(self.root), "MOCK_STATE": str(self.state_path),
            "MOCK_LOG": str(self.log_path), "CONFIRM_PUBLISH": f"v{version}",
        }
        self.version = version
        self.artifact = self.checkout / f".release/Display-Loom-{version}.dmg"
        self.checksum = Path(f"{self.artifact}.sha256")
        self.provenance = Path(f"{self.artifact}.commit")

    def state(self):
        return json.loads(self.state_path.read_text())

    def update_state(self, **updates):
        state = self.state()
        state.update(updates)
        self.state_path.write_text(json.dumps(state))

    def commands(self):
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]

    def clear_log(self):
        self.log_path.write_text("")

    def run(self, *args):
        return subprocess.run(
            [BASH, *map(str, args)], cwd=self.checkout, env=self.env,
            text=True, input="", capture_output=True, timeout=30,
        )

    def package(self, *versions):
        return self.run(self.checkout / "scripts/package-release.sh", *(versions or (self.version,)))

    def publish(self, *versions):
        return self.run(self.checkout / "scripts/publish-release.sh", *(versions or (self.version,)))

    def seed_artifact(self):
        self.artifact.parent.mkdir(exist_ok=True)
        self.artifact.write_bytes(b"mock completed release\n")
        digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.checksum.write_text(f"{digest}  {self.artifact.name}\n")
        self.provenance.write_text(f"{COMMIT}\n")

    def seed_remote_assets(self, *paths):
        self.update_state(assets=[{
            "name": path.name, "content": base64.b64encode(path.read_bytes()).decode(),
            "size": path.stat().st_size,
        } for path in paths])


class ReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.fixture = self.new_fixture()

    def new_fixture(self, version=VERSION):
        fixture = ReleaseFixture(version)
        self.addCleanup(fixture.temp.cleanup)
        return fixture

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_failure(self, result, message=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if message:
            self.assertIn(message, result.stdout + result.stderr)

    def assert_no_remote_access(self, fixture=None):
        for command in (fixture or self.fixture).commands():
            self.assertNotEqual(command[0], "gh", command)
            self.assertNotIn(command[:2], (["git", "fetch"], ["git", "ls-remote"]), command)
        self.assert_no_remote_writes(fixture)

    def assert_no_remote_writes(self, fixture=None):
        for command in (fixture or self.fixture).commands():
            self.assertNotIn(command[:2], (["git", "tag"], ["git", "push"], ["git", "config"]), command)
            if command[0] == "gh":
                self.assertIn(command[1:3], (["release", "view"], ["release", "download"]), command)

    def assert_package_rejected(self, **updates):
        self.fixture.update_state(**updates)
        self.assert_failure(self.fixture.package())
        self.assert_no_remote_access()
        self.assertFalse(self.fixture.provenance.exists())


class PackageTests(ReleaseTestCase):
    def test_universal_ad_hoc_dmg_and_sidecars(self):
        self.assert_success(self.fixture.package())
        self.assertEqual(self.fixture.provenance.read_text(), f"{COMMIT}\n")
        digest = hashlib.sha256(self.fixture.artifact.read_bytes()).hexdigest()
        self.assertEqual(self.fixture.checksum.read_text(), f"{digest}  {self.fixture.artifact.name}\n")
        app = self.fixture.checkout / ".release/build/Build/Products/Release/Display Loom.app"
        staging = self.fixture.checkout / ".release/dmg-root"
        self.assertTrue(self.fixture.state()["staged_app"])
        self.assertEqual(self.fixture.state()["applications_target"], "/Applications")
        commands = self.fixture.commands()
        build = next(command for command in commands if command[0] == "xcodebuild")
        self.assertEqual(build[-1], "build")
        for flag, value in (
            ("-configuration", "Release"), ("-destination", "generic/platform=macOS"),
        ):
            self.assertEqual(build[build.index(flag) + 1], value)
        derived = Path(build[build.index("-derivedDataPath") + 1])
        self.assertEqual((self.fixture.checkout / derived).resolve(), self.fixture.checkout / ".release/build")
        for setting in ("ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO"):
            self.assertIn(setting, build)
        for argument in ("archive", "-exportArchive", "-archivePath"):
            self.assertNotIn(argument, build)
        sign = next(command for command in commands if command[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], "-")
        self.assertIn("--timestamp=none", sign)
        self.assertEqual(sign[sign.index("--options") + 1], "runtime")
        entitlements = Path(sign[sign.index("--entitlements") + 1])
        self.assertEqual((self.fixture.checkout / entitlements).resolve(), self.fixture.checkout / "DisplayLoom/Resources/DisplayLoom.entitlements")
        self.assertEqual((self.fixture.checkout / sign[-1]).resolve(), app)
        self.assertTrue(any(command[:2] == ["codesign", "--verify"] for command in commands))
        create = next(command for command in commands if command[:2] == ["hdiutil", "create"])
        for flag, value in (("-volname", "Display Loom"), ("-format", "UDZO")):
            self.assertEqual(create[create.index(flag) + 1], value)
        self.assertIn("-quiet", create)
        self.assertIn("-ov", create)
        self.assertEqual((self.fixture.checkout / create[create.index("-srcfolder") + 1]).resolve(), staging)
        self.assertEqual((self.fixture.checkout / create[-1]).resolve(), self.fixture.artifact)
        verify = next(command for command in commands if command[:2] == ["hdiutil", "verify"])
        self.assertEqual((self.fixture.checkout / verify[-1]).resolve(), self.fixture.artifact)
        self.assertTrue(self.fixture.state()["create_stdin_null"])
        self.assertTrue(self.fixture.state()["verify_stdin_null"])
        self.assert_no_remote_access()

    def test_release_directory_is_recreated_before_build(self):
        self.fixture.seed_artifact()
        (self.fixture.artifact.parent / "stale.txt").write_text("old build")
        self.assert_success(self.fixture.package())
        self.assertTrue(self.fixture.state()["clean_at_build"])
        self.assertFalse((self.fixture.artifact.parent / "stale.txt").exists())

    def test_historical_commit_and_detached_head_are_allowed(self):
        self.fixture.update_state(origin=NEW_COMMIT, branch="")
        self.assert_success(self.fixture.package())
        self.assertTrue(any(command[:3] == ["git", "merge-base", "--is-ancestor"] for command in self.fixture.commands()))

    def test_rejects_dirty_source(self):
        self.assert_package_rejected(dirty=True)

    def test_rejects_wrong_branch(self):
        self.assert_package_rejected(branch="feature")

    def test_rejects_commit_outside_main_ancestry(self):
        self.assert_package_rejected(ancestor=False)
        self.assertFalse(self.fixture.artifact.exists())

    def test_rejects_project_version_mismatch(self):
        (self.fixture.checkout / "Configuration/Version.xcconfig").write_text("MARKETING_VERSION = 9.9.9\n")
        self.assert_package_rejected()
        self.assertFalse(self.fixture.artifact.exists())

    def test_rejects_missing_project_build_number(self):
        (self.fixture.checkout / "project.yml").write_text("name: DisplayLoom\n")
        self.assert_package_rejected()

    def test_rejects_missing_app(self):
        self.assert_package_rejected(missing_app=True)

    def test_rejects_bundle_version_mismatch(self):
        self.assert_package_rejected(bundle_version="9.9.9")

    def test_rejects_bundle_build_mismatch(self):
        self.assert_package_rejected(bundle_build="8")

    def test_rejects_nonuniversal_executable(self):
        for architectures in ("arm64", "x86_64", "", "arm64e x86_64"):
            with self.subTest(architectures=architectures):
                fixture = self.new_fixture()
                fixture.update_state(architectures=architectures)
                self.assert_failure(fixture.package())
                self.assertFalse(fixture.provenance.exists())
                self.assert_no_remote_access(fixture)

    def test_packaging_failures_do_not_record_provenance(self):
        for failure in ("fail_build", "fail_sign", "fail_signature", "fail_copy", "fail_dmg_create", "fail_dmg_verify", "fail_checksum"):
            with self.subTest(failure=failure):
                fixture = self.new_fixture()
                fixture.seed_artifact()
                fixture.update_state(**{failure: True})
                self.assert_failure(fixture.package())
                self.assertFalse(fixture.provenance.exists())
                self.assert_no_remote_access(fixture)

    def test_head_change_during_packaging_does_not_record_provenance(self):
        self.assert_package_rejected(change_during_packaging="head")
        self.assertTrue(self.fixture.artifact.exists())

    def test_source_change_during_packaging_removes_old_provenance(self):
        self.fixture.seed_artifact()
        self.assert_package_rejected(change_during_packaging="source")
        self.assertTrue(self.fixture.artifact.exists())


class PublishTests(ReleaseTestCase):
    def setUp(self):
        super().setUp()
        self.fixture.seed_artifact()

    def uploads(self, fixture=None):
        return [command for command in (fixture or self.fixture).commands() if command[:3] == ["gh", "release", "upload"]]

    def test_uploads_only_dmg_and_checksum_to_existing_release(self):
        self.assert_success(self.fixture.publish())
        uploads = self.uploads()
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0][3], f"v{VERSION}")
        self.assertEqual(set(uploads[0][4:]), {str(self.fixture.artifact), str(self.fixture.checksum)})
        self.assertNotIn("--clobber", uploads[0])
        self.assertEqual({asset["name"] for asset in self.fixture.state()["assets"]}, {self.fixture.artifact.name, self.fixture.checksum.name})
        commands = self.fixture.commands()
        self.assertFalse(any(command[:2] in (["git", "tag"], ["git", "push"], ["git", "config"]) for command in commands))
        self.assertFalse(any(command[0] == "gh" and command[2] in ("create", "edit", "delete") for command in commands))
        self.assertFalse(list(self.fixture.artifact.parent.glob("publish.*")))

    def test_packaged_artifact_can_be_uploaded(self):
        self.assert_success(self.fixture.package())
        self.assert_success(self.fixture.publish())

    def test_historical_commit_and_detached_head_are_allowed(self):
        self.fixture.update_state(origin=NEW_COMMIT, branch="")
        self.assert_success(self.fixture.publish())
        self.assertTrue(any(command[:3] == ["git", "merge-base", "--is-ancestor"] for command in self.fixture.commands()))

    def test_lightweight_remote_tag_is_allowed(self):
        self.fixture.update_state(lightweight_tag=True)
        self.assert_success(self.fixture.publish())

    def test_identical_retry_is_a_noop(self):
        self.assert_success(self.fixture.publish())
        self.fixture.clear_log()
        self.assert_success(self.fixture.publish())
        self.assert_no_remote_writes()
        downloads = [command for command in self.fixture.commands() if command[:3] == ["gh", "release", "download"]]
        self.assertEqual({command[command.index("--pattern") + 1] for command in downloads}, {self.fixture.artifact.name, self.fixture.checksum.name})
        self.assertFalse(list(self.fixture.artifact.parent.glob("publish.*")))

    def test_each_missing_asset_can_be_uploaded_without_replacing_existing_asset(self):
        for existing_name in ("artifact", "checksum"):
            with self.subTest(existing=existing_name):
                fixture = self.new_fixture()
                fixture.seed_artifact()
                existing = getattr(fixture, existing_name)
                missing = fixture.checksum if existing_name == "artifact" else fixture.artifact
                fixture.seed_remote_assets(existing)
                self.assert_success(fixture.publish())
                self.assertEqual(self.uploads(fixture)[0][4:], [str(missing)])
                commands = fixture.commands()
                compare = next(index for index, command in enumerate(commands) if command[0] == "cmp")
                upload = next(index for index, command in enumerate(commands) if command[:3] == ["gh", "release", "upload"])
                self.assertLess(compare, upload)

    def test_all_existing_assets_are_compared_before_any_upload(self):
        # The DMG is missing, but the checksum conflicts. No DMG may be uploaded.
        self.fixture.checksum.write_text("conflicting remote checksum\n")
        self.fixture.seed_remote_assets(self.fixture.checksum)
        self.fixture.seed_artifact()
        result = self.fixture.publish()
        self.assert_failure(result, "original packaged files")
        self.assert_no_remote_writes()
        self.assertFalse(list(self.fixture.artifact.parent.glob("publish.*")))

    def test_conflicting_dmg_is_not_replaced(self):
        self.fixture.seed_remote_assets(self.fixture.artifact, self.fixture.checksum)
        assets = self.fixture.state()["assets"]
        assets[0]["content"] = base64.b64encode(b"different published DMG").decode()
        self.fixture.update_state(assets=assets)
        self.assert_failure(self.fixture.publish(), "must not be replaced")
        self.assert_no_remote_writes()

    def test_conflicting_checksum_is_not_replaced(self):
        self.fixture.seed_remote_assets(self.fixture.artifact, self.fixture.checksum)
        assets = self.fixture.state()["assets"]
        assets[1]["content"] = base64.b64encode(b"different checksum bytes").decode()
        self.fixture.update_state(assets=assets)
        self.assert_failure(self.fixture.publish(), "must not be replaced")
        self.assert_no_remote_writes()

    def test_partial_upload_can_be_retried_with_the_same_bytes(self):
        self.fixture.update_state(upload_fail_after=1)
        self.assert_failure(self.fixture.publish())
        self.assertEqual(len(self.fixture.state()["assets"]), 1)
        self.fixture.update_state(upload_fail_after=None)
        self.fixture.clear_log()
        self.assert_success(self.fixture.publish())
        self.assertEqual(self.uploads()[0][4:], [str(self.fixture.checksum)])

    def test_download_errors_do_not_allow_uploads(self):
        self.fixture.seed_remote_assets(self.fixture.checksum)
        self.fixture.update_state(download_error=True)
        self.assert_failure(self.fixture.publish(), "could not download")
        self.assert_no_remote_writes()

    def test_api_errors_are_not_interpreted_as_missing_releases(self):
        for error in ("HTTP 401: bad credentials", "HTTP 403: forbidden", "HTTP 500: unavailable"):
            with self.subTest(error=error):
                self.fixture.update_state(view_error=error)
                self.fixture.clear_log()
                self.assert_failure(self.fixture.publish(), "could not read GitHub Release")
                self.assert_no_remote_writes()

    def test_missing_release_is_rejected(self):
        self.fixture.update_state(release=False)
        self.assert_failure(self.fixture.publish(), "could not read GitHub Release")
        self.assert_no_remote_writes()

    def test_draft_release_is_rejected(self):
        self.fixture.update_state(draft=True)
        self.assert_failure(self.fixture.publish(), "must not be a draft")
        self.assert_no_remote_writes()

    def test_invalid_release_response_is_rejected(self):
        for response in ("not JSON", '{}', '{"isDraft": false, "assets": null}'):
            with self.subTest(response=response):
                self.fixture.update_state(release_response=response)
                self.fixture.clear_log()
                self.assert_failure(self.fixture.publish())
                self.assert_no_remote_writes()

    def test_unexpected_duplicate_or_invalid_asset_names_are_rejected(self):
        for assets in (
            [{"name": "old-release.zip"}],
            [{"name": self.fixture.provenance.name}],
            [{"name": self.fixture.artifact.name}, {"name": self.fixture.artifact.name}],
            [{"name": self.fixture.artifact.name + "\n" + self.fixture.checksum.name}],
            [{"size": 123}],
            {"name": self.fixture.artifact.name},
        ):
            with self.subTest(assets=assets):
                self.fixture.update_state(assets=assets)
                self.fixture.clear_log()
                self.assert_failure(self.fixture.publish(), "unexpected or duplicate assets")
                self.assert_no_remote_writes()

    def test_wrong_or_missing_remote_tag_is_rejected(self):
        for commit in (None, NEW_COMMIT):
            with self.subTest(commit=commit):
                self.fixture.update_state(remote_tag=commit)
                self.fixture.clear_log()
                self.assert_failure(self.fixture.publish(), "does not point to HEAD")
                self.assert_no_remote_writes()
                self.assertFalse(any(command[0] == "gh" for command in self.fixture.commands()))

    def test_tag_lookup_error_is_rejected(self):
        self.fixture.update_state(tag_query_error=True)
        self.assert_failure(self.fixture.publish(), "could not check remote tag")
        self.assert_no_remote_writes()

    def test_rejects_commit_outside_main_ancestry(self):
        self.fixture.update_state(ancestor=False)
        self.assert_failure(self.fixture.publish(), "ancestor of origin/main")
        self.assert_no_remote_writes()
        self.assertFalse(any(command[0] == "gh" for command in self.fixture.commands()))

    def test_head_change_during_fetch_is_rejected(self):
        self.fixture.update_state(change_on_fetch=True)
        self.assert_failure(self.fixture.publish(), "HEAD changed during publication")
        self.assert_no_remote_writes()

    def test_source_change_during_fetch_is_rejected(self):
        self.fixture.update_state(dirty_on_fetch=True)
        self.assert_failure(self.fixture.publish(), "working tree changed during publication")
        self.assert_no_remote_writes()

    def test_checksum_must_cover_only_the_expected_dmg(self):
        other = self.fixture.artifact.parent / "other-file"
        other.write_bytes(b"not the release DMG")
        other_digest = hashlib.sha256(other.read_bytes()).hexdigest()
        valid_checksum = self.fixture.checksum.read_text()
        for checksum in ("", "not a checksum\n", f"{other_digest}  {other.name}\n", valid_checksum + f"{other_digest}  {other.name}\n"):
            with self.subTest(checksum=checksum):
                self.fixture.clear_log()
                self.fixture.checksum.write_text(checksum)
                self.assert_failure(self.fixture.publish(), "checksum verification failed")
                self.assert_no_remote_access()

    def test_preflight_guards_run_before_remote_access(self):
        cases = (
            ("confirmation", "confirm public publication"),
            ("wrong_confirmation", "confirm public publication"),
            ("dirty", "working tree must be clean"),
            ("branch", "published from main"),
            ("version", "project version"),
            ("artifact", "release artifact not found"),
            ("checksum", "checksum not found"),
            ("provenance", "commit provenance not found"),
            ("empty_provenance", "not packaged from HEAD"),
            ("old_provenance", "not packaged from HEAD"),
            ("checksum_mismatch", None),
        )
        for guard, message in cases:
            with self.subTest(guard=guard):
                fixture = self.new_fixture()
                fixture.seed_artifact()
                if guard == "confirmation":
                    fixture.env.pop("CONFIRM_PUBLISH")
                elif guard == "wrong_confirmation":
                    fixture.env["CONFIRM_PUBLISH"] = "v9.9.9"
                elif guard == "dirty":
                    fixture.update_state(dirty=True)
                elif guard == "branch":
                    fixture.update_state(branch="feature")
                elif guard == "version":
                    (fixture.checkout / "Configuration/Version.xcconfig").write_text("MARKETING_VERSION = 9.9.9\n")
                elif guard in ("artifact", "checksum", "provenance"):
                    getattr(fixture, guard).unlink()
                elif guard == "empty_provenance":
                    fixture.provenance.write_text("")
                elif guard == "old_provenance":
                    fixture.update_state(head=NEW_COMMIT, origin=NEW_COMMIT)
                elif guard == "checksum_mismatch":
                    fixture.artifact.write_bytes(b"changed after packaging")
                self.assert_failure(fixture.publish(), message)
                self.assert_no_remote_access(fixture)


class InterfaceTests(ReleaseTestCase):
    def test_stable_release_versions(self):
        for version in ("0.0.0", "1.2.3", "10.20.30"):
            with self.subTest(version=version):
                fixture = self.new_fixture(version)
                self.assert_success(fixture.package())
                self.assert_success(fixture.publish())

    def test_invalid_versions_are_rejected_before_remote_access(self):
        for version in ("1.2", "v1.2.3", "1.2.3-rc.1", "1.2.3+build.1", "1.2.3-", "1.2.3+", "1.2.3+a..b", "1.2.3/../bad"):
            with self.subTest(version=version):
                fixture = self.new_fixture()
                self.assert_failure(fixture.package(version))
                self.assert_failure(fixture.publish(version))
                self.assert_no_remote_access(fixture)
                self.assertFalse(fixture.artifact.exists())

    def test_argument_count(self):
        for script in ("package-release.sh", "publish-release.sh"):
            for args in ((), (VERSION, VERSION)):
                with self.subTest(script=script, args=args):
                    result = self.fixture.run(self.fixture.checkout / "scripts" / script, *args)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assert_no_remote_access()

    def test_shell_syntax(self):
        for name in ("package-release.sh", "publish-release.sh"):
            with self.subTest(script=name):
                self.assert_success(self.fixture.run("-n", self.fixture.checkout / "scripts" / name))
        for job in ("release-pr", "select", "package", "publish"):
            for name, script in workflow_run_steps(job):
                with self.subTest(workflow_job=job, workflow_step=name):
                    self.assert_success(self.fixture.run("-n", "-c", script))


if __name__ == "__main__":
    unittest.main()
