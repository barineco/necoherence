# Gleam 向けの Necoherence の HTTP アダプター

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

この任意のパッケージは、Necoherence のネットワーク副作用のコマンドを、Erlang 上で `gleam_httpc` を使って実行します。ライセンスは MIT です。
核の `necoherence` パッケージの版 0.2.x に依存します。
核が提供するのは、HTTP クライアントに依存しない台帳と、呼び出し側が渡すホストのポートです。

```bash
gleam add necoherence_http_adapter
```

```gleam
import necoherence_http_adapter as http

pub fn ports() {
  http.host_port(http.default_ports())
}
```

返されたポートが提供するものは、次の 2 つです。

- `semantic_signature_http.Binding`
- 関数構成のランタイムが使うネットワークの所有者

アダプターは、より低い水準の実行の関数も提供します。

- `start`: 発行したコマンドを開始する
- `observe`: 次の観測を読む
- `cancel`: 取り消しを要求する
- `close`: 実行を閉じる

ソースからの開発では、ネットワーク副作用の照合のテスト用パッケージを使います。このパッケージは、直接の path 依存で、このリポジトリの 2 つのパッケージを選びます。アダプターの manifest は、核の Hex の版の要件を宣言しています。

```bash
cd ../comparison/network_effect/gleam_driver
gleam format --check
gleam build --warnings-as-errors
gleam test
```

公開用のアーカイブは、核の版が Hex で利用できるようになった後で、アダプターのディレクトリで次のコマンドを実行して作ります。書き出しの前に、Gleam が宣言した Hex の依存を解決するためです。

```bash
gleam export hex-tarball
```

[MIT ライセンス](LICENSE)
