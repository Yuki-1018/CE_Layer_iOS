# Third-party software

This application statically links DOSBox Pure at commit
`7f6e8fb7385fa446d1444d671063268520bf9b54`.

DOSBox Pure and the original DOSBox code are licensed under the GNU General
Public License, version 2 or (at your option) any later version. The exact
upstream source is available at <https://github.com/schellingb/dosbox-pure>,
and this repository contains the complete local patch in
`patches/dosbox-pure-ios-fixed-disk.patch`.

The upstream `LICENSE`, `DOSBOX-AUTHORS`, and `DOSBOX-THANKS` files are copied
into the application during the build.

The iOS physical-keyboard connection design was informed by dospad commit
`2e329c69913a1e3e58a9e12a089d079469521749`, which uses `GCKeyboard` to send
HID key transitions to its emulator. dospad is GPL-2.0 licensed and is
available at <https://github.com/litchie/dospad>. No dospad binary is linked.

Microsoft Windows 95 is not part of this repository and is not licensed or
distributed by this project. Users must supply their own lawfully licensed,
already-installed disk image.
