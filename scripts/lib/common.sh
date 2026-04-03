#!/usr/bin/env bash
set -euo pipefail

llmcache::die() {
  echo "error: $*" >&2
  exit 1
}

llmcache::common_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

llmcache::detect_layout() {
  local common_dir payload_root app_root
  common_dir="$(llmcache::common_dir)"

  if [[ -f "$common_dir/../../Package.swift" ]]; then
    LLMCACHE_LAYOUT_MODE="repo"
    LLMCACHE_APP_ROOT="$(cd "$common_dir/../.." && pwd)"
    LLMCACHE_PAYLOAD_ROOT="$LLMCACHE_APP_ROOT"
    return
  fi

  payload_root="$(cd "$common_dir/../.." && pwd)"
  app_root="$(cd "$common_dir/../../../.." && pwd)"
  if [[ -f "$payload_root/Tools/python-requirements.txt" && -x "$app_root/bin/llmcache" ]]; then
    LLMCACHE_LAYOUT_MODE="package"
    LLMCACHE_APP_ROOT="$app_root"
    LLMCACHE_PAYLOAD_ROOT="$payload_root"
    return
  fi

  llmcache::die "Unable to resolve llmcache layout from $common_dir"
}

llmcache::detect_layout

llmcache::repo_root() {
  [[ "$LLMCACHE_LAYOUT_MODE" == "repo" ]] || llmcache::die "Developer command is only available from a source checkout."
  echo "$LLMCACHE_APP_ROOT"
}

llmcache::payload_root() {
  echo "$LLMCACHE_PAYLOAD_ROOT"
}

llmcache::app_root() {
  echo "$LLMCACHE_APP_ROOT"
}

llmcache::requirements_file() {
  echo "$(llmcache::payload_root)/Tools/python-requirements.txt"
}

llmcache::bridge_script() {
  echo "$(llmcache::payload_root)/Tools/mlx_vlm_bridge.py"
}

llmcache::dev_venv_dir() {
  echo "$(llmcache::repo_root)/.venv"
}

llmcache::release_python_dir() {
  echo "$(llmcache::app_root)/python"
}

llmcache::python_executable() {
  if [[ "$LLMCACHE_LAYOUT_MODE" == "package" ]]; then
    echo "$(llmcache::release_python_dir)/bin/python3"
  else
    echo "$(llmcache::dev_venv_dir)/bin/python3"
  fi
}

llmcache::bootstrap_python() {
  if [[ -n "${LLMCACHE_BOOTSTRAP_PYTHON:-}" ]]; then
    echo "$LLMCACHE_BOOTSTRAP_PYTHON"
    return
  fi
  command -v python3 >/dev/null 2>&1 || llmcache::die "python3 is required for bootstrap."
  command -v python3
}

llmcache::swift_binary() {
  local configuration="${1:-debug}"
  if [[ "$LLMCACHE_LAYOUT_MODE" == "package" ]]; then
    echo "$(llmcache::app_root)/bin/llmcache"
  else
    echo "$(llmcache::repo_root)/.build/$configuration/llmcache"
  fi
}

llmcache::ensure_dev_venv() {
  [[ "$LLMCACHE_LAYOUT_MODE" == "repo" ]] || return 0
  local venv_dir
  venv_dir="$(llmcache::dev_venv_dir)"
  if [[ ! -x "$venv_dir/bin/python3" ]]; then
    "$(llmcache::bootstrap_python)" -m venv "$venv_dir"
  fi
}

llmcache::requirements_stamp() {
  if [[ "$LLMCACHE_LAYOUT_MODE" == "package" ]]; then
    echo "$(llmcache::release_python_dir)/.llmcache-requirements.sha256"
  else
    echo "$(llmcache::dev_venv_dir)/.llmcache-requirements.sha256"
  fi
}

llmcache::requirements_hash() {
  shasum -a 256 "$(llmcache::requirements_file)" | awk '{print $1}'
}

llmcache::install_python_deps() {
  local python_executable requirements_hash stamp_file current_hash
  python_executable="$(llmcache::python_executable)"
  stamp_file="$(llmcache::requirements_stamp)"
  requirements_hash="$(llmcache::requirements_hash)"
  current_hash=""
  if [[ -f "$stamp_file" ]]; then
    current_hash="$(cat "$stamp_file")"
  fi

  if [[ "$current_hash" == "$requirements_hash" ]]; then
    return 0
  fi

  "$python_executable" -m pip install --upgrade pip setuptools wheel
  "$python_executable" -m pip install -r "$(llmcache::requirements_file)"
  printf '%s' "$requirements_hash" >"$stamp_file"
}

llmcache::build_swift() {
  [[ "$LLMCACHE_LAYOUT_MODE" == "repo" ]] || return 0
  local configuration="${1:-debug}"
  swift build -c "$configuration" --product llmcache --package-path "$(llmcache::repo_root)"
}

llmcache::export_runtime_env() {
  export LLMCACHE_PYTHON="$(llmcache::python_executable)"
  export LLMCACHE_MLX_VLM_BRIDGE="$(llmcache::bridge_script)"
}

llmcache::ensure_dev_runtime() {
  local configuration="${1:-debug}"
  llmcache::ensure_dev_venv
  llmcache::install_python_deps
  llmcache::build_swift "$configuration"
  llmcache::export_runtime_env
}

llmcache::ensure_packaged_runtime() {
  [[ -x "$(llmcache::python_executable)" ]] || llmcache::die "Packaged Python runtime is missing."
  [[ -x "$(llmcache::swift_binary)" ]] || llmcache::die "Packaged llmcache binary is missing."
  [[ -f "$(llmcache::bridge_script)" ]] || llmcache::die "Packaged bridge script is missing."
  llmcache::export_runtime_env
}

llmcache::prepare_runtime() {
  local configuration="${1:-debug}"
  if [[ "$LLMCACHE_LAYOUT_MODE" == "package" ]]; then
    llmcache::ensure_packaged_runtime
  else
    llmcache::ensure_dev_runtime "$configuration"
  fi
}

llmcache::run_cli() {
  local configuration="${LLMCACHE_BUILD_CONFIGURATION:-debug}"
  llmcache::prepare_runtime "$configuration"
  exec "$(llmcache::swift_binary "$configuration")" "$@"
}
