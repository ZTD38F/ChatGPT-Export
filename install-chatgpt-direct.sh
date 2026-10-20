#!/usr/bin/env bash
# Public one-command installer for ChatGPT Direct Toolkit.
set -Eeuo pipefail
umask 077
if [[ -z "$(printenv HOME 2>/dev/null || true)" ]];then
  HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
  export HOME
fi
[[ -n "$HOME" ]] || { echo 'Could not determine the home directory' >&2; exit 1; }

REPO='ZTD38F/chatgpt-state-orchestrator'
BRANCH='main'
XDG_HOME="$(printenv XDG_DATA_HOME 2>/dev/null || true)"
APP_HOME="$HOME/.local/share/chatgpt-direct"
if [[ -n "$XDG_HOME" ]]; then APP_HOME="$XDG_HOME/chatgpt-direct"; fi

notice(){ printf '[ChatGPT Direct] %s\n' "$*"; }
die(){ printf '[ChatGPT Direct] ERROR: %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
as_root(){
 if [[ "$(id -u)" -eq 0 ]];then "$@"
 elif have sudo;then sudo "$@"
 else die 'sudo is required to install missing system dependencies.'
 fi
}
packages(){
 if have apt-get;then
   as_root apt-get update
   as_root apt-get install -y "$@"
 elif have dnf;then as_root dnf install -y "$@"
 elif have pacman;then as_root pacman -Sy --noconfirm "$@"
 elif have apk;then as_root apk add "$@"
 else die 'Unsupported distro: install GitHub CLI (gh), Python 3.10+ and venv first.'
 fi
}
python_ok(){ have python3 && python3 -c 'import sys;sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; }
[[ "$(uname -s)" == 'Linux' ]] || die 'This command is for Linux only.'
if [[ "$*" == '--dry-run' ]];then
 notice "Dry-run: private repo $REPO, install $APP_HOME"
 notice 'Install requires Python 3.10+, GitHub CLI, browser login and owner-granted repository access.'
 exit 0
fi
[[ "$#" == 0 ]] || die 'Unknown installer arguments.'
if ! python_ok;then
 notice 'Installing Python automatically...'
 if have apt-get;then packages python3 python3-venv python3-pip
 elif have dnf;then packages python3 python3-pip
 elif have pacman;then packages python python-pip
 elif have apk;then packages python3 py3-pip
 else die 'Please install Python >=3.10 via your distro.'
 fi
fi
python_ok || die 'Python 3.10+ is missing.'
if ! have gh;then notice 'Installing GitHub CLI automatically...';packages gh;fi
have gh || die 'GitHub CLI still missing.'
if ! gh auth status --hostname github.com >/dev/null 2>&1;then
 notice 'Opening GitHub authorization. This uses your account, never a pasted token.'
 [[ -r /dev/tty ]] || die 'Interactive terminal required for first GitHub authorization.'
 gh auth login --hostname github.com --git-protocol https --web --scopes repo </dev/tty
fi
if ! gh api "repos/$REPO" --jq .private >/dev/null 2>&1;then
 die "GitHub access denied for $REPO. Ask the owner for collaborator access or refresh scope with gh auth refresh -s repo."
fi
TMP="$(mktemp -d "/tmp/chatgpt-direct.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export CHATGPT_DIRECT_TMP="$TMP" CHATGPT_DIRECT_REPO="$REPO" CHATGPT_DIRECT_BRANCH="$BRANCH"
notice 'Downloading private package using your GitHub authorization...'
python3 - <<'PY'
import os,pathlib,subprocess,urllib.request,urllib.error,urllib.parse,zipfile,shutil,stat
root=pathlib.Path(os.environ["CHATGPT_DIRECT_TMP"])
repo=os.environ["CHATGPT_DIRECT_REPO"]
branch=os.environ["CHATGPT_DIRECT_BRANCH"]
token=subprocess.check_output(["gh","auth","token"],text=True).strip()
if not token:raise SystemExit("No GitHub authorization token")
class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        next_req=super().redirect_request(req,fp,code,msg,headers,newurl)
        if next_req and urllib.parse.urlparse(req.full_url).hostname!=urllib.parse.urlparse(newurl).hostname:
            next_req.remove_header("Authorization")
        return next_req
url=f"https://api.github.com/repos/{repo}/zipball/{branch}"
req=urllib.request.Request(url,headers={"Authorization":"Bearer "+token,
 "Accept":"application/vnd.github+json","User-Agent":"ChatGPTDirectBootstrap/1.0"})
try:
    with urllib.request.build_opener(SafeRedirect).open(req,timeout=90) as response:
        with (root/"source.zip").open("wb") as output:shutil.copyfileobj(response,output)
except urllib.error.HTTPError as e:
    raise SystemExit(f"GitHub HTTP {e.code}: confirm access to {repo}; use gh auth refresh -s repo if needed")
out=root/"package"
with zipfile.ZipFile(root/"source.zip") as z:
    members=z.infolist()
    roots={m.filename.split("/",1)[0] for m in members if "/" in m.filename}
    if len(roots)!=1:raise SystemExit("Unexpected private GitHub archive layout")
    prefix=next(iter(roots))+"/integrations/chatgpt-direct/"
    found=False
    for member in members:
        if not member.filename.startswith(prefix):continue
        sub=member.filename[len(prefix):]
        if not sub or member.is_dir():continue
        path=pathlib.PurePosixPath(sub)
        if path.is_absolute() or ".." in path.parts or (member.external_attr>>16)&0o170000==stat.S_IFLNK:
            raise SystemExit("Unexpected path in private GitHub archive")
        dest=out.joinpath(*path.parts)
        dest.parent.mkdir(parents=True,exist_ok=True)
        with z.open(member) as source,dest.open("wb") as target:shutil.copyfileobj(source,target)
        found=True
    if not found or not (out/"pyproject.toml").is_file():
        raise SystemExit("Private repository has no integrations/chatgpt-direct")
print("Verified package layout; ready to install.")
PY
mkdir -p "$APP_HOME"
chmod 700 "$APP_HOME"
if [[ ! -x "$APP_HOME/venv/bin/python" ]];then
 notice 'Creating isolated Python environment...'
 if ! python3 -m venv "$APP_HOME/venv";then
    if have apt-get;then packages python3-venv;python3 -m venv "$APP_HOME/venv"
    else die 'Python venv unavailable; install python3-venv from your package manager.'
    fi
 fi
fi
notice 'Installing Python package and browser automatically...'
"$APP_HOME/venv/bin/python" -m pip install --disable-pip-version-check --upgrade --force-reinstall "$TMP/package"
"$APP_HOME/venv/bin/python" -m playwright install chromium
notice "Installed successfully: $APP_HOME"
DISPLAY_STATE="$(printenv DISPLAY 2>/dev/null || true)"
WAYLAND_STATE="$(printenv WAYLAND_DISPLAY 2>/dev/null || true)"
if [[ -n "$DISPLAY_STATE" || -n "$WAYLAND_STATE" ]];then
 notice 'Launching ChatGPT browser for user authorization...'
 if [[ -r /dev/tty ]];then
   "$APP_HOME/venv/bin/python" -m chatgpt_direct.cli login </dev/tty
 else
   notice "No interactive input: launch later with $APP_HOME/venv/bin/chatgpt-direct login"
 fi
else
 notice 'Headless Linux detected: sign in via an authenticated local Chrome/CDP session.'
 notice 'Example: CHATGPT_CDP_URL=http://127.0.0.1:9222 ~/.local/share/chatgpt-direct/venv/bin/chatgpt-direct doctor'
fi
notice "Ready. CLI: $APP_HOME/venv/bin/chatgpt-direct"
notice 'Rerun this one-line command to update. No chat is ever deleted by installer.'
