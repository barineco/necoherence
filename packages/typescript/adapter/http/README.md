# Necoherence の HTTP アダプター (TypeScript)

[プロジェクトの概要](../../../../README.md)

ネットワーク副作用コマンドを TypeScript で実行する追加アダプターパッケージです。また、HTTP クライアントには標準の `fetch` を使用します。コアパッケージ ( `necoherence` ) は副作用状態を管理し、本アダプターから渡された I/O 観測結果を受け取って状態機械を更新します。両パッケージは同一バージョンでインストールして使用します。

```bash
npm install necoherence@0.3.0 necoherence-http-adapter@0.3.0
```

## 使い方

### drive で試行を最後まで進める

関数 `drive` は、コアパッケージの `semanticExecution.start` が返した最初の進行を受け取り、結果が確定するまで処理を進めます。戻り値は `DriveResult` の Promise であり、成功と失敗の区別は公開 API の節に示します。

```typescript
import { networkEffect, semanticExecution } from "necoherence";
import { FetchHttpAdapter, drive } from "necoherence-http-adapter";

// admitted: semanticExecution.AdmittedComposition, providers: semanticExecution.Provider の配列,
// args: 引数の値の配列 ( コアパッケージの手順で用意 )
const adapter = new FetchHttpAdapter();
const started = semanticExecution.start(
  admitted,
  providers,
  args,
  networkEffect.emptyNetworkState(),
);
if (started.tag !== "Ok") throw new Error("start failed");
const driven = await drive(adapter, started.value);
if (driven.tag === "Ok") {
  const { result, retained } = driven.value;
} else {
  const { cause, retained } = driven.failure;
}
```

引数 `admitted` と `providers` は、コアパッケージの手順で用意します。関数 `drive` の挙動は次のとおりです。

- 送信の指示: `adapter.start` の呼び出し
- 観測の指示: worker からの通知による、観測が届くまでの待機
- コアパッケージへの反映のたび: 処理した試行の `release` の呼び出しと、記録の破棄
- 期限を持つ試行の待機: clock の `until` が返した時間で終了
- 結果の確定時: コアパッケージがまだ観測を要求する試行を `retained` に入れて返却

成功の値と失敗の値は、いずれも `retained` フィールドを持ちます。これは、`drive` が戻る時点でコアパッケージがまだ観測を要求している試行の配列です。すでにコアパッケージ側で終端に達した試行は、worker が実行中でも `retained` には入りません。その試行の送信中だった要求は中断済みとなり、記録は worker が終わった時に削除されます。結果が確定した通常の場合は、空の配列になります。

失敗の値に含まれる `cause` は次の三種類です。

| cause | 意味 |
| --- | --- |
| コアパッケージの `RunFailure` | コアパッケージが観測の反映を拒否した |
| `UnknownExecution` | 観測を待つ handle の記録が削除されていた |
| `DeadlineWaitUnavailable` | clock の `until` が空の値を返した |

原因が `DeadlineWaitUnavailable` の場合、`drive` は即座に制御を返します。このとき、記録は `retained` に入ります。

### start と observe を自分で呼ぶ

試行の進め方を自分で制御する場合、コアパッケージの関数とアダプターの関数は次の順に呼び出します。

1. 通信の指示の準備: `networkEffect.prepare`
2. 送信の命令の作成: `networkEffect.sendCommand`
3. 送信の開始: `adapter.start`
4. 開始の観測の反映: `networkEffect.observeStart`
5. 観測の取り出し: `adapter.observe`
6. 観測の反映と結果の確定: `networkEffect.observe`
7. 取り出しを終えた試行の記録の破棄: `adapter.release`

記録は `start` で作成され、`release` が破棄を認めるまで保持されます。取り出しを終えた試行は、次のように `release` に渡します。

```typescript
const decision = adapter.release(state, startedAttempt);
```

引数 `state` はコアパッケージが返した最新の状態であり、`startedAttempt` は開始の観測を反映した結果が持つ試行です。ここで `release` が返す破棄の判定は次のとおりです。

| 判定 | 意味 |
| --- | --- |
| `dematerialize` | 破棄を認めた。記録が削除される |
| `retain` ( 理由は `futureUse` ) | コアパッケージがその試行をまだ待っている |
| `retain` ( 理由は `outstandingEffect` ) | worker がまだ動いている |

判定結果が `retain` だった場合は、状態が進んだ後で同じ試行に対して `release` を呼び直します。関数 `drive` を使う場合は、この呼び出しを `drive` が自動で行います。

### 公開 API

```typescript
export class FetchHttpAdapter {
  constructor(options?: FetchHttpAdapterOptions);
  start(command: SendCommand): StartObservation;
  observe(started: StartedAttempt): HostObservation | UnknownExecution;
  cancel(command: CancelCommand): HostObservation | UnknownExecution;
  close(started: StartedAttempt): HostObservation | UnknownExecution;
  release(state: NetworkState, started: StartedAttempt): HostRecordDecision;
}

export function drive(
  adapter: FetchHttpAdapter,
  first: semanticExecution.Progress,
): Promise<DriveResult>;

export type DriveResult =
  | { readonly tag: "Ok"; readonly value: Driven }
  | { readonly tag: "Failed"; readonly failure: DriveFailure };

export interface Driven {
  readonly result: semanticExecution.ExecutionResult;
  readonly retained: readonly StartedAttempt[];
}

export interface DriveFailure {
  readonly cause: semanticExecution.RunFailure | UnknownExecution | DeadlineWaitUnavailable;
  readonly retained: readonly StartedAttempt[];
}

export interface UnknownExecution {
  readonly tag: "UnknownExecution";
  readonly handle: { readonly value: string };
}

export interface DeadlineWaitUnavailable {
  readonly tag: "DeadlineWaitUnavailable";
  readonly handle: { readonly value: string };
}
```

## port と capability

アダプターは、時刻の port と取り消しの port を、オプションとして受け取ります。

```typescript
const adapter = new FetchHttpAdapter({
  monotonicClock: clock,
  cancellation: canceller,
});
```

オプションには、`fetch` と `createAbortController` も渡せます。各 port のインターフェースは次のとおりです。

```typescript
export interface MonotonicClockPort {
  capability: () => MonotonicClockCapability;
  observe: () => MonotonicClockObservation | HostFailure;
  until?: (limit: bigint) => number | undefined;
}

export interface CancellationPort {
  capability: () => CancellationCapability;
  request: (handle: ExecutionHandle) => undefined | HostFailure;
}
```

既定では、clock も取り消しの port も空です。そのため、期限を持つ試行には clock を、取り消しを使う試行には取り消しの port を渡します。

各 port は失敗を戻り値で返します。失敗の値は、コアパッケージの `HostFailure` ( `tag` を持つ値 ) です。時刻の観測は `tag` フィールドを持たないため、戻り値の `tag` の有無で通常の値と失敗を見分けます。

取り消しの port は、成功時に `undefined` を返し、受け取る引数は `handle` の 1 個のみです。命令の capability と port の capability の照合は、アダプターが担当する設計です。

時刻の port が失敗の値を返した時と例外を出した時は、アダプターは次の値を持つ失敗の観測を一度だけ追加します。追加した後の `observe` は、すでに追加済みのその観測をそのまま返します。

- 段階: `Deadline` ( 失敗の値が `Timeout` の時は、その値が持つ段階 )
- 原因: 返された失敗の値 ( 例外の時は `HostRuntimeFailure` )
- 作用が不明になった理由: `HostFailure`

メソッド `until` の戻り値は、期限までの待機時間をミリ秒で表す `number` です。値が `undefined` の場合は、clock が待機時間を算出不能であることを表し、`until` 自体は省略可能です。

関数 `start` における検査の順序と、失敗時の原因を以下に示します。

1. scheme の検査: `UnsupportedUriScheme`
2. コアパッケージ入力の検査: `InvalidHostConfiguration` ( 設定の clock の capability が期限の capability と異なる入力を含みます )
3. 期限 clock の検査: `DeadlineControlUnavailable`
4. 取り消し capability の検査: `InvalidHostConfiguration`
5. worker の開始: `ExecutionStartFailed`

最初に失敗した検査で、開始の失敗が返ります。このとき失敗の段階は `Start`、効果は `Unknown` です。期限 clock の検査が失敗するのは次の場合です。

- 期限があり、clock が空
- clock の capability が、期限の capability と異なる

取り消しの capability の検査が失敗するのは次の場合に限られます。

- 設定の取り消しの capability があり、port が空
- 設定の capability が、port の capability と異なる

設定の capability と port の capability が一致する入力のみが、worker の開始へ進みます。ここで worker の開始とは、`createAbortController` の呼び出しです。

## 期限、取り消し、close

アダプターは、期限到達、clock の失敗、取り消しの結果、close のいずれの契機でも、観測を追加した時点で送信中の要求を止めます。その後に worker が得た結果は破棄されます。観測の一覧は次のとおりです。

| 契機 | 観測 |
| --- | --- |
| clock が期限に達した | `DeadlineObservation` |
| clock の失敗の値か例外 | `FailureObservation` と、返された失敗の値 ( 例外は `HostRuntimeFailure` ) |
| 取り消しの受理 | `CancellationObservation` |
| 取り消しの拒否 | 失敗の観測と `CancellationRejected` |
| 取り消しの port の失敗の値か例外 | `FailureObservation` と、返された失敗の値 ( 例外は `HostRuntimeFailure` ) |
| close | `FailureObservation` と `HostClosed` |

関数 `observe` は期限への到達を確かめます。期限に関わる観測 ( `DeadlineObservation` と clock の失敗 ) は、一つの試行で一度だけ返るのが仕様です。

失敗の段階について、取り消しの失敗と close では `Cancel`、clock の失敗では `Deadline` になります。なお、失敗の値が `Timeout` の時は、その値が持つ段階が優先されます。効果の理由については、期限が `Deadline`、取り消しが `Cancellation` です。また、取り消しの port が失敗の値を返した場合、port が空の場合、例外を出した場合も、要求は止まり、応答は破棄されます。

取り消しの命令が持つ権限が取り消し機構の権限と一致した場合に限り、要求は機構へ渡されます。不一致の場合は、取り消しの拒否と同じ観測が返り、要求が止まる仕組みです。

関数 `close` は、開始済みの試行を 1 件受け取り、`HostClosed` を原因とする失敗の観測を含む観測を返します。閉じる対象は、渡された試行の記録と、その送信中の要求のみです。記録が削除された handle への応答は `UnknownExecution` になります。

関数 `cancel` と `close` は、記録の待ち行列の先頭にある観測を返します。先に届いた応答があれば、その応答が先に返るのが仕様です。要求の終わりを決めるのは、期限、取り消し、close です。

リクエストの中断は、`createAbortController` が返す controller の `abort` で行います。

## 記録の寿命

アダプターは `start` ごとに記録を一つ作ります。記録が削除される契機は次のとおりです。

- `release` が `dematerialize` を返した時
- `release` が `retain` を返した後、コアパッケージでその試行が終端に達しており、かつ worker が終わった時

関数 `release` は記録の状態だけを進めます。要求自体は、アダプターが観測を追加した時点で止められています。もし `release` が `retain` を返し、コアパッケージ側でその試行が終端に達している時は、worker が終わった時に記録が削除されます。要求を止めた後の観測は、止めた時に追加された一つが最後です。

記録が削除された後の handle に対する応答を以下に示します。

```typescript
adapter.observe(started); // { tag: "UnknownExecution", handle }
adapter.cancel(command); // { tag: "UnknownExecution", handle }
adapter.close(started); // { tag: "UnknownExecution", handle }
```

未開始の handle に対しても、同じ応答が返ります。

関数 `drive` は処理した試行に `release` を呼ぶため、結果が確定すれば記録は削除されています。試行を自分で進める場合は、`release` が破棄を認めるまで記録が残るのが仕様です。

## 検査

開発時には、まず上位ディレクトリ `..` をビルドしてください。本リポジトリ内の開発時依存関係はローカルのコアパッケージを参照しますが、公開 npm パッケージとしてはコアパッケージを peer dependency として宣言しています。

```bash
npm ci
npm run typecheck
npm test
npm pack
```

## ライセンス

[MIT License](LICENSE)
