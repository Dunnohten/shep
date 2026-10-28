#!/bin/bash
# The one shell copy of Shep's never-capture list (a mirror of ControlPolicy.mayCapture). Sourced by scripts/e2e-glimmer.sh and
# scripts/record-fix-demo.sh; sourcing has no side effects. ShepCoreTests (CapturePolicyLibTests) read this file and check that
# every id below is refused by ControlPolicy.mayCapture and that every id Swift refuses is listed here.
#   capture_denied <bundle-id>   returns 0 (denied) for a listed app, and also for an empty or unresolved id (fail closed);
#                                returns 1 only for a non-empty id that is not on the list.

capture_denied() {
  local id
  id="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  id="${id#"${id%%[![:space:]]*}"}"
  id="${id%"${id##*[![:space:]]}"}"
  [ -n "$id" ] || return 0
  case "$id" in
# BEGIN never-capture list
    com.apple.systempreferences|com.apple.settings|com.apple.keychainaccess|com.1password.1password|com.agilebits.onepassword7|\
    com.bitwarden.desktop|com.apple.passwords|com.lastpass.lastpass|com.apple.console|\
    com.apple.mobilesms|com.apple.mail|com.apple.facetime|com.apple.passbook|com.tinyspeck.slackmacgap|com.hnc.discord|\
    net.whatsapp.whatsapp|ru.keepcoder.telegram|org.telegram.desktop|org.whispersystems.signal-desktop|com.microsoft.teams2|\
    com.microsoft.outlook|us.zoom.xos|com.skype.skype|com.viber.osx|\
    com.apple.terminal|com.googlecode.iterm2|net.kovidgoyal.kitty|io.alacritty|org.alacritty|com.github.wez.wezterm|co.zeit.hyper|\
    com.mitchellh.ghostty|com.microsoft.vscode|dev.zed.zed|com.apple.dt.xcode|com.apple.shortcuts|com.apple.automator|\
    com.jetbrains.*|dev.warp.*)
# END never-capture list
      return 0 ;;
  esac
  return 1
}
