#!/usr/bin/env python3
"""Apply pinned, hardened Kata/Firecracker settings to configuration-fc.toml (section-aware).

Usage: kata-harden.py <in.toml> <out.toml> <jailer_path>
"""
import re
import sys
import tomllib

src, dst, jailer = sys.argv[1], sys.argv[2], sys.argv[3]

# section -> {key: toml_literal}
SETTINGS = {
    "hypervisor.firecracker": {
        "jailer_path": f'"{jailer}"',
        "enable_annotations": "[]",
        "default_vcpus": "4",
        "default_memory": "4096",
        "enable_debug": "false",
        "entropy_source": '"/dev/urandom"',
    },
    "runtime": {
        "disable_guest_seccomp": "false",
        "sandbox_cgroup_only": "true",
        "static_sandbox_resource_mgmt": "true",
        "enable_debug": "false",
    },
    "agent.kata": {
        "debug_console_enabled": "false",
        "enable_debug": "false",
    },
    "factory": {
        "enable_template": "false",
    },
}

text = open(src).read()
lines = text.splitlines()

def section_bounds(name):
    start = None
    for i, l in enumerate(lines):
        if l.strip() == f"[{name}]":
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^\s*\[.+\]\s*$", lines[j]):
            end = j
            break
    return start, end

for section, kv in SETTINGS.items():
    start, end = section_bounds(section)
    if start is None:
        lines += ["", f"[{section}]"]
        start, end = len(lines) - 1, len(lines)
    for key, val in kv.items():
        pat = re.compile(rf"^\s*#?\s*{re.escape(key)}\s*=.*$")
        replaced = False
        for i in range(start + 1, end):
            if pat.match(lines[i]):
                lines[i] = f"{key} = {val}"
                replaced = True
                break
        if not replaced:
            lines.insert(start + 1, f"{key} = {val}")
            end += 1

out = "\n".join(lines) + "\n"
# Validate it still parses and the values landed
cfg = tomllib.loads(out)
assert cfg["hypervisor"]["firecracker"]["jailer_path"] == jailer
assert cfg["hypervisor"]["firecracker"]["enable_annotations"] == []
assert cfg["runtime"]["sandbox_cgroup_only"] is True
assert cfg["runtime"]["static_sandbox_resource_mgmt"] is True
assert cfg["runtime"]["disable_guest_seccomp"] is False
assert cfg["factory"]["enable_template"] is False
assert cfg["agent"]["kata"]["debug_console_enabled"] is False
open(dst, "w").write(out)
print(f"wrote {dst}")
