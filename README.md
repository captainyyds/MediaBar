# Media Bar

Whatever is playing, on the Touch Bar. A [Pock](https://github.com/pigigaldi/Pock)
widget with a scrubbable progress bar, transport controls, the cover art and a
volume slider — for any app, with no resident process.

![Expanded](docs/expanded.png)

Collapsed it is one glyph wide: the cover inside a ring that fills as the track
plays, so it can sit beside your other widgets without crowding them.

![Collapsed](docs/collapsed.png)

Nothing here knows about any particular application. It reads the system's Now
Playing session, so a browser, a music app and a video player all show up the
same way, and an app that starts playing takes over the bar without any code
being added for it.

## Why this exists

Pock ships a Now Playing widget. On recent macOS it shows nothing.

The reason is more interesting than a broken API. `MediaRemote` still works
perfectly — but it decides whether to answer based on **what kind of process is
asking**. An Apple-signed interpreter gets the full session. Everything else
gets an empty dictionary and no error:

| Host process | Fields returned |
| --- | --- |
| `/usr/bin/python3` | 14 |
| `/usr/bin/perl` | 14 |
| a compiled Swift or ObjC binary | 0 |

Both compiled languages were tried, with the same result: the call succeeds, the
dictionary comes back empty, and nothing reports an error. Whether entitlements
or a hardened runtime would change that was not tested — loading into an
interpreter works, so the question stopped mattering.

So the part of this widget that talks to MediaRemote is not a tool. It is a
dylib (`helper/nowplaying.m`) loaded into `/usr/bin/perl` at runtime, which
prints one line of JSON and exits. Perl rather than Python for the path that
runs on a timer: its interpreter starts in about four milliseconds against
Python's nineteen, which on a reading that costs eighteen in total is most of
the difference.

## What keeps it cheap

**Nothing stays resident.** Every interpreter that can reach MediaRemote loads
Foundation with it, which is a seventeen-megabyte floor no choice of language
gets under. A subscription would mean paying that continuously. Reading on
demand and exiting costs a little CPU instead, which is the better trade when
the machine has cores to spare and memory it would rather keep.

**The progress bar does not ask anything to animate.** MediaRemote hands back an
anchor — the elapsed time as of a particular instant, plus the playback rate —
so the position at any later moment is arithmetic:

```
position = elapsed + (now − anchorDate) × rate
```

That is drift-free and free of IPC. A reading is only how a change made
somewhere else — a track ending, a pause pressed in the app — gets noticed, so
readings are rare rather than continuous.

Measured on a 13″ M2 MacBook Pro, as a share of one core. A reading costs 18 ms
and happens every 10 s collapsed, every 3 s expanded:

| | readings | drawing | total |
| --- | --- | --- | --- |
| collapsed | 0.18 % | below the noise floor | **≈ 0.2 %** |
| expanded | 0.60 % | below the noise floor | **≈ 0.6 %** |

"Below the noise floor" is meant literally. Over three 40-second windows an
empty Pock measured 0.07 %, 0.25 % and 0.02 %; adding the widget moved the
median by 0.03 points collapsed and 0.05 points expanded, which is well inside
that spread. The drawing is not distinguishable from not having it.

Two notes on measuring this, both learned the hard way. `ps`'s `%cpu` is an
average over the process's whole life, not its current rate, so it cannot show
what a widget costs now — these numbers come from differencing cumulative CPU
time over a fixed window. And a machine you are actively using is not a quiet
one: the same configuration measured 0.02 % while idle and 1.15 % while
applications were being switched, because every Touch Bar show and hide relays
the widget out.

Resident processes: none. Resident memory: none beyond the widget's own views
inside Pock.

## Taking the Control Strip, and giving it back

Expanded, the bar covers the whole strip — including the space the Control Strip
normally occupies — and collapsing gives it back. Both without Pock rebuilding
its bar, so the toggle does not flicker.

The lever is the `placement` argument of the private
`+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`:
**0 shares the strip with the Control Strip, 1 takes all of it.** Pock's own
`presentOnTop:` always passes 1, which is why going through it can take the
Control Strip away and never give it back.

Two details that are easy to get wrong, both found by measuring rather than
reading:

- Presenting a bar that is already on screen does not move it. The placement is
  fixed when it goes up, so it has to come down first.
- It must come down through Pock's own `dismissFromTop:`, not AppKit's
  `dismissSystemModalTouchBar:`. The raw one tears the items down with it and
  leaves the widget deallocated.

Every step is checked at runtime and falls back to Pock's ordinary reload if a
future version renames any of it.

## Install

Download `MediaBar.pkarchive` from the
[releases](../../releases) and open it — Pock installs it. Or build it:

```bash
cd widget && ./build.sh --install
```

Then relaunch Pock and add **Media Bar** from its customisation panel.

Requires macOS 15 or later and Pock 0.9 or later. Builds with the Command Line
Tools; no Xcode project.

## Layout

Expanded, left to right: collapse, previous, play/pause, next, cover, elapsed,
the scrubbable track with the title riding on it, remaining, mute, volume.

- Drag anywhere on the track to scrub. The bar follows your finger and only
  commits on release, so overshooting costs nothing.
- Drag the volume slider and it follows live, because volume has no equivalent
  of overshooting.
- Buttons an app has not registered are dimmed rather than hidden, so the
  layout stays put as you move between apps.

## Tests

```bash
cd widget && ./build.sh
swiftc -parse-as-library -o dist/render-test tests/render.swift Sources/*.swift \
  -I dist -L dist/lib -lPockKit -Xlinker -rpath -Xlinker "$PWD/dist/lib"
./dist/render-test
```

The Touch Bar cannot be screenshotted, so the layout is checked by rendering the
view to PNG and measuring where the content actually lands. The images above are
its output.

## License

MIT. `widget/Vendor/PockKit/` is vendored from Pock, also MIT,
© Pierluigi Galdi.
