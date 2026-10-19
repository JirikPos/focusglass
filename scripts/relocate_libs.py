#!/usr/bin/env python3
"""Přibalí dynamické knihovny programů do jedné složky a přepíše cesty, aby fungovaly bez Homebrew.

    relocate_libs.py <složka-s-programy> <složka-pro-knihovny>

Programy se hledají ve <složka-s-programy> (bin/), knihovny skončí v <složka-pro-knihovny> (lib/).
Programy odkazují na `@executable_path/../lib/x.dylib`, knihovny mezi sebou na `@loader_path/x.dylib`.
Systémové knihovny (/usr/lib, /System) se nechávají.
"""
import os
import re
import shutil
import subprocess
import sys

SYSTEM = ("/usr/lib/", "/System/", "/Library/")
SEARCH = ["/opt/homebrew/lib", "/usr/local/lib"]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def deps_of(path):
    """Závislosti souboru bez jeho vlastního install name."""
    lines = run("otool", "-L", path).splitlines()[1:]
    own = None
    if path.endswith(".dylib"):
        out = run("otool", "-D", path).splitlines()
        own = out[1].strip() if len(out) > 1 else None
    result = []
    for line in lines:
        name = line.strip().split(" (")[0]
        if name and name != own:
            result.append(name)
    return result


def rpaths_of(path):
    paths, lines = [], run("otool", "-l", path).splitlines()
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            m = re.match(r"\s*path (.+) \(offset", lines[i + 2])
            if m:
                paths.append(m.group(1))
    return paths


def resolve(dep, origin_dir, rpaths):
    """Skutečná cesta knihovny na disku, nebo None."""
    candidates = []
    if dep.startswith("@rpath/") or dep.startswith("@loader_path/") or dep.startswith("@executable_path/"):
        tail = dep.split("/", 1)[1]
        if dep.startswith("@loader_path/") or dep.startswith("@executable_path/"):
            candidates.append(os.path.join(origin_dir, tail))
        for rp in rpaths:
            rp = rp.replace("@loader_path", origin_dir).replace("@executable_path", origin_dir)
            candidates.append(os.path.join(rp, tail))
        for base in SEARCH:
            candidates.append(os.path.join(base, tail))
        opt = "/opt/homebrew/opt"
        if os.path.isdir(opt):
            for pkg in sorted(os.listdir(opt)):
                candidates.append(os.path.join(opt, pkg, "lib", tail))
    else:
        candidates.append(dep)
    for c in candidates:
        if os.path.exists(c):
            return os.path.realpath(c)
    return None


def main():
    bin_dir, lib_dir = (os.path.abspath(p) for p in sys.argv[1:3])
    os.makedirs(lib_dir, exist_ok=True)
    # Zdroj → cíl v lib/ (podle skutečné cesty, ať se nic nekopíruje dvakrát).
    copied = {}
    # Fronta: (cesta v balíčku, kde soubor původně ležel, je to program?)
    queue = [(os.path.join(bin_dir, f), os.path.dirname(os.path.realpath(shutil.which(f) or os.path.join(bin_dir, f))), True)
             for f in sorted(os.listdir(bin_dir))]
    while queue:
        path, origin, is_tool = queue.pop(0)
        rpaths = rpaths_of(path)
        for dep in deps_of(path):
            if dep.startswith(SYSTEM):
                continue
            real = resolve(dep, origin, rpaths)
            if real is None:
                sys.exit(f"! Knihovna {dep} (z {os.path.basename(path)}) nenalezena")
            name = os.path.basename(dep) if not dep.startswith("@rpath/") else os.path.basename(dep)
            if real not in copied:
                target = os.path.join(lib_dir, name)
                shutil.copyfile(real, target)
                os.chmod(target, 0o755)
                copied[real] = target
                queue.append((target, os.path.dirname(real), False))
            new = ("@executable_path/../lib/" if is_tool else "@loader_path/") + os.path.basename(copied[real])
            subprocess.run(["install_name_tool", "-change", dep, new, path], check=True, capture_output=True)
        if not is_tool:
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + os.path.basename(path), path], check=True, capture_output=True)
    print(f"✓ Přibaleno knihoven: {len(copied)}")


if __name__ == "__main__":
    main()
