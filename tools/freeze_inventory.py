"""Attribute final frozen files to their installed RECORD owners, never the whole venv.

The reader adapter is reviewed for PyInstaller 6.22.3. It reads constructed build
objects and final archives, not PyInstaller's private serialized .toc files.
"""
from __future__ import annotations

import hashlib
import importlib.metadata as metadata
import json
import os
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

from packaging.requirements import Requirement

ADAPTER_VERSION = "6.22.3"
TOOLS = ("pyinstaller", "pyinstaller-hooks-contrib", "packaging")
NATIVE = {"libcrypto-3.dll": "openssl", "libssl-3.dll": "openssl", "libffi-8.dll": "libffi",
          "sqlite3.dll": "sqlite", "zlib1.dll": "zlib", "tcl86t.dll": "tcl", "tk86t.dll": "tk"}
CRT = re.compile(r"(?:vcruntime140(?:_1)?|msvcp140|ucrtbase|api-ms-win-crt-[a-z0-9-]+)\.dll", re.I)


def canonical(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def relative(value: str) -> str:
    value = str(value).replace("\\", "/")
    if (not value or ":" in value or any(ord(c) < 32 for c in value) or
            PurePosixPath(value).is_absolute() or any(p in ("", ".", "..") for p in value.split("/"))):
        raise RuntimeError("Unsafe frozen relative path")
    return value


def digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Frozen evidence is missing or is a symlink")
    try:
        with path.open("rb") as source:
            return hashlib.file_digest(source, "sha256").hexdigest()
    except OSError:
        raise RuntimeError("Frozen evidence cannot be read") from None


def pins(path: Path, environment: dict | None = None) -> dict[str, str]:
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip().rstrip("\\").strip()
        if not line or line.startswith(("#", "--")):
            continue
        requirement = Requirement(line)
        if requirement.marker and not requirement.marker.evaluate(environment):
            continue
        specs = list(requirement.specifier)
        name = canonical(requirement.name)
        if len(specs) != 1 or specs[0].operator != "==" or "*" in specs[0].version or name in result:
            raise RuntimeError("Freeze inputs require unique exact version pins")
        result[name] = specs[0].version
    return result


def _diagnostic_path(value: str | None) -> Path | None:
    if not value or any(ord(c) < 32 for c in value):
        return None
    try:
        path = Path(value)
        return path.resolve() if path.is_absolute() else None
    except (OSError, RuntimeError, ValueError):
        return None


class Environment:
    def __init__(self, root: Path, distributions=None, *, python: Path | None = None,
                 venv: Path | None = None, system: Path | None = None, markers: dict | None = None):
        self.root = root.resolve()
        self.python = (python or Path(sys.base_prefix)).resolve()
        self.venv = (venv or Path(sys.prefix)).resolve()
        if system is None and not os.environ.get("WINDIR"):
            raise RuntimeError("Windows system source root is unavailable")
        self.system = (system or Path(os.environ["WINDIR"]) / "System32").resolve()
        self.runtime = pins(root / "hub/requirements-runtime.txt", markers)
        self.lock = pins(root / "hub/requirements-windows.txt", markers)
        self.distributions, self.owners = {}, {}
        for dist in metadata.distributions() if distributions is None else distributions:
            name = canonical(dist.metadata["Name"])
            if name in self.distributions:
                raise RuntimeError("Ambiguous installed distribution: " + name)
            self.distributions[name] = dist
            for record in dist.files or []:
                path = Path(dist.locate_file(record)).resolve()
                self.owners.setdefault(path, []).append((name, record))
        for name, version in self.runtime.items():
            if self.lock.get(name) != version:
                raise RuntimeError("Runtime/Windows lock mismatch: " + name)
            self.require(name)

    def require(self, name: str):
        dist = self.distributions.get(name)
        if dist is None or dist.version != self.lock.get(name):
            raise RuntimeError("Installed distribution differs from Windows lock: " + name)
        return dist

    def label(self, source: Path, *, installed: bool = False) -> str:
        roots = [(self.venv, "<venv>"), (self.python, "<python>"), (self.system, "<system>")]
        if not installed:
            roots.insert(0, (self.root, ""))
        for root, prefix in roots:
            if source.is_relative_to(root):
                return (prefix + "/" if prefix else "") + relative(source.relative_to(root).as_posix())
        raise RuntimeError("Frozen source is outside approved roots")

    def diagnostic_origin(self, source: Path) -> str:
        """Describe rejected input without granting ownership or exposing local paths."""
        path_entries = [index for index, value in enumerate(os.environ.get("PATH", "").split(os.pathsep))
                        if (entry := _diagnostic_path(value)) is not None and entry == source.parent]
        for installed in (True, False):
            try:
                origin = self.label(source, installed=installed)
                break
            except RuntimeError:
                continue
        else:
            roots = []
            for key, prefix in (("WINDIR", "<windows>"), ("ProgramFiles", "<program-files>"),
                                ("ProgramFiles(x86)", "<program-files-x86>"), ("RUNNER_TOOL_CACHE", "<runner-tool-cache>")):
                if (root := _diagnostic_path(os.environ.get(key))) is not None:
                    roots.append((root, prefix))
            if (executable := _diagnostic_path(getattr(sys, "_base_executable", None))) is not None:
                roots.append((executable.parent, "<base-executable>"))
            matching = [(root, prefix) for root, prefix in roots if source.is_relative_to(root)]
            if matching:
                root, prefix = max(matching, key=lambda item: len(item[0].parts))
                public = {part.casefold(): part for part in ("Windows Kits", "PowerShell", "Git", "WinSxS", "System32",
                          "SysWOW64", "Redist", "ucrt", "DLLs", "bin", "mingw64", "x64", "x86", "arm64")}
                if prefix == "<runner-tool-cache>":
                    public.update({part.casefold(): part for part in ("Python", "PyPy", "Ruby", "node", "go", "Java", "Scripts")})
                parts = source.relative_to(root).parts[:-1]
                parts = [public.get(part.casefold(), part if re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", part) else "<redacted>")
                         for part in parts]
                origin = "/".join([prefix, *parts, relative(source.name)])
            else:
                prefix = "<path-entry[" + str(path_entries[0]) + "]>" if path_entries else "<unapproved>"
                origin = prefix + "/" + relative(source.name)
        # Membership is evidence of a candidate directory, not which search resolved it.
        if path_entries:
            origin += "; pathEntries=[" + ",".join(str(index) for index in path_entries) + "]"
        return origin

    def owner(self, source: str, name: str, kind: str, *, bootstrap: dict | None = None) -> dict:
        if source in (None, "-"):
            if not kind.startswith("PYMODULE") or not re.fullmatch(r"[\w.]+", name):
                raise RuntimeError("Unattributed generated frozen entry")
            return {"component": "generated:namespace", "role": "generated", "source": "<generated>/namespace/" + name}
        path = Path(source)
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
            raise RuntimeError("Frozen source symlink refused")
        path = path.resolve()
        if bootstrap and path.suffix == ".pyc" and path.is_relative_to(self.root / "build/pyinstaller"):
            original = bootstrap.get(name)
            if original is None:
                raise RuntimeError("Unattributed compiled bootstrap entry")
            path = Path(original).resolve()
        owners = self.owners.get(path, [])
        if len(owners) > 1:
            raise RuntimeError("Frozen file has multiple RECORD owners")
        if owners:
            dist_name, record = owners[0]
            dist = self.require(dist_name)
            result = {"component": "distribution:" + dist_name, "name": dist_name, "version": dist.version,
                      "role": "application" if dist_name in self.runtime else "embedded-tool-runtime",
                      "source": self.label(path, installed=True), "record": relative(str(record))}
            if dist.metadata.get("License-Expression"):
                result["licenseExpression"] = dist.metadata["License-Expression"]
            return result
        if path.is_relative_to(self.root / "build/pyinstaller"):
            if (kind not in ("DATA", "ZIPFILE") or PurePosixPath(name).name != "base_library.zip" or
                    path.name != "base_library.zip" or not zipfile.is_zipfile(path)):
                raise RuntimeError("Unknown generated frozen file")
            with zipfile.ZipFile(path) as archive:
                for member in archive.namelist():
                    member = relative(member)
                    module = member.split("/")[0].split(".")[0]
                    if not member.endswith(".pyc") or module not in sys.stdlib_module_names:
                        raise RuntimeError("Unknown module in generated stdlib archive")
            return {"component": "cpython", "role": "cpython", "version": sys.version.split()[0],
                    "source": "<generated>/base_library.zip"}
        if (path.is_relative_to(self.root) and not any(path.is_relative_to(p) for p in (self.venv, self.python, self.system))
                and kind not in ("BINARY", "EXTENSION", "EXECUTABLE")
                and path.suffix.lower() not in (".dll", ".pyd", ".exe", ".so", ".dylib")):
            return {"component": "project", "role": "project", "source": self.label(path)}
        if path.is_relative_to(self.python) and "site-packages" not in [p.lower() for p in path.parts]:
            leaf = path.name.lower()
            module = leaf.split(".")[0]
            lib = self.python / "Lib"
            python_module = (path.is_relative_to(lib) and path.relative_to(lib).parts[0].split(".")[0] in sys.stdlib_module_names)
            if (path.suffix.lower() in (".py", ".pyc") and python_module or
                    path.parent == self.python / "DLLs" and path.suffix.lower() == ".pyd" and module in sys.stdlib_module_names or
                    path.parent == self.python and re.fullmatch(r"python\d+t?(?:_d)?\.dll", leaf)):
                return {"component": "cpython", "role": "cpython", "version": sys.version.split()[0],
                        "source": "<python>/" + relative(path.relative_to(self.python).as_posix())}
            if path.parent in (self.python, self.python / "DLLs") and (leaf in NATIVE or CRT.fullmatch(leaf)):
                return {"component": "native:" + NATIVE.get(leaf, "microsoft-crt"), "role": "cpython-native",
                        "providedBy": "cpython", "source": "<python>/" + relative(path.relative_to(self.python).as_posix())}
        if path.parent == self.system and CRT.fullmatch(path.name):
            return {"component": "native:microsoft-crt", "role": "system", "source": "<system>/" + relative(path.name)}
        origin = self.diagnostic_origin(path)
        raise RuntimeError("Frozen file has no reviewed owner: " + relative(name) + " (origin: " + origin + ")")


def checked_members(expected: set[str], actual: set[str], container: str) -> None:
    if expected != actual:
        raise RuntimeError("Final frozen members differ from build evidence: " + container)


def tree_files(root: Path) -> set[str]:
    result = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("Frozen output contains a symlink")
        if path.is_file():
            result.add(relative(path.relative_to(root).as_posix()))
    return result


def capture_bundle(bundle: str, root: Path, pyz, exe, collect=None, *, environment=None,
                   reader_factory=None, bootstrap=None) -> dict:
    """Called after EXE/COLLECT completes; retain only evidence present in final outputs."""
    env = environment or Environment(root)
    if env.require("pyinstaller").version != ADAPTER_VERSION:
        raise RuntimeError("Revalidate the frozen archive adapter for the pinned PyInstaller version")
    tools = {name: env.require(name).version for name in TOOLS}
    if reader_factory is None:
        from PyInstaller.archive.readers import CArchiveReader
        from PyInstaller.depend.analysis import get_bootstrap_modules
        reader_factory = CArchiveReader
        bootstrap = {name: source for name, source, _ in get_bootstrap_modules()}
    final_dir = Path(collect.name) if collect else Path(exe.name).parent
    final_exe = final_dir / Path(exe.name).name
    archive = reader_factory(str(final_exe))
    files, outputs = [], {}

    def evidence(container, name, source, kind, content=None):
        row = {"bundle": bundle, "container": container, "destination": relative(name), "type": kind,
               **env.owner(source, name, kind, bootstrap=bootstrap)}
        row["sha256"] = hashlib.sha256(content).hexdigest() if content is not None else digest(Path(source))
        # Both reviewed Windows specs disable strip and UPX, so these entries
        # must retain their source bytes even when stored inside the onefile EXE.
        if content is not None and kind in ("BINARY", "EXTENSION", "DATA", "ZIPFILE"):
            if row["sha256"] != digest(Path(source)):
                raise RuntimeError("Final frozen content differs from source evidence: " + container)
        files.append(row)

    entries = {}
    options = []
    for name, source, kind in exe.toc:
        if kind == "OPTION":
            options.append(name)
            continue
        if exe.exclude_binaries and kind in ("BINARY", "EXTENSION", "DATA", "ZIPFILE"):
            continue
        if kind not in ("PYZ", "PYSOURCE", "PYSOURCE-1", "PYSOURCE-2", "PYMODULE", "PYMODULE-1", "PYMODULE-2",
                        "BINARY", "EXTENSION", "DATA", "ZIPFILE"):
            raise RuntimeError("Unsupported frozen EXE entry type")
        name = "PYZ.pyz" if kind == "PYZ" else name.replace("\\", "/")
        if name in entries:
            raise RuntimeError("Duplicate frozen EXE destination")
        entries[name] = (source, kind)
    archive_names = {relative(name): name for name in archive.toc}
    checked_members(set(entries), set(archive_names), "EXE")
    if sorted(options) != sorted(archive.options):
        raise RuntimeError("Final frozen options differ from build evidence")
    for name, (source, kind) in entries.items():
        actual_kind = archive.toc[archive_names[name]][-1]
        expected_kind = ("z" if kind == "PYZ" else "m" if kind.startswith("PYMODULE") else
                         "s" if kind.startswith("PYSOURCE") else "Z" if kind == "ZIPFILE" else
                         "xb" if kind == "DATA" else "b")
        if actual_kind not in expected_kind:
            raise RuntimeError("Final frozen entry type differs from build evidence")
        if kind == "PYZ":
            content = archive.extract(archive_names[name])
            if (hashlib.sha256(content).hexdigest() != digest(Path(pyz.name)) or
                    digest(Path(source)) != digest(Path(pyz.name))):
                raise RuntimeError("Final frozen PYZ content differs from build evidence")
            embedded = archive.open_embedded_archive(archive_names[name])
            checked_members({name for name, _, _ in pyz.toc}, set(embedded.toc), "PYZ")
            for module, origin, module_kind in pyz.toc:
                content = embedded.extract(module, raw=True)
                evidence("PYZ", module, origin, module_kind, content if content is not None else b"")
        else:
            evidence("EXE", name, source, kind, archive.extract(archive_names[name]))
    for name, source, kind in exe.exefiles:
        evidence("bootloader", name, source, kind)
    if collect:
        for name, source, kind in collect.toc:
            name = relative(name)
            if kind == "EXECUTABLE" and (name != final_exe.name or Path(source).resolve() != Path(exe.name).resolve()):
                raise RuntimeError("Unknown collected executable")
            location = name
            if kind != "EXECUTABLE" and collect.contents_directory:
                location = relative(collect.contents_directory + "/" + name)
            if location.casefold() in {p.casefold() for p in outputs}:
                raise RuntimeError("Ambiguous collected destination")
            outputs[location] = digest(final_dir / location)
            if kind == "EXECUTABLE" and outputs[location] != digest(Path(source)):
                raise RuntimeError("Final collected executable differs from build evidence")
            if kind != "EXECUTABLE":
                if kind not in ("BINARY", "EXTENSION", "DATA", "ZIPFILE"):
                    raise RuntimeError("Unsupported collected entry type")
                evidence("COLLECT", location, source, kind, (final_dir / location).read_bytes())
        checked_members(set(outputs), tree_files(final_dir), "COLLECT")
    else:
        outputs[final_exe.name] = digest(final_exe)
    result = {"schemaVersion": 1, "bundle": bundle, "target": "windows-x86_64", "buildTools": tools,
              "files": files, "outputs": outputs}
    destination = root / "build/pyinstaller/inventory" / (relative(bundle) + ".json")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def merge_inventories(root: Path, package: Path) -> dict:
    components, files, tools = {}, [], {}
    for bundle, prefix in (("hub", "hub"), ("launcher", "")):
        data = json.loads((root / "build/pyinstaller/inventory" / (bundle + ".json")).read_text(encoding="utf-8"))
        if data["schemaVersion"] != 1 or data["bundle"] != bundle or data["target"] != "windows-x86_64":
            raise RuntimeError("Unsupported frozen inventory")
        for name, version in data["buildTools"].items():
            if name in tools and tools[name] != version:
                raise RuntimeError("Frozen build tool versions conflict")
            tools[name] = version
        for name, expected in data["outputs"].items():
            if digest(package / prefix / relative(name)) != expected:
                raise RuntimeError("Copied frozen output differs from inventory: " + relative(name))
        if bundle == "hub":
            checked_members(set(data["outputs"]) | {"config.json"}, tree_files(package / "hub"), "copied hub")
            if digest(package / "hub/config.json") != digest(root / "hub/config.json"):
                raise RuntimeError("Copied hub configuration differs from reviewed source")
        files.extend(data["files"])
    for row in files:
        component = {k: row[k] for k in ("component", "name", "version", "role", "providedBy", "licenseExpression") if k in row}
        previous = components.setdefault(row["component"], component)
        if previous != component:
            raise RuntimeError("Frozen component identities conflict")
    result = {"schemaVersion": 1, "files": files, "buildTools": tools,
              "dependencies": {c["name"]: c["version"] for c in components.values() if c["role"] == "application"},
              "runtimeComponents": [c for c in components.values() if c["role"] not in ("application", "project")],
              "distributions": [c for c in components.values() if c["role"] in ("application", "embedded-tool-runtime")]}
    (root / "build/pyinstaller/inventory/combined.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def notice_path(path: Path, root: Path, role: str) -> Path:
    """Keep notice IO inside its resolved root without following reparse points."""
    path = path.absolute()
    try:
        for part in (path, *path.parents):
            try:
                info = part.lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise RuntimeError("Notice " + role + " reparse point refused")
        resolved = path.resolve()
        if not resolved.is_relative_to(root):
            raise RuntimeError("Notice " + role + " is outside its root")
        return resolved
    except OSError:
        raise RuntimeError("Frozen notice " + role + " unavailable") from None


def copy_distribution_notices(target: Path, inventory: dict, distributions=None) -> None:
    target = notice_path(target, target.resolve(), "destination")
    installed = {canonical(d.metadata["Name"]): d for d in (metadata.distributions() if distributions is None else distributions)}
    destinations = set()
    for component in inventory["distributions"]:
        name, version = component["name"], component["version"]
        dist = installed.get(name)
        if (dist is None or dist.version != version or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or
                not re.fullmatch(r"[A-Za-z0-9.!+_-]+", version)):
            raise RuntimeError("Notice distribution differs from frozen evidence: " + name)
        records = {str(f).replace("\\", "/"): f for f in dist.files or []}
        roots = {p.split("/", 1)[0] for p in records if p.split("/", 1)[0].endswith(".dist-info")}
        if len(roots) != 1:
            raise RuntimeError("Ambiguous distribution notice root: " + name)
        base = roots.pop()
        declared = dist.metadata.get_all("License-File") or []
        selected = []
        for value in declared:
            value = relative(value)
            choices = [p for p in (base + "/licenses/" + value, base + "/" + value) if p in records]
            if len(choices) != 1:
                raise RuntimeError("Declared notice is missing or ambiguous: " + name)
            selected.append(choices[0])
        selected.extend(p for p in records if p not in selected and
                        re.match(r"^(license|licence|copying|copyright|notice|authors)([._-]|$)", PurePosixPath(p).name, re.I))
        if not selected:
            raise RuntimeError("Frozen distribution has no recorded license text: " + name)
        install_root = Path(dist.locate_file("")).absolute()
        install_root = notice_path(install_root, install_root.resolve(), "source")
        for record in selected:
            record = relative(record)
            source = notice_path(Path(dist.locate_file(records[record])), install_root, "source")
            try:
                contents = source.read_bytes()
            except OSError:
                raise RuntimeError("Frozen notice source unavailable: " + name) from None
            if not contents:
                raise RuntimeError("Frozen distribution notice is empty: " + name)
            suffix = record[len(base) + 1:] if record.startswith(base + "/") else record
            dest = target / "python" / (name + "-" + version) / relative(suffix)
            key = dest.relative_to(target).as_posix().casefold()
            if key in destinations or dest.exists():
                raise RuntimeError("Duplicate or conflicting frozen notice destination")
            dest = notice_path(dest, target, "destination")
            destinations.add(key)
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(contents)
            except OSError:
                raise RuntimeError("Frozen notice destination unavailable: " + name) from None
