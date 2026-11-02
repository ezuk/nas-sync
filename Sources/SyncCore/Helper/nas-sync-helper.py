#!/usr/bin/env python3
"""NAS Sync helper. Runs on the NAS; the app and the nas-sync tool install and update it.

Layout: <state>/helper/<version>-<fingerprint>/nas-sync-helper.py, with <state>/helper/current
pointing at the active folder. Tokens are <state>/github-token-<owner>. <state>/manifest.json lists
the repos to back up, and <state>/last-run.json reports on the latest run. Output is JSON.
Keep this file compatible with Python 3.8 and the standard library.
"""
import datetime
import fcntl
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

HELPER_VERSION = 2
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

MANIFEST_VERSION = 1
MANIFEST = os.path.join(STATE, "manifest.json")
LAST_RUN = os.path.join(STATE, "last-run.json")
RUN_LOCK = os.path.join(STATE, "run.lock")
FETCH_TIMEOUT = 6 * 3600
QUICK_TIMEOUT = 300
# Branches and tags under these names hold work sent from a Mac. GitHub's refs never touch them.
MAC_PREFIXES = ("refs/heads/from-mac/", "refs/tags/from-mac/")
DELETED_PREFIX = "refs/deleted/"
MIRROR_STATE = "nas-sync-state.json"
# Mirrors with more than this many packs or loose objects get repacked. Nothing is dropped.
TIDY_PACKS = 30
TIDY_LOOSE = 5000


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


# Backing up repos


class RepoFailure(Exception):
    """A repo couldn't be backed up. The message is shown to the user."""


def write_json(path, value):
    temporary = "%s.%d" % (path, os.getpid())
    with open(temporary, "w") as f:
        json.dump(value, f, sort_keys=True)
    os.replace(temporary, path)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def token_file(owner):
    try:
        names = os.listdir(STATE)
    except OSError:
        return None
    for name in names:
        if name.lower() == "github-token-" + owner.lower():
            return os.path.join(STATE, name)
    return None


def repo_env(name, url):
    """Git's environment for a repo. Holds the token file's path, never the token."""
    env = dict(TOOL_ENV)
    path = token_file(name.split("/")[0]) if url.startswith("https://github.com/") else None
    if path:
        quoted = "'" + path.replace("'", "'\\''") + "'"
        credential = ('!f() { test "$1" = get && echo username=x-access-token && '
                      'echo "password=$(tr -d \'\\r\\n\' < %s)"; }; f' % quoted)
        env.update({"GIT_CONFIG_COUNT": "2",
                    "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "",
                    "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": credential})
    return env


def git(args, env, cwd=None, timeout=QUICK_TIMEOUT, stdin=None):
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, env=env, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RepoFailure("git %s timed out after %d seconds" % (args[0], timeout))
    except OSError as e:
        raise RepoFailure("couldn't run git: %s" % e)
    return r


def git_ok(args, env, cwd=None, timeout=QUICK_TIMEOUT, stdin=None, step=None):
    r = git(args, env, cwd, timeout, stdin)
    if r.returncode != 0:
        lines = [line for line in r.stderr.splitlines() if line.strip()]
        detail = next((line for line in lines if line.startswith(("fatal:", "error:"))), lines[0] if lines else "exit %d" % r.returncode)
        raise RepoFailure("%s: %s" % (step or "git " + args[0], detail))
    return r.stdout


def is_mac_ref(ref):
    return ref.startswith(MAC_PREFIXES)


def parse_refs(text):
    refs = {}
    for line in text.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and not parts[1].endswith("^{}"):
            refs[parts[1]] = parts[0]
    return refs


def github_refs(url, env):
    out = git_ok(["ls-remote", "--heads", "--tags", url], env, step="reading branches from GitHub")
    return {ref: sha for ref, sha in parse_refs(out).items() if not is_mac_ref(ref)}


def github_default_branch(url, env):
    r = git(["ls-remote", "--symref", url, "HEAD"], env)
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "ref:":
                return parts[1]
    return None


def mirror_refs(mirror, env):
    out = git_ok(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags"], env, cwd=mirror)
    return {ref: sha for ref, sha in parse_refs(out).items() if not is_mac_ref(ref)}


def all_ref_names(mirror, env):
    return set(git_ok(["for-each-ref", "--format=%(refname)"], env, cwd=mirror).splitlines())


def deleted_name(ref, day, existing):
    """refs/deleted/<day>/heads/<branch>. A taken or clashing name moves to a -2, -3... day folder."""
    rest = ref[len("refs/"):]
    name = "%s%s/%s" % (DELETED_PREFIX, day, rest)
    n = 2
    while name in existing or any(other.startswith(name + "/") or name.startswith(other + "/") for other in existing):
        name = "%s%s-%d/%s" % (DELETED_PREFIX, day, n, rest)
        n += 1
    existing.add(name)
    return name


def update_refs(mirror, env, commands):
    if commands:
        git_ok(["update-ref", "--stdin"], env, cwd=mirror, stdin="\n".join(commands) + "\n")


def refs_fingerprint(refs):
    text = "\n".join("%s %s" % (refs[ref], ref) for ref in sorted(refs))
    return hashlib.sha256(text.encode()).hexdigest()


def prepare_mirror(mirror, url, env):
    if not os.path.exists(os.path.join(mirror, "HEAD")):
        if os.path.exists(mirror) and os.listdir(mirror):
            raise RepoFailure("%s exists but isn't a git repository" % mirror)
        os.makedirs(mirror, exist_ok=True)
        git_ok(["init", "--bare", "--quiet", "."], env, cwd=mirror)
    # Git must never clean up by itself: objects only reachable from kept refs have to stay.
    git_ok(["config", "gc.auto", "0"], env, cwd=mirror)
    git_ok(["config", "core.logAllRefUpdates", "false"], env, cwd=mirror)
    git_ok(["config", "remote.origin.url", url], env, cwd=mirror)


def update_mirror(mirror, source, env, day, keep):
    """Brings the mirror up to date with GitHub, keeping whatever GitHub deleted or rewrote."""
    before = mirror_refs(mirror, env)
    existing = all_ref_names(mirror, env)
    kept, pruned, commands = [], [], []
    for ref in sorted(before):
        if ref not in source:
            if keep:
                name = deleted_name(ref, day, existing)
                commands.append("create %s %s" % (name, before[ref]))
                kept.append(name)
            else:
                pruned.append(ref)
            commands.append("delete %s %s" % (ref, before[ref]))
    # Before the fetch, so a new branch fix/x can replace a deleted branch fix.
    update_refs(mirror, env, commands)

    git_ok(["-c", "gc.auto=0", "fetch", "--quiet", "--force", "--no-write-fetch-head", "origin",
            "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
           env, cwd=mirror, timeout=FETCH_TIMEOUT, step="fetching from GitHub")

    after = mirror_refs(mirror, env)
    if keep:
        commands = []
        for ref in sorted(before):
            if ref not in source or after.get(ref) in (None, before[ref]):
                continue
            is_branch = ref.startswith("refs/heads/")
            if is_branch and git(["merge-base", "--is-ancestor", before[ref], after[ref]], env, cwd=mirror).returncode == 0:
                continue
            name = deleted_name(ref, day, existing)
            commands.append("create %s %s" % (name, before[ref]))
            kept.append(name)
        update_refs(mirror, env, commands)
    return kept, pruned


def set_head(mirror, url, env, refs):
    default = github_default_branch(url, env)
    choice = default if default in refs else None
    if not choice:
        current = git(["symbolic-ref", "-q", "HEAD"], env, cwd=mirror).stdout.strip()
        branches = sorted(ref for ref in refs if ref.startswith("refs/heads/"))
        preferred = [ref for ref in ("refs/heads/main", "refs/heads/master") if ref in refs]
        choice = current if current in refs else (preferred or branches or [None])[0]
    if choice:
        git(["symbolic-ref", "HEAD", choice], env, cwd=mirror)


def fetch_lfs(mirror, env):
    """Downloads the LFS files of every ref. Returns an error message, or None."""
    r = git(["lfs", "fetch", "--all", "origin"], env, cwd=mirror, timeout=FETCH_TIMEOUT)
    if r.returncode == 0:
        return None
    lines = [line for line in (r.stderr + r.stdout).splitlines() if line.strip()]
    return lines[-1] if lines else "git lfs fetch failed (exit %d)" % r.returncode


def tidy_mirror(mirror, env):
    counts = {}
    for line in git_ok(["count-objects", "-v"], env, cwd=mirror).splitlines():
        key, _, value = line.partition(":")
        if value.strip().isdigit():
            counts[key.strip()] = int(value)
    if counts.get("packs", 0) > TIDY_PACKS or counts.get("count", 0) > TIDY_LOOSE:
        git_ok(["-c", "gc.auto=0", "-c", "pack.threads=2", "gc", "--quiet", "--prune=never"], env, cwd=mirror, timeout=FETCH_TIMEOUT)


def folder_stats(path):
    total, files = 0, 0
    for folder, _, names in os.walk(path):
        for name in names:
            try:
                total += os.lstat(os.path.join(folder, name)).st_size
                files += 1
            except OSError:
                pass
    return total, files


def back_up_repo(entry, root, day, keep):
    name, url = entry["name"], entry["url"]
    mirror = os.path.join(root, entry["path"])
    env = repo_env(name, url)
    result = {"name": name, "action": "unchanged"}
    source = github_refs(url, env)
    is_new = not os.path.exists(os.path.join(mirror, "HEAD"))
    prepare_mirror(mirror, url, env)
    state_path = os.path.join(mirror, MIRROR_STATE)
    state = read_json(state_path, {})
    current = mirror_refs(mirror, env)

    if not source:
        if current:
            raise RepoFailure("GitHub reported no branches, but this repo had %d at the last backup. The mirror wasn't changed." % len(current))
        result["action"] = "skipped"
        result["detail"] = "empty repository, nothing to back up"
        return result

    fingerprint_now = refs_fingerprint(source)
    refs_changed = current != source
    if refs_changed:
        kept, pruned = update_mirror(mirror, source, env, day, keep)
        current = mirror_refs(mirror, env)
        result["action"] = "new" if is_new else "changed"
        if kept:
            result["kept_refs"] = kept
        if pruned:
            result["pruned_refs"] = pruned
    set_head(mirror, url, env, current)

    lfs_error = None
    if refs_changed or state.get("lfs_done_for") != fingerprint_now:
        lfs_error = fetch_lfs(mirror, env)
        state["lfs_done_for"] = None if lfs_error else fingerprint_now
        write_json(state_path, state)
    if refs_changed:
        tidy_mirror(mirror, env)
        git_ok(["fsck", "--connectivity-only", "--no-dangling", "--no-progress"], env, cwd=mirror, timeout=FETCH_TIMEOUT, step="checking the mirror")

    lfs_bytes, lfs_files = folder_stats(os.path.join(mirror, "lfs", "objects"))
    result.update(branches=sum(ref.startswith("refs/heads/") for ref in current),
                  tags=sum(ref.startswith("refs/tags/") for ref in current),
                  lfs_files=lfs_files, lfs_bytes=lfs_bytes, bytes=folder_stats(mirror)[0])
    if lfs_error:
        result["action"] = "warning"
        result["detail"] = "Git LFS files weren't all downloaded: %s" % lfs_error
    return result


def command_run(_args):
    manifest = read_json(MANIFEST)
    if not manifest:
        raise SystemExit("no manifest at %s" % MANIFEST)
    if manifest.get("version") != MANIFEST_VERSION:
        raise SystemExit("manifest version %s isn't supported" % manifest.get("version"))
    with open(RUN_LOCK, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return {"status": "already running"}
        return run_manifest(manifest)


def run_manifest(manifest):
    root = manifest["mirrors"]
    keep = manifest.get("on_remote_delete", "keep") == "keep"
    day = time.strftime("%Y-%m-%d")
    report = {"status": "running", "helper_version": HELPER_VERSION, "started": now_iso(), "total": len(manifest["repos"]), "repos": []}
    write_json(LAST_RUN, report)
    for entry in manifest["repos"]:
        started = time.time()
        report["current"] = entry["name"]
        write_json(LAST_RUN, report)
        try:
            result = back_up_repo(entry, root, day, keep)
        except RepoFailure as e:
            result = {"name": entry["name"], "action": "failed", "detail": str(e)}
        except Exception as e:  # One repo's surprise must not stop the others.
            result = {"name": entry["name"], "action": "failed", "detail": "%s: %s" % (type(e).__name__, e)}
        result["seconds"] = round(time.time() - started, 1)
        report["repos"].append(result)
    report.pop("current", None)
    report["status"] = "finished"
    report["finished"] = now_iso()
    write_json(LAST_RUN, report)
    return report


COMMANDS = {
    "version": lambda _args: dict(identity(), python=".".join(str(n) for n in sys.version_info[:3])),
    "check": command_check,
    "activate": command_activate,
    "run": command_run,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write("usage: nas-sync-helper %s\n" % "|".join(sorted(COMMANDS)))
        return 2
    print(json.dumps(COMMANDS[argv[1]](argv[2:]), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
