# role: macos

**UNVERIFIED ON macOS.** No Mac is reachable from the environment this role
was written in. Every task below is a line-for-line conversion of
`macos/defaults.sh`, checked with `--syntax-check`, `ansible-lint`
(production profile), `ansible-doc community.general.osx_defaults`, and a
container run proving the role is skipped cleanly on non-Darwin hosts — not
against a running macOS system. Do not treat it as tested. See the
"Retirement" section below for what proves it.

## What it does

Applies the same macOS user-defaults preferences as `macos/defaults.sh`, via
`community.general.osx_defaults` instead of shelling out to `defaults write`,
and restarts only the app whose cached preferences actually changed (the
original script restarts Finder/Dock/SystemUIServer unconditionally on every
run; this role only notifies the matching handler when a value changed).

`macos/defaults.sh` and the "macOS system defaults" section of
`legacy/provision_legacy.py` (tagged `Retires with: #42`) are **not** edited
or deleted by this role. See "Retirement" below.

## Line-by-line mapping (`macos/defaults.sh` -> task)

| `defaults.sh` line | Task file | Task | Notes |
| --- | --- | --- | --- |
| `osascript -e 'tell application "System Preferences" to quit' 2>/dev/null \|\| true` | `tasks/main.yml` | Close System Preferences | Plain `command` task (osascript has no dedicated module); `failed_when: false` mirrors `\|\| true`. Runs unconditionally before the writes, like the original. |
| `defaults write com.apple.finder ShowPathbar -bool true` | `tasks/finder.yml` | Show the path bar in Finder windows | notifies `Restart Finder` |
| `defaults write com.apple.finder ShowStatusBar -bool true` | `tasks/finder.yml` | Show the status bar in Finder windows | notifies `Restart Finder` |
| `defaults write com.apple.finder AppleShowAllFiles -bool true` | `tasks/finder.yml` | Show hidden files in Finder | notifies `Restart Finder` |
| `defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"` | `tasks/finder.yml` | Default Finder windows to list view | notifies `Restart Finder` |
| `defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"` | `tasks/finder.yml` | Default Finder search scope to the current folder | notifies `Restart Finder` |
| `defaults write NSGlobalDomain AppleShowAllExtensions -bool true` | `tasks/finder.yml` | Always show all filename extensions | notifies `Restart Finder` |
| `defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true` | `tasks/finder.yml` | Disable .DS_Store on network shares | notifies `Restart Finder` |
| `defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true` | `tasks/finder.yml` | Disable .DS_Store on USB volumes | notifies `Restart Finder` |
| `defaults write com.apple.dock autohide -bool true` | `tasks/dock.yml` | Auto-hide the Dock | notifies `Restart Dock` |
| `defaults write com.apple.dock autohide-delay -float 0.1` | `tasks/dock.yml` | Set Dock auto-hide delay | notifies `Restart Dock` |
| `defaults write com.apple.dock tilesize -int 48` | `tasks/dock.yml` | Set Dock icon tile size | notifies `Restart Dock` |
| `defaults write com.apple.dock show-recents -bool false` | `tasks/dock.yml` | Hide recent applications from the Dock | notifies `Restart Dock` |
| `defaults write NSGlobalDomain KeyRepeat -int 2` | `tasks/keyboard.yml` | Set key repeat rate | no restart (matches original) |
| `defaults write NSGlobalDomain InitialKeyRepeat -int 15` | `tasks/keyboard.yml` | Set initial key repeat delay | no restart |
| `defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false` | `tasks/keyboard.yml` | Prefer key repeat over the press-and-hold accent popup | no restart |
| `defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true` | `tasks/trackpad.yml` | Enable tap-to-click | no restart |
| `defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false` | `tasks/trackpad.yml` | Disable natural (inverted) scroll direction | no restart |
| `defaults write com.apple.screencapture location -string "$HOME/Desktop"` | `tasks/screenshots.yml` | Set the default screenshot save location | notifies `Restart SystemUIServer`; `$HOME` -> `lookup('env', 'HOME')` (no shell interpolation in `value:`) |
| `defaults write com.apple.screencapture type -string "png"` | `tasks/screenshots.yml` | Set the default screenshot file format | notifies `Restart SystemUIServer` |
| `defaults write com.apple.screencapture disable-shadow -bool true` | `tasks/screenshots.yml` | Disable the drop shadow around window screenshots | notifies `Restart SystemUIServer` |
| `defaults write com.apple.Safari IncludeDevelopMenu -bool true` | `tasks/safari.yml` | Enable the Safari Develop menu | no restart |
| `defaults write com.apple.ActivityMonitor OpenMainWindow -bool true` | `tasks/activity_monitor.yml` | Open the main window when Activity Monitor launches | no restart |
| `defaults write com.apple.ActivityMonitor ShowCategory -int 0` | `tasks/activity_monitor.yml` | Show all processes in Activity Monitor | no restart |
| `for app in Finder Dock SystemUIServer; do killall "$app" ...; done` | `handlers/main.yml` | `Restart Finder` / `Restart Dock` / `Restart SystemUIServer` | Split into three handlers, each fired only by the domain(s) it actually governs, instead of an unconditional restart-all on every run. |

Every `defaults.sh` line is a scalar `-bool` / `-int` / `-float` / `-string`
write against a plain (non-host-scoped) domain, so every line maps cleanly to
`osx_defaults`; **there is no upstream gap to report for this manifest**.
`community.general.osx_defaults` does have known coverage limits in general
(no first-class way to merge one key into an existing `-array-add`-style
array — `dict_mode: add` covers the dict case; and `host: currentHost` is
supported natively) but none of them are triggered by anything in
`macos/defaults.sh` today. If a future addition to `defaults.sh` needs
`-array-add` semantics, extend this table and flag the gap then, per the
epic's "contribute the gap, don't shim it" standing preference.

## Handler mapping (why three, not one)

The original script restarts all three apps unconditionally at the end,
regardless of which section actually changed anything. This role narrows
that to "restart the app whose cached defaults changed, only when they
changed":

- `Restart Finder` — every Finder-domain and `com.apple.desktopservices` key
  (desktopservices governs Finder's own `.DS_Store` behaviour).
- `Restart Dock` — every `com.apple.dock` key.
- `Restart SystemUIServer` — every `com.apple.screencapture` key (the
  screenshot flash/shadow chrome is SystemUIServer's, not Finder's or the
  Dock's).

Keyboard, trackpad, Safari, and Activity Monitor keys are not restarted in
the original script either (they take effect on next use/launch), so no
handler is notified for them here.

## Profile gating

None. Unlike `packages`' AI-CLI task, macOS system-preference defaults are
not AI tooling — every profile (`bare`/`inline`/`agentic`) wants the same
Finder/Dock/keyboard/trackpad ergonomics. The role is gated only on
`ansible_facts.os_family == 'Darwin'` in `site.yml`, with a `macos` tag, the
same shape as the `packages` role's OS-family dispatch.

## Check-mode safety

`community.general.osx_defaults` fully supports `check_mode` (returns a
predicted `changed` without writing). The `command` tasks (`osascript … quit`
and the three `killall` handlers) have no `check_mode` support at all, so
Ansible skips them outright under `--check` — nothing in this role needs a
manual `check_mode: false`/`true` override to stay safe in a dry run.

## Retirement

This role does **not** retire `macos/defaults.sh` or the macOS section of
`legacy/provision_legacy.py`. Per the epic (#35), nothing is removed until
its replacement is verified against a running system, not merely against its
own test suite. Tracked in a separate issue: run `site.yml --check --diff`,
then a real run, then `defaults read <domain> <key>` for every key in the
mapping table above and diff against `macos/defaults.sh`'s expectations.
