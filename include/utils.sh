#!/usr/bin/env bash
# Armored Turtle Automated Filament Changer
#
# Copyright (C) 2024 Armored Turtle
#
# This file may be distributed under the terms of the GNU GPLv3 license.

pushd() {
  command pushd "$@" >/dev/null
}

popd() {
  command popd >/dev/null
}

function show_help() {
  echo "Usage: afc-mgmt.sh [options]"
  echo ""
  echo "Options:"
  echo "  -k <path>                   Specify the path to the Klipper directory"
  echo "  -m <moonraker config path>  Specify the path to the Moonraker config file (default: ~/printer_data/config/moonraker.conf)"
  echo "  -s <klipper service name>   Specify the name of the Klipper service (default: klipper)"
  echo "  -p <printer config dir>     Specify the path to the printer config directory (default: ~/printer_data/config)"
  echo "  -b <branch>                 Specify the branch to use (default: main)"
  echo "  -u                          Uninstall the extensions"
  echo "  -h                          Display this help message"
  echo ""
  echo "Example:"
  echo " $0 [-k <klipper_path>] [-s <klipper_service_name>] [-m <moonraker_config_path>] [-p <printer_config_dir>] [-b <branch>] [-u] [-h] "
}

function copy_config() {
  if [ -d "${afc_config_dir}" ]; then
    mkdir -p "${afc_config_dir}"
  fi
  cp -R "${afc_path}/config" "${afc_config_dir}"
}

function clone_repo() {
  # Function to clone the AFC Klipper Add-On repository if it is not already cloned.
  # Uses the global variables:
  #   - afc_path: The path where the repository should be cloned.
  #   - gitrepo: The URL of the repository to clone.
  #   - branch: The branch to check out after cloning or pulling the repository.

  local afc_dir_name afc_base_name
  afc_dir_name="$(dirname "${afc_path}")"
  afc_base_name="$(basename "${afc_path}")"

  if [ ! -d "${afc_path}" ]; then
    echo "Cloning AFC Klipper Add-On repo..."
    if git -C $afc_dir_name clone --quiet $gitrepo $afc_base_name; then
      print_msg INFO "AFC Klipper Add-On repo cloned successfully"
      pushd "${afc_path}" || exit
      git checkout --quiet "${branch}"
      popd || exit
    else
      print_msg ERROR "Failed to clone AFC Klipper Add-On repo"
      exit 1
    fi
  else
    pushd "${afc_path}" || exit
    git pull --quiet
    git checkout --quiet "${branch}"
    popd || exit
  fi
}

backup_afc_config() {
  # Function to back up the existing AFC configuration.
  # Arguments:
  #   - AFC_CONFIG_PATH: The path to the AFC configuration directory.
  #   - PRINTER_CONFIG_PATH: The path to the printer configuration directory.

  if [ -d "${afc_config_dir}" ]; then
    pushd "${printer_config_dir}" || exit
    mv AFC AFC.backup."$backup_date"
    popd || exit
  fi
}

backup_afc_config_copy() {
  # Function to back up the existing AFC configuration.
  # Arguments:
  #   - AFC_CONFIG_PATH: The path to the AFC configuration directory.
  #   - PRINTER_CONFIG_PATH: The path to the printer configuration directory.

  if [ -d "${afc_config_dir}" ]; then
    pushd "${printer_config_dir}" || exit
    cp -R AFC AFC.backup."$backup_date"
    popd || exit
  fi
}

exclude_from_klipper_git() {
  local EXTRAS_DIR="${afc_path}/extras"
  local EXCLUDE_FILE="${klipper_dir}/.git/info/exclude"

  # Find all .py files in the extras directory and add them to the exclude file if they are not already present
  find "$EXTRAS_DIR" -type f -name "*.py" | while read -r file; do
    # Adjust the file path to the required format
    local relative_path="klippy/extras/$(basename "$file")"
    if ! grep -Fxq "$relative_path" "$EXCLUDE_FILE"; then
      echo "$relative_path" >> "$EXCLUDE_FILE"
    fi
  done
}

restart_service() {
  # Function to restart a given service.
  # Arguments:
  #   $1 - The name of the service to restart.

  local service_name=$1
  if command -v systemctl &> /dev/null; then
    sudo systemctl restart "${service_name}"
  else
    sudo service "${service_name}" restart
  fi
}

restart_klipper() {
  if query_printer_status; then
    restart_service klipper
  fi
}

exit_afc_install() {
  if [ "$files_updated_or_installed" == "True" ]; then
    echo "AFC_INSTALL_VERSION=$current_install_version" > "${afc_config_dir}/.afc-version"
  restart_klipper
  fi
  exit 0
}

function auto_update() {
  check_and_append_prep "${afc_config_dir}/AFC.cfg"
  remove_t_macros
  # merge_configs "${AFC_CONFIG_PATH}/AFC_Hardware.cfg" "${AFC_PATH}/templates/AFC_Hardware-AFC.cfg" "${AFC_CONFIG_PATH}/AFC_Hardware-temp.cfg"
  # cleanup_blank_lines "${AFC_CONFIG_PATH}/AFC_Hardware-temp.cfg"
  # mv "${AFC_CONFIG_PATH}/AFC_Hardware-temp.cfg" "${AFC_CONFIG_PATH}/AFC_Hardware.cfg"
}

check_old_config_version() {
  local config_file="${afc_config_dir}/AFC.cfg"

  # Check if the configuration file exists
  if [[ ! -f "$config_file" ]]; then
    force_update=False
    force_update_no_version=False
    return
  fi

  # Check if 'Type: Box_Turtle' is found in the first 15 lines of the file
  if head -n 15 "$config_file" | grep -v '^\s*#' | grep -q 'Type: Box_Turtle'; then
    force_update=True
    # Since we have software without an AFC_INSTALL_VERSION in it, we need a way to designate this as a version that needs to be updated.
    force_update_no_version=True
  else
    force_update=False
    force_update_no_version=False
  fi
}

set_install_version_if_missing() {
  local version_file="${afc_config_dir}/.afc-version"

  # Check if the version file exists
  if [[ ! -f "$version_file" ]]; then
    return
  fi

  # Check if 'AFC_INSTALL_VERSION' is missing and add it if necessary
  if ! grep -q 'AFC_INSTALL_VERSION' "$version_file"; then
    if ! echo "AFC_INSTALL_VERSION=$CURRENT_INSTALL_VERSION" > "$version_file"; then
      echo "Error: Failed to write to version file '$version_file'."
      return 1
    fi
  fi
}

check_version_and_set_force_update() {
  local version_file="${afc_config_dir}/.afc-version"
  local current_version

  if [[ -f $version_file ]]; then
    current_version=$(grep -oP '(?<=AFC_INSTALL_VERSION=)[0-9]+\.[0-9]+\.[0-9]+' "$version_file")
  fi

  if [[ -z "$current_version" || "$current_version" < "$min_version" ]]; then
    force_update=True
  else
    force_update=False
  fi
}