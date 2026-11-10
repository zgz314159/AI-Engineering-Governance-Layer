#!/usr/bin/env bash
# AEGL-TOOL-OBS-DEPLOY-r1 pins.
#
# Machine-readable deployment declaration. Sourced by bin/run_smoke.sh.
# No command is executed at source time.

# --- provenance --------------------------------------------------------------- #
CANDIDATE_COMMIT="926c34fbecf1157c2ae88e57e85ef67f6f82de33"
CHECK_SOURCE_COMMIT="4232cb114f74dbbbf15046cce6e62ec95604bbd7"
R10_ROOT_ANCHOR="e458957cd15cab763191b031cc2598af5a4c7c2136fe951c629d40e414081f65"
R10_ROOT_LOG="/root/aegl-tool-obs-check-r10.G1DVhS/check.log"
R10_ROOT_RESULT="OBS_CHECK=PASS"
R10_CHECK_COMMAND_EXIT="0"

# --- fixed install target ------------------------------------------------------ #
DEPLOY_TARGET="/usr/local/lib/aegl-model"
TARGET_OWNER="root:root"
TARGET_MODE="755"          # reported as 0755

# --- the only four files this package installs --------------------------------- #
# Order is the required install order: two new modules -> broker -> launcher.
PAYLOAD_ORDER=(
  tool_event_client.py
  tool_observer_config.py
  model_broker.py
  aegl-hermes-sandbox
)
NEW_PAYLOADS=(tool_event_client.py tool_observer_config.py)

declare -A PAYLOAD_SHA=(
  [tool_event_client.py]=f70630cacfdcb1afd5eff08ad20ada9737c91b097a42741a122a0fa651df83bf
  [tool_observer_config.py]=424369561202ca48f122b8116fc6b2ebca8cbb1d108dbeb04674608b807591c3
  [model_broker.py]=7aa88b1831ca18fdbe9b14273321a90b352bb6026299b9bb9c26d4ca9b8ee59a
  [aegl-hermes-sandbox]=f3e556f079d14c6e4dd7173cd3a571b6e8a32527db12dc91aae44fbf75929479
)
declare -A PAYLOAD_MODE=(
  [tool_event_client.py]=644
  [tool_observer_config.py]=644
  [model_broker.py]=644
  [aegl-hermes-sandbox]=755
)
declare -A PAYLOAD_OWNER=(
  [tool_event_client.py]=root:root
  [tool_observer_config.py]=root:root
  [model_broker.py]=root:root
  [aegl-hermes-sandbox]=root:root
)
# Existing targets only. The two new modules must be absent.
declare -A PAYLOAD_PREDECESSOR=(
  [model_broker.py]=ab0d4c36cb27f1b23cc1510f3650f10df8375dd72db4078eb2a99ad41d93c3e3
  [aegl-hermes-sandbox]=8c4dd19b19d1983c7b716d2606e16227ed45c1ad5518d39ae7ad5c933b1eadf5
)
declare -A PAYLOAD_SOURCE=(
  [tool_event_client.py]="recovery/tool_event_client.py@${CANDIDATE_COMMIT}"
  [tool_observer_config.py]="recovery/tool_observer_config.py@${CANDIDATE_COMMIT}"
  [model_broker.py]="recovery/model_broker.py@${CANDIDATE_COMMIT}"
  [aegl-hermes-sandbox]="bin/aegl-hermes-sandbox@${CANDIDATE_COMMIT}"
)

# --- the other twelve runtime dependencies are verified, never installed ------- #
DEP_ORDER=(
  aegl-model-broker
  guard_capture.py
  guard_hook_client.py
  diag_events.py
  loopback_shim.py
  exec_spec.py
  sandbox_spec.py
  prepare_targets.py
  drop_verify.py
  model_config.py
  git_meta_mounts.sh
  guard/contract_guard.py
)
declare -A DEP_SHA=(
  [aegl-model-broker]=e7ca9db0fbd029cb3fb72b163e792fe9c62ca6b85c571569cf2ad9319917fba9
  [guard_capture.py]=4422f725fc2fb88ecff4de6baba81a519e4f450be5ad644948b29745d877be1a
  [guard_hook_client.py]=19121446cea3c752f266c7dea0e0f6c682aa78dbb166ec4097635c8965265869
  [diag_events.py]=0f79ca1f4eaae497aaef7b93ae2ee5587e23be2c3aec3cd47a0524dda47f4f2e
  [loopback_shim.py]=75cf4ad616d4d40a5529e4f263267c08b521ef26bf9cc4a556814e44a4031d5c
  [exec_spec.py]=cb9e82ffe8656ee5e7f2bf056a96bdcc55b92a218248d90274b93c2b69ae1546
  [sandbox_spec.py]=1b95ec402fa326808d0f21b8e67a6bee0763832a5492a2642cf012d338b11890
  [prepare_targets.py]=2279cb1137014bb7385ea937f36d59eccc2074846c5b8e82e39921a0dcd25232
  [drop_verify.py]=a0b9d219397d57dffb6184a5f63a0be08cd5044d5dc72d6ad63a31ca45c5eecc
  [model_config.py]=ef14777e7dcc25b835caf3d5154d989b3745f5a42dd6a6f0f907a3b8a223568f
  [git_meta_mounts.sh]=f93bbfdd286e6a554c10edcdda6dd40a20d32d1ffbcb17dc56091bbeac8ac50a
  [guard/contract_guard.py]=19f6be638c37b28d401820b7a4562f852a459188cbfa793f757668fe9b330455
)
declare -A DEP_MODE=(
  [aegl-model-broker]=755
  [guard_capture.py]=644
  [guard_hook_client.py]=644
  [diag_events.py]=644
  [loopback_shim.py]=644
  [exec_spec.py]=644
  [sandbox_spec.py]=644
  [prepare_targets.py]=644
  [drop_verify.py]=644
  [model_config.py]=644
  [git_meta_mounts.sh]=755
  [guard/contract_guard.py]=444
)
declare -A DEP_OWNER=(
  [aegl-model-broker]=root:root
  [guard_capture.py]=root:root
  [guard_hook_client.py]=root:root
  [diag_events.py]=root:root
  [loopback_shim.py]=root:root
  [exec_spec.py]=root:root
  [sandbox_spec.py]=root:root
  [prepare_targets.py]=root:root
  [drop_verify.py]=root:root
  [model_config.py]=root:root
  [git_meta_mounts.sh]=root:root
  [guard/contract_guard.py]=root:root
)
