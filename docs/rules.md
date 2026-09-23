# Rules distilled from this project

Each rule comes from something that happened here: a bug, a measurement, or a dead end. The
evidence is listed so the rule can be re-checked, not just believed.

## A. Architecture

1. **State changes through one function. The UI only sends events.**
   Evidence: 23 logic steps ran in 0.2 s headless and 8 s attached with the same script, because
   the script talks to `reduce`, not to buttons.

2. **Navigation is data in the model, never a call in a view.**
   Evidence: "back keeps the search filter", "re-select tab pops to root", and the bench
   traversal were each one line of reducer logic and needed no UI code.

3. **Every side effect is an interface owned by the presenter, and its result comes back as an
   event.** Evidence: swapping the seed for the Rick and Morty API touched the reducer once
   (three events) and left all 20 existing unit tests untouched; loading and failure got tests
   without a network.

4. **Invalid events are typed errors, not silent no-ops.**
   Evidence: `already open`, `already at the root`, `no character with id 99` are asserted in
   the scripts; an agent needs to know a command did not apply.

5. **Snapshot is the contract.** Everything the UI shows must be derivable from one JSON
   snapshot of the model. Evidence: the CLI, the bridge, the shell script and the XCUITest
   all assert against the same `Snapshot`, so a UI redesign would break none of them.

## B. Testing strategy

6. **Three tiers, in this ratio: many reducer tests, some bridge-driven scripts, few real-user
   UI tests.** Evidence per run: reducer 26 tests in 3 ms; bridge 23 steps in 0.2 s headless
   or 8 s attached; XCUITest 15 steps in 17 to 38 s.

7. **Real-user tests check state too.** After each gesture, read the model through the bridge.
   Evidence: this is what turned "the screen looks right" into "the app believes the right
   thing" and caught nothing being loaded before the first assertion.

8. **Never sleep. Wait for a condition you can name.** Evidence: replacing fixed pauses with
   exists-first waits cut the UI run from 73 s to 38 s with zero behavior change.

9. **Know your test framework's hidden waits before optimizing your app.** Evidence:
   XCUITest's quiescence wait cost about one second per event; `waitForExistence` polls once a
   second, so a 300 ms transition was billed as 1 s. Fine-grained polling and disabling the
   idle wait took the run to 21 s.

10. **When gestures are fast, ask the app whether it is ready.** Evidence: without the idle
    wait, a back swipe during a push was ignored, a tap on a decelerating list became "stop
    scrolling", and a tap after closing search was swallowed. The `settle` command (no
    transition, no scrolling) fixed all three deterministically; retry-on-no-effect is the
    fallback.

## C. Debug bridge and agent tooling

11. **The bridge answers only after the UI has applied the change.** Evidence: answering after
    two run-loop turns left a race where SwiftUI wrote back a stale navigation path and undid
    the next push (about 1 in 3 bench runs). Waiting until the navigation controller matches the
    model's stack made 120 consecutive open/close cycles pass.

12. **Verify "animations off" with a timing log, not by trusting the switch.**
    Evidence: `UIView.setAnimationsEnabled(false)` left push/pop at ~480 ms; navigation needed
    its own switch. With it, an open+back cycle went from ~1000 ms to ~50 ms.

13. **A persistent session beats one-shot commands.** Evidence: the bridge restores animations
    when the last client leaves, so a one-shot `send "animations off"` was undone immediately
    and produced a misleading benchmark.

14. **Debug-only, localhost-only, zero cost in release.** Evidence: the whole bridge is under
    `#if DEBUG` and listens on loopback; nothing about it ships.

## D. Platform quirks to check on every new OS version

15. **Do not hardcode system control labels; dump the accessibility tree first.**
    Evidence: iOS 26 labels the search cancel button "Close", not "Cancel"; toggles needed a
    trailing-edge tap; tab buttons were identified by symbol name.

16. **A gesture that keeps momentum is not "done" when the tool returns.** Evidence: flick
    scrolling left the list decelerating for ~1 s; a controlled drag was faster to settle.

## E. Process and tooling hygiene

17. **Background processes must not inherit the session's pipes.** Evidence: the video recorder
    inherited the repl fifo and the script hung for 11 minutes.

18. **Guard every external tool with a timeout and a "done" signal.** Evidence: xcodebuild
    hangs after the suite at "Resolve Package Graph"; the script now watches for the suite
    result line and kills the process.

19. **Keep the offline seed even after wiring a real API.** Evidence: unit tests, the local CLI
    and `--offline` still run with no network, and the same scripts run against live data.

20. **Migrate one slice at a time; keep old tests green until the new tier replaces them.**
    Evidence: the migration playbook (`docs/migration-playbook.md`) is structured this way
    because every fast-mode bug above was found only because the slower tier still passed.

21. **Bind debug listeners to an explicit address and fail loudly on collision.** Evidence: a
    stale simulator app held `127.0.0.1:8765` (IPv4), the bridge bound the IPv6 wildcard and
    logged "ready", and every client hung with no reply. The bridge now binds `127.0.0.1` and
    reports "Address already in use".

22. **A loop framework is an implementation of these rules, not a substitute.** Evidence:
    porting the presenter to Mobius.swift (`docs/mobius-port.md`) changed no script, bridge
    command or UI test; the rules above still decided what the update, effects and bridge do.

23. **In a sandboxed app, resolve user folders through the password database, not
    `FileManager.urls(for:)`.** Evidence: the watcher reported Downloads as denied while TCC had
    granted it, because the URL pointed into the app container; `getpwuid(getuid())` fixed it.

24. **An unanswered privacy prompt stalls more than the app that asked.** Evidence: while the
    Downloads prompt waited, the privacy daemon queued the shell's Documents access and a
    `swift test` compile hung at 0 % CPU for nine minutes. Answer prompts before running
    anything else, and never launch the app from an unattended script on a fresh machine.

25. **An outcome event answers with a toast, never a throw.** Evidence: the second "Add
    Folder…" of the same folder threw `folderAlreadyWatched` from `folderChosen`, but that event
    came back from the panel effect, so no caller saw the error and the scenario step could only
    assert on silence. Errors are for events a caller sent; outcomes talk to the user.

26. **A scripted answer to a system panel grants no sandbox access.** Evidence: `pick /tmp/x`
    added the folder and started the watcher, yet nothing ever arrived: the open panel is what
    hands the sandbox a bookmark, and the script skipped it. Attached tests put extra folders
    under `~/Downloads`, which the entitlement already covers.

27. **A fake clock must wait for its sleeper before advancing.** Evidence: the undo-expiry
    test failed one run in three because the timer task had not yet called `sleep` when the test
    moved time forward, so its deadline landed in a future that never came. `TestClock.advance`
    now waits for a sleeper; polling assertions (`eventually`) cover the dispatch that follows.

28. **The first click into a popover must do the work, not just wake the window.** Evidence:
    with another app frontmost, the first click on a row did nothing and the second opened the
    file. The cooperative `NSApp.activate()` had been refused, so the popover window was not
    key and AppKit spent the click on making it key. Now the app activates with
    `ignoringOtherApps`, the hosting view answers `acceptsFirstMouse`, and
    `scripts/test-click.sh` reproduces the case with real `CGEvent` clicks, because a bridge
    event or an accessibility "press" never goes through the first-mouse path.

29. **A toggle button that also dismisses the thing it toggles gets two events per click.**
    Evidence: with the popover open, clicking the status item closed it on mouse-down (a
    transient popover closes on any outside click) and reopened it on mouse-up (the button's
    action toggles). The delegate now notes a close with the mouse over the button and the
    next action is dropped; a bridge `hotkey` never showed this because it is one event.

30. **Only one instance, and know which one you are talking to.** Evidence: a run from Xcode
    and a build from `.build` were both up, each with its own status item and both after the
    bridge port; every real click landed on the wrong one and an hour of "the status item
    stopped working" followed. The app now quits at launch when another copy is running, and a
    debugged process ignores even `kill -9` until its debugserver goes.

31. **Blame the environment before the API.** Evidence: `sendAction(on: [.leftMouseUp,
    .rightMouseUp])` was declared broken and replaced twice, when the real fault was the second
    instance from rule 30 taking the clicks. With one instance the canonical call works.

## Performance guardrails (not yet needed at 20 items, will be at 10k)

- Normalize large collections by id; keep the model small and copy-cheap.
- Compute derived data once in the reducer or memoize; do not sort in a computed property that
  the view reads several times per render.
- Split observable state so a change re-evaluates only the views that read that slice.
- The reducer runs on the main thread; anything heavier than microseconds goes into an effect.
