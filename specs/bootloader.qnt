// bootloader.qnt — Quint model of my_nvim_bootloader startup/recovery + auto_update
//
// Grounds (source-file correspondence):
//   bootloader.qnt  <->  lua/my_nvim_bootloader/init.lua        (startup, F1/F2 dispatch)
//                        lua/my_nvim_bootloader/fallback.lua    (error_number routing)
//                        lua/my_nvim_bootloader/min/init.lua    (rescue_min/rescue_normal)
//                        lua/my_nvim_bootloader/min/github_installer.lua (clone)
//                        lua/my_nvim_bootloader/dpp/make_state.lua (normal deps, F3)
//                        lua/my_nvim_bootloader/dpp/auto_update.lua (update flows)
//                        lua/my_nvim_bootloader/autocmds.lua    (config-change detection)
//
// COVERS
//   Core boot flow:
//   - startup(): load_state success -> Loaded
//   - F1 (state broken): ensure denops -> start denops -> make_state
//   - F2 (dpp missing): rescue_min (clone min deps) -> restart (UI only)
//   - F3 (normal deps missing): rescue_normal (clone) -> retry make_state
//   - headless guard: restart requires a UI session
//   - restart bound (model-level, not an explicit code bound)
//   auto_update flow:
//   - config-change detection (BufWritePost): toml vs non-toml
//   - TOML-save flow (dpp_update_toml): make_state -> install -> ask restart
//   - config-change flow (non-toml): make_state only -> ask restart
//   - :DppUpdate force flow: installer chain -> make_state -> ask restart
//   - ask_restart: UI-only, YES -> restart, NO -> stay
//
// RUN (from this directory):
//   quint typecheck bootloader.qnt
//   quint test  bootloader_test.qnt --main bootloader_test
//   quint test  bootloader_test.qnt --main bootloader_headless_test
//   quint run   bootloader_test.qnt --main bootloader_test \
//     --invariant "loadedImpliesDepsInstalled and loadedImpliesStateOk and \
//                  headlessNeverRestarts and restartBounded and \
//                  restartOnlyAfterUpdate and updateKeepsSessionAlive and \
//                  headlessNeverAsksRestart" \
//     --witnesses witnessLoaded --witnesses witnessFailed \
//     --witnesses witnessRestart --witnesses witnessF1 --witnesses witnessF2 \
//     --witnesses witnessUpdateFlow --witnesses witnessRestartApproved
//
// DOES NOT COVER
//   - installer internals: install / checkNotUpdated / getNotInstalled are
//     fused into one "installer chain" (installerBusy -> done)
//   - load_state_live (in-session state reload) failure: modeled as always
//     succeeding after make_state
//   - scoped updates (names filter): all updates are full updates
//   - autocmds.lua: DenopsReady wiring details, BufWritePost pattern matching
//   - headless F2 outcome: code returns true (session continues degraded);
//     modeled as Failed (boot goal — plugins loaded — not achieved)
//
// WHEN TO UPDATE: change this spec and re-verify BEFORE touching the code
// files above. The spec is the ground truth for the boot flow's behavior.

module bootloader {
  type Repo = str
  type Phase = Booting | Loaded | Failed
  type Recovery = None | F1 | F2 | F3

  // --- system-model assumptions (instantiated in bootloader_test.qnt) ---
  const MIN_DEPS: Set[Repo]      // minimum deps: dpp.vim, dpp-ext-lazy, denops.vim
  const NORMAL_DEPS: Set[Repo]   // full dpp stack needed for make_state
  const HAS_UI: bool             // session has a UI (headless guard)
  const MAX_RESTARTS: int        // model bound on the restart loop

  // --- state ---
  var phase: Phase
  var recovery: Recovery
  var minDeps: Set[Repo]         // installed minimum deps (on disk)
  var normalDeps: Set[Repo]      // installed normal deps (on disk)
  var stateOk: bool              // state.vim exists and is loadable
  var denopsRunning: bool        // denops server running in this session
  var restartCount: int

  // --- auto_update state (auto_update.lua, autocmds.lua) ---
  var configChanged: bool       // config write detected, update in progress
  var tomlChanged: bool         // the changed config includes a .toml
  var installPending: bool      // toml-save flow flag (install_pending)
  var installerBusy: bool       // installer chain running (install/checkNotUpdated)
  var restartAsked: bool        // ask_restart() called (UI session only)
  var restartApproved: bool     // user chose YES (NO -> flow done, stays false)

  val denopsInstalled: bool = minDeps.contains("denops.vim")

  // --- init: fresh machine (nothing installed) ---
  action init: bool = all {
    phase' = Booting,
    recovery' = None,
    minDeps' = Set(),
    normalDeps' = Set(),
    stateOk' = false,
    denopsRunning' = false,
    restartCount' = 0,
    configChanged' = false,
    tomlChanged' = false,
    installPending' = false,
    installerBusy' = false,
    restartAsked' = false,
    restartApproved' = false,
  }

  // --- load_state outcomes (init.lua:startup step 2) ---
  action loadStateSucceeds: bool = all {
    phase == Booting,
    minDeps.contains("dpp.vim"),
    stateOk,
    phase' = Loaded,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action loadStateFails: bool = all {
    phase == Booting,
    minDeps.contains("dpp.vim"),
    not(stateOk),
    phase' = Booting,
    recovery' = F1,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action loadStateMissing: bool = all {
    phase == Booting,
    not(minDeps.contains("dpp.vim")),
    phase' = Booting,
    recovery' = F2,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // --- F1: state broken -> ensure denops -> start denops -> make_state ---
  action f1EnsureDenopsSucceeds: bool = all {
    recovery == F1,
    not(denopsInstalled),
    phase' = Booting,
    recovery' = F1,
    minDeps' = minDeps.union(Set("denops.vim")),
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f1EnsureDenopsFails: bool = all {
    recovery == F1,
    not(denopsInstalled),
    phase' = Failed,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f1StartDenops: bool = all {
    recovery == F1,
    denopsInstalled,
    not(denopsRunning),
    phase' = Booting,
    recovery' = F1,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = true,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // normal deps missing -> F3 sub-recovery (rescue_normal clones them)
  action f1CheckNormalDeps: bool = all {
    recovery == F1,
    denopsRunning,
    normalDeps != NORMAL_DEPS,
    phase' = Booting,
    recovery' = F3,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f1MakeStateSucceeds: bool = all {
    recovery == F1,
    denopsRunning,
    normalDeps == NORMAL_DEPS,
    phase' = Booting,          // state file now valid; next boot loads it
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = true,
    denopsRunning' = false,    // fresh session
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f1MakeStateFails: bool = all {
    recovery == F1,
    denopsRunning,
    normalDeps == NORMAL_DEPS,
    phase' = Failed,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // --- F2: dpp missing -> rescue_min (clone min deps) -> restart (UI only) ---
  action f2RescueMinSucceeds: bool = all {
    recovery == F2,
    phase' = Booting,
    recovery' = F2,
    minDeps' = minDeps.union(MIN_DEPS),
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f2RescueMinFails: bool = all {
    recovery == F2,
    phase' = Failed,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f2Restart: bool = all {
    recovery == F2,
    minDeps == MIN_DEPS,
    HAS_UI,
    restartCount < MAX_RESTARTS,
    phase' = Booting,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = false,    // fresh session
    restartCount' = restartCount + 1,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // headless (or restart budget exhausted): cannot load plugins this session
  action f2GiveUp: bool = all {
    recovery == F2,
    minDeps == MIN_DEPS,
    not(HAS_UI) or restartCount >= MAX_RESTARTS,
    phase' = Failed,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // --- F3: normal deps missing -> rescue_normal (clone) -> back to F1 ---
  action f3RescueNormalSucceeds: bool = all {
    recovery == F3,
    phase' = Booting,
    recovery' = F1,
    minDeps' = minDeps,
    normalDeps' = normalDeps.union(NORMAL_DEPS),
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  action f3RescueNormalFails: bool = all {
    recovery == F3,
    phase' = Failed,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // ==========================================================================
  // auto_update flow (auto_update.lua, autocmds.lua)
  // ==========================================================================

  // --- config-change detection (autocmds.lua BufWritePost) ---
  // A config write under $NVIM_CONFIG_HOME is detected; whether it is a
  // .toml decides the flow (toml -> dpp_update_toml, else make_state only).
  action configChangeToml: bool = all {
    phase == Loaded,
    not(configChanged),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = true,
    tomlChanged' = true,
    installPending' = false,
    installerBusy' = false,
    restartAsked' = false,
    restartApproved' = false,
  }

  action configChangeNonToml: bool = all {
    phase == Loaded,
    not(configChanged),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = true,
    tomlChanged' = false,
    installPending' = false,
    installerBusy' = false,
    restartAsked' = false,
    restartApproved' = false,
  }

  // --- TOML-save flow (dpp_update_toml) ---
  // 1: install_pending = true, make_state starts (async).
  action tomlUpdateStart: bool = all {
    configChanged,
    tomlChanged,
    not(installPending),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    installPending' = true,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // 2: make_state completes (Dpp:makeStatePost) -> state file valid;
  //    on_make_state_post (install_pending branch) reloads and installs.
  action tomlMakeStateSucceeds: bool = all {
    installPending,
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    stateOk' = true,
    installPending' = false,
    configChanged' = false,
    tomlChanged' = false,
    installerBusy' = true,   // reload -> install chain
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // 2': make_state fails -> update aborted, session stays Loaded.
  action tomlMakeStateFails: bool = all {
    installPending,
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    stateOk' = stateOk,
    installPending' = false,
    configChanged' = false,
    tomlChanged' = false,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // --- installer chain completion (Dpp:ext:installer:updateDone) ---
  // Shared end point for the toml flow (install after make_state) and the
  // :DppUpdate force flow (install -> checkNotUpdated -> make_state).
  // Fused: installer done + make_state done + state verified -> ask restart.
  action installerDone: bool = all {
    installerBusy,
    not(configChanged),
    not(installPending),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    installerBusy' = false,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    restartAsked' = HAS_UI,   // headless: ask_restart() skips
    restartApproved' = restartApproved,
  }

  // --- config-change flow, non-toml (dpp_update: no toml changed) ---
  // make_state only; on_make_state_post (default branch) verifies and
  // installs or asks to restart.
  action configMakeState: bool = all {
    configChanged,
    not(tomlChanged),
    not(installPending),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    stateOk' = true,
    configChanged' = false,
    tomlChanged' = false,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = HAS_UI,
    restartApproved' = restartApproved,
  }

  action configMakeStateFails: bool = all {
    configChanged,
    not(tomlChanged),
    not(installPending),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    stateOk' = stateOk,
    configChanged' = false,
    tomlChanged' = false,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // --- :DppUpdate force flow (dpp_update(args, true)) ---
  // Full update of all plugins: installer chain -> make_state -> ask restart.
  action forceUpdateStart: bool = all {
    phase == Loaded,
    not(configChanged),
    not(installerBusy),
    not(restartAsked),
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    installerBusy' = true,
    configChanged' = false,
    tomlChanged' = false,
    installPending' = false,
    restartAsked' = restartAsked,
    restartApproved' = restartApproved,
  }

  // --- ask_restart outcomes (auto_update.lua ask_restart) ---
  // restartAsked == true means ask_restart() was called and the user is
  // choosing. UI sessions only; headless never sets restartAsked.

  // YES -> restart: new session, disk state (deps, stateOk) survives.
  action restartApprovedAction: bool = all {
    restartAsked,
    HAS_UI,
    restartCount < MAX_RESTARTS,
    restartCount' = restartCount + 1,
    phase' = Booting,
    recovery' = None,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = false,    // fresh session
    configChanged' = false,
    tomlChanged' = false,
    installPending' = false,
    installerBusy' = false,
    restartAsked' = false,
    restartApproved' = true,
  }

  // NO -> stay in the current session, update flow done.
  action restartDeclined: bool = all {
    restartAsked,
    HAS_UI,
    phase' = phase,
    recovery' = recovery,
    minDeps' = minDeps,
    normalDeps' = normalDeps,
    stateOk' = stateOk,
    denopsRunning' = denopsRunning,
    restartCount' = restartCount,
    configChanged' = configChanged,
    tomlChanged' = tomlChanged,
    installPending' = installPending,
    installerBusy' = installerBusy,
    restartAsked' = false,
    restartApproved' = false,   // NO is not an approval
  }

  // --- step ---
  action step: bool = any {
    loadStateSucceeds,
    loadStateFails,
    loadStateMissing,
    f1EnsureDenopsSucceeds,
    f1EnsureDenopsFails,
    f1StartDenops,
    f1CheckNormalDeps,
    f1MakeStateSucceeds,
    f1MakeStateFails,
    f2RescueMinSucceeds,
    f2RescueMinFails,
    f2Restart,
    f2GiveUp,
    f3RescueNormalSucceeds,
    f3RescueNormalFails,
    configChangeToml,
    configChangeNonToml,
    tomlUpdateStart,
    tomlMakeStateSucceeds,
    tomlMakeStateFails,
    installerDone,
    configMakeState,
    configMakeStateFails,
    forceUpdateStart,
    restartApprovedAction,
    restartDeclined,
  }

  // --- invariants (safety) ---
  // Loaded requires every minimum dep installed and the state file valid.
  val loadedImpliesDepsInstalled: bool =
    phase == Loaded implies (minDeps == MIN_DEPS and normalDeps == NORMAL_DEPS)

  val loadedImpliesStateOk: bool =
    phase == Loaded implies stateOk

  // The headless guard: restart only happens in a UI session.
  val headlessNeverRestarts: bool =
    HAS_UI or restartCount == 0

  // Model bound on the restart loop (not an explicit code bound).
  val restartBounded: bool =
    restartCount <= MAX_RESTARTS

  // auto_update: an approved restart only happens after ask_restart() ran.
  // restartApproved stays true after the restart (restartCount > 0); the
  // F2 boot restart is automatic — `:restart!` — and never sets
  // restartApproved, so it is outside this invariant's scope.
  val restartOnlyAfterUpdate: bool =
    restartApproved implies (restartAsked or restartCount > 0)

  // auto_update: update processing never leaves Loaded (session stays alive).
  val updateKeepsSessionAlive: bool =
    configChanged implies phase == Loaded

  // auto_update: headless sessions never ask for restart.
  val headlessNeverAsksRestart: bool =
    not(HAS_UI) implies not(restartAsked)

  // --- witnesses (reachability) ---
  val witnessLoaded: bool = phase == Loaded
  val witnessFailed: bool = phase == Failed
  val witnessRestart: bool = restartCount > 0
  val witnessF1: bool = recovery == F1
  val witnessF2: bool = recovery == F2
  val witnessUpdateFlow: bool = restartAsked
  val witnessRestartApproved: bool = restartApproved
}
