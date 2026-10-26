provider "juju" {
  controller_mode = true
  lazy_api_check  = true
}

resource "juju_controller" "controller" {
  juju_binary = var.path_juju_binary
  name        = var.name

  cloud            = var.cloud
  cloud_credential = var.cloud_credential

  agent_version           = var.agent_version
  bootstrap_base          = var.bootstrap_base
  bootstrap_config        = var.bootstrap_config
  bootstrap_constraints   = var.bootstrap_constraints
  controller_config       = var.controller_config
  controller_model_config = var.controller_model_config
  destroy_flags           = var.destroy_flags
  model_constraints       = var.model_constraints
  model_default           = var.model_default
  storage_pool            = var.storage_pool
}

# TODO: Terraform actions are available to enable HA, however actions are not yet supported by OpenTofu, thus we stick with local-exec for now.
# https://documentation.ubuntu.com/terraform-provider-juju/v1.4.3/howto/manage-controllers/#enable-controller-high-availability
#
# Zone spread (verified live, juju 3.6.29 on clustered LXD, 2026-10-26):
#   - enable-ha --constraints=zones=a,b,c  -> members 1/2/0 (zones is an
#     eligibility FILTER; it never distributes).
#   - enable-ha --to zone=a,zone=b,zone=c  -> same-zone members; directives
#     not honored for distribution.
#   - per-zone `add-machine ... zone=<member>` + `enable-ha -n` + demote
#     duplicate-zone members -> 1/1/1, 3/3 ha-enabled. This script does
#     that and FAILS the apply if the final member set is not one machine
#     per cluster member.
# Controller registration/selection (verified live + local juju 3.6.29
# help): `login <arg>` resolves <arg> as a PUBLIC ALIAS only, and `-c`
# selects an ALREADY-REGISTERED controller — neither registers a private
# address, so the module's original `login -c <name> <addr>` only works in
# a client data dir that already knows the name. Register with
# `env JUJU_CONTROLLER=<addr> juju login -u <user> --no-prompt` (the env
# override skips alias resolution and logins register the controller),
# then address everything through the resulting current controller.
resource "terraform_data" "juju_enable_ha" {
  count = var.controller_num_units > 1 ? 1 : 0
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # Run ALL juju commands in ONE private client-data dir (the module's
      # own get-api-url.sh pattern): /snap/juju/current/bin/juju with
      # JUJU_DATA=/tmp/juju-<rand> — bare `juju` on a snap install keeps its
      # data in snap-private-tmp which is invisible/unreusable. The dir is
      # removed at the end.
      export JUJU_DATA=/tmp/juju-ha-$(openssl rand -hex 4)
      JUJUC=/snap/juju/current/bin/juju
      trap 'rm -rf "$JUJU_DATA"' EXIT

      CURRENT=
      # login: positional = controller NAME, address after -c (juju 3.6.29
      # verified; an address-shaped positional is rejected).
      echo "$JUJU_PASSWORD" | "$JUJUC" login -c "$CONTROLLER_NAME" "$API_ADDRESS" -u "$JUJU_USERNAME" --trust --no-prompt
      CURRENT=$("$JUJUC" controllers --format json | jq -r '."current-controller" // empty')
      [ -n "$CURRENT" ] || CURRENT="$CONTROLLER_NAME"
      MODEL="$CURRENT:controller"

      members() { "$JUJUC" show-controller --format json 2>/dev/null | jq -r 'to_entries[0].value."controller-machines" // {} | keys[]'; }
      zone_of() { "$JUJUC" status -m "$MODEL" --format json | jq -r --arg m "$1" '.machines[$m].zone // "none"'; }

      verify() {
        local ms zs n
        ms=$(members | sort -n)
        n=$(printf '%s\n' "$ms" | grep -c . || true)
        if [ "$n" -ne "$HA_COUNT" ]; then
          echo "FAIL: $n members, want $HA_COUNT (members: $ms)" >&2; return 1
        fi
        zs=$(for m in $ms; do zone_of "$m"; done | sort | uniq)
        if [ "$(printf '%s\n' "$zs" | grep -c . || true)" -ne "$HA_COUNT" ]; then
          echo "FAIL: members not spread across distinct cluster members: $zs" >&2; return 1
        fi
        if printf '%s\n' "$zs" | grep -qx none; then
          echo "FAIL: members missing zone placement: $zs" >&2; return 1
        fi
        echo "OK: controller HA verified: $HA_COUNT members on zones: $(printf '%s ' $zs)"
      }

      # 1. one machine pinned per zone
      for z in $ZONES; do
        "$JUJUC" add-machine -m "$MODEL" --constraints "$MACHINE_CONSTRAINTS" "zone=$z" || true
      done

      # 2. wait for every current member machine to be started
      for mid in $(members); do
        "$JUJUC" wait-for machine -m "$MODEL" "$mid" --timeout 30m
      done

      # 3. converge membership
      "$JUJUC" enable-ha -n "$HA_COUNT"

      # 4. demote duplicate-zone members until one per zone
      for attempt in 1 2 3 4 5; do
        dup=$(for m in $(members); do zone_of "$m"; done | grep -vx none | sort | uniq -d | head -n1 || true)
        [ -z "$dup" ] && break
        for m in $(members | sort -rn); do
          if [ "$(zone_of "$m")" = "$dup" ]; then
            echo "duplicate member zone=$dup; removing machine $m"
            "$JUJUC" remove-machine -m "$MODEL" "$m" --force
            break
          fi
        done
        "$JUJUC" enable-ha -n "$HA_COUNT"
        sleep 30
      done

      # 5. quiescence + verify
      "$JUJUC" wait-for model "$MODEL" --timeout 1800s --query='forEach(units, unit => (unit.workload-status == "active"))'
      verify
    EOT
    environment = {
      # (CONTROLLER_NAME kept only for naming; never JUJU_CONTROLLER here —
      # it would pin selection for EVERY juju invocation in the script.)
      CONTROLLER_NAME = juju_controller.controller.name
      API_ADDRESS         = juju_controller.controller.api_addresses[0]
      JUJU_USERNAME       = juju_controller.controller.username
      JUJU_PASSWORD       = juju_controller.controller.password
      HA_COUNT            = var.controller_num_units
      ZONES               = can(var.bootstrap_constraints.zones) ? join(" ", split(",", var.bootstrap_constraints.zones)) : ""
      MACHINE_CONSTRAINTS = join(" ", [for k, v in var.bootstrap_constraints : "${k}=${v}" if k != "zones"])
    }
  }
}
