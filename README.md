# メディアを10秒・1秒戻す・進める

AutoHotkey v2 で `MediaSeek.ahk` を起動します。
Windows 10 バージョン1809以降／Windows 11 に対応します。

| 操作 | ショートカット |
| --- | --- |
| 10秒前に戻る | Ctrl + Alt + Shift + F7 |
| 10秒後に進む | Ctrl + Alt + Shift + F8 |
| 1秒前に戻る | Ctrl + Alt + Shift + F9 |
| 1秒後に進む | Ctrl + Alt + Shift + F10 |

デバイスには上のキーの組み合わせを登録してください。
一般的なキー操作との衝突を避けやすくするため、3つの修飾キーを組み合わせています。

AutoHotkeyからWindowsのメディアAPIを直接呼びます。必要なファイルは `MediaSeek.ahk` だけです。
Windowsが選んだメディアセッションを操作します。別のアプリを操作中でも使えます。
非対応のアプリやメディアの場合は何もせず、エラー表示もしません。

キーはファイル冒頭付近の `Hotkey(...)` の4行で変更できます。
`^` は Ctrl、`!` は Alt、`+` は Shift を表します。
移動精度はプレーヤー側のシーク処理に依存します。

## 設定と連打時の動作

`MediaSeek.ahk` 冒頭の `MediaSeekSettings` で変更します。

| 設定 | 初期値 | 内容 |
| --- | --- | --- |
| `LargeSeconds` | `10` | F7 / F8 の移動秒数 |
| `SmallSeconds` | `1` | F9 / F10 の移動秒数 |
| `SendIntervalMs` | `100` | シーク要求を送る最短間隔（ミリ秒） |
| `TimeoutMs` | `1500` | 管理オブジェクトの初期取得・各シーク要求のタイムアウト（ミリ秒） |
| `ShowPosition` | `true` | 操作対象と目標位置の短い表示。`false` で非表示 |
| `PositionDisplayMs` | `800` | 最後の表示更新から消えるまでの時間（ミリ秒） |

秒数には正の数、ミリ秒には1以上の整数を指定してください。
初回の要求は次のタイマー実行時に送り、連打中は設定した間隔で入力をまとめます。
処理中のシーク要求は1件までとし、完了待ちの間も追加のキー入力を受け付けます。
入力は順番どおりに反映し、開始位置・終了位置でそれ以上移動できない要求は送りません。
プレーヤーの位置情報の更新が遅れている場合も、同じ端への重複要求を省きます。

位置表示の `Target` は要求する目標位置です。操作対象はWindowsが返すアプリ識別子
（例：`chrome.exe`）で表示します。実際の到達位置・反映速度はプレーヤーに依存します。

COMのメソッド番号は `MediaAbi` にインターフェース別に集約しています。
位置の取得・シーク要求・完了確認は `MediaApi`、入力と送信間隔の管理は `MediaSeeker` が担当します。

## テスト

PowerShellでこのフォルダーを開き、次を実行します。

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut .\MediaSeek.Tests.ahk | Out-String
```

テストは仮のプレーヤーを使い、実際の再生位置を変更しません。
連打の集約、送信間隔、非同期処理中の入力保持、両端の重複省略、
対象の変更、失敗・タイムアウト時の復旧、時間表示を確認します。
末尾に `--live-read` を追加すると、実際のWindowsメディアAPIの読み取りも確認します。

## 常駐

`MediaSeek.ahk` をダブルクリックすると常駐し、別のアプリを操作中も使えます。
エクスプローラーやエディターを閉じても常駐を続けます。
通知領域の隠れたアイコン内も含め、AutoHotkeyのアイコンから操作できます。
変更後は通知領域のAutoHotkeyアイコンを右クリックして Reload Script を選びます。
終了は同じメニューの Exit です。

## ログイン時の自動起動

1. エクスプローラーで `MediaSeek.ahk` をコピーします。
2. Win + R で `shell:startup` を開きます。
3. フォルダー内を右クリックして「ショートカットの貼り付け」を選びます。

次回のWindowsへのログインから自動で常駐します。
Windows 11で項目が見つからない場合は「その他のオプションを確認」を開きます。
スクリプト本体は元のフォルダーに置いたままにしてください。

前に案内した、AutoHotkey64.exeとスクリプトのフルパスを指定するショートカットも引き続き使えます。
自動起動を解除するときは、登録したショートカットを削除します。

参考：[AutoHotkeyの起動方法](https://www.autohotkey.com/docs/v2/Program.htm#run)、[Windowsのスタートアップ設定](https://support.microsoft.com/en-gb/windows/experience/startup-boot/configure-startup-applications-in-windows)

