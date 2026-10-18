# TypeScript 向けの Necoherence の HTTP アダプター

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

この任意のパッケージは、Necoherence のネットワーク副作用のコマンドを `fetch` で実行します。ライセンスは MIT です。
核の `necoherence` パッケージは、台帳を持ち、呼び出し側が渡す観測を受け取ります。
2 つのパッケージは、同じ版で導入します。

```bash
npm install necoherence@0.2.1 necoherence-http-adapter@0.2.1
```

```typescript
import { FetchHttpAdapter } from "necoherence-http-adapter";

const adapter = new FetchHttpAdapter();
```

開発では、先に `../typescript` をビルドします。開発時の依存は、ローカルの核のパッケージを参照します。公開するパッケージは、核を peer dependency として宣言します。

```bash
npm ci
npm run typecheck
npm test
npm pack
```

[MIT ライセンス](LICENSE)
