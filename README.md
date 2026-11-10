# DefiBar

**English** · [日本語](README.ja.md)

DefiBar displays [Defi](https://github.com/qeude/Defi) workspaces in a single row in the macOS menu bar. It shows workspaces for the display that Defi reports as focused. Named workspaces show their names, and unnamed workspaces show their numbers.

- Click a workspace button to switch to that workspace on the display.
- The active workspace has a distinct background color and shows one icon per app in that workspace to the right of its label.
- Right-click the DefiBar area to open Defi settings or quit DefiBar. If workspaces are unavailable, DefiBar shows a grid icon. The first item in the right-click menu shows the current status.

## Build and run

You need macOS 15.4 or later, Swift 5.9 or later, and Defi 0.9 or later. Run the following from the project directory. You can start Defi and DefiBar in either order.

```sh
./build-app.sh
open .build/DefiBar.app
```

DefiBar looks for the CLI in `~/Applications/Defi.app`, `/Applications/Defi.app`, and then on its runtime `PATH`. To use a CLI in another location, quit DefiBar and relaunch it with the absolute path to the CLI.

```sh
DEFI_BIN="/path/to/defi" .build/DefiBar.app/Contents/MacOS/DefiBar
```

On startup, DefiBar uses the Defi CLI to fetch the initial workspace state. If Defi cannot respond yet, DefiBar waits for a workspace change notification from Defi. It updates the display using the JSON in the notification. If the notification does not provide the workspace state, DefiBar fetches it again through the CLI. SketchyBar itself is optional.

For integration details, see [Defi’s SketchyBar integration documentation](https://github.com/qeude/Defi/blob/main/contrib/sketchybar/README.md).

### MIT License

DefiBar is released under the [MIT License](LICENSE).
