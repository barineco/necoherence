# TypeScript 向けの Necoherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

このパッケージは、Necoherence の TypeScript による実装です。
リビジョンなどの自然数は `bigint` で表します。
ES モジュールとして提供し、動作は Node.js 22 ( CI で使う版 ) で確認しています。

## 意味プロファイルの受け入れ

呼び出し側は、宣言を復号するときと、生成したライブラリを受け入れるときに、版の付いた意味プロファイルを渡します。
検証、符号化と復号、実行で使う転送形式は、受け入れたプロファイルが定めます。

収録しているプリセットは、シグネチャ用のプロファイルです。
呼び出し側は、信頼するバイト列、期待する参照、出典を照合してから、`checkLibrary` でライブラリを受け入れます。

```typescript
import { Buffer } from "node:buffer";
import { semanticSignatures as S, semanticValues as V } from "necoherence";

function decide(
  expected: V.ProfileRef, sources: readonly V.SourceIdentity[],
  trusted: Uint8Array, input: Uint8Array, library: S.TypeSignatureLibrary,
  typeId: string, value: V.ExactJson,
): V.ExactJson {
  V.requireEvidence(Buffer.from(trusted).equals(Buffer.from(input)), "profile bytes");
  const text = new TextDecoder("utf-8", { fatal: true }).decode(input);
  const profile = JSON.parse(text) as S.ValueSemanticProfile;
  V.requireEvidence(V.same(profile.reference, expected), "profile reference");
  V.requireEvidence(V.same(profile.source_refs, sources), "profile sources");
  const checked = S.checkLibrary({ ...library, profile });
  const reference = checked.refs.get(typeId);
  V.requireEvidence(reference, "type identity");
  return checked.context.validate(reference, value);
}
```

失敗の型は、原因ごとに次のとおりです。

- `SemanticEvidenceError`: バイト列、参照、出典、型のいずれかが期待と食い違っている
- `DeclarationPredicateFailure`: ライブラリが宣言の条件に違反している
- `SemanticValueError`: 値が検証で拒否された

## その他の機能

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) に挙げた機能のほかに、次の機能があります。

- 宣言の検査: 識別子の重複や、宣言にない型や定義への参照など、型と操作の宣言の誤りを検出する
- 生成したコードのランタイム: 生成した TypeScript のコードが実行時に呼び出す、値の検証とコーデックの共通の処理

任意の [HTTP アダプター](../typescript-http-adapter/) は、`necoherence-http-adapter` として独立に配布します。ネットワーク副作用のコマンドを `fetch` で実行し、観測を核の台帳へ返します。

## 付属のツール

型と操作の宣言から TypeScript の型とコーデックを生成する生成器は、[tools/](https://github.com/barineco/necoherence/tree/publish/tools) にあります。
ライセンスは AGPL-3.0-only です。

## 型検査とテスト

次のコマンドで、型検査とテストを実行します。

```bash
npm ci
npm run typecheck
npm test
```

## ライセンス

[MIT](LICENSE)
