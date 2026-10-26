"""Small final-archive/RECORD fixtures; these do not claim a Windows freeze passed."""
import json
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from email.message import Message
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
from unittest import mock

from tools.freeze_inventory import Environment, capture_bundle, copy_distribution_notices, merge_inventories, pins


class Distribution:
    def __init__(self, base, name, version, files, licenses=()):
        self.base, self.version = base, version
        self.metadata = Message()
        self.metadata["Name"] = name
        for value in licenses:
            self.metadata["License-File"] = value
        self.files = [PurePosixPath(name) for name in files]
        for name, contents in files.items():
            path = self.locate_file(PurePosixPath(name))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)

    def locate_file(self, record):
        return self.base / str(record)


class Archive:
    def __init__(self, modules, entries, options=()):
        self.modules, self.entries = modules, entries
        self.toc = {name: (0, 0, 0, 0, kind) for name, (kind, _) in entries.items()}
        self.options = list(options)

    def extract(self, name):
        return self.entries[name][1]

    def open_embedded_archive(self, name):
        return SimpleNamespace(toc={m: (0, 0, 0) for m in self.modules},
                               extract=lambda name, raw=False: self.modules[name])


class FreezeInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.venv, self.python, self.system = [self.root / p for p in ("venv", "python", "system")]
        self.site = self.venv / "Lib/site-packages"
        self.distributions = []
        self.runtime = ["alpha==1"]
        self.lock = [*self.runtime, "pyinstaller==6.22.3", "pyinstaller-hooks-contrib==2026.9", "packaging==26.3"]
        self.add_dist("alpha", "1", {"alpha/__init__.py": b"alpha", "alpha/native.pyd": b"extension"},
                      ("third/a/LICENSE.txt", "third/b/LICENSE.txt"))
        self.add_dist("pyinstaller", "6.22.3", {"PyInstaller/bootloader/run.exe": b"bootloader"})
        self.add_dist("pyinstaller-hooks-contrib", "2026.9", {})
        self.add_dist("packaging", "26.3", {})
        # Installed development packages are deliberately absent from the build lock.
        self.add_dist("pytest", "9", {"pytest/__init__.py": b"developer package"})
        self.add_dist("ruff", "1", {"ruff/ruff.exe": b"developer tool"})

    def add_dist(self, name, version, files, licenses=()):
        files = dict(files)
        base = name.replace("-", "_") + "-" + version + ".dist-info"
        for index, value in enumerate(licenses or ("LICENSE",)):
            files[base + "/licenses/" + value] = ("license " + name + " " + str(index)).encode()
        dist = Distribution(self.site, name, version, files, licenses or ("LICENSE",))
        self.distributions.append(dist)
        return dist

    def environment(self):
        (self.root / "hub").mkdir(exist_ok=True)
        (self.root / "hub/requirements-runtime.txt").write_text("\n".join(self.runtime), encoding="utf-8")
        (self.root / "hub/requirements-windows.txt").write_text("\n".join(self.lock), encoding="utf-8")
        return Environment(self.root, self.distributions, python=self.python, venv=self.venv, system=self.system,
                           markers={"sys_platform": "win32"})

    def capture(self, bundle="hub", archive=None, *, extra=(), replacements=None, pyz_content=b"pyz"):
        env = self.environment()
        work = self.root / "build/pyinstaller"
        work.mkdir(parents=True, exist_ok=True)
        entry = self.root / "tools/entry.py"
        entry.parent.mkdir(exist_ok=True)
        entry.write_bytes(b"project entry")
        pyz = SimpleNamespace(name=str(work / "built.pyz"),
                              toc=[("alpha", str(self.site / "alpha/__init__.py"), "PYMODULE")])
        Path(pyz.name).write_bytes(pyz_content)
        (work / "original-name.pyz").write_bytes(b"pyz")
        options = ["pyi-contents-directory _internal"] if bundle == "hub" else []
        exe = SimpleNamespace(name=str(work / "sport-hub.exe" if bundle == "hub" else self.root / "package/SportGames.exe"),
                              toc=[("original-name.pyz", str(work / "original-name.pyz"), "PYZ"),
                                   ("entry", str(entry), "PYSOURCE"), *extra, *[(o, "", "OPTION") for o in options]],
                              exclude_binaries=bundle == "hub",
                              exefiles=[("run.exe", str(self.site / "PyInstaller/bootloader/run.exe"), "EXECUTABLE")])
        collect = None
        final = work / "output/sport-hub" if bundle == "hub" else self.root / "package"
        final.mkdir(parents=True, exist_ok=True)
        Path(exe.name).write_bytes(b"final executable")
        (final / Path(exe.name).name).write_bytes(b"final executable")
        if bundle == "hub":
            collect = SimpleNamespace(name=str(final), contents_directory="_internal",
                                      toc=[("sport-hub.exe", exe.name, "EXECUTABLE"),
                                           ("alpha/native.pyd", str(self.site / "alpha/native.pyd"), "EXTENSION"), *extra])
            for name, source, kind in collect.toc:
                if kind != "EXECUTABLE":
                    destination = final / "_internal" / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(Path(source).read_bytes())
        for name, contents in (replacements or {}).items():
            (final / name).write_bytes(contents)
        reader = archive or Archive({"alpha": b"compiled alpha"}, {"PYZ.pyz": ("z", b"pyz"), "entry": ("s", b"compiled entry")}, options)
        return capture_bundle(bundle, self.root, pyz, exe, collect, environment=env, reader_factory=lambda _: reader), final

    def combined(self):
        _, hub = self.capture()
        self.capture("launcher")
        package = self.root / "package"
        shutil.copytree(hub, package / "hub")
        config = self.root / "hub/config.json"
        config.write_text("{}", encoding="utf-8")
        shutil.copyfile(config, package / "hub/config.json")
        return merge_inventories(self.root, package)

    def test_unfrozen_development_packages_do_not_enter_dependencies_or_notices(self):
        inventory = self.combined()
        self.assertEqual(inventory["dependencies"], {"alpha": "1"})
        self.assertEqual({d["name"] for d in inventory["distributions"]}, {"alpha", "pyinstaller"})
        notices = self.root / "notices"
        copy_distribution_notices(notices, inventory, self.distributions)
        self.assertEqual({p.name for p in (notices / "python").iterdir()}, {"alpha-1", "pyinstaller-6.22.3"})
        serialized = json.dumps(inventory)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn(self.root.as_posix(), serialized)
        self.assertIn("<venv>/", serialized)

    def test_namespace_files_map_to_their_own_records_not_a_shared_top_level(self):
        for name in ("winrt-a", "winrt-b"):
            self.runtime.append(name + "==1")
            self.lock.append(name + "==1")
            self.add_dist(name, "1", {"winrt/" + name[-1] + ".pyd": name.encode()})
        env = self.environment()
        for name in ("winrt-a", "winrt-b"):
            row = env.owner(str(self.site / ("winrt/" + name[-1] + ".pyd")), "winrt." + name[-1], "EXTENSION")
            self.assertEqual(row["component"], "distribution:" + name)
        self.assertEqual(env.owner("-", "winrt", "PYMODULE")["role"], "generated")

    def test_unknown_distribution_or_unowned_native_fails_closed(self):
        self.add_dist("surprise", "1", {"surprise/code.py": b"unknown"})
        env = self.environment()
        with self.assertRaisesRegex(RuntimeError, "Windows lock"):
            env.owner(str(self.site / "surprise/code.py"), "surprise.code", "PYMODULE")
        for base in (self.venv, self.python, self.system, self.root / "tools"):
            path = base / "unknown.dll"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"unknown")
            with self.subTest(base=base.name), self.assertRaisesRegex(RuntimeError, "no reviewed owner"):
                env.owner(str(path), "unknown.dll", "BINARY")

    def test_unreviewed_native_origin_is_labeled_without_disclosing_local_paths(self):
        env = self.environment()
        unapproved = self.root.parent / (self.root.name + "-private-install")
        name = "api-ms-win-core-console-l1-1-0.dll"
        for base, label in ((self.python, "<python>/"), (self.system, "<system>/"),
                            (self.venv, "<venv>/"), (self.root / "tools", "tools/"),
                            (unapproved, "<unapproved>/")):
            source = base / name
            with self.subTest(label=label), self.assertRaisesRegex(RuntimeError, "no reviewed owner") as failure:
                env.owner(str(source), "_internal/" + name, "BINARY")
            message = str(failure.exception)
            self.assertIn("origin: " + label + name, message)
            for private in (str(self.root), self.root.as_posix(), str(base), base.as_posix()):
                self.assertNotIn(private, message)

    def test_python_and_system_native_are_explicitly_classified(self):
        env = self.environment()
        for base, name, role, component in [
            (self.python / "Lib", "struct.py", "cpython", "cpython"),
            (self.python / "DLLs", "libssl-3.dll", "cpython-native", "native:openssl"),
            (self.system, "vcruntime140.dll", "system", "native:microsoft-crt")
        ]:
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"runtime")
            row = env.owner(str(path), name, "BINARY")
            self.assertEqual((row["role"], row["component"]), (role, component))
            self.assertTrue(row["source"].startswith("<system>/" if role == "system" else "<python>/"))

    def test_runtime_markers_and_exact_installed_lock_versions_are_enforced(self):
        self.runtime.append("dbus-fast==1 ; sys_platform == 'linux'")
        self.lock.append("dbus-fast==1 ; sys_platform == 'linux'")
        env = self.environment()
        self.assertNotIn("dbus-fast", env.runtime)
        self.lock[0] = "alpha==2"
        with self.assertRaisesRegex(RuntimeError, "lock mismatch"):
            self.environment()
        self.lock[0] = "alpha==1"
        self.distributions[0].version = "2"
        with self.assertRaisesRegex(RuntimeError, "Installed distribution"):
            self.environment()

    def test_final_archive_members_and_copied_files_are_verified(self):
        bad = Archive({"alpha": b"compiled"}, {"PYZ.pyz": ("z", b"pyz"), "entry": ("s", b"entry"),
                                                       "unexpected": ("b", b"unowned")}, ["pyi-contents-directory _internal"])
        with self.assertRaisesRegex(RuntimeError, "EXE"):
            self.capture(archive=bad)
        inventory = self.combined()
        self.assertTrue(inventory["files"])
        (self.root / "package/hub/_internal/alpha/native.pyd").write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "Copied frozen output"):
            merge_inventories(self.root, self.root / "package")

    def test_same_named_pyz_with_changed_bytes_is_rejected(self):
        changed = Archive({"alpha": b"compiled alpha"},
                          {"PYZ.pyz": ("z", b"replaced pyz"), "entry": ("s", b"compiled entry")},
                          ["pyi-contents-directory _internal"])
        with self.assertRaisesRegex(RuntimeError, "PYZ content"):
            self.capture(archive=changed)
        with self.assertRaisesRegex(RuntimeError, "PYZ content"):
            self.capture(pyz_content=b"different constructed PYZ")

    def test_same_named_unprocessed_exe_and_collect_content_is_bound_to_source(self):
        source = self.root / "tools/data.txt"
        source.parent.mkdir(exist_ok=True)
        source.write_bytes(b"reviewed data")
        for kind in ("DATA", "ZIPFILE", "BINARY", "EXTENSION"):
            origin = source if kind in ("DATA", "ZIPFILE") else self.site / "alpha/native.pyd"
            entry = ("payload", str(origin), kind)
            changed = Archive({"alpha": b"compiled alpha"},
                              {"PYZ.pyz": ("z", b"pyz"), "entry": ("s", b"compiled entry"),
                               "payload": ("x" if kind == "DATA" else "Z" if kind == "ZIPFILE" else "b", b"replaced")})
            with self.subTest(container="EXE", kind=kind), self.assertRaisesRegex(RuntimeError, "content differs"):
                self.capture("launcher", changed, extra=[entry])
            with self.subTest(container="COLLECT", kind=kind), self.assertRaisesRegex(RuntimeError, "content differs"):
                self.capture(extra=[entry], replacements={"_internal/payload": b"replaced"})

    def test_same_named_stdlib_zip_members_with_replaced_content_are_rejected(self):
        source = self.root / "build/pyinstaller/cache/base_library.zip"
        source.parent.mkdir(parents=True)
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("encodings/__init__.pyc", b"reviewed stdlib")
        replacement = self.root / "replacement.zip"
        with zipfile.ZipFile(replacement, "w") as archive:
            archive.writestr("encodings/__init__.pyc", b"replaced stdlib")
        with self.assertRaisesRegex(RuntimeError, "content differs"):
            self.capture(extra=[("base_library.zip", str(source), "DATA")],
                         replacements={"_internal/base_library.zip": replacement.read_bytes()})

    def test_collected_executable_copy_is_bound_to_built_executable(self):
        with self.assertRaisesRegex(RuntimeError, "collected executable"):
            self.capture(replacements={"sport-hub.exe": b"replaced executable"})

    def test_same_named_notices_keep_their_full_relative_hierarchy(self):
        inventory = self.combined()
        target = self.root / "notices"
        copy_distribution_notices(target, inventory, self.distributions)
        a = target / "python/alpha-1/licenses/third/a/LICENSE.txt"
        b = target / "python/alpha-1/licenses/third/b/LICENSE.txt"
        self.assertNotEqual(a.read_bytes(), b.read_bytes())
        self.assertEqual(len(list(target.rglob("LICENSE.txt"))), 2)

    def test_declared_notice_traversal_missing_text_and_duplicate_destinations_fail(self):
        inventory = {"distributions": [{"name": "alpha", "version": "1"}]}
        dist = self.distributions[0]
        for values in [("../LICENSE",), ("absent.txt",), ("third/a/LICENSE.txt", "third/a/LICENSE.txt")]:
            del dist.metadata["License-File"]
            for value in values:
                dist.metadata["License-File"] = value
            with self.subTest(values=values), self.assertRaises(RuntimeError):
                copy_distribution_notices(self.root / "notices", inventory, self.distributions)

    def test_notice_source_and_resolved_destination_must_stay_inside_their_roots(self):
        inventory = {"distributions": [{"name": "alpha", "version": "1"}]}
        dist = self.distributions[0]
        outside = (self.root / "outside-LICENSE.txt").resolve()
        outside.write_bytes(b"outside installation root")
        original_locate = dist.locate_file
        def locate(record):
            return outside if str(record).endswith("third/a/LICENSE.txt") else original_locate(record)
        with mock.patch.object(dist, "locate_file", side_effect=locate), self.assertRaisesRegex(RuntimeError, "source.*outside"):
            copy_distribution_notices(self.root / "notices", inventory, self.distributions)
        target = (self.root / "notices").resolve()
        destination = (target / "python/alpha-1/licenses/third/a/LICENSE.txt").resolve()
        destination_hits = []
        original_resolve = Path.resolve
        def resolve(path, *args, **kwargs):
            if path == destination:
                destination_hits.append(path)
                return outside
            return original_resolve(path, *args, **kwargs)
        with mock.patch.object(Path, "resolve", resolve), self.assertRaisesRegex(RuntimeError, "destination.*outside"):
            copy_distribution_notices(target, inventory, self.distributions)
        self.assertEqual(destination_hits, [destination])
        self.assertEqual(outside.read_bytes(), b"outside installation root")

    @unittest.skipUnless(sys.platform == "win32", "Windows junction fixture")
    def test_windows_junction_notice_sources_and_destinations_are_rejected(self):
        inventory = {"distributions": [{"name": "alpha", "version": "1"}]}
        source_parent = self.site / "alpha-1.dist-info/licenses/third/a"
        (source_parent / "LICENSE.txt").unlink()
        source_parent.rmdir()
        for role, link in (("source", source_parent), ("destination", self.root / "notices/python")):
            outside = self.root / ("outside-" + role)
            outside.mkdir()
            (outside / "LICENSE.txt").write_bytes(b"outside notice")
            link.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)], check=True, capture_output=True)
            try:
                with self.subTest(role=role), self.assertRaisesRegex(RuntimeError, role + " reparse point"):
                    copy_distribution_notices(self.root / "notices", inventory, self.distributions)
                self.assertEqual([p.name for p in outside.iterdir()], ["LICENSE.txt"])
            finally:
                link.rmdir()
            if role == "source":
                source_parent.mkdir()
                (source_parent / "LICENSE.txt").write_bytes(b"restored notice")

    def test_legacy_record_notices_and_undeclared_third_party_text_are_preserved(self):
        dist = self.distributions[0]
        for name in ("alpha/vendor/a/NOTICE", "alpha/vendor/b/NOTICE"):
            record = PurePosixPath(name)
            dist.files.append(record)
            path = dist.locate_file(record)
            path.parent.mkdir(parents=True)
            path.write_text(name, encoding="utf-8")
        inventory = {"distributions": [{"name": "alpha", "version": "1"}]}
        for modern in (True, False):
            if not modern:
                del dist.metadata["License-File"]
            target = self.root / ("modern" if modern else "legacy")
            copy_distribution_notices(target, inventory, self.distributions)
            for name in ("alpha/vendor/a/NOTICE", "alpha/vendor/b/NOTICE"):
                self.assertEqual((target / "python/alpha-1" / name).read_text(encoding="utf-8"), name)

    def test_multiple_record_owners_and_extra_final_directory_files_are_rejected(self):
        self.runtime.append("other==1")
        self.lock.append("other==1")
        self.add_dist("other", "1", {"alpha/__init__.py": b"shared claim"})
        env = self.environment()
        with self.assertRaisesRegex(RuntimeError, "multiple RECORD"):
            env.owner(str(self.site / "alpha/__init__.py"), "alpha", "PYMODULE")
        self.distributions.pop()
        self.runtime.pop()
        self.lock.pop()
        _, final = self.capture()
        (final / "unexpected.dll").write_bytes(b"unowned")
        with self.assertRaisesRegex(RuntimeError, "COLLECT"):
            self.capture()

    def test_bootstrap_pyc_is_attributed_to_verified_original_source(self):
        source = self.site / "PyInstaller/loader.py"
        dist = self.distributions[1]
        dist.files.append(PurePosixPath("PyInstaller/loader.py"))
        source.write_bytes(b"loader source")
        compiled = self.root / "build/pyinstaller/cache/localpycs/loader.pyc"
        compiled.parent.mkdir(parents=True)
        compiled.write_bytes(b"compiled loader")
        env = self.environment()
        row = env.owner(str(compiled), "loader", "PYMODULE", bootstrap={"loader": str(source)})
        self.assertEqual(row["component"], "distribution:pyinstaller")
        self.assertEqual(row["role"], "embedded-tool-runtime")
        with self.assertRaisesRegex(RuntimeError, "bootstrap"):
            env.owner(str(compiled), "loader", "PYMODULE", bootstrap={"other": str(source)})

    def test_stdlib_generated_archive_is_not_an_unknown_native_escape_hatch(self):
        env = self.environment()
        source = self.root / "build/pyinstaller/cache/base_library.zip"
        source.parent.mkdir(parents=True)
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("encodings/__init__.pyc", b"compiled stdlib")
        self.assertEqual(env.owner(str(source), "_internal/base_library.zip", "DATA")["role"], "cpython")
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("surprise/__init__.pyc", b"unknown")
        with self.assertRaisesRegex(RuntimeError, "Unknown module"):
            env.owner(str(source), "base_library.zip", "DATA")

    def test_unpinned_and_duplicate_requirement_inputs_are_rejected(self):
        path = self.root / "requirements.txt"
        for text in ("alpha>=1", "alpha==1\nAlpha==1"):
            path.write_text(text, encoding="utf-8")
            with self.subTest(text=text), self.assertRaisesRegex(RuntimeError, "unique exact"):
                pins(path)

    def test_adapter_version_changes_require_review(self):
        self.distributions[1].version = "6.22.4"
        self.lock[1] = "pyinstaller==6.22.4"
        with self.assertRaisesRegex(RuntimeError, "Revalidate"):
            self.capture()

    def test_reviewed_specs_keep_modes_hidden_imports_web_data_and_disable_upx(self):
        repo = Path(__file__).resolve().parents[2]
        for bundle in ("hub", "launcher"):
            calls = {}
            def analysis(*args, _calls=calls, **kwargs):
                _calls["analysis"] = kwargs
                _calls["entry"] = args[0]
                return SimpleNamespace(pure=[], scripts=[], binaries=[], datas=[])
            def exe(*args, _calls=calls, **kwargs):
                _calls["exe"] = kwargs
                return object()
            def collect(*args, _calls=calls, **kwargs):
                _calls["collect"] = kwargs
                return object()
            modules = {"freeze_inventory": SimpleNamespace(capture_bundle=mock.Mock()),
                       "PyInstaller.utils.hooks": SimpleNamespace(collect_submodules=lambda name: [name + ".fixture"])}
            previous = list(sys.path)
            spec = repo / "tools/pyinstaller" / (bundle + ".spec")
            try:
                with mock.patch.dict(sys.modules, modules):
                    runpy.run_path(str(spec), init_globals={"SPECPATH": str(spec.parent), "Analysis": analysis,
                                                          "PYZ": lambda _: object(), "EXE": exe, "COLLECT": collect})
            finally:
                sys.path[:] = previous
            self.assertFalse(calls["exe"]["upx"])
            self.assertEqual(calls["exe"]["console"], bundle == "hub")
            if bundle == "hub":
                self.assertTrue(calls["exe"]["exclude_binaries"])
                self.assertEqual(calls["analysis"]["hiddenimports"], ["bleak.backends.winrt.fixture", "winrt.fixture"])
                self.assertEqual(calls["analysis"]["datas"], [(str(repo / "hub/regina_hub/web"), "regina_hub/web")])
                self.assertIn("collect", calls)
            else:
                self.assertNotIn("collect", calls)

    def test_missing_notice_failure_does_not_expose_the_installation_path(self):
        source = self.site / "alpha-1.dist-info/licenses/third/a/LICENSE.txt"
        source.unlink()
        with self.assertRaisesRegex(RuntimeError, "source unavailable") as failure:
            copy_distribution_notices(self.root / "notices", {"distributions": [{"name": "alpha", "version": "1"}]}, self.distributions)
        self.assertNotIn(str(self.root), str(failure.exception))


if __name__ == "__main__":
    unittest.main()
