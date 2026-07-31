#!/usr/bin/env python3
"""Generate omo-npm-packages.json from bun.lock for Nix fetchurl approach.

Parses bun.lock (JSONC), extracts per-package:
- registry URL + SRI hash
- node_modules install path (from key structure)
- os/cpu constraints for platform filtering
- bin entries for .bin symlinks
- workspace/file symlink targets

Output JSON consumed by omo-senpi.nix at build time.
"""
import re, json, sys, os


def parse_jsonc(text):
    """Strip // comments (outside strings) and trailing commas."""
    result = []
    in_string = False
    escape_next = False
    i = 0
    while i < len(text):
        ch = text[i]
        if escape_next:
            result.append(ch)
            escape_next = False
            i += 1
            continue
        if ch == '\\' and in_string:
            result.append(ch)
            escape_next = True
            i += 1
            continue
        if ch == '"':
            in_string = not in_string
            result.append(ch)
            i += 1
            continue
        if not in_string and ch == '/' and i + 1 < len(text) and text[i + 1] == '/':
            while i < len(text) and text[i] != '\n':
                i += 1
            continue
        result.append(ch)
        i += 1
    cleaned = ''.join(result)
    cleaned = re.sub(r',(\s*[}\]])', r'\1', cleaned)
    return cleaned


def npm_url(identifier):
    """Convert '@scope/name@1.2.3' to npm tarball URL."""
    at_pos = identifier.rfind('@')
    if at_pos <= 0:
        return None
    name = identifier[:at_pos]
    version = identifier[at_pos + 1:]
    if name.startswith('@'):
        parts = name.split('/', 1)
        scope, pkg_name = parts[0], parts[1]
        return f"https://registry.npmjs.org/{scope}/{pkg_name}/-/{pkg_name}-{version}.tgz"
    else:
        return f"https://registry.npmjs.org/{name}/-/{name}-{version}.tgz"


def resolve_path(key, ws_name_to_path):
    """Determine node_modules install path from bun.lock key."""
    for ws_name, ws_path in ws_name_to_path.items():
        prefix = ws_name + "/"
        if key.startswith(prefix):
            rest = key[len(prefix):]
            if ws_path:
                dir_part = ws_path[len('packages/'):] if ws_path.startswith('packages/') else ws_path
                return f"packages/{dir_part}/node_modules/{rest}"
            else:
                return f"node_modules/{rest}"
    return f"node_modules/{key}"


def matches_system(os_val, cpu_val, system):
    """Check if an os/cpu constraint matches the Nix system."""
    if not os_val and not cpu_val:
        return True  # No constraint = matches everything

    system_map = {
        "x86_64-linux":   ("linux", "x64"),
        "aarch64-linux":  ("linux", "arm64"),
        "x86_64-darwin":  ("darwin", "x64"),
        "aarch64-darwin": ("darwin", "arm64"),
    }
    if system not in system_map:
        return True  # Unknown system, include everything

    target_os, target_cpu = system_map[system]

    os_match = (not os_val) or (os_val == target_os)
    cpu_match = (not cpu_val) or (cpu_val == target_cpu)

    return os_match and cpu_match


def main():
    lock_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/bun.lock'
    out_path = sys.argv[2] if len(sys.argv) > 2 else '/dev/stdout'
    target_system = sys.argv[3] if len(sys.argv) > 3 else None

    with open(lock_path) as f:
        raw = f.read()

    cleaned = parse_jsonc(raw)
    data = json.loads(cleaned)
    packages = data.get('packages', {})
    workspaces = data.get('workspaces', {})

    # Build workspace name -> path mapping
    ws_name_to_path = {}
    for ws_path, ws_info in workspaces.items():
        if isinstance(ws_info, dict) and 'name' in ws_info:
            ws_name_to_path[ws_info['name']] = ws_path

    npm_packages = {}
    workspace_symlinks = {}
    file_packages = {}

    for pkg_key, entry in packages.items():
        if not isinstance(entry, list) or len(entry) < 1:
            continue

        identifier = entry[0]
        install_path = resolve_path(pkg_key, ws_name_to_path)
        metadata = entry[2] if len(entry) >= 3 and isinstance(entry[2], dict) else {}

        # Workspace dependency
        if 'workspace:' in identifier:
            at_pos = identifier.rfind('@')
            dep_name = identifier[:at_pos] if at_pos > 0 else identifier
            ws_rel_path = identifier[at_pos+1+len('workspace:'):]
            workspace_symlinks[pkg_key] = {
                "name": dep_name,
                "installPath": install_path,
                "sourcePath": ws_rel_path,
            }
            continue

        # File dependency
        if 'file:' in identifier:
            at_pos = identifier.rfind('@')
            dep_name = identifier[:at_pos] if at_pos > 0 else identifier
            file_rel_path = identifier[at_pos+1+len('file:'):]
            file_packages[pkg_key] = {
                "name": dep_name,
                "installPath": install_path,
                "sourcePath": file_rel_path,
            }
            continue

        # npm package
        hash_val = entry[3] if len(entry) >= 4 else None
        if not isinstance(hash_val, str) or not hash_val.startswith('sha512-'):
            continue

        url = npm_url(identifier)
        if url is None:
            continue

        # Extract os/cpu constraints
        os_val = metadata.get('os')
        cpu_val = metadata.get('cpu')
        if isinstance(os_val, list):
            os_val = os_val[0] if os_val else None
        if isinstance(cpu_val, list):
            cpu_val = cpu_val[0] if cpu_val else None

        # Platform filtering
        if target_system and not matches_system(os_val, cpu_val, target_system):
            continue

        # Extract bin entries
        bin_entries = metadata.get('bin', {})

        npm_packages[pkg_key] = {
            "url": url,
            "hash": hash_val,
            "installPath": install_path,
        }
        if bin_entries:
            npm_packages[pkg_key]["bin"] = bin_entries

    result = {
        "npmPackages": npm_packages,
        "workspaceSymlinks": workspace_symlinks,
        "filePackages": file_packages,
    }

    with open(out_path, 'w') as f:
        json.dump(result, f, indent=2, sort_keys=True)

    print(f"npm: {len(npm_packages)}, ws-symlinks: {len(workspace_symlinks)}, file: {len(file_packages)}", file=sys.stderr)


if __name__ == '__main__':
    main()
