# javac と Error Prone の設定

本設定は、Java のパッケージと HTTP アダプターのビルド時に、`packages/java/build-maven.sh` および CI の Java ジョブで使用するものです。同じ検査を自身のコードに適用する場合にも、この設定を利用できます。

## javac のオプション

| オプション | 役割 |
|---|---|
| `--release 21` | Java 21 の API と言語機能のみを対象にする |
| `-Xlint:all` | 全ての警告を有効にする |
| `-Werror` | 警告が発生した時点でビルドを失敗させる |

## Error Prone の検査

ここでは Error Prone 2.51.0 を `javac` のプラグインとして使います。指定時は `-XepDisableAllChecks` で全ての検査を一度無効にし、四つの検査だけをエラーレベル ( `ERROR` ) で有効にしています。

- [`BanJNDI`](https://errorprone.info/bugpattern/BanJNDI)
- [`DoNotCall`](https://errorprone.info/bugpattern/DoNotCall)
- [`CatchFail`](https://errorprone.info/bugpattern/CatchFail)
- [`CheckReturnValue`](https://errorprone.info/bugpattern/CheckReturnValue)

プラグインの指定の形:

```
-Xplugin:ErrorProne -XepDisableAllChecks -Xep:BanJNDI:ERROR -Xep:DoNotCall:ERROR -Xep:CatchFail:ERROR -Xep:CheckReturnValue:ERROR
```

## JDK 21 での追加の設定

ツール `javac` で Error Prone を使う場合は、`javac` の内部オプションが必要です。

- コンパイルの方針: `-XDcompilePolicy=simple` など
- `jdk.compiler` の各パッケージの公開: `--add-exports`

全ての値は `build-maven.sh` に記載されています。
