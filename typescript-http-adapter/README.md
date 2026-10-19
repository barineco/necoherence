# Necoherence HTTP adapter for TypeScript

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This optional MIT package executes Necoherence network-effect commands with `fetch`.
The core `necoherence` package contains the ledger and accepts caller-supplied observations.
Install both packages at matching versions:

```bash
npm install necoherence@0.2.2 necoherence-http-adapter@0.2.2
```

```typescript
import { FetchHttpAdapter } from "necoherence-http-adapter";

const adapter = new FetchHttpAdapter();
```

For development, build `../typescript` first. The development dependency links that local core package; the published package declares it as a peer dependency.

```bash
npm ci
npm run typecheck
npm test
npm pack
```

[MIT License](LICENSE)
