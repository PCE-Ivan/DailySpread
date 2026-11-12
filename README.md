# DailySpread

A menu bar app that puts a new high-resolution wallpaper on your Mac every day and
spreads it across all your displays as one continuous picture.

## Install

Download `DailySpread-1.3.dmg` from the [latest release](../../releases/latest), open it
and drag DailySpread onto Applications. It runs on Apple silicon and Intel Macs with
macOS 13 or later.

DailySpread isn't notarised by Apple, so the first time you open it macOS says it
can't verify it. Click Done, then open System Settings › Privacy & Security and click
**Open Anyway** next to DailySpread.

## Build from source

Double-click `build.command`. It compiles the app, installs it in Applications
(replacing any copy already there) and opens it. Double-click `make-dmg.command` to
build a drag-to-install `.dmg` for Apple silicon and Intel Macs instead. The first
time, macOS may ask to install Apple's free Command Line Tools; click Install, then
run it again.

## Sources

- **Wallhaven** (wallhaven.cc): a big wallpaper library with an open API.
- **Wikimedia Commons featured pictures**: photos voted the best on Commons,
  freely licensed and often far larger than 8K. The photographer and licence are
  shown in the menu.
- **Wikimedia Commons quality images**: hundreds of thousands of freely licensed
  photos that passed Commons' quality review, cars included.
- **NASA Image Library** (off by default): public-domain pictures of space, and of
  Earth from orbit on nature days. Most are well under 8K, so it rarely finds one
  big enough unless the minimum size is lowered.
- **Flickr** (optional, needs a free API key): Creative Commons photos at their
  original size. This product uses the Flickr API but is not endorsed or certified
  by SmugMug, Inc.
- **A folder of your own pictures**: e.g. photos you download from unsplash.com.
- **Another app**: keep using Unsplash Wallpapers (or any app) to choose pictures,
  and DailySpread spreads whatever it sets.

Unsplash's and Pexels' API terms don't allow wallpaper apps to fetch their photos,
so DailySpread doesn't; the folder and "another app" options cover Unsplash.
Openverse and most museum APIs were checked too, but only offer images far smaller
than 8K.

Sources and topics take turns, and each day's picture is drawn at random from the
strongest candidates (sharp on your screens, little cropping), so days don't repeat
the same look.

## Topics

Tick subjects in Settings (Nature, Cars, Mountains, Space…) or type your own. Each
day takes the next topic, and the sources take turns too.

## How it spreads a picture

- **Real sizes.** Each display reports its panel size in millimetres, so the picture
  is laid out in millimetres: it carries on at the same size from one screen to the
  next even when the screens differ in size, resolution or scaling.
- **Lining up.** "Show Alignment Grid" puts a test grid across the screens. Adjust
  the gap (the frames between the pictures) and each screen's height until the lines
  run straight across.
- **Sharpness.** DailySpread works out how many pixels a picture needs to show full
  detail across your panels and picks the sharpest candidate, then the least cropped.
  Each slice is drawn at the display's full resolution with Lanczos resampling in the
  display's own colour space.
- **Every day** at the time you choose, or when the Mac wakes if it was asleep.
  Rearranging or plugging in displays re-cuts the current picture automatically.

Files live in `~/Library/Application Support/DailySpread`.

Spanning approach modelled on SpreadPaper (MIT, github.com/spreadpaper/SpreadPaper).
