#!/usr/bin/env python3
"""NAS Sync helper. Runs on the NAS; the app and the nas-sync tool install and update it.

Layout: <state>/helper/<version>-<fingerprint>/nas-sync-helper.py, with <state>/helper/current
pointing at the active folder. Tokens are <state>/github-token-<owner>. Output is JSON.
Keep this file compatible with Python 3.8 and the standard library.
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request

HELPER_VERSION = 1
PROTOCOL = 1

MIN_PYTHON = (3, 8)
SCRIPT = os.path.realpath(__file__)
INSTALL_DIR = os.path.dirname(SCRIPT)
HELPER_ROOT = os.path.dirname(INSTALL_DIR)
STATE = os.path.dirname(HELPER_ROOT)
FOLDER_NAME = re.compile(r"^\d+-[0-9a-f]{12}$")
INCOMING_MAX_AGE = 86400

TOOL_ENV = dict(os.environ, LC_ALL="C", GIT_TERMINAL_PROMPT="0")
TOOL_ENV["PATH"] = "/usr/local/bin:/var/packages/git/target/bin:" + os.environ.get("PATH", "/usr/bin:/bin")


def fingerprint(path=SCRIPT):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def identity():
    return {"helper_version": HELPER_VERSION, "protocol": PROTOCOL, "sha256": fingerprint()}


def check_result(check_id, status, detail, expires=None):
    result = {"id": check_id, "status": status, "detail": detail}
    if expires:
        result["expires"] = expires
    return result


def tool_output(args):
    try:
        r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                           timeout=30, env=TOOL_ENV)
    except (OSError, subprocess.SubprocessError) as e:
        return None, str(e)
    text = r.stdout.strip()
    return (text if r.returncode == 0 else None), text


def check_python():
    version = ".".join(str(n) for n in sys.version_info[:3])
    return check_result("python", "ok" if sys.version_info[:2] >= MIN_PYTHON else "failed", version)


def check_tool(check_id, args):
    out, error = tool_output(args)
    if out is None:
        return check_result(check_id, "failed", error.splitlines()[0] if error else "not found")
    return check_result(check_id, "ok", out.splitlines()[0] if out else "")


def check_transport():
    paths = [TOOL_ENV["PATH"]]
    exec_path, _ = tool_output(["git", "--exec-path"])
    if exec_path:
        paths.append(exec_path)
    search = os.pathsep.join(paths)
    missing = [name for name in ("git-upload-pack", "git-receive-pack") if not shutil.which(name, path=search)]
    return check_result("git-transport", "failed" if missing else "ok", ", ".join(missing) or "found")


def expiry_iso(header):
    if not header:
        return None
    text = header.replace(" UTC", " +0000")
    try:
        when = datetime.datetime.strptime(text, "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        return None
    return when.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def check_token_online(check_id, token):
    request = urllib.request.Request("https://api.github.com/user", headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "nas-sync-helper/%d" % HELPER_VERSION,
    })
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            expires = expiry_iso(response.headers.get("github-authorization-token-expiration"))
            return check_result(check_id, "ok", "accepted", expires)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return check_result(check_id, "failed", "rejected")
        return check_result(check_id, "unknown", "GitHub answered %d" % e.code)
    except (urllib.error.URLError, OSError) as e:
        return check_result(check_id, "unknown", "couldn't reach GitHub: %s" % type(e).__name__)


def check_token(path, online):
    check_id = "token:" + os.path.basename(path)[len("github-token-"):]
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        return check_result(check_id, "failed", "readable by others")
    with open(path) as f:
        token = f.read().strip()
    if not token:
        return check_result(check_id, "failed", "empty")
    half = len(token) // 2
    if len(token) % 2 == 0 and token[:half] == token[half:]:
        return check_result(check_id, "failed", "saved twice")
    if not online:
        return check_result(check_id, "unknown", "not checked")
    return check_token_online(check_id, token)


def check_tokens(online):
    try:
        names = sorted(n for n in os.listdir(STATE) if n.startswith("github-token-"))
    except OSError:
        names = []
    if not names:
        return [check_result("tokens", "failed", "none")]
    return [check_token(os.path.join(STATE, n), online) for n in names]


def command_check(args):
    online = "--offline" not in args
    checks = [
        check_python(),
        check_tool("git", ["git", "--version"]),
        check_tool("git-lfs", ["git", "lfs", "version"]),
        check_transport(),
    ] + check_tokens(online)
    return dict(identity(), checks=checks)


def prune(keep):
    now = time.time()
    for name in os.listdir(HELPER_ROOT):
        path = os.path.join(HELPER_ROOT, name)
        old_incoming = name.startswith(".incoming-") and now - os.path.getmtime(path) > INCOMING_MAX_AGE
        old_version = FOLDER_NAME.match(name) and name not in keep
        if old_incoming or old_version:
            shutil.rmtree(path, ignore_errors=True)


def command_activate(_args):
    digest = fingerprint()
    name = "%d-%s" % (HELPER_VERSION, digest[:12])
    final = os.path.join(HELPER_ROOT, name)
    if INSTALL_DIR != final:
        existing = os.path.join(final, os.path.basename(SCRIPT))
        if os.path.isdir(final) and os.path.isfile(existing) and fingerprint(existing) == digest:
            shutil.rmtree(INSTALL_DIR)
        else:
            shutil.rmtree(final, ignore_errors=True)
            os.rename(INSTALL_DIR, final)
    link = os.path.join(HELPER_ROOT, "current")
    previous = os.readlink(link) if os.path.islink(link) else None
    temporary = os.path.join(HELPER_ROOT, ".current-%d" % os.getpid())
    os.symlink(name, temporary)
    os.replace(temporary, link)
    prune({name, previous})
    return {"active": name, "previous": previous}


COMMANDS = {
    "version": lambda _args: dict(identity(), python=".".join(str(n) for n in sys.version_info[:3])),
    "check": command_check,
    "activate": command_activate,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write("usage: nas-sync-helper %s\n" % "|".join(sorted(COMMANDS)))
        return 2
    print(json.dumps(COMMANDS[argv[1]](argv[2:]), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
