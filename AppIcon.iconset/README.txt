TokenBurn — macOS App Icon Set
==============================

This folder (AppIcon.iconset) contains all PNGs required to build a macOS
.icns file. Images are square, full-bleed, sRGB, with no pre-rounded corners —
macOS applies the squircle mask automatically.

Files:
  icon_16x16.png       16x16
  icon_16x16@2x.png     32x32
  icon_32x32.png        32x32
  icon_32x32@2x.png     64x64
  icon_128x128.png     128x128
  icon_128x128@2x.png  256x256
  icon_256x256.png     256x256
  icon_256x256@2x.png  512x512
  icon_512x512.png     512x512
  icon_512x512@2x.png 1024x1024  (also the App Store submission size)

Build the .icns (run on macOS from the folder's parent):
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
