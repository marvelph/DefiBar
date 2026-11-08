# DefiBar

Defi のワークスペースを macOS のメニューバーに横一列で表示します。表示対象は Defi がフォーカス中と報告するディスプレイです。名前のあるワークスペースには名前を、名前のないワークスペースには番号を表示します。

- ワークスペースのボタンをクリックすると、そのディスプレイ上で切り替わります。
- アクティブなワークスペースは背景色で区別し、名前の右に所属アプリのアイコンをアプリごとに1つ表示します。
- DefiBar の表示領域を右クリックすると、Defi の設定を開いたり、DefiBar を終了したりできます。ワークスペースを表示できないときはグリッドのアイコンが表示され、右クリックメニューの先頭で状態を確認できます。

## ビルドと起動

macOS 15.4 以降、Swift 5.9 以降、および `defi list-workspaces --json` に対応する Defi が必要です。プロジェクトのディレクトリで次を実行してください。Defi と DefiBar はどちらを先に起動しても構いません。

```sh
./build-app.sh
open .build/DefiBar.app
```

DefiBar は `~/Applications/Defi.app`、`/Applications/Defi.app`、実行時の `PATH` の順に CLI を探します。別の場所にある CLI を指定する場合は、アプリを終了してから絶対パスを使って起動できます。

```sh
DEFI_BIN="/path/to/defi" .build/DefiBar.app/Contents/MacOS/DefiBar
```

DefiBar の起動時に Defi CLI で初期状態を取得します。Defi がまだ応答できない場合は、Defi のワークスペース変更通知を待ちます。通知に含まれる JSON で表示を更新します。通知から状態を取得できない場合は CLI で再取得します。SketchyBar 本体のインストールは不要です。

連携仕様は [Defi の SketchyBar 連携ドキュメント](https://github.com/qeude/Defi/blob/main/contrib/sketchybar/README.md)を参照しています。
