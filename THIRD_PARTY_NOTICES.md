# Third-party notices

EdgeCompanion includes code adapted from, or closely following, the MIT-licensed projects below.
The source files that use them say so in a comment. Each project's copyright notice and the MIT
license text are reproduced here as that license requires.

| Project | Used for | Files |
|---|---|---|
| [exelban/stats](https://github.com/exelban/stats) | CPU, SMC, network, disk, battery and Bluetooth readers | `Sources/EdgeCompanion/Telemetry/*` |
| [vladkens/macmon](https://github.com/vladkens/macmon) | SMC temperature key discovery on Apple Silicon | `Sources/EdgeCompanion/Telemetry/SensorsReader.swift` |
| [MonitorControl/MonitorControl](https://github.com/MonitorControl/MonitorControl) | DDC/CI over `IOAVService` on Apple Silicon | `Sources/EdgeCompanion/Display/DDCController.swift` |
| [bwya77/DockAnchor](https://github.com/bwya77/DockAnchor) | Moving the Dock by replaying an edge push | `Sources/EdgeCompanion/Kiosk/DockRelocator.swift` |

Linked at build time through Swift Package Manager (not included in this repository; include its
notice when distributing a built app):

| Project | Used for |
|---|---|
| [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | The dashboard terminal |

Bundled font (in `Resources/Fonts`, shipped inside the app):

| Font | License | Files |
|---|---|---|
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), patched by [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) v3.5.1 ("JetBrainsMono Nerd Font Mono") | SIL Open Font License 1.1 (`Resources/Fonts/OFL.txt`). The added icon sets keep their own licenses, listed in `Resources/Fonts/NerdFonts-JetBrainsMono-README.md` | `JetBrainsMonoNerdFontMono-Regular.ttf`, `JetBrainsMonoNerdFontMono-Bold.ttf` |

Hardware facts (DDC feature codes, the touch controller's report layout, gain scales) were learned
from several other projects, including GPL-licensed ones. No code from those projects is included.

---

## exelban/stats

Copyright (c) 2019 Serhiy Mytrovtsiy

## vladkens/macmon

Copyright (c) 2024 vladkens

## MonitorControl

Copyright © 2017 MonitorControl contributors (@JoniVR, @theOneyouseek, @waydabber and others)

## DockAnchor

Copyright (c) 2025 Bradley Wyatt

## SwiftTerm

Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

---

All of the above are distributed under the MIT License:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
