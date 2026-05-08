#!/bin/sh
# Sourced very early by startplasma-wayland (before KWin). PS5 routes the internal
# DP through an HDMI bridge that mishandles HDR / wide-gamut / 10bpc signalling:
# assumed-HDR EDID paths and AR30/AB30 primaries can yield a valid mode but a black
# HDMI image. Force HDR off and prefer 8bpc/24bpp framebuffers.
#   - KWIN_FORCE_ASSUME_HDR_SUPPORT=0 (https://invent.kde.org/plasma/kwin/-/merge_requests/7337)
#   - KWIN_DRM_PREFER_COLOR_DEPTH=24
export KWIN_FORCE_ASSUME_HDR_SUPPORT=0
export KWIN_DRM_PREFER_COLOR_DEPTH=24
