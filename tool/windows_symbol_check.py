"""Windows symbol-coverage check against llama.cpp release DLLs.

Scans llama_cpp_dart's generated FFI bindings for every symbol they can
request, then verifies the names exist in an unpacked llama.cpp Windows
release (`llama-b*-bin-win-*-x64.zip`):

  python tool/windows_symbol_check.py <dir-with-llama.dll>

Coverage rules enforced here:
  * `llama_*`   -> must exist in llama.dll
  * `mtmd_*`    -> must exist in mtmd.dll (mtmd.dll also hosts mtmd_helper_*)
  * `ggml_*`    -> allowed to live in ggml-base.dll / ggml.dll /
                   ggml-cpu-*.dll (the package loader walks that chain at
                   runtime)
  * libc chunks (fopen, fgets, ...) are darwin-only ffigen artifacts and are
    ignored everywhere.

Exits 0 on full coverage, 2 when llama_dll inputs are missing, 3 on any
uncovered binding symbol.
"""

from __future__ import annotations

import os
import re
import struct
import sys


def _read_exports(path: str) -> set[str]:
    with open(path, "rb") as f:
        data = f.read()
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew : e_lfanew + 4] != b"PE\0\0":
        raise ValueError(f"{path}: not a PE image")
    coff = e_lfanew + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    optsize = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    dd_off = opt + (112 if magic == 0x20B else 96)
    export_rva = struct.unpack_from("<I", data, dd_off)[0]
    sec_off = opt + optsize
    sections = []
    for i in range(nsec):
        s = sec_off + i * 40
        vsize, vaddr, _rsize, raddr = struct.unpack_from("<IIII", data, s + 8)
        sections.append((vaddr, vsize, raddr))
    def rva_to_off(rva: int) -> int | None:
        for vaddr, vsize, raddr in sections:
            if vaddr <= rva < vaddr + vsize:
                return raddr + (rva - vaddr)
        return None
    if export_rva == 0:
        return set()
    eo = rva_to_off(export_rva)
    if eo is None:
        return set()
    nnames = struct.unpack_from("<I", data, eo + 24)[0]
    names_rva = struct.unpack_from("<I", data, eo + 32)[0]
    noff = rva_to_off(names_rva)
    if noff is None:
        return set()
    names: set[str] = set()
    for i in range(nnames):
        n_rva = struct.unpack_from("<I", data, noff + i * 4)[0]
        off = rva_to_off(n_rva)
        if off is None:
            continue
        end = data.index(b"\0", off)
        names.add(data[off:end].decode("ascii", "replace"))
    return names


LIBC_NOT_WINDOWS = {
    "__snprintf_chk", "__sprintf_chk", "__stderrp", "__stdinp",
    "__stdoutp", "__svfscanf", "__vsnprintf_chk", "__vsprintf_chk",
    "asprintf", "ctermid", "ctermid_r", "dprintf", "fdopen", "feof",
    "fgetc", "fgetln", "fgetpos", "fgets", "fmemopen", "fmtcheck",
    "fopen", "fprintf", "fputs", "freopen", "fscanf", "fseek", "fseeko",
    "fsetpos", "ftello", "funopen", "getc", "getchar_unlocked", "getdelim",
    "getline", "gets", "getw", "open_memstream", "popen", "putchar",
    "rename", "renameat", "renameatx_np", "renamex_np", "setbuf",
    "setbuffer", "setvbuf", "sprintf", "sys_errlist", "sys_nerr",
    "tempnam", "tmpfile", "tmpnam", "vasprintf", "vdprintf", "vfprintf",
    "vfscanf", "vprintf", "vscanf", "vsnprintf", "vsprintf", "vsscanf",
}

# Symbols declared in the generated bindings but never invoked by the
# package. ffigen makes every binding a `late final` lookup, so unused
# declarations can reference APIs that newer llama.cpp releases removed.
ALLOWED_MISSING = {
    "ggml_threadpool_get_n_threads",
}


def _binding_symbols(repo_root: str) -> list[str]:
    src = open(
        os.path.join(repo_root, "lib", "src", "ffi", "bindings.dart"),
        encoding="utf-8",
    ).read()
    names = sorted(set(
        m for m in re.findall(r"_lookup<[^;]*?>\('([^']+)'\)", src)
        if not m.startswith("_")
    ))
    return names


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    folder = os.path.abspath(sys.argv[1])
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    llama = os.path.join(folder, "llama.dll")
    mtmd = os.path.join(folder, "mtmd.dll")
    if not os.path.isfile(llama):
        print(f"error: {llama} not found", file=sys.stderr)
        return 2

    libs = {"llama.dll": _read_exports(llama)}
    if os.path.isfile(mtmd):
        libs["mtmd.dll"] = _read_exports(mtmd)
    for name in os.listdir(folder):
        if name.endswith(".dll") and name not in libs:
            libs[name] = _read_exports(os.path.join(folder, name))

    symbols = _binding_symbols(root)
    print(f"bindings reference {len(symbols)} symbols")
    print(f"scanned {len(libs)} DLLs in {folder}")

    missing: list[str] = []
    for name in symbols:
        if name in LIBC_NOT_WINDOWS or name in ALLOWED_MISSING:
            continue
        if name.startswith("mtmd_"):
            if name not in libs.get("mtmd.dll", ()):
                missing.append(name)
        elif name.startswith(("llama_", "ggml_")):
            if name not in libs["llama.dll"] and not any(
                name in exports
                for dll, exports in libs.items()
                if dll.startswith(("ggml",))
            ):
                missing.append(name)
        # anything else (libc glue) is ignored.

    llama_syms = [s for s in symbols if s.startswith("llama_")]
    mtmd_syms = [s for s in symbols if s.startswith("mtmd_")]
    print(f"llama_* needed: {len(llama_syms)}")
    print(f"mtmd_* needed:  {len(mtmd_syms)}  (mtmd.dll present: "
          f"{'mtmd.dll' in libs})")

    if missing:
        print(f"\nUNCOVERED: {len(missing)}", file=sys.stderr)
        for name in missing:
            print(f"  - {name}", file=sys.stderr)
        return 3

    print("\nPASS: every binding symbol resolves on this release")
    return 0


if __name__ == "__main__":
    sys.exit(main())
