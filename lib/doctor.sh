# shellcheck shell=bash
# airlock doctor — verify workspace invariants and host prerequisites (§7).
#
# Reports everything it checks, not only what is wrong: a doctor that prints
# nothing on a healthy workspace leaves you unsure it looked.

doctor_usage() {
  cat <<'EOF'
usage: airlock doctor [<name>] [--fix]

  <name>    workspace to check (default: every workspace, plus host prerequisites)
  --fix     repair what is safely repairable; never touches a tamper finding
EOF
}

DOCTOR_OK=0
DOCTOR_FIXED=0
DOCTOR_WARN=0
DOCTOR_FAIL=0

ck_ok()    { DOCTOR_OK=$((DOCTOR_OK + 1));       printf '  ok      %s\n' "$*"; }
ck_fixed() { DOCTOR_FIXED=$((DOCTOR_FIXED + 1)); printf '  fixed   %s\n' "$*"; }
ck_warn()  { DOCTOR_WARN=$((DOCTOR_WARN + 1));   printf '  warn    %s\n' "$*"; }
ck_fail()  { DOCTOR_FAIL=$((DOCTOR_FAIL + 1));   printf '  FAIL    %s\n' "$*"; }

# A repairable finding: applies the fix under --fix, otherwise reports what
# would be done. Everything safely repairable goes through here so that the
# dry-run and the repair can never describe different things.
ck_repair() { # fix_enabled label fix_cmd...
  local fix="$1" label="$2"; shift 2
  if [ "$fix" = "1" ]; then
    if "$@" >/dev/null 2>&1; then ck_fixed "$label"; else ck_fail "$label (repair failed)"; fi
  else
    ck_fail "$label — repairable with --fix"
  fi
}

# --- host ----------------------------------------------------------------

doctor_host() {
  printf 'host\n'
  if command -v git >/dev/null 2>&1; then
    ck_ok "git $(git --version | awk '{print $3}')"
  else
    ck_fail "git is not on PATH"
  fi

  # The substrate needs KVM and Nix to launch anything. Neither is needed by
  # init or doctor themselves, so a missing one is a warning here, not a
  # failure: the workspace is fine, the host just cannot run it yet.
  if [ -e /dev/kvm ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
      ck_ok "/dev/kvm is readable and writable"
    else
      ck_warn "/dev/kvm exists but is not readable/writable by this user — add yourself to the kvm group"
    fi
  else
    ck_warn "/dev/kvm is missing — this host cannot run a VM (no KVM, or a nested-virt guest)"
  fi

  if command -v nix >/dev/null 2>&1; then
    ck_ok "nix $(nix --version 2>/dev/null | awk '{print $3}')"
  else
    ck_warn "nix is not on PATH — needed to build and launch the guest"
  fi
}

# --- workspace -----------------------------------------------------------

doctor_workspace() { # name fix_enabled
  local name="$1" fix="$2"
  local root work_dir agent_home config project flavor branch upstream hub clone ctx
  root="$(workspace_root "$name")"
  [ -d "$root" ] || die "no such workspace: $name"

  printf 'workspace %s (%s)\n' "$name" "$root"

  work_dir="$root/work_dir"
  agent_home="$root/agent_home"
  config="$root/config"

  # --- config, first: everything below is interpreted through it ---
  if [ -f "$config" ]; then
    ck_ok "config present"
  else
    ck_fail "config is missing — cannot verify the rest without it"
    return
  fi
  project="$(config_get "$config" project)"
  flavor="$(config_get "$config" flavor claude)"
  branch="$(config_get "$config" default_branch)"
  upstream="$(config_get "$config" upstream upstream)"
  [ -n "$project" ] || { ck_fail "config declares no project"; return; }
  flavor_row "$flavor" >/dev/null 2>&1 || ck_fail "config declares an unknown flavor: $flavor"

  hub="$work_dir/$project.git"
  clone="$work_dir/$project"
  ctx="$work_dir/$(flavor_context_file "$flavor")"

  # --- layout (§4) ---
  if [ -L "$work_dir" ]; then
    ck_fail "work_dir is a symlink — the share must be a real directory"
  elif [ -d "$work_dir" ]; then
    ck_ok "work_dir is a real directory"
  else
    ck_fail "work_dir is missing"
  fi

  # A symlinked agent_home sends the substrate's -cri and -store disks next to
  # the link target instead of into the workspace, because it derives both from
  # realpath(AGENT_HOME) by string suffix. Not auto-repairable: the right
  # recovery depends on what is already at the target.
  if [ -L "$agent_home" ]; then
    ck_fail "agent_home is a symlink — the substrate realpath()s it, so its -cri/-store disks would land outside the workspace"
  elif [ -d "$agent_home" ]; then
    ck_ok "agent_home is a real directory"
  else
    ck_repair "$fix" "agent_home is missing" mkdir -p "$agent_home"
  fi

  if [ -d "$root/watermarks" ]; then
    ck_ok "watermarks/ present"
  else
    ck_repair "$fix" "watermarks/ is missing" mkdir -p "$root/watermarks"
  fi

  # Private state inside work_dir would be readable *and writable* by the
  # guest, which is exactly what D16's tamper-evidence depends on not being
  # true. Never auto-moved: a file here may be the real one.
  local stray stray_found=0
  for stray in config watermarks lock; do
    if [ -e "$work_dir/$stray" ]; then
      ck_fail "work_dir/$stray is inside the share — airlock state must live in the unmounted root"
      stray_found=1
    fi
  done
  [ "$stray_found" = "1" ] || ck_ok "no airlock state inside the share"

  # --- hub ---
  if [ -d "$hub" ] && [ "$(git -C "$hub" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
    ck_ok "hub is a bare repository"
  else
    ck_fail "hub is missing or not bare: $hub"
    return
  fi

  local head_ref
  head_ref="$(git -C "$hub" symbolic-ref --quiet HEAD || true)"
  if [ -z "$head_ref" ]; then
    ck_fail "hub HEAD is detached"
  elif git -C "$hub" rev-parse --verify --quiet "$head_ref" >/dev/null; then
    ck_ok "hub HEAD -> $head_ref"
  elif [ -n "$branch" ] && git -C "$hub" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    # The failure mode init exists to prevent: HEAD naming a branch that is not
    # there leaves every fresh clone with no checkout at all.
    ck_repair "$fix" "hub HEAD points at $head_ref, which does not exist" \
      git -C "$hub" symbolic-ref HEAD "refs/heads/$branch"
  else
    ck_fail "hub HEAD points at $head_ref, which does not exist, and config's default_branch ($branch) is missing too"
  fi

  local guard
  for guard in receive.denyNonFastForwards receive.denyDeletes; do
    if [ "$(git -C "$hub" config --get "$guard" 2>/dev/null)" = "true" ]; then
      ck_ok "hub $guard=true"
    else
      ck_repair "$fix" "hub $guard is not true" git -C "$hub" config "$guard" true
    fi
  done

  # --- hub upstreams (D8) ---
  local r want
  for r in $(git -C "$hub" remote 2>/dev/null); do
    want="+refs/heads/*:refs/upstream/$r/*"
    if [ "$(git -C "$hub" config --get "remote.$r.fetch" 2>/dev/null)" = "$want" ]; then
      ck_ok "hub remote '$r' fetches into refs/upstream/$r/*"
    else
      ck_repair "$fix" "hub remote '$r' has the wrong fetch refspec" \
        git -C "$hub" config "remote.$r.fetch" "$want"
    fi
  done
  [ -n "$(git -C "$hub" remote 2>/dev/null)" ] || ck_ok "hub has no upstream remotes configured"
  [ "$upstream" = "$upstream" ] || true   # config's upstream name is advisory

  # --- clone ---
  if is_git_repo "$clone"; then
    ck_ok "clone present"
  else
    ck_fail "clone is missing or not a git repository: $clone"
    return
  fi

  local want_origin
  want_origin="/work/$project.git"
  if [ "$(git -C "$clone" remote get-url origin 2>/dev/null)" = "$want_origin" ]; then
    ck_ok "clone origin is the guest path ($want_origin)"
  else
    ck_repair "$fix" "clone origin is not the guest path ($want_origin)" \
      git -C "$clone" remote set-url origin "$want_origin"
  fi

  if git -C "$clone" config --get-all remote.origin.fetch 2>/dev/null \
      | grep -qF '+refs/upstream/*:refs/remotes/upstreams/*'; then
    ck_ok "clone maps upstream refs read-only"
  else
    ck_repair "$fix" "clone is missing the upstream fetch refspec" \
      git -C "$clone" config --add remote.origin.fetch '+refs/upstream/*:refs/remotes/upstreams/*'
  fi

  # The identity is written into the clone's git config at init, so editing the
  # workspace config afterwards leaves the two disagreeing. `config` edits text
  # only and points here; this is what notices.
  local uname uemail clone_name clone_email
  uname="$(config_get "$config" user_name)"
  uemail="$(config_get "$config" user_email)"
  clone_name="$(git -C "$clone" config --get user.name 2>/dev/null || true)"
  clone_email="$(git -C "$clone" config --get user.email 2>/dev/null || true)"
  if [ -z "$clone_email" ] && [ -z "$uemail" ]; then
    ck_fail "clone has no commit identity and config declares none"
  elif [ -z "$uemail" ] && [ -z "$uname" ]; then
    ck_ok "clone commits as $clone_name <$clone_email> (config declares none)"
  elif [ "$clone_name" = "$uname" ] && [ "$clone_email" = "$uemail" ]; then
    ck_ok "clone commits as the config says ($uname <$uemail>)"
  else
    ck_repair "$fix" \
      "clone commits as $clone_name <$clone_email>, config says $uname <$uemail>" \
      doctor_set_identity "$clone" "$uname" "$uemail"
  fi

  # --- emitted context file (D14) ---
  if [ -f "$ctx" ]; then
    ck_ok "context file present ($(basename "$ctx"))"
  else
    ck_repair "$fix" "context file $(basename "$ctx") is missing" \
      write_context_file "$ctx" "$project"
  fi

  # A flavor changed after init leaves the previous flavor's context file in the
  # share, where the agent will read it alongside the right one.
  local other stale_ctx
  for other in claude gemini codex pi; do
    [ "$other" != "$flavor" ] || continue
    stale_ctx="$work_dir/$(flavor_context_file "$other")"
    [ "$stale_ctx" != "$ctx" ] || continue
    [ -f "$stale_ctx" ] || continue
    ck_repair "$fix" \
      "$(basename "$stale_ctx") is left over from another flavor and is still in the share" \
      rm -f "$stale_ctx"
  done

  # --- watermarks: the security-relevant check (D16/D17) ---
  doctor_watermarks "$root" "$hub"

  # --- run leftovers ---
  local lock
  lock="$(lock_file "$root")"
  if lock_is_live "$lock"; then
    ck_ok "a run holds the lock (pid $(head -1 "$lock"))"
  elif [ -f "$lock" ]; then
    ck_repair "$fix" "stale lock from a run that is no longer alive" rm -f "$lock"
  else
    ck_ok "no lock held"
  fi

  # The writable store disk is per-run and removed on exit, so finding one with
  # no live run means the last run died rather than finished.
  if [ -d "$root/agent_home-store" ] && ! lock_is_live "$lock"; then
    ck_warn "agent_home-store/ left behind by a run that did not exit cleanly — safe to delete"
  fi

  doctor_daemons "$name"
}

doctor_watermarks() { # root hub
  local root="$1" hub="$2" wm ref sha count=0 bad=0
  [ -d "$root/watermarks" ] || return 0
  while IFS= read -r wm; do
    count=$((count + 1))
    ref="${wm#"$root/watermarks/"}"
    sha="$(head -1 "$wm" 2>/dev/null || true)"
    if [ -z "$sha" ]; then
      ck_fail "watermark $ref is empty"
      bad=1
    elif ! git -C "$hub" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      # Loudly, and never repaired: under D17 the agent can rewrite hub refs
      # directly, and a reviewed commit that is gone is the evidence.
      ck_fail "TAMPER: watermarked commit $sha ($ref) is no longer in the hub — history was rewritten or pruned"
      bad=1
    elif [ -z "$(git -C "$hub" for-each-ref --contains "$sha" --count=1 2>/dev/null)" ]; then
      ck_fail "TAMPER: watermarked commit $sha ($ref) is unreachable from every hub ref — history was rewritten"
      bad=1
    fi
  done < <(find "$root/watermarks" -type f 2>/dev/null)
  if [ "$count" = "0" ]; then
    ck_ok "no watermarks recorded yet"
  elif [ "$bad" = "0" ]; then
    ck_ok "$count watermarked commit(s) still reachable in the hub"
  fi
}

# Best effort: the substrate names its per-instance daemons after the shared
# directory, and they are supposed to be cleaned up when the VM exits.
doctor_daemons() { # name
  local name="$1" units
  command -v systemctl >/dev/null 2>&1 || return 0
  units="$(systemctl --user list-units --no-legend --plain 'work_dir-*-vm-virtiofsd-*' 2>/dev/null || true)"
  if [ -n "$units" ]; then
    ck_warn "virtiofsd units still running for $name — the VM may not have exited cleanly"
  fi
}

cmd_doctor() {
  local name="" fix=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) doctor_usage; return 0 ;;
      --fix)     fix=1; shift ;;
      -*)        die "unknown option: $1" ;;
      *)         [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done

  if [ -n "$name" ]; then
    validate_workspace_name "$name"
    doctor_workspace "$name" "$fix"
  else
    doctor_host
    local dh ws
    dh="$(data_home)"
    if [ -d "$dh" ]; then
      for ws in "$dh"/*/; do
        [ -d "$ws" ] || continue
        printf '\n'
        doctor_workspace "$(basename "$ws")" "$fix"
      done
    fi
  fi

  printf '\n%d ok, %d fixed, %d warning(s), %d failure(s)\n' \
    "$DOCTOR_OK" "$DOCTOR_FIXED" "$DOCTOR_WARN" "$DOCTOR_FAIL"
  [ "$DOCTOR_FAIL" -eq 0 ]
}

# Both halves at once: ck_repair takes a single command, and an identity is two.
doctor_set_identity() { # clone name email
  git -C "$1" config user.name "${2:-airlock agent}" \
    && git -C "$1" config user.email "${3:-agent@airlock.invalid}"
}
