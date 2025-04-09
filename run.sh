#!/bin/bash
# ------------------------------------------------------------------------------
# Enhanced OpenStack Infrastructure Deployment Script (Dynamic Hosts Support)
# This script authenticates to OpenStack and deploys infrastructure via Ansible
# ------------------------------------------------------------------------------

set -euo pipefail

# Configuration
SECRETS_FILE="/keybase/team/xdew.admin/openstack.yml"
FLOATING_IP_NAME="xdew-public-ip"
FLOATING_NETWORK="ext-floating1"
ANSIBLE_JINJA2_NATIVE=true
export ANSIBLE_JINJA2_NATIVE

# Log functions
log_info()    { echo -e "\033[0;34m[INFO]\033[0m $1" >&2; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1" >&2; }
log_warn()    { echo -e "\033[0;33m[WARNING]\033[0m $1" >&2; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# Check dependencies
for cmd in yq openstack jq ansible-playbook; do
  if ! command -v "$cmd" &> /dev/null; then
    log_error "$cmd is not installed. Please install it first."
    exit 1
  fi
done

# Check secrets file
if [[ ! -f "$SECRETS_FILE" ]]; then
  log_error "Secrets file not found at $SECRETS_FILE"
  exit 1
fi

# Load OpenStack credentials from secrets file
load_openstack_credentials() {
  log_info "Loading OpenStack credentials..."

  local credentials=(
    "auth_url" "username" "password"
    "project_name" "user_domain_name"
    "region_name" "interface" "identity_api_version"
  )

  for cred in "${credentials[@]}"; do
    local env_var="OS_$(echo "$cred" | tr '[:lower:]' '[:upper:]')"
    local value
    value=$(yq ".$cred" "$SECRETS_FILE" | tr -d '"')

    if [[ -z "$value" || "$value" == "null" ]]; then
      log_error "Failed to load $env_var from secrets file"
      exit 1
    fi

    export "$env_var"="$value"
  done

  log_success "OpenStack credentials loaded successfully"
}

# Load extra configuration values from secrets file
load_configuration() {
  log_info "Loading deployment configuration..."

  VPN_ENABLED=$(yq ".vpn_enabled" "$SECRETS_FILE" | tr -d '"')
  NUM_MACHINES=$(yq ".num_machines" "$SECRETS_FILE" | tr -d '"')

  if [[ -z "$VPN_ENABLED" || "$VPN_ENABLED" == "null" ]]; then
    log_error "Failed to load vpn_enabled"
    exit 1
  fi

  if [[ -z "$NUM_MACHINES" || "$NUM_MACHINES" == "null" || ! "$NUM_MACHINES" =~ ^[0-9]+$ ]]; then
    log_error "Invalid or missing num_machines value"
    exit 1
  fi

  log_success "VPN_ENABLED: $VPN_ENABLED"
  log_success "NUM_MACHINES: $NUM_MACHINES"
}

# Ensure a floating IP exists or create one
ensure_floating_ip_exists() {
  local ip_name="$1"
  local network_name="$2"

  log_info "Checking for floating IP: $ip_name"

  local ip_id
  ip_id=$(openstack floating ip list --tag "$ip_name" -f value -c ID | head -n1)

  if [[ -z "$ip_id" ]]; then
    log_info "Creating new floating IP with tag '$ip_name'..."
    local result
    result=$(openstack floating ip create --description "$ip_name" --tag "$ip_name" "$network_name" -f json)
    local new_ip
    new_ip=$(echo "$result" | jq -r '.floating_ip_address')

    if [[ -n "$new_ip" && "$new_ip" != "null" ]]; then
      log_success "Created new floating IP: $new_ip"
      echo "$new_ip"
    else
      log_error "Failed to create floating IP"
      exit 1
    fi
  else
    local ip_address
    ip_address=$(openstack floating ip show "$ip_id" -f value -c floating_ip_address)
    log_success "Using existing floating IP: $ip_address (ID: $ip_id)"
    echo "$ip_address"
  fi
}

# Run Ansible playbook with appropriate parameters
run_ansible_playbook() {
  local extra_vars=("$@")
  log_info "Running Ansible playbook"

  if ! ansible-playbook -i inventory/hosts.yml "${extra_vars[@]}" playbook.yml; then
    log_error "Ansible playbook execution failed"
    exit 1
  fi

  log_success "Ansible playbook executed successfully"
}

# Main execution
main() {
  log_info "Starting deployment"

  load_openstack_credentials
  load_configuration

  local ansible_params=()

  if [[ "$VPN_ENABLED" == "true" ]]; then
    log_info "Using VPN configuration"
    for i in $(seq 1 "$NUM_MACHINES"); do
      host_id=$(printf "xdew%02d" "$i")
      host_ip="10.0.0.$((10 * i))"
      host_port=22
      ansible_params+=("-e" "${host_id}_ip=${host_ip}" "-e" "${host_id}_port=${host_port}")
    done
    ansible_params+=("-e" "nas_ip=10.0.0.100" "-e" "nas_port=22")
  else
    log_info "Using direct public IP configuration"
    local public_ip
    public_ip=$(ensure_floating_ip_exists "$FLOATING_IP_NAME" "$FLOATING_NETWORK")

    for i in $(seq 1 "$NUM_MACHINES"); do
      host_id=$(printf "xdew%02d" "$i")
      host_port=$((3220 + i))
      ansible_params+=("-e" "${host_id}_ip=${public_ip}" "-e" "${host_id}_port=${host_port}")
    done
    ansible_params+=("-e" "nas_ip=${public_ip}" "-e" "nas_port=3230")
  fi

  ansible_params+=("-e" "vpn_enabled=$VPN_ENABLED")

  run_ansible_playbook "${ansible_params[@]}"
}

# Execute
main
