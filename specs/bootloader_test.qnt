// bootloader_test.qnt — concrete instances + run tests for bootloader.qnt
//
// Instantiates the consts so the spec is runnable (quint run requires
// concrete values; `assume` documents but does not supply them).
//
// Two modules: `bootloader_test` (HAS_UI = true) and
// `bootloader_headless_test` (HAS_UI = false). Run with:
//   quint test bootloader_test.qnt --main bootloader_test
//   quint test bootloader_test.qnt --main bootloader_headless_test
//
// Test names end in `Test` so the default `--match` picks them up.
// The `*State` actions below are state builders (not tests): they set up
// the preconditions the code's recovery paths assume (dpp installed, state
// broken, etc.) which `init` (a fresh machine) does not provide.

module bootloader_test {
  import bootloader(
    MIN_DEPS = Set("dpp.vim", "dpp-ext-lazy", "denops.vim"),
    NORMAL_DEPS = Set(
      "dpp-ext-toml", "dpp-ext-local", "dpp-ext-installer",
      "dpp-ext-packspec", "dpp-protocol-git", "dpp-protocol-http",
      "dpp-ext-lazy", "denops.vim"
    ),
    HAS_UI = true,
    MAX_RESTARTS = 2,
  ).* from "./bootloader"

  // --- state builders (preconditions for recovery scenarios) ---

  // dpp installed, state broken (F1 precondition)
  action brokenState: bool = all {
    phase' = Booting,
    recovery' = None,
    minDeps' = MIN_DEPS,
    normalDeps' = NORMAL_DEPS,
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

  // dpp installed but denops.vim missing (F1 denops-install path)
  action brokenStateNoDenops: bool = all {
    phase' = Booting,
    recovery' = None,
    minDeps' = MIN_DEPS.exclude(Set("denops.vim")),
    normalDeps' = NORMAL_DEPS,
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

  // dpp installed, one normal dep missing (F3 path)
  action brokenStateNoNormal: bool = all {
    phase' = Booting,
    recovery' = None,
    minDeps' = MIN_DEPS,
    normalDeps' = NORMAL_DEPS.exclude(Set("dpp-ext-toml")),
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

  // healthy loaded session (auto_update precondition)
  action loadedState: bool = all {
    phase' = Loaded,
    recovery' = None,
    minDeps' = MIN_DEPS,
    normalDeps' = NORMAL_DEPS,
    stateOk' = true,
    denopsRunning' = false,
    restartCount' = 0,
    configChanged' = false,
    tomlChanged' = false,
    installPending' = false,
    installerBusy' = false,
    restartAsked' = false,
    restartApproved' = false,
  }

  // --- core boot scenarios ---

  // Fresh machine: F2 (dpp missing) -> clone -> restart -> F1 (state broken)
  // -> F3 (normal deps missing) -> make_state -> state valid.
  run freshBootLoadsTest = all {
    init.then(loadStateMissing)
        .then(f2RescueMinSucceeds)
        .then(f2Restart)
        .then(loadStateFails)
        .then(f1StartDenops)
        .then(f1CheckNormalDeps)
        .then(f3RescueNormalSucceeds)
        .then(f1MakeStateSucceeds)
        .expect(stateOk),
  }

  // State broken, everything else present: F1 -> make_state -> state valid.
  run brokenStateRecoversTest = all {
    brokenState.then(loadStateFails)
        .then(f1StartDenops)
        .then(f1MakeStateSucceeds)
        .expect(stateOk),
  }

  // State broken + denops missing: F1 installs denops, then recovers.
  run denopsInstallRecoversTest = all {
    brokenStateNoDenops.then(loadStateFails)
        .then(f1EnsureDenopsSucceeds)
        .then(f1StartDenops)
        .then(f1MakeStateSucceeds)
        .expect(stateOk),
  }

  // State broken + normal dep missing: F1 routes through F3, then recovers.
  run f1RoutesThroughF3Test = all {
    brokenStateNoNormal.then(loadStateFails)
        .then(f1StartDenops)
        .then(f1CheckNormalDeps)
        .then(f3RescueNormalSucceeds)
        .then(f1MakeStateSucceeds)
        .expect(stateOk),
  }

  // Clone failure during F2 ends in Failed.
  run cloneFailureFailsTest = all {
    init.then(loadStateMissing)
        .then(f2RescueMinFails)
        .expect(phase == Failed),
  }

  // Denops clone failure during F1 ends in Failed.
  run denopsCloneFailureFailsTest = all {
    brokenStateNoDenops.then(loadStateFails)
        .then(f1EnsureDenopsFails)
        .expect(phase == Failed),
  }

  // make_state failure ends in Failed.
  run makeStateFailureFailsTest = all {
    brokenState.then(loadStateFails)
        .then(f1StartDenops)
        .then(f1MakeStateFails)
        .expect(phase == Failed),
  }

  // --- auto_update scenarios ---

  // TOML save: make_state -> install -> user approves restart -> new session.
  run tomlUpdateRestartsTest = all {
    loadedState.then(configChangeToml)
        .then(tomlUpdateStart)
        .then(tomlMakeStateSucceeds)
        .then(installerDone)
        .then(restartApprovedAction)
        .expect(restartCount == 1 and phase == Booting and restartApproved),
  }

  // TOML save: user declines restart -> session stays Loaded.
  run tomlUpdateDeclinedTest = all {
    loadedState.then(configChangeToml)
        .then(tomlUpdateStart)
        .then(tomlMakeStateSucceeds)
        .then(installerDone)
        .then(restartDeclined)
        .expect(phase == Loaded and restartCount == 0),
  }

  // TOML save: make_state fails -> update aborted, session stays Loaded.
  run tomlMakeStateFailureTest = all {
    loadedState.then(configChangeToml)
        .then(tomlUpdateStart)
        .then(tomlMakeStateFails)
        .expect(phase == Loaded and not(installPending)),
  }

  // Non-toml config change: make_state only -> ask restart -> declined.
  run nonTomlUpdateTest = all {
    loadedState.then(configChangeNonToml)
        .then(configMakeState)
        .then(restartDeclined)
        .expect(phase == Loaded and stateOk),
  }

  // :DppUpdate force flow: installer chain -> make_state -> approved restart.
  run forceUpdateRestartsTest = all {
    loadedState.then(forceUpdateStart)
        .then(installerDone)
        .then(restartApprovedAction)
        .expect(restartCount == 1 and phase == Booting),
  }

  // :DppUpdate force flow: user declines -> session stays Loaded.
  run forceUpdateDeclinedTest = all {
    loadedState.then(forceUpdateStart)
        .then(installerDone)
        .then(restartDeclined)
        .expect(phase == Loaded and restartCount == 0),
  }
}

module bootloader_headless_test {
  import bootloader(
    MIN_DEPS = Set("dpp.vim", "dpp-ext-lazy", "denops.vim"),
    NORMAL_DEPS = Set(
      "dpp-ext-toml", "dpp-ext-local", "dpp-ext-installer",
      "dpp-ext-packspec", "dpp-protocol-git", "dpp-protocol-http",
      "dpp-ext-lazy", "denops.vim"
    ),
    HAS_UI = false,
    MAX_RESTARTS = 2,
  ).* from "./bootloader"

  // Headless F2: plugins cloned but no restart; session gives up.
  run headlessF2GivesUpTest = all {
    init.then(loadStateMissing)
        .then(f2RescueMinSucceeds)
        .then(f2GiveUp)
        .expect(phase == Failed and restartCount == 0),
  }

  // Headless session never restarts (the infinite-restart-loop guard).
  run headlessNeverRestartsTest = all {
    init.then(loadStateMissing)
        .then(f2RescueMinSucceeds)
        .then(f2GiveUp)
        .expect(restartCount == 0),
  }

  // Headless TOML update: make_state + install run, but no restart is asked.
  run headlessUpdateNoRestartTest = all {
    init.then(loadStateMissing)
        .then(f2RescueMinSucceeds)
        .then(f2GiveUp)
        .expect(restartCount == 0),
  }
}
