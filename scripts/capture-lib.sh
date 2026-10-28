#!/bin/bash
# Shared helpers for docked-shot.sh and record-demo.sh. Source it; it runs nothing by itself.
#
# Capture rule: the window's own bounds plus ONLY the tab's rectangle above it (the tab, plus 12 pt of headroom for the
# dog's head). Whatever else lies in the strip above the window (other windows, the desktop) must not be recorded, so a
# capture covers the union of the two rectangles and everything outside both is masked.
#   * PNG: scripts/shep-mask.swift makes the outside transparent.
#   * MOV: with ffmpeg, black boxes (drawbox) cover the outside; without it, the window alone is recorded and the tab
#     gets its own small recording.
# All rectangles are global points, top-left origin.

tab_height=30    # TabGeometry.height: how far the tab rises above the window's top edge
tab_peek=12      # PanelGeometry headroom: the dog's head may rise this far above the tab

# tab_from_log <shep log>  ->  "<above|inside> x y w h" of the tracker's latest TextEdit placement; fails if none.
tab_from_log() {
  local line
  line="$(grep 'com.apple.TextEdit' "$1" | grep -v 'demo fallback' | tail -n 1 || true)"
  printf '%s\n' "$line" | sed -nE 's/.*-> tab (above|inside) \((-?[0-9]+),(-?[0-9]+) ([0-9]+)x([0-9]+)\).*/\1 \2 \3 \4 \5/p' | grep .
}

# plan_capture <wx> <wy> <ww> <wh> <style> <tx> <ty> <tw> <th>
# Sets: cap_x cap_y cap_w cap_h (what to capture), keep_window / keep_tab ("x,y,w,h" or empty), mask_boxes (lines "x y w h"
# in points relative to the capture origin, covering every part of the capture outside the two kept rectangles).
plan_capture() {
  local wx=$1 wy=$2 ww=$3 wh=$4 style=$5 tx=$6 ty=$7 tw=$8 th=$9
  keep_window="$wx,$wy,$ww,$wh"; keep_tab=""; mask_boxes=""
  cap_x=$wx; cap_y=$wy; cap_w=$ww; cap_h=$wh
  [ "$style" = "above" ] || return 0   # an inside tab is part of the window already
  # The tab with its headroom, never past the top of the screen.
  local ky=$(( ty - tab_peek )) kh=$(( th + tab_peek ))
  if [ "$ky" -lt 0 ]; then kh=$(( kh + ky )); ky=0; fi
  [ "$kh" -gt 0 ] || return 0
  keep_tab="$tx,$ky,$tw,$kh"
  local right_w=$(( wx + ww )) right_t=$(( tx + tw ))
  cap_x=$(( wx < tx ? wx : tx ))
  cap_y=$(( wy < ky ? wy : ky ))
  local cap_r=$(( right_w > right_t ? right_w : right_t ))
  cap_w=$(( cap_r - cap_x ))
  cap_h=$(( wy + wh - cap_y ))
  # Band between the tab's top and the window's top: only the tab's columns survive.
  local band_h=$(( wy - ky ))
  if [ "$band_h" -gt 0 ]; then
    [ "$tx" -gt "$cap_x" ] && mask_boxes+="0 $(( ky - cap_y )) $(( tx - cap_x )) $band_h"$'\n'
    [ "$right_t" -lt "$cap_r" ] && mask_boxes+="$(( right_t - cap_x )) $(( ky - cap_y )) $(( cap_r - right_t )) $band_h"$'\n'
  fi
  # Rows of the window: only the window's columns survive (matters when the tab's flare reaches past a window edge).
  [ "$wx" -gt "$cap_x" ] && mask_boxes+="0 $(( wy - cap_y )) $(( wx - cap_x )) $wh"$'\n'
  [ "$right_w" -lt "$cap_r" ] && mask_boxes+="$(( right_w - cap_x )) $(( wy - cap_y )) $(( cap_r - right_w )) $wh"$'\n'
  return 0
}

# ffmpeg_mask_filter <pixels per point>  ->  a -vf chain of black drawbox filters for mask_boxes (empty if none).
ffmpeg_mask_filter() {
  local scale=$1 chain="" x y w h
  while read -r x y w h; do
    [ -n "${w:-}" ] || continue
    chain+="${chain:+,}drawbox=x=$(( x * scale )):y=$(( y * scale )):w=$(( w * scale )):h=$(( h * scale )):color=black:t=fill"
  done <<<"$mask_boxes"
  printf '%s' "$chain"
}

# bring_frontmost <shep-winfo binary> <app> <title fragment> <seconds> [<file to open>]
# Activates the app (`open -a`; the file too when the window is still not the focused one) and waits until the app is
# frontmost AND its focused window's title contains the fragment. On failure FRONT_REPORT says what is in front instead.
bring_frontmost() {
  local bin=$1 app=$2 fragment=$3 seconds=$4 file=${5:-} tries=0
  FRONT_REPORT=""
  open -a "$app" 2>/dev/null || true
  while [ "$tries" -lt "$seconds" ]; do
    if FRONT_REPORT="$("$bin" --frontmost "$app" "$fragment" 2>&1)"; then return 0; fi
    tries=$(( tries + 1 ))
    if [ "$tries" -eq 3 ] && [ -n "$file" ]; then open -a "$app" "$file" 2>/dev/null || true; fi
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------------------------------------------------
# Keep-only capture for the cycle recording (scripts/record-cycle.sh): the doghouse, the window, the tab and the travel arc's
# corridor are kept; everything else in the recorded bounding box is replaced by a flat neutral colour. Rectangles are
# "x y w h" lines in global points, top-left origin.

# clip_rect <x> <y> <w> <h> <min_x> <min_y>  ->  "x y w h" clipped to x >= min_x, y >= min_y; prints nothing when it is empty.
clip_rect() {
  local x=$1 y=$2 w=$3 h=$4 min_x=$5 min_y=$6
  if [ "$x" -lt "$min_x" ]; then w=$(( w - (min_x - x) )); x=$min_x; fi
  if [ "$y" -lt "$min_y" ]; then h=$(( h - (min_y - y) )); y=$min_y; fi
  if [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; then printf '%s %s %s %s\n' "$x" "$y" "$w" "$h"; fi
  return 0
}

# bounding_box  (rect lines on stdin)  ->  "x y w h" of their union; prints nothing for no input.
bounding_box() {
  awk 'NF >= 4 { if (!n++) { x0 = $1; y0 = $2; x1 = $1 + $3; y1 = $2 + $4; next }
       if ($1 < x0) x0 = $1; if ($2 < y0) y0 = $2; if ($1 + $3 > x1) x1 = $1 + $3; if ($2 + $4 > y1) y1 = $2 + $4 }
       END { if (n) printf "%d %d %d %d\n", x0, y0, x1 - x0, y1 - y0 }'
}

# ffmpeg_keep_filter <px per point> <cap_x> <cap_y> <cap_w> <cap_h>  (rect lines on stdin)  ->  a -filter_complex graph, input [0:v],
# output [out]: a flat background the size of the capture with only the kept rectangles copied in from the source.
ffmpeg_keep_filter() {
  local scale=$1 cx=$2 cy=$3 cw=$4 ch=$5 x y w h n=0 i
  local rx=() ry=() rw=() rh=()
  while read -r x y w h; do
    [ -n "${h:-}" ] || continue
    rx+=( $(( (x - cx) * scale )) ); ry+=( $(( (y - cy) * scale )) ); rw+=( $(( w * scale )) ); rh+=( $(( h * scale )) )
    n=$(( n + 1 ))
  done
  [ "$n" -gt 0 ] || return 1
  local g="color=c=0x202024:s=$(( cw * scale ))x$(( ch * scale )):r=30[b0];[0:v]split=$n"
  for (( i = 0; i < n; i++ )); do g+="[s$i]"; done
  g+=";"
  for (( i = 0; i < n; i++ )); do g+="[s$i]crop=${rw[$i]}:${rh[$i]}:${rx[$i]}:${ry[$i]}[k$i];"; done
  for (( i = 0; i < n; i++ )); do g+="[b$i][k$i]overlay=${rx[$i]}:${ry[$i]}:shortest=1[b$(( i + 1 ))];"; done
  g+="[b$n]pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p[out]"
  printf '%s' "$g"
}

# now_seconds  ->  wall-clock seconds with milliseconds (macOS date has no %N; perl ships with macOS).
now_seconds() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# mux_bark <video> <wav> <delay_ms> <out>  ->  <out>: the video copied unchanged, with the WAV delayed by <delay_ms> as its
# audio track (AAC), ending with the video. The WAV is padded with silence so a short bark does not cut the clip.
mux_bark() {
  local video=$1 wav=$2 delay=$3 out=$4
  ffmpeg -loglevel error -y -i "$video" -i "$wav" \
    -filter_complex "[1:a]adelay=${delay}|${delay},apad[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -shortest "$out"
}

# log_field <log> <prefix> <name>  ->  the value of "name=" on the last log line starting with "[shep] <prefix>" (up to a space).
log_field() {
  grep -F "[shep] $2" "$1" | tail -n 1 | sed -nE "s/.*[ ]$3=([^ ]*).*/\\1/p"
}
