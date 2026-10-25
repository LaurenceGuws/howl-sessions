# howl-odin

Experimental polished desktop client in the Howl module family.

See [`EXPERIENCE.md`](EXPERIENCE.md) for the living user-facing experience
charter. This README remains the narrower ledger of behavior the current client
can actually prove.

The client owns desktop application policy only: windows, tabs, pane layout,
profiles, settings, command palette, keybindings, and OS integration. It must
not duplicate VT, PTY, Instance, text shaping, or terminal raster semantics.

The current Linux proof plus Windows Remote and Local canaries use Odin + SDL3
for the application/backend shell and the existing Howl native render owners for
terminal presentation. `native/` is
a C-shaped Zig seam over transported `server_client.terminal`/`server-client` routes and the
canonical Instance/Render owners used directly by Local. It exports neither
wire/client backing structs nor a copied terminal renderer: Odin receives canonical
Canvas resource/command facts. Attached routes send semantic input through
`server_client.terminal`; Local sends the same semantic operations directly to its sole
terminal-thread Instance owner. SDL3_ttf remains only for app
chrome and IME composition; real terminal presentation is Canvas-only.

Odin has no emergency substitute implementation path. A required canonical
owner either succeeds or reports/fails explicitly. The sole intentional
substitution mechanism is text shaping's ordered fallback font faces. A font or
display change may retain the last already-accepted canonical Canvas frame until
its replacement frame is accepted, but a replacement failure discards that
retained frame and exposes the exact failure.

Server attachments retain the existing compressed observation policy. The transient
`--server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID` startup route connects to
one Server. Every observer/control/render/consequence worker independently attaches
to that exact Instance and completes construction at the common ready response.
Cancellation stays active through connect, ready and blocked worker I/O. No
per-Instance listener or byte proxy is introduced. The daily Odin build keeps
debug symbols, assertions and bounds checks while explicitly selecting `-o:speed`.
Contained texture quads share a pane clip; actual clipped/overhanging content keeps
its exact requested clip. These are host-side cost reductions, not a new protocol,
cache, frame-rate limit, or application-specific path.

Current canary:

- Settings, the profile menu, and Command Palette accept pointer input without
  passing those clicks to the terminal behind them. Profile management has visible
  New/Duplicate/Delete, View/Edit, Set default, Save/Cancel, and environment controls;
  default-profile, size, mode, and theme values have clickable selectors. Read-only
  information and built-in templates are visibly distinct. Long settings forms
  scroll while toolbar/footer controls stay reachable, with keyboard selection
  automatically revealed. Appearance now edits the exact regular/style/fallback font-file recipe used by Canvas; blank fields inherit startup discovery;

- native resizable SDL3 window with Windows-familiar tabs, `+`/menu affordance,
  command palette, and Settings surface;
- Local launch profiles own canonical in-process Instances on Linux and Windows. Linux
  uses the native PTY owner; Windows uses ConPTY. One `howl-odin-terminal` worker
  exclusively claims each Local Instance, services PTY/VT state, executes semantic
  control/query/consequence work, and publishes immutable Render frames. SDL consumes
  those publications on the graphical thread. No HWLS client stream, listener, hidden
  daemon, or Server exists in the Local path.
  Windows currently accepts the interactive shell and cwd recipe; a nonempty profile
  command fails explicitly until Windows command-shell grammar has a deliberate contract.
  Direct Attach profiles own observer/control clients, cancellation, and teardown;
  **Attach Home Instance** remains the existing direct `tcp://127.0.0.1:39601` route.
  Separately, `--server` opens one non-owning Server-managed Instance as the initial tab
  on Linux or Windows; closing Odin leaves that Instance alive under Server ownership;
- tabs use canonical terminal titles only; absent title stays absent. The visible mapping
  table defaults Ctrl+Tab/reverse cycling, Ctrl+1…8 direct selection, and
  Ctrl+Shift+PageUp/PageDown reorder; pointer
  drag reorder through one shared ordering owner. A held chip gets an immediate
  outline, follows the original pointer grab, and leaves an outlined destination
  slot. Updates are input-driven; no tween timer or extra terminal texture exists.
  Keyboard interruption retires local tab/scrollbar dragging and consumes only
  that canceled gesture's pending left release before tab/overlay routing. TUI
  mouse-reporting captures keep their own release path. `Ctrl+Shift+D` duplicates the
  active profile recipe into a fresh Instance/view; closing a created tab retires
  only that tab's owned child Instance, and closing the final single-pane tab closes
  the window;
- `Ctrl+Shift+N` / Command Palette opens a new independent Odin OS window through
  the same executable and inherited config. The parent uses a self-cleaning process
  reaper only; live tab tear-out/cross-window Instance transfer is deliberately not
  implemented until UI state has an explicit transfer owner;
- tabs use a bounded recursive pane tree rather than a fixed primary/secondary
  pair. Side-by-side and top/bottom actions may nest up to eight pane slots.
  Pane focus/resize/swap each expose four directional mappings in Settings →
  Mappings, but all twelve are unbound by default so Odin reserves no Alt chords.
  Pointer drag owns a forgiving divider hit lane, `Ctrl+Shift+Z` remains the
  default mapping for pane zoom, and `Ctrl+Shift+W` remains the default mapping
  for collapsing only the active leaf while promoting the sibling subtree;
- Canvas commands are pane-clipped even during the brief resize transition, so
  an old wider frame can never paint across the split into its sibling;
- one bounded action registry owns command ids, labels, categories,
  context-enabled state, and execution. A separate bounded key-mapping registry
  is the only owner of global shortcuts and can target either an action or a
  typed parameterized command such as “select tab 3” or “focus pane left.”
  Settings → Mappings exposes every row, including unbound rows; Command Palette
  remains action-oriented. Impossible actions such as zoom on a single pane
  render disabled rather than failing silently;
- Settings is a real navigable application surface rather than one static mock:
  Startup, Interaction, Appearance, Color schemes, Mappings, Profiles, and Profile
  pages expose the client's current truthful configuration and ownership state.
  Actions can be rebound from the keyboard, unbound, or reset; conflicts are rejected
  without mutating either action and the conflicting action is named in the UI.
  Profiles can be created, duplicated, edited, and deleted with built-in vs user-owned
  boundaries kept explicit; active profile text editing owns SDL composition input.
  `Ctrl+F` inside Settings searches pages, registry actions, and live profiles and
  navigates to typed destinations; outside Settings the same chord remains terminal input;
- Appearance owns the first live presentation setting: terminal font size is
  one bounded 8–48 px integer, adjustable one pixel at a time from Settings or
  the global zoom shortcut. Changing it never mutates canonical Instance
  geometry; the exact pixel value persists across app restarts in the existing
  schema-versioned `$XDG_CONFIG_HOME/howl/odin.json` written by temporary-file
  + rename rather than in-place truncation;
- Appearance owns a searchable **Choose terminal font** surface over the installed
  terminal-width catalogue on Linux. Fontconfig spacing 90 (dual-width) and 100
  (strict monospace) are admitted; proportional/unset spacing is excluded. Typing filters family names, the selected row shows
  a real candidate-face sample, Right applies the family to the live Canvas as a
  temporary preview, Left restores the exact previous recipe, Enter commits it,
  and Esc cancels.
  Choosing one family resolves Regular/Italic/Bold/Bold Italic automatically; the
  six exact-path slots remain visible underneath as the advanced contract. Blank
  fallback paths inherit the startup-resolved Arabic/CJK chain. If Regular is
  explicitly replaced while style slots are blank, those styles deliberately reuse
  Regular instead of cross-mixing another family. The catalogue is lazily heap-owned,
  bounded to 256 terminal-width families, and currently uses fontconfig monospace discovery; Windows
  keeps the exact-path editor until an equivalent installed-font catalogue owner is wired;
- Color schemes now owns the first live application-chrome themes: Howl Dark,
  Slate, and High Contrast cycle with Left/Right and persist by stable id. The
  theme changes desktop shell chrome only; terminal renderer colors remain canonical
  Howl output. A managed-KWin A/B kept sampled terminal pixels identical across all
  three themes, and High Contrast survived a full process restart;
- Startup owns the second persisted setting: the default profile can be Home
  Instance (attach) or Local shell (owned in-process Instance). Schema 2 also persists
  custom shortcuts by stable mapping id; schema-1 files remain readable and upgrade
  only on save. A missing config file intentionally uses built-in defaults; an
  existing malformed/unsupported config, bad profile/server row, unknown default
  profile, invalid theme/font value, or invalid mapping set aborts startup rather
  than partially loading or substituting defaults. Save/write/rename failures are
  reported instead of silently discarded;
- `+`, `Ctrl+T`, startup, and split-pane creation all consume that same default
  profile instead of hard-coding a process type. The runtime catalogue includes
  bounded user recipes beside Home/Local; each recipe names attach-vs-launch ownership,
  shell/command/cwd, inherited-environment overrides, endpoint, and an optional font-size
  presentation default. The profile dropdown enumerates the real catalogue and marks the
  stable-id default. Schema 4 also persists labelled Server endpoints separately from
  launch/attach profiles;
- Launch profiles now create a canonical presented Howl Instance in-process and hand it
  directly to one terminal worker. PTY service, input, resize, history publication,
  search, selection extraction/expansion, hyperlink lookup, consequence handling,
  presentation reconfiguration, VT observation and Render production all stay on that
  owner. SDL receives only final backend-neutral Render publications. No HWLS, client
  snapshot path, listener, filesystem socket, Session, Server, or standalone daemon is
  created for Local. Shell/command/cwd are live recipe inputs; nonempty environment
  overrides currently fail explicitly rather than being silently ignored;
- Servers is a separate product route: the dropdown opens an asynchronous persisted
  Server browser, observes Server -> Sessions -> Instances, and attaches one exact
  running Instance. After Local creation or Remote attach, both routes use the same
  ordinary Odin terminal tabs/panes/input/Canvas/history path;
- Home tab observes the existing canonical Howl Instance at
  `tcp://127.0.0.1:39601` without taking geometry leadership;
- committed text plus named/control keys use the same canonical VT semantics: Attach/
  Server routes round-trip through `server_client.terminal`, while Local feeds the owned Instance
  directly on its terminal thread;
- desktop pointer routing now consults Howl's coherent interaction state instead of
  assuming every mouse belongs to the client. Ordinary shell tracking-off behavior
  remains local selection/history; a child enabling canonical mouse tracking gets
  semantic press/release/move/wheel facts through the bridge's canonical semantic
  actions, and VT alone chooses the child escape encoding. Attached routes use
  `server_client.terminal.actions.mouse`; Local applies the same facts directly to Instance.
  Shift+drag and Shift+wheel are explicit
  local overrides even while tracking is enabled. A controlled SGR button-event
  canary produced exact child mouse reports for click, drag, and wheel, while the
  same Shift overrides produced no additional child RX bytes;
- real desktop focus gain/loss is forwarded as semantic Howl focus input. VT suppresses
  it unless the child requested focus reporting; with DEC focus reporting enabled,
  the managed-KWin canary received canonical focus-out `ESC[O` and focus-in `ESC[I`.
  Focus loss also terminates any terminal-owned mouse capture with semantic releases;
- Ctrl+left-click is the deliberate desktop hyperlink override. The app resolves the
  exact displayed stable cell through canonical OSC 8 metadata, using `server_client.terminal.view`
  for attachments and direct VT observation for Local, accepts only
  valid UTF-8 `http://` / `https://` targets, and delegates opening to SDL. Ordinary
  unlinked Ctrl-clicks fall through to the existing mouse/selection router; unsupported
  canonical schemes such as `file://` are never handed to the platform;
- DEC alternate-scroll is routed through canonical named-key cycles, never client
  escape strings. In a controlled alternate-screen canary with mouse tracking off,
  DEC alternate-scroll on, and application-cursor mode on, wheel-up/down arrived as
  VT-owned `ESC OA` / `ESC OB`. Shift+wheel remained the explicit local override and
  produced no child bytes. The same canary, with focus reporting off, also proved
  semantic focus transitions are suppressed by VT when the child did not request them;
- desktop text composition owns SDL `TEXT_EDITING` as bounded client-local preedit
  state. Candidate placement follows the active terminal cursor or Find field, UTF-8
  preedit caret indices are measured into pixel offsets, transient composition is cleared
  when input ownership changes, and only final `TEXT_INPUT` crosses into Howl. A private
  XWayland `us(intl)` dead-key canary composed dead-acute + `e` into exactly one `é`;
  that backend did not emit a visible preedit event, so a true runtime `TEXT_EDITING`
  producer remains a future platform canary rather than a claimed proof;
- named physical-key coverage includes F1-F12, lock keys, and the numeric keypad.
  F5, F12, and Shift+F5 were pressure-tested through VT-owned encoding; standalone
  modifier-key transitions remain deliberately withheld until shortcut arbitration can
  guarantee app-owned shortcuts never leak half a modifier chord to the child;
- Kitty all-event key semantics are pressure-tested end-to-end: a 700 ms F5 hold
  produced one press (`ESC[15~`), four repeat events (`ESC[15;1:2~`), and one release
  (`ESC[15;1:3~`). SDL produced the physical lifecycle, Odin sent semantic actions, and
  VT alone chose the terminal encoding;
- managed-KWin interaction dogfood now includes real Neovim, btop, tmux, and less paths: Neovim accepted click/wheel while Shift+drag stayed local, btop's actual menu and process-list wheel worked, a mouse-enabled two-pane tmux instance changed pane focus from a click and accepted input only in that pane, and less correctly ignored wheel with tracking/alternate-scroll off while PageDown navigated normally;
- observation and control use independent client connections: a named worker
  blocks on revision-relative observation while the SDL event/render thread
  owns only control delivery; teardown wakes the blocked observer through
  `server_client.terminal`'s duplicate-socket cancellation primitive;
- Instance publication wakes the SDL main thread through one registered user
  event. The desktop loop blocks in `SDL_WaitEvent` between invalidations and
  paints once per drained event burst instead of repainting the complete app at
  compositor cadence when nothing changed;
- scrollback is pane-local and uses Howl's canonical retained-history window:
  physical mouse-wheel input and Shift+PageUp/PageDown request exact history
  offsets. High-resolution fractional wheel input accumulates canonical row
  intent instead of turning every tiny delta into a whole wheel notch. An
  absolute retained-row anchor keeps a scrolled viewport stationary
  while newer PTY output arrives, alternate-screen observations reset the pane
  to LIVE, and committed terminal input returns only the active pane to LIVE
  before delivery;
- retained history also exposes a thin per-pane position scrollbar: the thumb
  stays quiet at LIVE, becomes accent-colored while scrolled, tracks the
  accepted canonical history offset, and owns a forgiving pointer lane for
  direct seek/drag without colliding with terminal text selection. A delivered
  button press owns the gesture even when explicit SDL capture is unsupported;
  normal held-button delivery (including Wayland's implicit grab) handles dragging.
  Release, focus loss, and window close terminate the gesture so later movement
  cannot keep scrolling. Private KWin tests cover thumb/track dragging, release
  outside the window, focus cancellation, and pane-local nested splits at 1x;
  single/split thumb dragging also passes at 1.7x.
  `Ctrl+Shift+Home/End` jump directly to the oldest retained window or back to
  LIVE without stealing ordinary terminal Home/End. Vertical-only geometry
  changes preserve the absolute retained-row anchor; an owned horizontal reflow
  deliberately returns to LIVE because the same numeric row can name different
  text after reflow;
- retained-history Find is pane-local and keyboard-first: `Ctrl+Shift+F` opens a
  compact query bar, Enter walks older matches, Shift+Enter walks newer matches,
  and matches are canonical projected row/column facts rather than scraped glyphs.
  The full retained ring is scanned on a lazily-created read-only worker connection,
  so SDL never waits for a 4,096-row search. A found match recenters through the
  same absolute history anchor used by manual scrollback and remains stationary
  while newer PTY output arrives. Reflow/eviction expires stale matches explicitly;
  a hot ring that evicts rows before they can be scanned reports an incomplete
  result instead of a false authoritative no-match. Search is currently exact,
  case-sensitive UTF-8 within one projected row; cross-wrap logical-line search,
  regex/case modes, and richer search options are deliberately not faked yet;
- desktop selection is pane-local and stores stable canonical row/column
  endpoints rather than viewport-relative rows. Left-drag paints only the
  visible intersection of that stable range; wheel/PageUp/scrollbar navigation
  and live output may move the viewport without destroying the selection, and
  an offscreen range can still be copied exactly through `server_client.terminal.selection`
  plus Instance `text_extract`. Holding a selection drag in the top/bottom two-row
  edge band autoscrolls one retained row every 100 ms and updates the same stable
  focus endpoint; the SDL loop gains that timeout only while the edge gesture is
  armed and returns to indefinite sleep on release or at oldest/LIVE. `Ctrl+Shift+V`
  uses semantic paste so bracketed-paste behavior remains VT-owned. Input
  deliberately clears selection while returning to LIVE; row eviction,
  screen-bank change, or column reflow invalidates the range instead of
  retargeting it. Double-click expands through `server_client.terminal.selection.word` to
  the contiguous non-space canonical word and may cross a soft-wrap boundary;
  triple-click deliberately selects only the current projected visual row's
  text-shaped extent, trimming untouched trailing blank cells rather than
  pretending a wrapped logical line has one stable desktop identity. VT itself
  normalizes wide-cell continuation endpoints during canonical text extraction;
- terminal content is projected by the shared `howl-render` terminal renderer;
  the Odin bridge exposes fixed C resource/removal/command
  records, while SDL caches Canvas resources and paints ordered solid,
  alpha-mask, and RGBA commands without parsing terminal cells itself;
- Renderer residency survives unchanged revisions, so the first frame uploads only
  missing presentation resources. Terminal images now use Canvas external-resource
  residency too: exact Instance image generations are demand-fetched through
  `server_client.terminal.images`, exposed to SDL through the same RGBA upload API, and then
  reused without further transfer. Kitty replacement preserves logical Canvas
  resource identity while advancing generation; crop/z-order and exact removal are
  renderer-owned, and a Sixel canary proved the path is protocol-independent;
- Font/DPI replacement keeps the last accepted canonical Canvas frame visible
  while the replacement Canvas is prepared. Commands, resources, accepted
  background, scale and geometry remain one immutable accepted cut; once the new
  frame is accepted it replaces that cut atomically. A renderer error destroys
  the retained frame and shows the exact Canvas diagnostic rather than switching
  renderers or drawing semantic text;
- terminal font selection now supplies ordered `howl-text` fallbacks and a caller-owned
  regular/italic/bold/bold-italic face family rather than accepting replacement diamonds
  or synthetic terminal styles as desktop policy. Explicit `HOWL_FONT`,
  `HOWL_ITALIC_FONT`, `HOWL_BOLD_FONT`, `HOWL_BOLD_ITALIC_FONT`,
  `HOWL_FALLBACK_FONT`, and `HOWL_SECONDARY_FALLBACK_FONT` files seed the startup-resolved recipe; persisted nonblank Appearance paths override their exact slots.
  Linux otherwise requires fontconfig to resolve JetBrainsMono Nerd Font and its available
  style faces plus Noto Sans Arabic and Noto Sans CJK JP exactly. Windows searches the
  normal Windows Fonts directory for style files matching the selected regular face
  and falls back deterministically when an optional style face is absent. When
  `HOWL_FONT` selects a custom family, unspecified style variants intentionally fall
  back to that regular face rather than mixing in JetBrains/Cascadia styles. A Nerd-font prompt still
  requires an explicit Nerd-capable primary. Each supplied style is an independent
  `howl-text.FontSet` with the same fallback chain, and `howl-render` selects it from
  canonical VT bold/italic state while retaining one bounded shape/alpha-atlas domain.
  Curly underline uses the shared renderer's smooth supersampled alpha mask rather than
  the old one-pixel staircase. A live corpus proved combining marks, CJK wide cells,
  Arabic fallback/shaping, ligatures, box drawing, all supported underline styles/colors,
  truecolor, and final-column wide-cell clipping. Color emoji remains explicit debt:
  the current `howl-text` raster contract accepts mono/gray masks, not BGRA glyphs;
- created Local-shell tabs acquire Instance size control once, then submit only
  owned resizes from actual Canvas cell metrics and pane extent. Attached views
  preserve the Instance size until the user chooses Take Instance size control;
  merely attaching, focusing, or opening a larger window never claims it;
- pane lifecycle is explicit and ownership-aware. Canonical Instance `stream_closed` /
  `child_exited` facts preserve the final frame behind a small recovery bar; an actually
  closed Local shell becomes `Process exited` with Restart. Local observer/control failure
  instead offers Reconnect to the same in-process Instance id and transfers ownership
  without retiring its PTY child. Unavailable/closed attached views reconnect to the same
  target. Restart is therefore reserved for canonical child closure; Reconnect never
  launches a shell. The exact bridge diagnostic is shown in the lifecycle bar and stderr.
  `Ctrl+Shift+R` invokes the appropriate recovery, and dead panes remain locally
  scrollable/selectable but stop forwarding terminal input;
- SDL rendering uses the window-logical coordinate space and keeps chrome,
  cursor placement, and converted pointer coordinates on one geometry contract.
  The renderer backend is explicit rather than SDL-selected: OpenGL on Unix and
  D3D11 on Windows, with only an explicit software lab override. Backend creation
  or identity mismatch is a startup failure;
- the current created-instance profile inherits the desktop client's process
  environment and launches the configured shell; richer profile persistence and
  environment editing remain deliberately deferred rather than faked.

## Toolchain

This experiment deliberately pins both compilers used by its build:

- Zig follows the repository root `.zigversion`;
- Odin follows `.odinversion` in this module.

## Build

```sh
./howl-odin/build.sh
```

The script runs the native bridge tests plus Odin's desktop unit tests, builds the
bridge ReleaseSafe, checks and builds the Odin client, then atomically publishes the
executable, matching bridge library, and window icon. No Instance daemon is packaged.
The result is:

```text
howl-odin/zig-out/bin/howl-odin
```

Managed Server startup is explicit and transient:

```text
howl-odin --server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID
```

The normal no-argument launch still uses the configured profile catalogue. Persistent
Server profile editing is not yet claimed. Old endpoint-only Attach profiles report
“Select an Instance through its Server”; Local Launch profiles retain direct composition.

The accepted Windows product canary builds the same Odin package for `windows_amd64`
against a Windows bridge DLL. The pinned Odin compiler can emit the Windows COFF object
but does not currently perform Linux-hosted Windows final linking, so the development
canary links that object with the repository-pinned Zig/LLD Windows driver. This is a
build-lab seam, not a second terminal implementation. Windows Local owns ConPTY and the
canonical Instance in-process, then converges into the same client/render path as Remote.


## Terminal-owned tab properties

Each pane observes its own canonical title and retained OSC9;4 progress. The tab
uses the active pane's canonical title only. An absent title stays empty and
profile metadata is never substituted. Title bytes are untrusted; controls/bidi
formatting are replaced with spaces in desktop labels only. The native window title remains Howl.

A thin tab progress strip displays normal, failure, paused and indeterminate
states. Indeterminate is a stationary segment rather than a timer-driven pulse;
all changes use existing Instance observer wakeups. Clearing the canonical state
removes the strip. Directory/remote-host/shell-mark properties also survive the
shared transport but have no automatic desktop execution behavior or new UI yet.

This uses the matching Server v2 client/Server bundle. Rebuilding source does
not update an independently running Server deployment.


## Compact desktop frame

The tab strip and window controls share one 46-logical-pixel header. The spare
header region delegates window movement to SDL's native hit-test API; the outer
four-pixel rim delegates resizing. Minimize, maximize/restore and close use SDL
window operations; close follows the existing Instance/gesture cleanup path.
Right-clicking spare header space requests the native system window menu. Do not
assume native titlebar double-click behavior is available on every SDL backend.
Hit-test or border-removal failure aborts startup; Odin never substitutes a
different window-chrome implementation.

There is no differently-colored outer terminal mat. Owned PTY sizing uses one
content allocation with six logical pixels on every outer edge. The history
scrollbar is an overlay lane and never removes terminal columns. Rows/columns floor into
that allocation at exact Canvas cell metrics; the resulting integer-cell surface
is then centered inside the allocation instead of pinning sub-cell remainder to
the right/bottom. Paint, pointer reporting, selection, search, scrollbar extent,
cursor/IME geometry and image commands all consume that same centered surface.
The surrounding pane and sub-cell remainder use the accepted Canvas snapshot's
default VT background (foreground under screen reverse), not the application
chrome theme. This changes no terminal cells, image bytes, protocol or saved
profile settings.

The 640x320 minimum and bounded eight-tab layout reserve window controls,
Settings, new/profile buttons and at least 28 pixels of native drag space.
Crowded tabs shrink; below 96 pixels their close target is removed, and below
64 pixels a numbered chip keeps each tab reachable. The existing close action,
keyboard navigation and palette still work. No installer or rollout is implied
by rebuilding the development bundle.


Private KWin qualification also exercises header drag, rim resize, native
maximize/restore, minimize/restore, F11 fullscreen, the system menu, and caption
close with exact teardown of three owned Instances. These are scoped native
controls proofs, not double-click-titlebar or mixed-monitor/hotplug acceptance.


## Asynchronous Instance I/O

One application-owned I/O runtime outlives all Instance workers. Transported
Direct/Server routes keep independent connection/control/observation workers for
protocol requests, search, selection, images and host policy. Local has exactly one
`howl-odin-terminal` worker per Instance; it owns PTY/VT service and all terminal-side
semantic work and publishes immutable Render frames. SDL windowing, drawing, resource
submission, clipboard and browser opening remain on the graphical thread. Native
transport for attachments is explicit Unix or numeric-IPv4 TCP; Odin owns no SSH
subprocess, bridge executable, Session or Server.

Local terminal service continues while a pane is hidden or its backend is delayed.
Each completed SDL presentation grants visible native panes one coalesced credit
for a current Render projection; unread intermediate states need not be projected.
Resize, font, history and lifecycle changes publish without waiting for a credit.
Synchronized output remains held until release or its one-second presentation
timeout, including when no further PTY bytes arrive.

## Instance size control

Command Palette (`Ctrl+Shift+P`) and Settings > Mappings expose two rebindable,
initially unbound actions:

- **Take Instance size control** fits the active pane once, then follows that
  pane's window/split/zoom/font changes while its control connection remains
  the Instance's geometry leader. This is an explicit takeover, not discovery.
- **Stop resizing Instance** disables this pane's future automatic size requests.
  The last accepted size stays in place unless another client changes it.

Local launches acquire once automatically as part of owning their new Instance.
Attachments, duplicates of attachment recipes, and reconnects begin fixed; they
never inherit another pane's authority or silently claim it on focus. Subsequent
automatic resizes use only the existing resize request, not assign-leader. A
not-leader reply stops auto-sizing and leaves ordinary terminal input usable.
There is no ownership polling timer and no automatic attempt to take it back.

For transported attachments the shared client preserves NotGeometryLeader separately
from transport failure. Odin allows one queued/in-flight size transaction per pane, remembers only ACKed
geometry, and uses an intent generation so a queued old request is retired or a
late completion cannot re-enable stopped/newly requested auto-sizing. A resize
already transmitted may still complete after Stop; Stop is not an unsend promise.
Local performs the same serialized size transaction on the terminal owner; invalid
geometry is a nonfatal rejected-size result rather than a terminal-owner failure.

Stop deliberately does not send the protocol's unconditional clear-leader
operation: a delayed clear could evict a different client's newer ownership.
Another client may explicitly take control at any time; closing the owning
connection releases its leadership naturally. No new wire operation, Instance
service update, route policy, profile conversion, or default shortcut is needed.


## Reusing an observed live view

For transported Direct/Server attachments, an image-free live observation transfers its existing immutable `server_client.terminal`
view to rendering instead of fetching and projecting the screen a second time.
The pane owns at most one newest offer; a render request may own one transferred
view. Replacement, failure and teardown destroy their own allocations. There is
no reference counting, second terminal model, row replay, or unbounded backlog.
An incoming observation still has its ordinary bounded transient decode storage.

The renderer borrows that view for CPU preparation only; shared view storage is
freed before the ready frame is published. SDL acceptance and stable front facts
keep the same asynchronous lifetime as before. A stale offer cannot roll back a
renderer that has already observed farther ahead on its own connection.

This eligibility rule is independent of transport: Unix, TCP and native SSH use
it equally. Existing lossless representation choices are unchanged. **External
image-bearing snapshots and historical viewports retain renderer-owned full
observation**. Their image generations are pinned by that connection and are not
borrowed from a different observer. Clearing the last image can return to live
view reuse. This is partial elimination of redundant work, not a claim that all
observations or connection lifetimes have been merged.

On transported attachments the two worker channels remain independent. A stalled external image fetch does
not block the graphical thread, input worker, or newer observer metadata. Native
text/image transition and stopped-carrier proofs remain required alongside the
pixel and CPU controls. The improvement is in Odin's use of the existing shared
model, not an implicit mobile/Web rollout or a new public client ABI.

Managed target identity includes the expected `SERVER_ID` from Server status/tree
(or the run receipt), before Session and Instance IDs. All three are nonzero decimal
u64 values. A reused endpoint with a different Server incarnation fails closed as
stale; explicitly browse/select the new Server instead of silently reconnecting to
its reused Session/Instance numbers. This is target identity, not authentication.

The native `create`, `render_create`, and `consequence_create` ABI now takes
`server_id` before Session/Instance IDs (nonzero for every Server target; Local retains its distinct route). Rebuild the Odin
caller and native bridge together; no legacy endpoint-plus-pair fallback is kept.
