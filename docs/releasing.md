# DefiBar のリリース手順

## Sparkle の署名鍵を準備する

署名に使う Mac で、DefiBar 用の EdDSA 鍵ペアを一度だけ作成します。Sparkle は秘密鍵をログインキーチェーンに保存し、アプリに組み込んだ公開鍵で配布 ZIP と `appcast.xml` の署名を検証します。秘密鍵は安全にバックアップし、Developer ID 署名に切り替える場合も同じ鍵を使い続けます。

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account DefiBar
```

## 配布ファイルを生成する

新しいバージョンと、前回のリリースより大きいビルド番号を指定します。スクリプトは既存の EdDSA 鍵を読み取り、Apple Silicon と Intel の両方に対応する署名済み ZIP と `appcast.xml` を生成します。

アドホック署名でビルドする場合は、`DEFI_BAR_SIGNING_IDENTITY` に `-` を指定します。

```sh
DEFI_BAR_SIGNING_IDENTITY=- ./build-release.sh 0.5.0 5
```

Developer ID で署名する場合は、Developer ID Application 証明書と対応する秘密鍵を、署名に使う Mac のキーチェーンに用意します。`security find-identity -v -p codesigning` で証明書名または SHA-1 ハッシュを確認し、`DEFI_BAR_SIGNING_IDENTITY` に指定します。スクリプトはこの証明書でアプリ本体と同梱の Sparkle ヘルパーに署名します。

```sh
DEFI_BAR_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./build-release.sh 0.5.0 5
```

このスクリプトで行うのは署名までです。Apple への公証申請は別工程です。

## GitHub で公開する

`.build/releases/v0.5.0/` に生成された ZIP と `appcast.xml` を、タグ `v0.5.0` の GitHub リリースに添付し、最新の正式リリースとして公開します。インストール済みのアプリは `releases/latest/download/appcast.xml` を読み取り、そこに記載されたバージョン別の URL から ZIP を取得します。両ファイルをサインインなしで HTTPS 経由で取得できるようにし、生成したファイル名と内容はそのまま使います。

v0.4.0 以前から更新する場合は、最初の Sparkle 対応版を手動でインストールします。通常の `./build-app.sh` では、既定でアドホック署名を使い、更新フィードと公開鍵は組み込みません。
