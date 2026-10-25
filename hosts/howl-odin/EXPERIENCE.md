# Howl Odin desktop experience charter

This is the living user-experience map for the experimental Odin desktop client.
It is deliberately not a release schedule and not a second architecture document.

`README.md` says what the client can prove **today**. Cairn records bounded work
and receipts. This file says what kind of desktop terminal application we are
trying to make and what experiences are worth pressure-testing next.

## North star

Build a polished, Windows-familiar desktop terminal shell that disappears into
ordinary work while keeping Howl's terminal truth singular.

A Windows Terminal user should understand the application immediately: tabs,
panes, profiles, a profile menu, command palette, settings, familiar keyboard
navigation, and restrained desktop chrome. Familiarity is a UX reference, not a
requirement to clone Microsoft's pixels, configuration format, internals, or
limitations.

Howl remains the terminal. Odin owns the desktop application around it.

## Status vocabulary

- **PROVEN** — exercised through the real Howl path with durable tests or a
  physical/nested desktop canary.
- **ACTIVE** — implemented enough to dogfood, but still under deliberate
  pressure or missing important edge behavior.
- **WANTED** — part of the intended ordinary desktop experience; implementation
  order is deliberately flexible.
- **EXPLORE** — potentially valuable, but should earn its complexity through use.

These labels are descriptive, not priority scores.

Status reconciled on 2026-09-17 through `c953298`: titles and progress have live
Odin consumers; the image-scan and resize-discovery fixes are accepted. Build/test
proof does not imply installation on another node or client. Shortcut spellings
below describe defaults, not a user's persisted overrides.

## Product rules

1. **One terminal truth.** Odin does not parse VT, generate escape sequences,
   own terminal history, shape terminal text, or invent terminal image rules.
   Those stay in the existing Howl owners.
2. **Desktop policy stays local.** Windows, tabs, panes, profile recipes,
   selection chrome, clipboard policy, settings, keybindings, and OS integration
   belong to the desktop client.
3. **Familiar before clever.** Common terminal gestures should behave the way an
   experienced desktop-terminal user expects unless Howl has a concrete reason
   to differ.
4. **Idle means idle.** An unchanged terminal should sleep. Work should be driven
   by Instance revisions, UI events, or real timers that own visible behavior.
5. **No fake settings.** A setting appears when it changes a real client contract.
   Unsupported options are named honestly instead of being decorative toggles.
6. **Pane-local by default.** History, selection, focus, geometry leadership,
   mouse ownership, and process lifetime should not leak between sibling panes.
7. **Failures should explain themselves.** Exited shells, unavailable Instances,
   missing resources, unsupported terminal images, or invalid configuration stay
   failures. Odin must not switch to a substitute renderer, backend, geometry,
   label source, process, profile, or config value to make the UI appear healthy.
   Ordered font-face fallback inside text shaping is the intentional exception.
8. **Dependencies must buy something.** Prefer Odin, SDL3, Howl's existing
   modules, and small native seams over a general UI framework unless a concrete
   experience earns the larger dependency.

## Experience inventory

### 1. Launch, window, and first-run behavior

**PROVEN**

- Opens as a normal resizable high-DPI desktop window.
- Startup profile is persistent and may either attach the built-in Home Instance
  or create a client-owned Local Instance in-process.
- Window rendering and pointer geometry share one logical coordinate system.
- Maximizing/resizing drives owned Local Instance geometry; attached Instances
  remain fixed unless the user explicitly takes Instance size control.

**PROVEN — multi-window policy**

- One Odin process owns one OS window. `Ctrl+Shift+N` and the command palette
  launch another independent Odin process with the same inherited environment
  and config; no tab or Instance state is transferred implicitly.
- The spawning window retains only one process handle, owned by a self-cleaning
  reaper thread. A KWin canary created a second PID/window, then closing only the
  child removed that PID and the reaper thread while the original window stayed
  alive.
- Live tab tear-out / cross-window tab movement is deliberately unsupported in
  this cut because no first-class UI-state transfer owner exists yet. We do not
  fake tear-out by destroying/recreating Instances.

**WANTED**

- Remember useful window geometry without restoring a broken/off-screen layout.
- Heterogeneous multi-monitor moves and display-hotplug dogfood coverage.
  Live display-scale change handling is wired,
  but moving one window across differently scaled real outputs is not yet proven.
- Explicit startup choices: default profile, attach an explicit Instance or browse
  a saved Server, or restore an accepted previous application layout.
- Qualify ordinary installed-bundle launch/update on the target desktop; native
  identity, icons, and the owned installer already exist (section 16).

**EXPLORE**

- Quake/drop-down summon mode.
- Tab tear-out into another window and cross-window tab movement.

**ACTIVE: compact desktop frame, 2026-09-17**

The current iteration merges tabs/window controls, removes the nested terminal
mat, and shares one content geometry across rendering and input. Gutter color
comes from accepted canonical presentation. Resize rim, scrollbar and cells have
separate hit lanes. Native drag/resize, matched caption clicks and compact tabs
have bounded policy tests; real desktop regression coverage remains a co-op task.
This is a source/bundle iteration, not an installer or new deployment channel.

### 2. Tabs

**PROVEN**

- Create, select, close, and cycle tabs. `Ctrl+Shift+W` closes the active pane,
  then tab, and finally the window when only one single-pane tab remains.
- `+` and `Ctrl+T` use the configured default profile. The explicit profile menu
  can always choose Local shell or the direct Home Instance; saved Servers are a
  separate browse route.
- Closing a client-owned tab destroys only its owned Local Instance; closing an
  attached view only disconnects that client and leaves the external Instance alive.
- `Ctrl+1…8` selects tab slots directly. `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle,
  while `Ctrl+Shift+PageUp/PageDown` reorders the active tab.
- Held tab chips immediately gain a small outline and follow the pointer's
  original grab point before any reorder threshold is crossed. The destination
  slot remains outlined. This is input-driven painting, not an animation clock,
  texture copy, or duplicate Instance state. A stationary held chip adds no timer.
- Keyboard interruption cancels tab/scrollbar intent before navigation/overlays;
  the canceled gesture's left release is consumed rather than clicking the new
  surface. Unrelated buttons, fresh clicks and TUI mouse releases stay independent.
- Pointer tab drag uses the same `move_tab` owner as keyboard reorder. A mixed
  Home/Local canary visibly changed `Home, Local A, Home, Local B` into
  `Home, Local B, Local A, Home` while both Local child PIDs remained unchanged.
- `Ctrl+Shift+D` duplicates the active tab's **profile recipe**, not live PTY
  state. Duplicating a Local tab increased owned children 2 → 3 and opened a
  fresh shell prompt.
- Framing-v9 snapshots carry canonical title and progress properties. The active
  pane supplies the tab label; an absent/empty title falls back to the profile
  name without modifying the saved recipe. Desktop labels validate UTF-8,
  replace control/bidi formatting, and stay clipped to their tab bounds.
- The thin progress strip consumes retained OSC 9;4 normal, indeterminate,
  failure, paused, and clear states. Indeterminate has no timer; zero-percent
  error/pause still has a status cue. The strip and active-tab underline have
  separate geometry. Metadata-only updates, title push/pop, clear, late attach,
  and a real Zig build were exercised without reinterpreting terminal text.
- The native window title remains Howl; dynamic tab labels are a separate policy.

**WANTED**

- Optional MRU switching behavior if it proves better than deterministic cycling.
- Optional tab-local activity indication, separate from the already-proven
  non-focus-stealing desktop attention policy.
- Reopen a recently closed attachment when its target Instance still exists, or
  a Local tab when the launch recipe is safely repeatable.
- Tab context menu with the same action registry as the command palette.

### 3. Panes and layout

**PROVEN**

- A bounded recursive pane tree owns layout topology while stable pane slots own
  Instance views. Repeated active-leaf splits can nest without moving Instance
  identities; the accepted Local canary created three independently owned panes
  with three distinct child shells/Instances.
- Pane-local focus, close/promote behavior, clipping, history, selection, and
  geometry leadership remain independent of tree topology.
- Closing a nested leaf retires only that pane view and its owned Local Instance,
  if any; attached external Instances survive client close. The three-owned-pane
  canary collapsed 3 → 2 → 1 while Local child count followed 3 → 2 → 1 exactly.
- Side-by-side and top/bottom split actions may be nested arbitrarily within
  the eight-pane bound. They are visible mappings but have no default shortcut.
- Spatial focus, directional resize, and directional swap are twelve explicit
  parameterized mappings. All are unbound by default, so Alt remains terminal
  input unless the user deliberately assigns an Alt chord.
- Directional resize moves the nearest divider in that axis, clamped to a sane
  15–85% ratio. Pointer divider drag uses the same ratio owner plus a forgiving
  invisible hit lane. One canary moved the divider from x=588–591 to x=740–743
  and the two canonical PTYs converged to 34×78 and 34×44 without changing child
  PIDs. Release outside the window and focus theft both terminated the drag; later
  buttonless pointer motion left the divider stationary.
- `Ctrl+Shift+Z` remains the default mapping for pane zoom. Directional swap
  exchanges Instance-view ownership between geometric neighbors without restarting
  either Instance when the user binds one of the visible swap mappings. A mixed
  topology canary (full-width top plus two bottom panes) preserved all three child
  PIDs through focus, keyboard resize, zoom/unzoom, and swap.

**WANTED**

- Split with a chosen profile instead of only the current default.
- Layout persistence only after lifecycle semantics are boring and exact.

### 4. Profiles

**PROVEN**

- Local shell means “create and own one canonical Instance in-process”. Linux
  uses the native PTY owner; Windows uses ConPTY. Both expose listener-free ordinary
  HWLS streams to the same Odin clients and create no sibling daemon or Server.
- Home Instance means “attach another non-owning direct client view”. Saved Servers
  are persisted separately and browse Server → Sessions → Instances before attach.
- One persisted default profile drives startup, `+`, `Ctrl+T`, and split creation.
- Owned Local shells inherit the real desktop process environment. A blank shell
  explicitly resolves through `SHELL` on Unix or `COMSPEC` on Windows; if that
  declared source is unavailable, launch fails rather than substituting `/bin/sh`
  or `cmd.exe`.
- User profiles are bounded typed recipes with stable id/name, attach-vs-launch
  ownership, shell, optional command/cwd, endpoint, environment fields, and optional
  8–48 px presentation override. Blank/zero keeps the global font size. Schema 4
  persists labelled Server endpoints separately from those recipes.
- Linux Local carries shell/command/cwd into the canonical in-process Instance.
  Windows Local carries interactive shell/cwd and rejects nonempty command until
  command-shell grammar is deliberately specified. Nonempty Local environment
  overrides currently fail explicitly rather than being silently ignored.
- Saves preserve user recipes atomically and name the default by stable profile id;
  older schemas remain readable and migrate only on later save.

**PROVEN — profile editor**

- Settings → Profiles is a real bounded catalogue with keyboard/pointer selection.
  Built-ins are visibly read-only; `D` duplicates either built-in or user recipe
  into a stable-id user-owned copy, while `N` creates a fresh launch recipe.
- The Profile page edits name, attach-vs-launch mode, shell, command, cwd, endpoint,
  inherited/global font override, and typed environment name/value entries. Text
  editing owns SDL `TEXT_INPUT`/preedit while active, with the candidate area anchored
  to the exact value row rather than leaking keystrokes into the terminal.
- Delete refuses built-ins and any recipe referenced by a live tab/pane. An unused
  user recipe deletes atomically and later profile indices/default references remap.
- Launch/attach mode changes clear incompatible fields in one save. A duplicated Lab
  canary switched Launch → Attach and atomically dropped shell/command/cwd/env while
  seeding the attach endpoint.
- Launch-policy edits apply to future/restarted Instances; presentation font is the
  explicit live exception. A running Local Instance changed **34×124 at 15 px → 28×102
  at 18 px → 34×124 at 15 px** with child PID/Instance identity unchanged.
- Settings edits round-trip cwd, environment fields, and presentation size through
  the typed profile config. Current Local launch applies shell/command/cwd and font
  policy, but rejects nonempty environment overrides explicitly rather than claiming
  they reached the child. In-use delete is refused; create/rename/delete remain bounded.

**WANTED**

- Profile icon and optional color accent.
- Additional per-profile defaults beyond the current typed launch recipe,
  environment fields, and font override. Built-in/user duplicate/edit/delete is proven.
- Direct custom-profile launch from the command palette. The profile menu and
  built-in Local/Home palette actions already work.
- Working-directory inheritance when splitting or duplicating where the canonical
  child/Instance contract can support it honestly.
- Import/export of user profile configuration without inventing compatibility
  with Windows Terminal's JSON format.

**EXPLORE**

- Platform/profile discovery such as installed shells, WSL, SSH recipes, or
  containers. Discovery should not become implicit remote/network policy.

### 5. Ordinary terminal input

**PROVEN**

- Committed UTF-8 text.
- Named and Unicode physical keys.
- Enter, Backspace, Delete, arrows, Tab, modifier chords, and ordinary control
  input through `howl-client.actions`.
- Semantic paste preserves VT-owned bracketed-paste behavior.
- Neovim and btop alt-screen open/input/exit canaries.
- F1–F12, lock keys, and numeric-keypad physical identities use Howl named-key semantics; F5, F12, and Shift+F5 were pressure-tested through VT-owned encoding. Standalone modifier-key transitions remain deliberately withheld until shortcut arbitration can prevent half-chord leakage.
- Kitty all-event keyboard mode has an end-to-end repeat/release canary: holding F5 for 700 ms produced `ESC[15~`, four `ESC[15;1:2~` repeats, then `ESC[15;1:3~` release through VT-owned encoding.
- Real desktop dead-key composition was pressure-tested in the private KWin/XWayland lab with `us(intl)`: dead-acute alone stayed uncommitted, then `e` produced exactly one composed `é` through SDL `TEXT_INPUT`.
- SDL `TEXT_EDITING` preedit is implemented as bounded client-local state for both terminal and Find owners; the platform candidate area follows the active terminal cursor or Find insertion point, UTF-8 character caret offsets are converted to pixel placement, and only committed `TEXT_INPUT` crosses into Howl. Unit/owner-transition coverage is green.

**WANTED**

- A real runtime `TEXT_EDITING`/candidate preedit producer canary on a desktop with fcitx/ibus/maliit or another native IME. The X11 dead-key canary committed composition but did not emit a visible preedit event.
- Broader keyboard-layout/dead-key coverage when it reflects real user environments.
- Explicit handling of application shortcuts versus terminal shortcuts, with no
  modifier-only keypress side effects.

### 6. Mouse and pointer arbitration

**PROVEN**

- Canonical interaction state decides pointer ownership. With terminal mouse
  tracking absent, primary drag remains local selection and wheel remains local
  scrollback; the scrollbar still owns only its narrow client-chrome hit lane.
- When the child enables terminal mouse tracking, Odin sends semantic press,
  release, button-drag motion, hover where requested, and wheel facts through
  `howl-client.actions.mouse`; VT alone chooses the child escape encoding.
- A controlled SGR button-event canary received exact mouse reports for click,
  drag, and wheel. A terminal-routed button-down owns the physical gesture until
  release, and focus loss synthesizes semantic releases from the last known
  terminal coordinate.
- Shift+drag and Shift+wheel are explicit client-local overrides while mouse
  tracking is enabled. In the controlled canary both overrides produced no new
  child mouse bytes; Shift+drag painted canonical selection and Shift+wheel
  entered local HISTORY.
- Real managed-KWin focus loss/gain is sent as semantic focus input. With DEC
  focus reporting enabled the child received ESC[O / ESC[I through VT-owned
  encoding; with focus reporting disabled a second canary received no bytes.
- DEC alternate-scroll is canonical-key routing rather than client escape generation.
  With mouse tracking off, alternate screen + DEC alternate-scroll + application
  cursor mode made wheel-up/down arrive as ESC OA / ESC OB from VT; Shift+wheel
  remained client-local and emitted no child bytes.
- Neovim, btop, tmux, and less mouse/focus pressure canaries are green: Neovim click/wheel plus Shift-selection override, btop menu/wheel, tmux mouse pane focus with nested input, and less tracking-off wheel-ignore plus PageDown navigation.

**WANTED**

- Pointer shape/visibility policy from canonical pointer mode where supported.

### 7. Scrollback and history

**PROVEN**

- Pane-local canonical retained-history observation.
- Physical wheel scrolling, including fractional high-resolution wheel deltas
  accumulated into whole canonical rows rather than amplified into fake ticks.
- Shift+PageUp/PageDown page navigation.
- Ctrl+Shift+Home to oldest retained row and Ctrl+Shift+End to LIVE.
- Absolute retained-row anchor keeps an old viewport stationary while new PTY
  output arrives.
- Bounded-ring eviction advances only when the anchored rows actually leave the
  retained ring.
- Alternate-screen entry and terminal input return the affected pane to LIVE.
- Thin per-pane scrollbar indicates retained position.
- Scrollbar supports direct seek and thumb drag with a forgiving invisible hit
  lane while preserving quiet visual chrome.
- A scrollbar button press owns its drag independently of optional explicit SDL
  capture. The unsupported Wayland capture path no longer cancels after the
  initial seek. Private KWin proves continuous thumb/track drag, outside-window
  release, focus cancellation, and isolation across sibling/nested panes; 1.7x
  single/split canaries also pass. Release/focus/close still end the gesture.
- Vertical-only resize preserves the top retained row.
- Horizontal reflow/column change deliberately returns an owned scrolled pane to
  LIVE because projected row identity is not stable across reflow.
- Executable Odin history/scrollbar tests run in the owner build, including
  capture-unavailable gesture admission, bounds, cancellation and pane isolation.

**PROVEN — Find**

- Ctrl+Shift+F opens a compact pane-local Find bar without mutating the Instance.
- Exact case-sensitive UTF-8 matching is owned by reusable `howl-client.search` over
  immutable projected rows; concealed text is not searchable and wide-cell matches
  use the same canonical visual-span rules as selection.
- Enter walks older results and Shift+Enter walks newer results, including multiple
  matches on one projected row.
- A dedicated search connection/worker is created lazily on the first actual query;
  merely opening Find adds no thread or Instance connection.
- Search may page the complete 4,096-row retained ring without blocking SDL. Results
  name canonical rows/columns and recenter through the same absolute history anchor,
  so live output can continue underneath a highlighted old match without dragging it.
- Search freezes one retained-domain cut at request start. If a hot full ring evicts
  oldest rows faster than the client can inspect them, the result is marked incomplete
  rather than turning missing evidence into a false no-match.
- Reflow or eviction invalidates an affected result explicitly as “match expired”.
  Closing Find removes its chrome/highlight but deliberately leaves the pane at the
  searched history position.
- Five executable Odin Find-state tests run with the owner build in addition to the
  shared `howl-client.search` unit coverage.

**ACTIVE**

- Continue resize, font-zoom, split/collapse, live-output, oldest-ring, and
  multi-pane pressure without weakening the reflow safety rule.
- Pressure Find across multiple panes/tabs and a full moving ring; refine compact
  feedback without growing a search-index subsystem prematurely.

**WANTED**

- Search result counts only if they can be derived cheaply and honestly.
- Optional case-insensitive/regex modes only after ordinary exact Find is boringly
  reliable and their Unicode semantics are explicit.
- Cross-soft-wrap logical-line search only if a stable logical-line identity earns it;
  do not silently pretend adjacent projected rows are one immutable string.
- Preserve the proven selection edge-autoscroll behavior (section 8) under the
  remaining multi-pane/history pressure cases.
- A future cross-reflow anchor only if Instance/VT gains a stable logical-line
  identity that can name the same text after column reflow. Do not fake this
  with row-number heuristics.

### 8. Selection and clipboard

**PROVEN**

- Pane-local primary drag stores stable canonical row/column endpoints and paints
  only the visible intersection of the retained range.
- Selection highlight follows the canonical text extent instead of filling empty
  row tails. The native bridge retains bounded row shapes from the same accepted
  Canvas frame and uses `howl-client.selection.Range.textSpan`, matching Web and
  Flutter's policy. Crossed hard line breaks get one newline marker, empty lines
  remain visible as one selected cell, and final/soft-wrapped rows gain no marker.
  A real KDE pointer canary covered unequal log lines, an empty line, leading
  spaces, CJK and combining text; canonical extraction stayed byte-identical to
  the old bridge. Wrong geometry/bank/row facts produce no phantom span.
- Ctrl+Shift+C asks `howl-client.selection` and Instance `text_extract` for
  canonical UTF-8; it does not scrape rendered glyphs. VT normalizes continuation
  cells to their lead grapheme during extraction.
- Selection survives manual wheel/PageUp/scrollbar movement and live output while
  both endpoints remain retained. It may move completely offscreen and still copy
  the original canonical range; returning the viewport over it paints the same
  stable endpoints again.
- Ctrl+Shift+V uses semantic paste, and ordinary terminal input clears selection
  while returning to LIVE.
- Eviction, screen-bank change, and column reflow invalidate stale ranges instead
  of silently retargeting them. Focus loss/window close ends an active drag while
  retaining any noncollapsed range accumulated so far.
- Selection drag edge-autoscroll is built on the same stable endpoint model:
  the top/bottom two-row band moves one retained row every 100 ms, expands the
  canonical range through the newly visible cells, and stops at oldest/LIVE.
  The SDL main loop uses a timeout only while that gesture is armed; after release
  the client returns to indefinite event sleep (measured 0.00% of one core idle).
- Eleven executable stable-selection/edge-policy tests run in the Odin owner build.

- Double-click expands the clicked cell through canonical word selection: one
  contiguous non-space word, including across a canonical soft-wrap boundary. A
  lab canary double-clicked the second projected row of a 140-cell wrapped word
  and copied all 140 cells as one word.
- Triple-click deliberately selects the current projected visual row, trimmed to
  its real text extent. It is not labelled a hard/logical-line gesture: clicking
  the second row of a wrapped line copied only that projected row, not the prefix
  or previous wrapped row.

**ACTIVE**

- Continue selection pressure across split panes, ring eviction, and app-owned mouse
  modes before adding platform-specific selection conveniences.

**WANTED**

- A separate hard/logical-line selection gesture only if Howl gains an identity
  that can name the same logical line honestly across viewport/reflow boundaries.
- Copy action in context menu/command palette and useful disabled-state feedback.
- Linux middle-click/primary-selection behavior only if it remains distinct from
  the normal clipboard and can be implemented without platform confusion.

### 9. Search and navigation

**PROVEN**

- Ctrl+Shift+F exact case-sensitive retained-history Find, with Enter/Shift+Enter
  older/newer navigation and stable canonical row/column highlights.
- Find scans on a lazy read-only worker connection rather than blocking SDL, and
  stable matches remain anchored while new output arrives.
- Reflow/eviction expires stale matches explicitly; a moving full ring reports an
  incomplete search instead of claiming an authoritative no-match.

**ACTIVE**

- Continue multi-pane/tab, hot-ring, resize, and ordinary desktop pressure on Find
  without introducing a persistent search index before it is earned.

**WANTED**

- Search result counts only if they remain cheap and honest.
- Case-insensitive and regex modes only when their Unicode/bounded semantics are
  explicit; exact UTF-8 remains the simple baseline.
- Cross-soft-wrap logical-line matching only with a stable logical-line identity.
- Command-palette actions for oldest/LIVE, next/previous result, pane focus,
  profile launch, and layout operations.
- Broader navigation conveniences must preserve the proven canonical OSC 8
  Ctrl+click policy (section 16); regex-only URL guessing is not a missing parser.

### 10. Alternate-screen and full-screen applications

**PROVEN**

- Neovim alt-screen lifecycle.
- btop full-screen lifecycle and repaint.
- 1049 saved-cursor resize/reflow backend fix exercised through the client.

**WANTED**

- Extend the existing Neovim/btop/tmux mouse/focus canaries (section 6) with
  longer sessions and zellij pressure.
- `less`, `man`, `fzf`, `yazi`, interactive Git TUIs, and long-running dashboards.
- Repeated enter/exit with resize, split, font zoom, and focus churn.
- No stale history chrome while the alternate screen owns interaction.

### 11. Renderer and visual correctness

**PROVEN**

- Real shared `howl-render` Terminal Canvas.
- SDL consumes Canvas solids, alpha masks, and RGBA resources without terminal
  cell parsing.
- Canvas residency avoids redundant atlas upload on unchanged generations.
- Font/DPI rebuild keeps the last accepted canonical Canvas frame visible until
  the replacement renderer accepts a complete frame. This is retained canonical
  state, not an emergency renderer. Replacement failure drops the retained frame
  and surfaces the exact Canvas error.
- Nerd/Powerline glyphs, ANSI colors, cursor, background, shaping, and HiDPI
  logical geometry are live in the Odin client.
- Display scaling keeps one logical desktop geometry while rasterizing terminal
  and application text at the monitor scale. Managed KWin canaries proved 1×,
  1.5×, and 2×: SDL's display scale remained the semantic scale while backing
  pixel density was allowed its expected fractional rounding (1.5× exposed
  ~1.50047 density from 1601 backing pixels over 1067 logical pixels).
- The canonical terminal Canvas scales its font/cell raster into backing pixels,
  then Odin projects Canvas destinations, clips, selection/search overlays,
  cursor geometry, scroll-edge bands, and pointer coordinates back through the
  same scale. At 2× a logical 15 px font became 30 px / 18×40 cells; at 1.5× it
  became 23 px / 14×31 cells, while an attached fixed Instance stayed exactly
  80×37. A client-owned shell at 1.5× resized its real PTY to 108×27 from the
  physical cell lattice instead of retaining the 80×37 startup geometry.
- SDL_ttf chrome uses logical point sizes with monitor-scaled DPI, rasterizes to
  a high-resolution surface, then presents that texture at its original logical
  rectangle. GDB proved UI/fallback fonts stayed 15 logical points at 108 DPI
  on 1.5× and 144 DPI on 2×; the 1×/1.5×/2× visual canaries retained identical
  tab/layout geometry. The fractional-scale owned-Instance canary returned to
  0.0% idle CPU after resize.
- Terminal images now use the canonical Howl external-resource lane end-to-end:
  Instance manifests identify exact image generations, `howl-client.images` fetches
  RGBA8 bytes on demand, `howl-render` owns placement/crop/z-order, Canvas names
  missing external resources and residency, and SDL sees only ordinary RGBA uploads
  and commands. A fresh image frame uploaded atlas + image once, then two unchanged
  frames produced zero uploads; replacing Kitty image id 78 kept Canvas resource 2
  while generation advanced 3 -> 5 and again settled to zero uploads.
- Kitty crop/z/lifetime are pressure-tested through the same seam: a 32x32 image
  placed only source x=16,y=0,w=16,h=32 into a 36x80 destination, negative-z image
  content painted below foreground `OVER` text, and deleting the exact placement
  emitted the matching resource-2 generation-7 Canvas removal and retired the SDL
  texture. A separate Sixel 60x30 red/green image rendered through the identical
  residency/refill path, proving Odin consumes canonical graphics state rather than
  a Kitty-specific protocol path.
- Desktop font ownership now carries the full face family. Explicit `HOWL_FONT`,
  `HOWL_ITALIC_FONT`, `HOWL_BOLD_FONT`, `HOWL_BOLD_ITALIC_FONT`,
  `HOWL_FALLBACK_FONT`, and `HOWL_SECONDARY_FALLBACK_FONT` paths win. Linux otherwise
  uses `fc-match` with exact family/style checks for JetBrainsMono Nerd Font regular,
  italic, bold and bold-italic plus the Arabic/CJK fallback chain. The bridge owns one
  independent `howl-text.FontSet` per available style and gives `howl-render` all four;
  Render selects style from canonical VT bits and falls back deterministically when an
  optional face is unavailable. A custom `HOWL_FONT` disables automatic style-family
  discovery unless matching style overrides are explicitly supplied, preventing silent
  cross-family mixing. No Unicode-specific shaping or raster logic exists in Odin.
- The accepted Switchyard canary proved real regular/italic/bold/bold-italic face
  consumption before its scaffolding was deleted. The Howl integration additionally
  proved all four real JetBrainsMono faces share exact 16 px terminal metrics while
  rasterizing the same glyph to four distinct alpha hashes.
- A live style/Unicode corpus proved bold/dim/italic/reverse/strike, single/double/
  curly/dotted/dashed underlines, independent underline color, truecolor foreground
  and background, combining marks, JetBrains Mono ligatures, generated box drawing,
  CJK wide-cell fallback, Arabic fallback/script shaping, and a CJK wide glyph at the
  final terminal column without corrupting the following line.

**WANTED**

- Image pressure across split panes/history/resize and the seven-image external
  resource bound where canonical semantics permit it.
- Windows installed-font family discovery to match the Linux fontconfig chooser.
- Color-emoji support only after `howl-text` gains a color-glyph/resource contract;
  its current raster API intentionally accepts only MONO/GRAY alpha masks, so Noto
  Color Emoji is not silently admitted as an incompatible fallback.
- Explicit bidi/reordering policy and pressure beyond HarfBuzz's per-run segment
  property guessing; one Arabic shaping canary is not treated as a full bidi proof.
- Renderer backend telemetry hidden behind diagnostics, not normal chrome.

**EXPLORE**

- Direct Vulkan presentation backend if measurements show SDL's renderer is the
  next meaningful performance/control ceiling.

### 12. Appearance

**PROVEN**

- Dark desktop shell.
- JetBrains Mono Nerd Font canary.
- Persistent exact 8–48 px font-size setting with one-pixel adjustment.
- Searchable Linux terminal-width family chooser backed by fontconfig. It admits
  spacing 90 dual-width families and spacing 100 strict monospace families while
  excluding proportional/unset spacing. Family search
  is keyboard-first, a selected candidate renders its own sample face, Right previews
  through the real terminal Canvas, Left restores, Enter commits and Esc cancels
  back to the previous exact recipe. One family resolves Regular/Italic/Bold/Bold italic automatically.
- Persistent exact-path Regular/Italic/Bold/Bold italic/Fallback 1/Fallback 2
  configuration remains the advanced layer. Blank values inherit startup discovery;
  a custom Regular makes blank styles reuse that regular face. Live edits restart
  renderer ownership without replacing canonical Instance state.
- Per-profile font size is either inherited or one exact value from the same range.
- Font zoom never mutates an attached non-owning Instance.
- Persistent application chrome themes with live preview: Howl Dark, Slate, and
  High Contrast. Theme switching changes tabs, Settings, borders, labels, and
  accents only; terminal Canvas colors remain byte-identical Howl output. A
  restart canary restored High Contrast from config, and the theme path retained
  the event-driven 0.00% quiet-CPU baseline.

**WANTED**

- Windows family-catalogue parity plus richer variable-font/OpenType refinement; exact-path configuration already remains available underneath.
- Canonical terminal color schemes and per-profile override only through the
  appropriate Howl VT/render ownership seam; application chrome must not become
  a hidden terminal-palette override.
- Terminal padding.
- Window opacity/acrylic only if the platform backend can do it without visual or
  performance debt.
- Cursor presentation preferences only where they do not override canonical
  terminal-requested semantics unexpectedly.

**EXPLORE**

- Background images and decorative effects. These are dessert, not architecture.

### 13. Settings and configuration

**PROVEN**

- Settings, profile menu, and Command Palette now route mouse-button releases
  into application controls instead of discarding all pointer events while an
  overlay is open. Buttons do not fall through into the terminal underneath.
- Profile discovery is pointer-first: visible New profile, Duplicate, Delete,
  per-row View/Edit, Set default, Save/Cancel, and environment controls invoke
  the same bounded profile operations as keyboard shortcuts. Built-ins are
  labeled templates and remain read-only. Deletion requires confirmation and
  keyboard repeat cannot supply that confirmation; in-use recipes remain protected.
- Clickable default-profile, terminal-size, profile-size, mode, and chrome-theme
  selectors share their draw/hit geometry. Informational fields do not look like text boxes. Appearance owns six bounded editable font-path fields with explicit inheritance, strict existing-file validation and live Canvas renderer restart.
- An edited field initially selects its existing value for replacement; Ctrl+A
  selects all, End/Right allows appending, and Backspace respects UTF-8 boundaries.
  Save validation keeps rejected/unsaved input visible; other pointer navigation
  cannot silently discard it. This remains a small end-edit field, not a claim of
  full native text-widget editing parity.
- A shared Settings body viewport clips painting and hit tests, scrolls long
  forms/action lists, and reveals keyboard selection. Toolbar and footer controls
  stay outside that scroll region. A physical KDE 820x580 canary kept the final
  environment field, toolbar and footer usable; off-panel controls are not clickable.
- Real KDE mouse canaries covered startup/theme/global and profile font changes,
  New/Duplicate/Edit/Save/Cancel, environment fields, confirmed deletion, Set default,
  profile-dropdown Instance creation and palette-to-Settings navigation. They used
  isolated config and left the original GUI, its three Instances and the real
  profile-config bytes unchanged. Quiet Settings used zero CPU ticks over three seconds.


- Real navigable Settings surface.
- Startup, Interaction, Appearance, Color schemes, Mappings, Profiles, and Profile
  pages.
- Atomic schema-versioned XDG config writes. Schema 2 adds stable mapping-id
  keybinding overrides while schema-1 files remain readable and upgrade only on save;
  schema 3 adds stable profile recipes and persisted application-theme identity.
  Absence of the config file means built-in defaults. An existing invalid config
  or any invalid persisted profile/server/mapping/default-profile field rejects
  startup as one failed configuration instead of loading valid siblings or
  substituting defaults. Save failures are reported.
- Persistent default profile, font size, and application theme.
- Settings → Mappings is keyboard-editable: Tab enters the mapping list, Up/Down
  chooses a mapping, Enter records a physical chord, Delete unbinds, and R restores
  the registry default. Recording owns the whole chord so modifier-only transitions
  never leak to the terminal or trigger another app action.
- Settings → Profiles/Profile is also keyboard-complete: Tab crosses sidebar/content
  ownership, Up/Down navigates catalogue/fields, Enter opens or edits, built-ins
  require Duplicate before mutation, and typed environment overrides have explicit
  add/remove/name/value controls rather than a `NAME=value` mini-language.
- Keybinding conflicts are rejected transactionally with the conflicting mapping
  named in UI. Hand-edited malformed mapping sets report the precise bad entry and
  reject the persisted configuration rather than retaining unrelated fields.

**PROVEN — Settings search**

- `Ctrl+F` while Settings is open owns a bounded Settings search surface over page
  metadata, the shared action registry, and the live profile catalogue. Results are
  typed destinations (page/action/profile), so Enter can focus the exact Actions row
  or open the exact Profile editor instead of merely changing page text.
- Search is synchronous and allocation-free over the tiny bounded surface; no worker,
  timer, or polling path was added. SDL composition follows the search field.
- Managed-KWin canaries proved `window → New window action`, `lab → Lab profile`, and
  `color → Color schemes`. Outside Settings, `Ctrl+F` remains terminal input; a Bash
  readline canary produced `abX`, proving the chord moved the shell cursor rather than
  opening application search.

**WANTED**

- Richer appearance choices only where they have a clear platform/terminal owner.
- Import/export user configuration.

### 14. Command palette, mappings, and keybindings

**PROVEN**

- Next/previous tab, close-entire-tab, and move-tab-left/right are first-class
  rebindable mappings backed by actions. Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+Shift+PageUp/PageDown
  retain their defaults without an unbindable direct-handler fallback. Close
  entire tab is initially unbound and closes every split; Close pane / tab keeps
  its existing Ctrl+Shift+W leaf-first behavior. The bounded palette reveals all
  registry entries through keyboard navigation even in short windows.


- One bounded action registry owns commands and context-enabled execution. A
  separate bounded mapping registry is the sole owner of global key chords and
  may target actions or typed parameterized commands. Command Palette remains
  action-oriented while Settings → Mappings exposes the complete shortcut surface.
- Context state is visible rather than silently ignored: for example pane zoom is
  muted with one pane while restart/reconnect is enabled only for a recoverable
  Instance lifecycle state.
- Keyboard navigation and Enter execution.
- Effective shortcut bindings are normalized from one bounded chord grammar and
  drive runtime dispatch plus every visible shortcut hint. Overrides persist by
  stable action id, may be unbound/reset, and permit transactional chord swaps.
  A managed-KWin canary changed New window from `Ctrl+Shift+N` to `Super+N`, proved
  the old chord stopped opening windows, survived a full process restart, rejected
  conflicting `Ctrl+T`, then reset to default with an empty override set.

**WANTED**

- Fuzzy/filterable command palette.
- Evaluate an opt-in Kitty shortcut preset after the real KDE dogfood exposed
  muscle-memory conflicts. Preserve the Windows-familiar defaults and explicit
  user overrides; route direct tab/history/zoom chords through the action owner
  before adding aliases that could collide with pane or tab navigation.
- Finish routing remaining direct shell shortcuts through the registry where they
  represent concrete actions rather than parameterized key families.
- Context-aware disabled actions with a reason when useful.
- Discoverable shortcut display in menus/settings.
- Per-profile actions only when the action genuinely belongs to a profile.

### 15. Instance and process lifecycle

**PROVEN**

- Client-created Local Instance ownership and exact child teardown.
- Attached direct/Server views never kill the externally owned Instance.
- Independent observer/control connections and explicit blocked-observer
  cancellation.
- Canonical `stream_closed` / `child_exited` snapshot facts drive destructive
  lifecycle state. A client-owned shell preserves its final Canvas frame as
  `Process exited`, stops accepting terminal input, remains locally selectable/
  scrollable, and offers Restart. Only this canonical closed state may destroy the
  old owned Local Instance and create a fresh in-process Instance in the same pane.
- Local observer/control failure is not child death. `Local connection unavailable`
  offers Reconnect to the same Local Instance id, transfers the owner to the fresh
  view, and never calls `local_instance_destroy` on the PTY child. Attached
  failure/closure remains Reconnect against the exact stored target.
- Exact bridge I/O diagnostics are printed to stderr and shown in the lifecycle bar
  so a channel failure cannot collapse into an untraceable generic unavailable state.
- Ownership is explicit `Attached` / `Owned` client state rather than inferred
  from whether Local creation happened to succeed, so even a failed Local launch
  retains Restart semantics.

**WANTED**

- Exit status once Instance exposes it canonically; until then the UI says only
  `Process exited` rather than inventing a status.
- Recent/pinned attach targets where discovery has an explicit owner.
- “Close tab” versus “terminate owned process/Instance” remains an explicit distinction.
- Application shutdown explains what will remain alive and what is client-owned.
- Useful cwd/shell-mark consumers beyond the already-live title. These facts
  cross the shared transport but do not yet imply automatic cwd inheritance.

### 16. Desktop/OS integration

**PROVEN**

- Native Wayland window on KDE through SDL3 with SDL application metadata set to
  `Howl` / `io.github.laurenceguws.howl`; KWin reports that exact app id and the
  production window title is simply `Howl`, not a canary label.
- Native desktop identity is packaged deliberately: a validated reverse-DNS
  `.desktop` entry, hicolor PNG launcher icon, and an app-private BMP fed to
  `SDL_SetWindowIcon`. A managed-KWin canary proved the wolf icon in the live
  decorated window after removing diagnostic icon-size fallbacks.
- User-local `--check` / `--promote` / `--uninstall` packaging keeps the Odin
  executable, matching bridge library, and live-window icon in one private libexec
  bundle. Local Instances run in-process; no Instance daemon is packaged. The
  executable retains `RUNPATH=$ORIGIN`; the launcher is tiny, XDG desktop data honors `XDG_DATA_HOME`, and a hash manifest
  prevents overwriting or removing unknown/modified files. A clean fake-HOME
  install/resolve/uninstall round trip and an in-place managed-lab manifest
  upgrade both passed.
- System clipboard via SDL3.
- XDG configuration location.
- Fullscreen is a rebindable `F11` action in the shared registry and Command
  Palette. It requests borderless desktop fullscreen without changing display
  modes or inventing a second compositor-state boolean. Three managed-KWin
  roundtrips restored the exact original frame rectangle; the owned PTY followed
  124x34 -> 137x36 -> 124x34 each time. A held 700 ms F11 generated no child
  keyboard bytes, including repeat/release in Kitty all-event mode.
- Registered application actions own their physical scancode through release.
  Changed modifiers and auto-repeat cannot leak the rest of an application-owned
  key cycle to the terminal. Fresh presses recover from a focus-hidden release.
- Maximize/restore and minimize/restore are proven through SDL/KWin window
  operations behind the mandatory unified client chrome.
  Hidden/minimized windows skip drawing and presentation but keep observation
  and Instance progress alive. A minimized owned child produced 500 lines without
  any PTY resize; restore presented the newest output. The app spent one 10 ms
  CPU tick processing that burst and zero ticks during the following three
  seconds of idle. Unfocused but visible windows still paint normally.
- File and text drag/drop enter only an active interactive terminal and use the
  canonical paste path. Text is preserved byte-for-byte; a file path becomes
  one POSIX single-quoted shell argument plus a trailing separator. The policy
  rejects empty/NUL/invalid-UTF-8/oversized paths instead of executing or
  interpreting them. A real Dolphin → Howl KWin drag proved spaces plus an
  embedded single quote as `'/tmp/howl-drop-fixture/Captain'\''s notes.txt' `.
- Ctrl+click opens only canonical Instance OSC 8 HTTP(S) hyperlinks; terminal
  text is never regexed into a link and `file://` is refused deliberately.
- Canonical BEL / RequestAttention / StealFocus consequences request brief
  desktop attention without stealing focus. Ordinary notification messages are
  consumed silently, so terminal output cannot manufacture a flashing desktop
  dashboard. Multi-window consequence authority hands off when an owner closes.

**WANTED**

- MIME/file-association policy only after Howl owns a concrete open-file/open-URL
  semantic; the desktop entry intentionally advertises no invented `MimeType`.
- Audible bell and user-visible desktop notification delivery only if they add
  value beyond the proven non-focus-stealing attention policy.
- Further OS integration must keep the native window identity distinct from
  the already-live canonical tab titles (section 2).
- Sensible multi-monitor placement and restore.

**EXPLORE**

- Default-terminal registration on platforms where that concept exists.
- Windows native packaging once the shell is valuable enough to justify the
  platform work. Windows familiarity does not require waiting for Windows.

### 17. Accessibility

**WANTED**

- Complete keyboard navigation for tabs, panes, menus, palette, and Settings.
- Screen-reader projection from canonical semantic text and application chrome.
- Focus indicators that remain visible without shouting.
- System-theme accommodation and full-surface contrast qualification. The
  explicit High Contrast application theme already exists (section 12).
- Reduced-motion behavior if animation is introduced later.
- Pointer hit targets larger than the painted affordance where appropriate, as
  already done for the scrollback thumb.

### 18. Diagnostics and recovery

**WANTED**

- Small About/Diagnostics surface with Howl revision, Odin/Zig versions, SDL
  backend, renderer backend, active profile/session identity, and geometry.
- Copy diagnostics action that excludes secrets and irrelevant environment data.
- Optional frame/revision/performance counters for investigation, invisible in
  ordinary use.
- Broader copyable diagnostics for unsupported image resources and bridge/attach
  failures. Renderer and invalid-config failures already remain explicit rather
  than falling back.
- Recovery actions are explicit; the client does not silently spawn a different
  Local Instance when attach fails.

### 19. Performance and resource behavior

**PROVEN**

- Event-driven presentation loop sleeps between invalidations.
- Quiet Home tab measured at effectively 0.00% of one core over a five-second
  interval on Home.
- A pre-Instance active-btop sample measured about 0.25–0.30% of one core in
  the Odin GUI after the scheduler fix. Its sibling service-process cost belongs to
  the historical topology and is superseded by the whole-process-tree comparison below.
- Warm complete Canvas regeneration measured roughly 0.7 ms on the attached Home
  view and roughly 1.9 ms on the larger Local shell during the first renderer
  canary.

**PROVEN: whole-process-tree btop cost, 2026-09-17**

- The earlier GUI-only figure above is a historical workload, not total terminal
  overhead. Captain's dense 61x271 grid at 12px, 2000ms btop configuration, filtered
  and collapsed on the owning GUI with process detail, was compared in private
  KWin. Sixty-second process-local user+system ticks were summed exactly once;
  100% is one logical CPU. btop/shell are included; compositor and sampler are not.
- Baseline total was 3.23% (GUI 1.10%, then-service 1.63%, btop 0.50%); matching Kitty
  was 0.65% (GUI/helpers 0.12%, btop 0.53%). The accepted CPU slice measured 1.60%
  total (GUI 0.57%, then-service 0.58%, btop 0.45%). Howl overhead fell from 2.73% to
  1.15%, about 58%, but remains materially above Kitty. Small differences between
  runs are not stable promises; machine load was not frozen.
- Unix observations avoid unnecessary compression/decompression using the shared
  raw request; TCP retains compressed transfer. Explicit speed optimization keeps
  debug/assert/bounds semantics. Redundant contained-quad clipping is eliminated
  without changing command order, source pixels, or clipped glyph/image bounds.
- An isolated raw-only stage comparison preserved 30 render observations, 30 wake
  observations and 30 presentations over 20 seconds, with no errors. No btop
  refresh slowdown, debounce, discarded snapshot or idle animation was introduced.
- A reusable decode-cache trial did not establish a material further benefit at
  this measurement resolution and was removed rather than retained speculatively.
  The exact fixture/candidate hashes and pixel/transport checks live in the
  desktop workstream's cpu-tabs-20260917 and btop-polish-20260917 evidence.

**PROVEN: local Yazi image-path latency, 2026-09-16**

- The local Pictures/40-item walk exposed shared VT and then-current service costs
  rather than SDL presentation. Inert printable-ASCII APC runs now use the parser's
  no-transition prefix; control bytes, bounds and failure recovery stay exact.
  The then-current service counts immutable image-placement slots once per
  manifest/visibility loop rather than repeatedly scanning the viewport for placeholders.
- A warmed old/new service comparison retained the same GUI/bridge: observation
  p95 628.9 -> 7.3 ms, SDL input-event age p95 798.8 -> 1.3 ms; no image-quality
  reduction, new debounce or skipped payload policy was added. These are scoped
  dequeue/observation measurements, not an input-to-photon guarantee.
- The current Yazi 26.9.1 emits many cell-sized placements, unlike the earlier
  single-placement Yazi canary. Seven new parser/capture/fragmentation/manifest
  proofs cover this narrower optimization, including OOM and service boundaries.
- The initial, pre-scan-guard Doom smoke delivered 170 full image uploads in
  10.6 s without observation errors. This is historical baseline evidence;
  the later full-size comparison and sustained run below supersede its rate.

**PROVEN: local pixel geometry and full tiled-preview coverage**

- Owned Odin panes send the actual Canvas cell-pixel metrics with canonical cell
  counts. The then-current terminal service commits VT queries, in-band resize and
  PTY pixel dimensions transactionally. This removes the previous 10x20 reported
  versus 11x24 drawn
  mismatch; observers still cannot resize or silently claim an attached Instance.
- The explicit v8 bundle boundary carries the pixel pair and raises independent
  placement capacity to 16K within the same 1 MiB manifest bound. Retained image
  bytes remain 64 MiB bounded. A 1,600-placement identity test crosses the old
  ceiling; a live tall preview covers every source pixel across 1,271 placements.
- A controlled 320x240 RGBA fixture survived source -> terminal-service resource
  byte for byte, and all 76,800 displayed RGB pixels matched at 1:1. This is not
  a promise
  that arbitrary user images resized by their producer remain pixel-identical.
- Terminal Doom requests a 1452x912 destination for its 640x400 source in the
  full-sized test pane. The geometry-only checkpoint still approached one CPU
  core; the subsequent scan-guard checkpoint below addresses that measured cost.

**PROVEN: full-sized Doom avoids impossible placeholder scans**

- Visibility projection now skips the cell lattice when the canonical bank has
  no virtual image-placement prototype. Ordinary image visibility no longer
  repeats a full viewport scan for each retained image. No new cache or timing
  heuristic was added; bank/admission/deletion and real placeholder tests pass.
- Identical GUI/bridge A/B at 1920x1036, source 640x400 and destination 1452x912:
  ~15.9 -> 69.9 full RGBA uploads/s; then-service CPU per uploaded frame
  ~62.0 -> 8.65 ms.
  The half-window repeat also reached ~70 uploads/s. Both retained exact image
  semantics and zero observation errors. These are scoped upload cadence/CPU
  measurements, not optical frame-rate or universal graphics acceptance.
- A two-minute run at `545697a`, before framing v9, completed 8,440 uploads in
  120.57 seconds with no observation errors. GUI sampled RSS rose about 2.26 MiB;
  this is not an all-night memory plateau proof. A separate v9 gameplay smoke
  preserved full destination geometry, graphics/properties updates, and teardown.

**PROVEN: in-band resize discovery and normal TUI teardown**

- DECSET 2048 now emits its required immediate size report, including repeated
  enable and restored enabled state. Unknown pixel dimensions report zero rather
  than suppressing the response. Reply capacity is reserved before changing a
  grouped command, preserving mode/reply state on allocation or bound failure.
- Real qualified terminal Doom, without resizing while active: before this fix
  its library failed to recognize the enabled protocol and left mode 2048 set
  on exit; the next resize leaked CSI 48 into Bash input. After the initial
  response it detects support, disables the mode during its normal teardown,
  and the matched post-exit resize leaves the shell prompt clean.
- This fixes the proven resize-mode leak, not every possible late ACK/DSR race
  in applications that stop reading before their final replies are drained.

**ACTIVE — graphics performance qualification**

- Local Yazi and full-sized Doom have the scoped measurements above. Longer
  memory slopes, current-v9 cadence, input under churn, and other producers still
  need qualification; quiet-text and image correctness are not universal proof.
- Stock Yazi 26.9.1 selects KgpOld for Howl's unrecognized truthful identity and
  requests cell-tiled stretching. Modern KGP/U=1 replay at the problem size is
  pixel-identical, but the Howl-brand producer proposal is application-checked
  only: it has not been compiled, submitted, or installed. Stock Yazi quality is
  not accepted, and Howl must not ignore requested rectangles or spoof Kitty.
- Separate transfer/decode, Instance/HWLS transport, client resource fetch, Canvas work,
  texture upload and presentation costs before choosing an optimization. Record
  workload, build mode, display scale and local-versus-remote producer context.
- Compare the same case before/after; pressure image replacement/removal, retained
  history, scroll/resize, selection, splits, hidden/minimized windows and return
  to idle. A stationary image must not create a busy render or resource-fetch loop.
- Performance work can proceed before accessibility is complete. A proven narrow
  bottleneck fix should not wait behind unrelated feature completion.

**WANTED**

- Preserve near-zero idle CPU as a regression bar.
- Target compositor-smooth 60 FPS presentation during sufficiently fast terminal
  output without blindly repainting at 60 Hz.
- Coalesce Instance revision bursts to the newest useful frame rather than render obsolete
  intermediate revisions.
- Measure frame production, Canvas composition, SDL painting, GPU present, and
  Instance/service costs separately.
- Bound retained resources and memory per pane/tab; no accidental unbounded UI
  logs or frame queues.
- Hidden/minimized windows should perform less work, not more.

### 20. Reliability dogfood matrix

A desktop terminal should be judged by boring repeated use, not only unit tests.
The ongoing canary matrix should include:

- shell typing/editing, Unicode, paste, Ctrl/Alt chords;
- thousands of lines of output and 4,096-row retained-ring eviction;
- wheel, page, oldest/LIVE, thumb seek/drag, and live-output anchoring;
- selection/copy/paste in LIVE and HISTORY;
- resize height-only versus width/reflow while scrolled;
- font zoom while scrolled;
- tab and split creation/close while output is active;
- Neovim, btop, tmux/zellij, less/man, fzf, yazi, and at least one mouse-aware
  application;
- maximize/fullscreen/DPI/display transitions;
- shell/process exit, app close/reopen, Instance disconnect/reconnect;
- image transfer, repeated replacement/animation, and interaction under image load;
- sustained high-output CPU/memory/frame-time measurement.

For co-operative desktop dogfood, put each tested iteration into Captain's live
GUI rather than preserving an old golden window beside it. Check active child
work before replacement, retain saved profiles/bindings, and keep owned versus
attached Instance teardown explicit. Use an isolated compositor only when it is a
deliberate part of the current testing agreement, not stale handoff recovery.

## Dependency posture

The Odin application deliberately has a small **direct** dependency surface:

- Odin core libraries;
- Odin's vendor SDL3 and SDL3_ttf bindings;
- `libSDL3` and `libSDL3_ttf` at runtime;
- one app-private `libhowl_odin_bridge.so`;
- libc/libm from the host platform.

The bridge reuses in-tree `howl-client` and `server-client` for transported
attachments, while Local directly owns the canonical `howl-instance`/
`howl-pty`/`howl-vt` composition and its Render publication path in-process.
Exactly one terminal worker owns each Local Instance; no Local HWLS/service/client
lane exists. Remote attach remains non-owning. Native text
rendering dynamically uses the
system FreeType/HarfBuzz stack, which in turn brings normal font/image support
libraries such as zlib, bzip2, libpng, Brotli, GLib, Graphite2, and PCRE2 on the
current Arch machine.

So “almost no dependencies” is fair at the **application architecture** level,
but not literally at the ELF dependency graph level. The important property is
that there is no GTK/Qt/Electron/web runtime/general retained widget framework
between Odin and the desktop. The app shell is ours; terminal semantics are
Howl's; SDL is the narrow platform/rendering substrate.

## Deliberate non-goals

- Do not clone Windows Terminal internals or configuration format.
- Do not move VT, PTY, shaping, history, image, or escape-sequence semantics into
  Odin for convenience.
- Do not add a generic UI framework merely to make Settings faster to build.
- Do not preserve ambiguous scrollback across horizontal reflow by guessing.
- Do not make attached Instance lifecycle implicit.
- Do not spend complexity on animation, translucency, or decorative effects
  while ordinary terminal interactions remain rough.
- Do not optimize from folklore: measure the specific owner that is expensive.

## Current near-term pressure lanes

Reconciled on 2026-09-27 after the accepted Linux/Windows Local + Remote checkpoints.
These are residual product/qualification tasks, not permission to reopen ownership
that is already proved.

1. Keep ordinary Local and Remote dogfood boring on Linux and Windows. Local owns a
   canonical in-process Instance; Server browsing/attach stays non-owning. Do not
   reintroduce a sibling daemon, per-Instance listener, or orchestration-shaped Local route.
2. Continue evidence-led graphics/performance work against current framing v10. Separate
   producer, Instance/HWLS, Canvas, backend upload and presentation costs; preserve the
   near-zero idle floor and exact image/resource lifetime.
3. Qualify remaining desktop product seams: mixed-monitor/hotplug, accessibility,
   Windows installed-font catalogue parity, diagnostics, and installed-bundle/distribution behavior.
4. Add host-consequence behavior only where a concrete desktop experience earns it.
   Odin currently owns explicit consequence authority; protocol semantics remain in VT.
5. Give transported properties deliberate consumers where useful, but keep cwd/shell
   metadata, discovery and process launch policy outside terminal semantics.
6. Retain the wider WANTED/EXPLORE inventory without treating optional UI ideas or
   historical canaries as current architecture. Keep transient experiments in workstreams.


Historical checkpoint note: dated sections below preserve the vocabulary and process
names measured in that epoch. Current ownership is the Instance/Server model described
above and in the 2026-09-26 Local/Remote checkpoints; old `Session`/`howl-sessiond`
mentions below are evidence labels, not current product dependencies.

Private-lab workflow (2026-09-17): Captain explicitly authorizes managed KWin
for repeatable input/control tests, then promotion of tested iterations into the
physical dogfood window. Private fixtures keep private settings; a desktop launch
uses Captain's saved profiles/bindings. Do not inject concurrent tests into an
adopted user window or replace active unsaved work without a safe handoff.


### SSH GUI worker-lifetime checkpoint, 2026-09-17

The existing native SSH carrier is now consumed by Attach profiles through one
application-owned I/O runtime. Pending connection, observation, ordered control,
search, selection/link queries, image fetch/composition and consequence work run
off the graphical thread. SDL accepts bounded prepared resources and stable front
facts. Explicit reconnect never retries uncertain input. Local SSH-shell profiles
and independently attached remote Sessions remain different ownership topologies.

Private KWin qualification covers a partial SSH handshake while Settings and a
Local tab remain usable, actual Brommer SSH input/history/progress/images,
duplicate attachments and remote splits, disconnection/reconnect without replacing
the remote Session, exact640x400 image pixels, and cancellation/child cleanup.
A stopped renderer channel does not block input; delayed history cannot undo LIVE.
Copy/Paste/Enter queued while SSH is stopped uses the completed Copy rather than
the previous clipboard. Scope-specific receipts live in the desktop workstream's
`evidence/ssh-gui-20260917/`.

The first asynchronous version repainted both the old and new frame and increased
local btop cost. Removing that scheduling-only repaint restored the matched dense
61x271 baseline: about1.10–1.12% of one core terminal overhead, not a new claimed
speedup. This does not remove duplicate snapshot/projection work or establish
sustained SSH throughput, mobile support, interactive auth, automatic remote
provisioning or geometry leadership. Those remain distinct open items.


### Explicit attached size control, 2026-09-17

Take Session size control and Stop resizing Session are palette/Actions entries,
without a new permanent bar or hard-coded shortcut. Attachment/focus/reconnect
remain non-mutating; explicit takeover fits once and then uses resize-only while
authorised. Local launch also claims only once instead of fighting a later peer.
One pending size transaction, acknowledged dimensions and intent-generation
checks protect delayed stop/retake. Not-leader is nonfatal and never auto-reclaims.
Stop is a local scheduling choice, not an unsafe global release or an unsend.

Private same-Session two-window tests over Unix and real SSH exercise takeover,
loss without input failure, resize/font/split/zoom, stop and close. A stopped SSH
channel proves that late completion cannot re-enable auto-sizing. Workstream
receipts: `evidence/geometry-20260917/`. Framing remains v9; the private matching
Odin bridge is ABI7. Long SSH performance, mobile/runtime rollouts and other
charter items are not included in this geometry checkpoint.


### Bounded live-view reuse, 2026-09-17

Odin can transfer the existing image-free live `howl-client.view.Snapshot` from
its observation worker to renderer preparation. One latest offer and one admitted
render request own their allocations; displaced/consumed views are destroyed.
Rendering uses the same shared Terminal Canvas. No codec,
route, protocol, terminal quality, producer pacing, or redraw-rate change.

This optimization applies independently to Unix/TCP/SSH. Image-bearing cuts and
historical viewports deliberately retain the current renderer-owned observation,
including that connection's exact generation retention. A late image-free cut
cannot regress a newer accepted renderer revision. Full-image observation reuse
and further common-client lifecycle simplification remain open, not hidden TODOs.

The desktop workstream's `evidence/observation-20260917/` records same-grid btop
CPU controls, native byte/cut accounting, transferred-view lifetime/failure proofs,
text/graphics pixel comparisons and actual SSH transition tests. These scoped
checks do not imply a mobile/Web install or universal remote throughput claim.


### Canonical cursor shape presentation, 2026-09-17

Neovim's DECSCUSR mode transitions were already retained by VT and Session:
normal block, insert bar, replace underline. The shared Canvas compositor painted
the complete target rectangle for all three, while (correctly) recoloring glyphs
only for block. A requested thin cursor therefore looked like an opaque block
hiding its character. Canvas now draws bounded two-pixel left/bottom strokes for
bar/underline while preserving the full target binding and block recoloring.

The regression proof changes only shape/revision with identical text, verifies
block glyph recoloring, cursor-free frames, one-pixel cells and clipped strokes.
The desktop workstream's cursor-20260917 evidence captures real clean Neovim mode
changes and the user's cursor options in an isolated no-plugin configuration.
No VT parsing, Session protocol, transport, blink policy or animation timer change.
Cross-host source/build checks are distinct from runtime/device rollout.

### Linux Local + Remote product model, 2026-09-26

Odin now has two first-class Linux routes that converge after Instance selection. Local
launch creates the canonical Howl Instance in-process, then adopts unnamed socketpair
streams into the ordinary HWLS service so control, observation, render, search and host
consequences stay on the same client semantics as attachments. Local owns no listener,
filesystem socket, Session, Server, discovery policy or standalone daemon. The local
Instance is destroyed only after its pane workers have retired; a two-pane physical
canary confirmed both child shells disappear when the owning Odin process closes.

Remote Servers are persisted separately from profiles in schema 4. The dropdown opens an
asynchronous Server browser, observes Server -> Sessions -> Instances, and attaches one
exact running Instance before returning to the ordinary Odin terminal path. Home -> Colt
physical evidence used the Mesh endpoint `tcp://100.96.0.7:43150`: interactive I/O passed,
closing all Odin windows left the remote Instance alive, and reattaching preserved shell
state. The same post-Local candidate reattached that Instance and passed interactive I/O
again.

The Local canary also exercised Canvas rendering, 120-line scrollback/history, and a
second owned Instance in a split pane. An early local fast-path race exposed that worker
completion can precede SDL's first wait; connection-pending windows now use the existing
bounded retry interval only until the first live cut, then return to the normal event-
driven floor. Local service admission uses a bounded queue into the single service owner
rather than contending on a mutex held across service polling. This keeps teardown
bounded and avoids listener-shaped ownership. Environment overrides remain an explicit
unsupported Local recipe field in this checkpoint; shell/command/cwd are live.

### Windows Remote product checkpoint, 2026-09-26

The Odin desktop now crosses the first Windows platform boundary without moving terminal
semantics into the UI. HWLS protocol vocabulary is exported independently from the Linux
Instance/PTy owner, `client-transport` selects a WinSock numeric-IPv4 TCP backend on
Windows, and Server attach still hands the selected Instance back to the ordinary
`howl-client` path. The Windows transport retains the existing bounded construction
deadline, `TCP_NODELAY`, exact diagnostics, and caller-owned event cancellation. Unix
endpoints fail explicitly on Windows rather than pretending to be portable.

Local ownership is behind one target-selected platform module. Linux retains the accepted
in-process canonical Instance + unnamed-HWLS-stream implementation. Windows now owns a
ConPTY-backed canonical Instance and listener-free in-process duplex pipe streams for HWLS;
neither route smuggles in a hidden local Server or daemon.

Windows uses Howl's pinned bundled FreeType/HarfBuzz build. Because that configuration is
memory-only, the bridge reads configured regular/style/fallback font files through Zig
I/O and constructs independent `FontSet.initMemory` owners; Linux keeps its path-backed
native text path. Explicit `HOWL_FONT*` files remain authoritative. Without overrides,
Windows resolves ordinary regular and optional style candidates from `%WINDIR%/Fonts`
so a clean machine can render a normal terminal; prompts
that depend on Nerd Font private-use glyphs still need a Nerd-capable primary rather than
silently substituting replacement diamonds.

Physical Win11/KVM evidence used a real Home Server over Fleet Mesh. The final Windows PE
loaded its SDL/bridge DLL set, attached an exact persisted Server -> Session -> Instance,
rendered live terminal cells, accepted physical keyboard input through the existing
WMIO-focus -> HostIO -> noVNC path, retained and scrolled 120 lines of history, and
survived normal app close/reopen while the Server-owned Instance remained alive. The
reopened client restored retained history and accepted another interactive round trip.
The final no-font-override bundle repeated the attach/render/input proof using Windows
font defaults. Windows Local/ConPTY is qualified separately below; installer/distribution
policy, richer Windows font selection UI, and broader Windows application dogfood remain
separate work.

### Windows Local ConPTY checkpoint, 2026-09-26

Windows Local now preserves the same product topology as Linux Local: Odin owns one
canonical Instance in-process and talks to it only through ordinary HWLS clients. The
platform PTY owner uses ConPTY and owns its process, pseudo-console, input/output pipes,
resize, exit observation, and bounded teardown. The local HWLS envelope uses two anonymous
one-way pipes as one duplex stream plus explicit wake events. There is no listener,
filesystem endpoint, Session, Server, or helper daemon.

The ConPTY bring-up exposed three Windows-specific ownership facts that are now explicit in
the owner: the pseudoconsole attribute receives the HPCON value itself; the pipe handles
given to `CreatePseudoConsole` remain alive through hosted `CreateProcessW`; and hosted
process creation sets `STARTF_USESTDHANDLES` with null standard handles so redirected parent
stdio cannot leak around ConPTY. A direct Win11 owner canary proved banner/output, input,
resize, clean `exit`, and child observation. A second canary proved those same facts through
the canonical Instance and VT rather than the raw PTY owner.

The Windows HWLS service preserves the existing protocol/materialization logic and swaps
only low-level adopted-stream mechanics. Large observations are drained through bounded
16 KiB nonblocking pipe writes; this matters because a complete 80x37 snapshot can exceed
the 64 KiB anonymous-pipe capacity and Windows may reject one oversized `PIPE_NOWAIT` write
instead of accepting a prefix. The regression canary that previously blocked on the first
snapshot now returns revision 2 in about 44 ms.

Physical Win11 dogfood used the built-in `Local shell` profile with no `--server` route and
no font overrides. The owned `cmd.exe` rendered normally, physical HostIO input round-tripped
`WINDOWS_LOCAL_IO_OK`, 120 lines of output remained scrollable, and the then-current split shortcut created a
second independent Local pane while the first retained its history position. The guest
process tree showed two distinct `cmd.exe` children and separate headless ConPTY hosts.
Normal Howl window close retired Howl, both child shells, and both headless ConPTY hosts.
The same candidate then re-ran the accepted Windows Remote route against a fresh Home Server
and round-tripped `CANDIDATE_REMOTE_OK`.

This checkpoint deliberately does not guess a universal Windows shell-command grammar.
Interactive shell and cwd are live; nonempty Local profile `command` is rejected explicitly
on Windows until cmd/PowerShell/other-shell recipe semantics are designed rather than
inferred. Odin profile environment overrides remain the same explicit unsupported field as
the Linux Local checkpoint.
