# Necoherence (TypeScript)

[プロジェクトの概要](../../../README.md)

このパッケージは、Necoherence の TypeScript 実装です。

- ES モジュール ( ESM ) として提供

動作確認は Node.js の LTS ( CI 環境のバージョン ) で行っています。リビジョンなどの非負整数値は `bigint` で表現します。

## 検証結果

値の検証結果は、「確定」「残余」「停止」「失敗」に分類されます。分類の判定順序については [docs/terminology.md](../../../docs/terminology.md#確定残余停止失敗) を参照してください。本実装では、次の関数で結果を分類します。

- `semanticValues.classifySemanticObligations`: 値の検証で未解決となった理由の分類
- `semanticComposition.classifyUnresolvedObligations`: 合成処理で未解決となった理由の分類

### 残余の記録

関数 `semanticResidualRecord.encodeSemanticResidual` は、値の検証が返した残余を、`neco-quotient` の正規のバイト列として書き出します。引数として生成の `basis`、型の参照、値、義務の列を受け取ります。記録は次の 4 つのフィールドを持ち、各フィールドの通信形式は Rust のアダプターと同じです。

- `schema`: 記録のバージョンを示す定数文字列
- `basis`: 生成の `basis` の通信形式
- `input`: 型の参照と値の通信形式
- `residuals`: 義務の列の通信形式

義務の列は順序と重複によらず同じバイト列になります。結果は成功と失敗を区別できる形で返り、符号化の失敗と通信形式への変換の失敗は、種類を区別して保たれます。

## データモデル宣言

仕様と照合の条件については、[docs/data-model.md](../../../docs/data-model.md) を参照してください。

収録されているプリセットは、シグネチャ用のデータモデル宣言です。呼び出し元は、信頼できるバイト列、期待する参照識別子、出典を照合した上で、`checkLibrary` を呼び出してライブラリを検証します。

```typescript
import { Buffer } from "node:buffer";
import { semanticSignatures as S, semanticValues as V } from "necoherence";

function decide(
  expected: V.ProfileRef, sources: readonly V.SourceIdentity[],
  trusted: Uint8Array, input: Uint8Array, library: S.TypeSignatureLibrary,
  typeId: string, value: V.ExactJson,
): V.ValidatedValue {
  V.requireEvidence(Buffer.from(trusted).equals(Buffer.from(input)), "profile bytes");
  const text = new TextDecoder("utf-8", { fatal: true }).decode(input);
  const profile = JSON.parse(text) as S.ValueSemanticProfile;
  V.requireEvidence(V.same(profile.reference, expected), "profile reference");
  V.requireEvidence(V.same(profile.source_refs, sources), "profile sources");
  const checked = S.checkLibrary({ ...library, profile });
  const reference = checked.refs.get(typeId);
  V.requireEvidence(reference, "type identity");
  return V.validated(V.validateValue(checked.context, reference, value), reference);
}
```

主なエラー型とその要因:

- `SemanticEvidenceError`: バイト列、参照識別子、出典、型のいずれかが期待値と不一致
- `DeclarationPredicateFailure`: ライブラリが型・操作の宣言規則に違反している
- `SemanticValueError`: 値が型制約の検証で拒否された

## その他の機能

[プロジェクトの概要](../../../README.md) に記載の機能に加え、次の機能を提供します。

- 宣言の検証: 識別子の重複や未定義の型・定義への参照など、型や操作の宣言エラーを静的に検出
- 生成コード用ランタイム: 生成された TypeScript コードが実行時に呼び出す、値検証およびコーデックの共通処理

ネットワーク副作用コマンドを HTTP 経由で実行する場合は、[`http/`](http/) の HTTP アダプターを使用します。

## コード生成の受け入れ

形式 `ncoh-checked-generation@5` の JSON を受け入れる関数:

- `basis` の計算: `semanticSignatures.signatureBasis`
- 受け入れ検証: `semanticSignatures.admitSignatureGeneration`

生成識別値 `basis` と受け入れ検証の規則は [docs/generation.md](../../../docs/generation.md) を参照してください。

## 合成の実行

検証を通過した合成を実行する関数:

- 実行の開始: `semanticExecution.start`
- 実行の再開: `semanticExecution.resume`

実行の開始には `AdmittedComposition` を渡します。これは受け入れ検証の結果の `composition` から取得します。

実行の入力、関数の実装、進捗状態の意味は [docs/composition.md](../../../docs/composition.md#合成の実行) を参照してください。

## 付属のツール

型と操作の宣言から TypeScript の型定義とコーデックを生成するコード生成ツールは、[generator/](../../../generator/) 配下にあります。ライセンスは AGPL-3.0-only です。

## 開発時

次のコマンドで型検査とテストを実行できます。

```bash
npm ci
npm run typecheck
npm test
```

## ライセンス

[MIT](LICENSE)
