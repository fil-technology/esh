#!/usr/bin/env bash
set -euo pipefail

esh::die() {
  echo "error: $*" >&2
  exit 1
}

esh::common_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

esh::detect_layout() {
  local common_dir payload_root app_root
  common_dir="$(esh::common_dir)"

  if [[ -f "$common_dir/../../Package.swift" ]]; then
    ESH_LAYOUT_MODE="repo"
    ESH_APP_ROOT="$(cd "$common_dir/../.." && pwd)"
    ESH_PAYLOAD_ROOT="$ESH_APP_ROOT"
    return
  fi

  payload_root="$(cd "$common_dir/../.." && pwd)"
  app_root="$(cd "$common_dir/../../../.." && pwd)"
  if [[ -f "$payload_root/Tools/python-requirements.txt" && -x "$app_root/bin/esh" ]]; then
    ESH_LAYOUT_MODE="package"
    ESH_APP_ROOT="$app_root"
    ESH_PAYLOAD_ROOT="$payload_root"
    return
  fi

  esh::die "Unable to resolve esh layout from $common_dir"
}

esh::detect_layout

esh::repo_root() {
  [[ "$ESH_LAYOUT_MODE" == "repo" ]] || esh::die "Developer command is only available from a source checkout."
  echo "$ESH_APP_ROOT"
}

esh::payload_root() {
  echo "$ESH_PAYLOAD_ROOT"
}

esh::app_root() {
  echo "$ESH_APP_ROOT"
}

esh::requirements_file() {
  echo "$(esh::payload_root)/Tools/python-requirements.txt"
}

esh::bridge_script() {
  echo "$(esh::payload_root)/Tools/mlx_vlm_bridge.py"
}

esh::bundled_llama_cli() {
  echo "$(esh::app_root)/share/esh/bin/llama-cli"
}

esh::resolve_llama_cli() {
  local candidates=()
  [[ -n "${ESH_LLAMA_CPP_CLI:-}" ]] && candidates+=("$ESH_LLAMA_CPP_CLI")
  [[ -n "${LLAMA_CPP_CLI:-}" ]] && candidates+=("$LLAMA_CPP_CLI")
  candidates+=("/opt/homebrew/bin/llama-cli" "/usr/local/bin/llama-cli")

  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done

  if command -v llama-cli >/dev/null 2>&1; then
    command -v llama-cli
    return 0
  fi

  return 1
}

esh::package_runtime_dir() {
  echo "${ESH_PACKAGE_RUNTIME_DIR:-$HOME/.esh/runtime/python}"
}

esh::bundled_python_dir() {
  echo "$(esh::app_root)/python"
}

esh::python_works() {
  local python_path="${1:-}"
  [[ -n "$python_path" && -x "$python_path" ]] || return 1
  (
    set +e
    "$python_path" -c 'import sys' >/dev/null 2>&1
  ) 2>/dev/null
}

esh::release_python_dir() {
  if [[ "$ESH_LAYOUT_MODE" != "package" ]]; then
    esh::die "Release python directory is only available from a packaged install."
  fi

  if [[ -n "${ESH_PACKAGE_PYTHON_DIR:-}" ]]; then
    echo "$ESH_PACKAGE_PYTHON_DIR"
    return
  fi

  local bundled_dir runtime_dir
  bundled_dir="$(esh::bundled_python_dir)"
  runtime_dir="$(esh::package_runtime_dir)"

  if esh::python_works "$bundled_dir/bin/python3"; then
    ESH_PACKAGE_PYTHON_DIR="$bundled_dir"
  else
    ESH_PACKAGE_PYTHON_DIR="$runtime_dir"
  fi

  echo "$ESH_PACKAGE_PYTHON_DIR"
}

esh::dev_venv_dir() {
  echo "$(esh::repo_root)/.venv"
}

esh::python_executable() {
  if [[ "$ESH_LAYOUT_MODE" == "package" ]]; then
    echo "$(esh::release_python_dir)/bin/python3"
  else
    echo "$(esh::dev_venv_dir)/bin/python3"
  fi
}

esh::bootstrap_python() {
  if [[ -n "${ESH_BOOTSTRAP_PYTHON:-}" ]]; then
    echo "$ESH_BOOTSTRAP_PYTHON"
    return
  fi
  command -v python3 >/dev/null 2>&1 || esh::die "python3 is required for bootstrap."
  command -v python3
}

esh::swift_binary() {
  local configuration="${1:-debug}"
  if [[ "$ESH_LAYOUT_MODE" == "package" ]]; then
    echo "$(esh::app_root)/bin/esh"
  else
    echo "$(esh::repo_root)/.build/$configuration/esh"
  fi
}

esh::ensure_dev_venv() {
  [[ "$ESH_LAYOUT_MODE" == "repo" ]] || return 0
  local venv_dir
  venv_dir="$(esh::dev_venv_dir)"
  if [[ ! -x "$venv_dir/bin/python3" ]]; then
    "$(esh::bootstrap_python)" -m venv "$venv_dir"
  fi
}

esh::requirements_stamp() {
  if [[ "$ESH_LAYOUT_MODE" == "package" ]]; then
    echo "$(esh::release_python_dir)/.esh-requirements.sha256"
  else
    echo "$(esh::dev_venv_dir)/.esh-requirements.sha256"
  fi
}

esh::requirements_hash() {
  shasum -a 256 "$(esh::requirements_file)" | awk '{print $1}'
}

esh::install_python_deps() {
  local python_executable requirements_hash stamp_file current_hash
  python_executable="$(esh::python_executable)"
  stamp_file="$(esh::requirements_stamp)"
  requirements_hash="$(esh::requirements_hash)"
  current_hash=""
  if [[ -f "$stamp_file" ]]; then
    current_hash="$(cat "$stamp_file")"
  fi

  if [[ "$current_hash" == "$requirements_hash" ]]; then
    return 0
  fi

  "$python_executable" -m pip install --upgrade pip setuptools wheel
  "$python_executable" -m pip install -r "$(esh::requirements_file)"
  printf '%s' "$requirements_hash" >"$stamp_file"
}

esh::ensure_external_package_runtime() {
  local runtime_dir
  runtime_dir="$(esh::package_runtime_dir)"
  mkdir -p "$(dirname "$runtime_dir")"

  if ! esh::python_works "$runtime_dir/bin/python3"; then
    rm -rf "$runtime_dir"
    "$(esh::bootstrap_python)" -m venv "$runtime_dir"
  fi

  ESH_PACKAGE_PYTHON_DIR="$runtime_dir"
  esh::install_python_deps
}

esh::build_swift() {
  [[ "$ESH_LAYOUT_MODE" == "repo" ]] || return 0
  local configuration="${1:-debug}"
  swift build -c "$configuration" --product esh --package-path "$(esh::repo_root)"
}

esh::export_runtime_env() {
  export ESH_PYTHON="$(esh::python_executable)"
  export ESH_MLX_VLM_BRIDGE="$(esh::bridge_script)"
  export LLMCACHE_PYTHON="$ESH_PYTHON"
  export LLMCACHE_MLX_VLM_BRIDGE="$ESH_MLX_VLM_BRIDGE"
}

esh::ensure_dev_runtime() {
  local configuration="${1:-debug}"
  esh::ensure_dev_venv
  esh::install_python_deps
  esh::build_swift "$configuration"
  esh::export_runtime_env
}

esh::ensure_packaged_runtime() {
  [[ -x "$(esh::swift_binary)" ]] || esh::die "Packaged esh binary is missing."
  [[ -f "$(esh::bridge_script)" ]] || esh::die "Packaged bridge script is missing."

  if ! esh::python_works "$(esh::bundled_python_dir)/bin/python3"; then
    esh::ensure_external_package_runtime
  fi

  [[ -x "$(esh::python_executable)" ]] || esh::die "Packaged Python runtime is missing."
  esh::export_runtime_env
}

esh::prepare_runtime() {
  local configuration="${1:-debug}"
  if [[ "$ESH_LAYOUT_MODE" == "package" ]]; then
    esh::ensure_packaged_runtime
  else
    esh::ensure_dev_runtime "$configuration"
  fi
}

esh::run_cli() {
  local configuration="${ESH_BUILD_CONFIGURATION:-${LLMCACHE_BUILD_CONFIGURATION:-debug}}"
  esh::prepare_runtime "$configuration"
  exec "$(esh::swift_binary "$configuration")" "$@"
}
