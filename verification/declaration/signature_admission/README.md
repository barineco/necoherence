# signature_admission

このパッケージは、Lean 実装におけるコード生成受け入れ検証 ( admission ) の実行エントリポイントです。標準入力から JSON を受け取り、検証結果を 1 行の JSON として標準出力へ返します。

## 依存関係

依存パッケージは、`neco-quotient` の固定リビジョンを参照して取得します。取得対象のコミットハッシュおよびリポジトリ URL は `lake-manifest.json` に定義しています。

## 実行手順

以下のコマンドで実行可能バイナリをビルドして実行できます。

```sh
cd verification/declaration/signature_admission
lake update
lake build
.lake/build/bin/signature_admission < request.json
```

## 入出力仕様

リクエストの JSON のフィールド:

- `exchange`: `ncoh-checked-generation@5` の JSON の文字列
- `expected_basis`: 期待する識別値と観測関数族を持つ値

レスポンスは、受理またはエラーを示す 1 行の JSON です。

### バッチ処理モード

6 言語のエントリポイントはいずれも `--batch` オプションに対応しています。このオプションを指定すると、標準入力の各行を 1 件のリクエストとして読み込み、リクエストと同一順序で 1 行ごとに検証結果を標準出力へ返します。入力の改行によって各リクエストが区切られます。途中の空行は JSON パースエラーとして処理されます。

バッチ処理モードでも、単一リクエスト時と同一の検証関数が呼び出されます。例外が発生したリクエストについては該当行にエラー JSON を出力し、後続のリクエスト処理を継続します。

### 合成エラーの名称規則

合成入力の準備エラーおよび合成検証エラーでは、Lean のコンストラクタ名の先頭を小文字化した識別子を理由フィールド ( `reason` ) に出力します。6 言語のエントリポイントすべてで同一の識別子が出力されます。

## 終了コード

正常な検証結果が得られた場合は、受理・拒否にかかわらず終了コード 0 を返します。

致命的障害 ( 標準入力の読み取りエラーなど ) が発生した場合に限り、Lean ランタイムが終了コード 1 で終了します。

## 言語間の比較テスト

全 6 言語のエントリポイントの出力を、基準となる Lean 実装の出力と比較します。この比較では Lean の出力を期待値とし、不一致があれば詳細を出力します。テスト入力は、`ncoh-checked-generation@5` の JSON と期待する `basis` から生成されます。

各言語の実行準備:

1. Lean: 前述の `lake build` を実行
2. TypeScript: 依存関係をインストールしてビルド
3. Python: 依存環境をセットアップ
4. Java: JAR ファイルをビルドして指定
5. Rust / Gleam: 各言語のエントリポイントをビルド

パッケージ TypeScript の依存関係インストールとビルド:

```sh
npm --prefix packages/typescript/adapter ci
npm --prefix packages/typescript/adapter run build
```

パッケージ Python の依存関係インストール:

```sh
pip install "neco-quotient-certificate==0.2.0"
```

比較テストの実行コマンド:

```sh
python3 verification/declaration/signature_admission_compare.py --languages lean,python,typescript
```

比較対象言語は `--languages` で選択でき、省略時は全言語が対象となります。なお、Lean は基準実装のため常に実行されます。オプションの詳細は `--help` で確認してください。

テストハーネスは、全テストケースを各言語プロセスへバッチ形式でパイプライン供給します。

主なオプション:

- `--jobs`: 同時実行する言語プロセス数
- `--shards`: 言語ごとのシャードプロセス数
- `--cases`: テストケース種別 ( 既定は静的ケース。他に変異生成ケース、両方 )
- `--diff-log`: 不一致ログの出力先ファイル

テストケース識別子のプレフィックスは判定内容を表します。変異生成テストケースは `exhaustive-*` で始まります。

基準となる JSON:

- `accepted`: 正常に受理される JSON
- `accepted-rich-library`: 全種類の型ノードおよび書式規則を含む JSON
- `accepted-composition`: 合成を含む JSON
- `accepted-unique`: 一意選択 ( `RequireUnique` ) の閉包を含む JSON
- `rejected-closure-used-site`: 閉包の使用箇所不一致を含む JSON

実行結果として、テスト件数、言語ごとの不一致件数、実行時間、不一致サマリ表などが出力されます。不一致またはエントリポイント準備エラーが発生した場合は終了コード 1 または 2 で終了します。

## Rust エントリポイント仕様

このセクションでは、Rust の生成照合エントリポイントの仕様を定めます。

### 実装ファイル

- エントリポイント本体: `verification/declaration/signature_generator/src/bin/signature_admission_outcome.rs`
- サンプルデータ: `verification/declaration/signature_admission/examples.json`

### 入力形式

オプション `--batch` の指定時は 1 行 1 JSON、非指定時は全体で 1 JSON を標準入力から読み込みます。この JSON は次の 2 フィールドを持ちます。

- `exchange`: `ncoh-checked-generation@5` の JSON
- `expected_basis`: 期待する識別値と観測関数族を持つ値

合成を含まない入力では、問題ダイジェストフィールドに `null` を指定します。

### 出力形式

標準出力に、結果を 1 行に 1 つの JSON 値として出力します。

出力種別:

- `accepted`: 受理
- `failed` ( kind 付き ): 検証エラー ( `certificate` の不一致を含む )
- `failed` ( kind: `request` ): リクエスト形式エラー
- `failed` ( kind: `decode` ): JSON のデコードエラー

### エラー種別 ( kind )

- `schema`: スキーマバージョン不一致 ( 実バージョン情報を付与 )
- `certificate`: 証明書不一致による拒否
- `entrypoints_empty`: エントリポイントが空
- `entrypoint_identity_empty`: エントリポイント識別子が空
- `entrypoint_duplicate`: エントリポイント識別子の重複
- `entrypoint_unresolved`: エントリポイント定義の未解決
- `declaration`: 宣言規則違反
- `composition`: 合成の検証エラー
- `rule_table`: 規則表のエラー
- `rendering`: コード生成のレンダリングエラー
- `decode`: デコードエラー
- `request`: リクエスト形式エラー

### 照合順序

エントリポイントは `admit_signature_generation` の判定順序に厳密に従います。

1. スキーマ検証およびデコード
2. エントリポイントの空判定・一意性・定義解決
3. 型宣言の検査および射影の準備
4. 生成識別値 `basis` の受け入れ照合 ( admit )
5. 合成の妥当性検証
