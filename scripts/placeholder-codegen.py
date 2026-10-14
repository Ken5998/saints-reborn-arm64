#!/usr/bin/env python3
"""Writes a stand-in for the code `rexglue codegen` generates from the game,
so the port can be compiled and linked without the game.

    scripts/placeholder-codegen.py SAINTS_REBORN SDK OUTDIR

SAINTS_REBORN is Saints Reborn made by prepare.sh, SDK the SDK's source tree
(for its codegen templates), OUTDIR the folder to write.

It declares and defines (with empty bodies) only the recompiled functions
Saints Reborn's own sources name, and renders the SDK's codegen header
template with made-up image addresses. The result builds and links like the
real thing but does nothing: it holds no code or data of the game, and the
executable built from it must not be run.
"""
import re
import sys
from pathlib import Path

sr, sdk, out = (Path(p) for p in sys.argv[1:4])
project = "saintsrow"
templates = sdk / "resources" / "templates"

# The functions Saints Reborn names: sub_XXXXXXXX overrides and calls, the
# register save / restore helpers (__savegprlr_N ...) its hand-translated
# code calls, and the kernel imports it replaces with PPC_FUNC_IMPL.
names, helpers, imports = set(), set(), set()
sources = []
for path in sorted((sr / "project" / "src").rglob("*")):
    if path.suffix in (".cpp", ".h", ".inc"):
        text = path.read_text(errors="replace")
        sources.append(re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S))  # not the comments

# Macros that paste an address into a name (sub_##A): the addresses they are
# invoked with.
pasting = {}  # macro -> argument positions
for text in sources:
    for m in re.finditer(r"#define (\w+)\(([^)]*)\)((?:[^\n]*\\\n)*[^\n]*)", text):
        params = [p.strip() for p in m.group(2).split(",")]
        used = [i for i, p in enumerate(params) if re.search(rf"sub_##\s*{p}\b", m.group(3))]
        if used:
            pasting[m.group(1)] = used
for text in sources:
    for macro, used in pasting.items():
        for m in re.finditer(rf"(?<!define )\b{macro}\(([^()]*)\)", text):
            args = [a.strip() for a in m.group(1).split(",")]
            names.update(f"sub_{args[i].upper()}" for i in used
                         if i < len(args) and re.fullmatch(r"[0-9A-Fa-f]{8}", args[i]))

for text in sources:
    names.update(re.findall(r"(?<![0-9A-Za-z])sub_[0-9A-F]{8}(?!\w)", text))
    helpers.update(re.findall(r"\b__(?:save|rest)(?:gprlr|fpr|vmx)_\d+\b", text))
    imports.update(re.findall(r"PPC_FUNC_IMPL\((__imp__[A-Za-z]\w*)\)", text))
names = sorted(names)
helpers = sorted(helpers)


def render(name: str, values: dict) -> str:
    """The subset of inja the codegen header templates use."""
    text = (templates / name).read_text()
    text = re.sub(r'\{% include "([^"]+)" %\}',
                  lambda m: render(m.group(1), values), text)

    def branch(m):
        key, yes, no = m.group(1), m.group(2), m.group(3) or ""
        value = values
        for part in key.split("."):
            value = value[part]
        return yes if value else no

    text = re.sub(r"\{% if ([\w.]+) %\}(.*?)(?:\{% else %\}(.*?))?\{% endif %\}",
                  branch, text, flags=re.S)
    return re.sub(r"\{\{ (\w+) \}\}", lambda m: str(values[m.group(1)]), text)


values = {
    "project": project,
    "image_base": "0x82000000", "image_size": "0x1000000",
    "code_base": "0x82100000", "code_size": "0x800000",
    "thunk_reserve_size": "0x10000",
    "rexcrt_heap": False,
    "config_flags": {k: False for k in (
        "skip_lr", "ctr_as_local", "xer_as_local", "reserved_as_local",
        "skip_msr", "cr_as_local", "non_argument_as_local", "non_volatile_as_local")},
}
out.mkdir(parents=True, exist_ok=True)
(out / f"{project}_pch.h").write_text(render("codegen/pch_h.inja", values))
(out / f"{project}_funcs.h").write_text(
    f'#pragma once\n#include "{project}_pch.h"\n\n'
    + "".join(f"DECLARE_REX_FUNC({n});\n" for n in names + helpers))
(out / f"{project}_init.h").write_text(
    f'#pragma once\n#include "{project}_pch.h"\n#include "{project}_funcs.h"\n')

imports = sorted(imports)
# Made-up addresses below the code for what has no address in its name.
fake = {f: 0x82000000 + 4 * k for k, f in enumerate(imports + helpers)}
(out / f"{project}_init.cpp").write_text(
    f'// Placeholder (scripts/placeholder-codegen.py): not the game.\n'
    f'#include "{project}_init.h"\n\n'
    + "".join(f'extern "C" REX_FUNC({i});\n' for i in imports)
    + "\nconst rex::PPCImageInfo PPCImageConfig = {\n"
    "    .code_base = REX_CODE_BASE,\n    .code_size = REX_CODE_SIZE,\n"
    "    .image_base = REX_IMAGE_BASE,\n    .image_size = REX_IMAGE_SIZE,\n"
    "    .func_mappings = PPCFuncMappings,\n    .rexcrt_heap = REXCRT_HEAP,\n};\n\n"
    "PPCFuncMapping PPCFuncMappings[] = {\n"
    + "".join(f"  {{0x{n[4:]}, {n}}},\n" for n in names)
    + "".join(f"  {{0x{fake[f]:08X}, {f}}},\n" for f in imports + helpers)
    + "  {0, nullptr}\n};\n")
(out / f"{project}_recomp.0.cpp").write_text(
    f'#include "{project}_init.h"\n\n'
    + "".join(f"DEFINE_REX_FUNC({n}) {{ (void)base; }}\n" for n in names + helpers))
(out / "sources.cmake").write_text(
    "set(GENERATED_SOURCES\n"
    + "".join(f"    ${{CMAKE_CURRENT_LIST_DIR}}/{project}_{f}.cpp\n"
              for f in ("init", "recomp.0"))
    + ")\n")
print(f"Placeholder generated code in {out}: {len(names) + len(helpers)} functions, "
      f"{len(imports)} imports")
