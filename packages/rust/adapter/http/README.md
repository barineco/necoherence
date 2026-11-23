# necoherence-http-adapter ( Rust )

本パッケージは、コアパッケージ ( `necoherence` ) が生成した HTTP 通信の指示を実際に送信し、その応答を観測結果として返す Rust 用アダプターです。

通信の指示と観測による状態の更新は、コアパッケージの [../README.md](../README.md) に記載されています。

## 導入

このアダプターは Rust 1.88 以降で動作します。実行時には、同じバージョンのコアパッケージ `necoherence` と、HTTP 通信に使うライブラリ `ureq` に依存します。

利用元のプロジェクトにある `Cargo.toml` の `[dependencies]` に、次の一行を加えます。

```toml
necoherence-http-adapter = "0.3.0"
```

## 使い方

### drive で試行を最後まで進める

関数 `drive` は、コアパッケージの `start` が返した最初の進行を受け取り、結果が確定するまで処理を進めます。戻り値は、成功なら `Ok(Driven)`、失敗なら `Err(DriveFailure)` です。

```rust
use necoherence::network_effect::NetworkState;
use necoherence::semantic_execution as execution;
use necoherence_http_adapter::{drive, UreqHttpAdapter};

// run: execution::PreparedRun, providers: Vec<execution::Provider>,
// arguments: 引数の値の Vec ( コアパッケージの手順で用意 )
let adapter = UreqHttpAdapter::default();
let first = execution::start(
    &run,
    run.workspace(),
    providers,
    arguments,
    NetworkState::default(),
)
.unwrap();
match drive(&adapter, first) {
    Ok(driven) => {
        let _result = driven.result;
        let _retained = driven.retained;
    }
    Err(failure) => {
        let _cause = failure.cause;
        let _retained = failure.retained;
    }
}
```

関数 `drive` の挙動は次のとおりです。

- 送信の指示: `adapter.start` の呼び出し
- 観測の指示: worker からの通知による、観測が届くまでの待機
- コアパッケージへの反映のたび: 処理した試行の `release` の呼び出しと、記録の破棄
- 期限を持つ試行の待機: clock の `until` が返した時間で終了
- 結果の確定時: コアパッケージがまだ観測を要求する試行を `retained` に入れて返却

成功の戻り値と失敗の戻り値は、いずれも `retained` フィールドを持ちます。これは、`drive` が戻る時点でコアパッケージがまだ観測を要求している試行の一覧です。すでにコアパッケージ側で終端に達した試行は、worker が実行中であっても `retained` には入りません。その試行で送信中だった要求は中断済みとなり、記録は worker の終了時に削除されます。結果が確定した通常の場合は、この一覧は空になります。

失敗の戻り値に含まれる `cause` は、`DriveCause` の次の四種類です。

| cause | 意味 |
| --- | --- |
| `Run` | コアパッケージが観測の反映を拒否した |
| `UnknownExecution` | 観測を待つ handle の記録が削除されていた |
| `MissingInstruction` | 進行が、送信の命令か観測の対象を欠いていた |
| `DeadlineWaitUnavailable` | clock の `until` が空の値を返した |

原因が `DeadlineWaitUnavailable` の場合、`drive` は即座に制御を返します。このとき、記録は `retained` に入ります。

### start と observe を自分で呼ぶ

試行の進め方を自分で制御する場合、コアパッケージの関数とアダプターの関数は次の順に呼び出します。

1. 通信の指示の準備: `prepare`
2. 送信の命令の作成: `send_command`
3. 送信の開始: `UreqHttpAdapter::start`
4. 開始の観測の反映: `observe_start`
5. 応答の観測の受け取り: `UreqHttpAdapter::observe`
6. 観測の反映と結果の確定: `observe`
7. 取り出しを終えた試行の記録の破棄: `UreqHttpAdapter::release`

利用方法の具体例は、[tests/network_effect_http_smoke.rs](tests/network_effect_http_smoke.rs) を参照してください。

記録は `start` の呼び出し時に作成され、`release` が破棄を認めるまで保持されます。取り出しを終えた試行は、次のように `release` に渡します。

```rust
let decision = adapter.release(&state, &started);
```

引数 `state` はコアパッケージが返した最新の状態であり、`started` は開始の観測を反映した結果が持つ試行です。ここで `release` が返す破棄の判定は次のとおりです。

| 判定 | 意味 |
| --- | --- |
| `Dematerialize` | 破棄を認めた。記録が削除される |
| `Retain` ( 理由は `FutureUse` ) | コアパッケージがその試行をまだ待っている |
| `Retain` ( 理由は `OutstandingEffect` ) | worker がまだ動いている |

判定結果が `Retain` だった場合は、状態が進んだ後で同じ試行に対して `release` を呼び直します。関数 `drive` を使う場合は、この呼び出しを `drive` が自動で行います。

### 公開 API

```rust
impl Default for UreqHttpAdapter<SystemMonotonicClock, CooperativeCancellation> { /* 既定の port */ }

impl<C: MonotonicClockPort + 'static, X: CancellationPort + 'static> UreqHttpAdapter<C, X> {
    pub fn new(clock: C, cancellation: X) -> Self;
    pub fn start(&self, command: SendCommand) -> StartObservation;
    pub fn observe_start(&self, command: SendCommand) -> StartObservation;
    pub fn observe(&self, started: &StartedAttempt) -> Result<HostObservation, UnknownExecution>;
    pub fn cancel(&self, command: CancelCommand) -> Result<HostObservation, UnknownExecution>;
    pub fn close(&self, started: &StartedAttempt) -> Result<HostObservation, UnknownExecution>;
    pub fn release(
        &self,
        state: &NetworkState,
        started: &StartedAttempt,
    ) -> ErasureDecision<AttemptIdentity, (), (), (), HostRecordObservation>;
}

pub fn drive<'r, 'g, C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    first: Progress<'r, 'g>,
) -> Result<Driven<'r>, DriveFailure>;

pub struct Driven<'r> {
    pub result: ExecutionResult<'r>,
    pub retained: Vec<StartedAttempt>,
}

pub struct DriveFailure {
    pub cause: DriveCause,
    pub retained: Vec<StartedAttempt>,
}

pub enum DriveCause {
    Run(Box<RunFailure>),
    UnknownExecution(UnknownExecution),
    MissingInstruction,
    DeadlineWaitUnavailable,
}
```

アダプターの `observe_start` は `start` と同じ処理の別名です。これはコアパッケージの `observe_start` とは別の関数になります。

## port と capability

アダプターは、時刻の port と取り消しの port を受け取ります。

```rust
let adapter = UreqHttpAdapter::new(
    SystemMonotonicClock::new(ClockBasis { value: "my-basis".to_owned() }),
    CooperativeCancellation::default(),
);
```

各 port のトレイト定義は次のとおりです。

```rust
pub trait MonotonicClockPort: Send + Sync {
    fn capability(&self) -> MonotonicClockCapability;
    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure>;
    fn until(&self, _limit: &Natural) -> Option<Duration> {
        None
    }
}

pub trait CancellationPort: Send + Sync {
    fn capability(&self) -> CancellationCapability;
    fn request(&self, handle: &ExecutionHandle) -> Result<(), HostFailure>;
}
```

取り消しの `request` は handle だけを受け取ります。命令の権限と取り消し機構の権限の照合は、アダプターが `request` の前に行います。

port でパニックが発生した場合、アダプターはパニックを捕捉し、`HostRuntimeFailure` の失敗の値に変換します。

既定の port と capability の対応は次のとおりです。

| 項目 | 値 |
| --- | --- |
| 既定の clock | `SystemMonotonicClock` |
| 既定の clock の capability | `rust-system-monotonic-clock` |
| 既定の clock の basis | `rust-system-monotonic` ( 単位はミリ秒 ) |
| 既定の取り消し | `CooperativeCancellation` |
| 既定の取り消しの capability | `rust-cooperative-cancellation` |

メソッド `until` の戻り値は、期限までの待機時間を表す `Duration` です。値が `None` の場合は、clock が待機時間を返せないことを表します。なお、`until` の既定の実装は `None` を返します。

関数 `start` における検査の順序と、失敗時の原因は次のとおりです。

1. scheme の検査: `UnsupportedUriScheme`
2. コアパッケージ入力の検査: `InvalidHostConfiguration` ( 設定の clock の capability が期限の capability と異なる入力を含みます )
3. 期限 clock の検査: `DeadlineControlUnavailable`
4. 取り消し capability の検査: `InvalidHostConfiguration`
5. worker の開始: `ExecutionStartFailed`

最初に失敗した検査で、開始の失敗が返ります。このとき失敗の段階は `Start`、効果は `Unknown` です。期限 clock の検査が失敗するのは次の場合です。

- clock の capability が、期限の capability と異なる

取り消しの capability の検査は、設定の capability が port の capability と異なる場合に失敗します。設定の capability と port の capability が一致する入力のみが、worker の開始へ進みます。

## 期限、取り消し、close

アダプターは、期限到達、clock の失敗、取り消しの結果、close のいずれの契機でも、観測を追加した時点で送信中の要求を止めます。その後に worker が得た結果は破棄されます。観測の一覧は次のとおりです。

| 契機 | 観測 |
| --- | --- |
| clock が期限に達した | `DeadlineObservation` |
| clock が返した失敗の値 | `FailureObservation` に中身を載せる |
| clock のパニック | `FailureObservation` と `HostRuntimeFailure` |
| 取り消しの受理 | `CancellationObservation` |
| 取り消しの拒否 | `FailureObservation` と `CancellationRejected` |
| 取り消しの `Err` | `FailureObservation` に中身を載せる |
| close | `FailureObservation` と `HostClosed` |

関数 `observe` は期限への到達を確かめます。期限に関わる観測 ( `DeadlineObservation` と clock の失敗 ) は、一つの試行で一度だけ返るのが仕様です。

失敗の段階について、取り消しの拒否、port のエラー、close のいずれの場合も既定の段階は `Cancel` です。これに対して clock の失敗の既定の段階は `Deadline` になります。返された失敗が `Timeout` の場合は、その値が持つ段階が優先されます。効果の理由は期限が `Deadline`、取り消しが `Cancellation` です。なお、取り消しの port が拒否した場合とエラーを返した場合も、要求は止まり、応答は破棄されます。

取り消しの命令が持つ権限が取り消し機構の権限と一致した場合に限り、要求は機構へ渡されます。不一致の場合は、取り消しの拒否と同じ観測が返り、要求は止まる仕組みです。

関数 `close` は、開始の観測が返した試行を引数に取り、待ち行列の先頭の観測か、記録がない handle に対する `UnknownExecution` を返す関数です。閉じる対象は引数で渡された試行の送信中リクエストのみであり、他の試行とアダプターの動作は継続します。

関数 `cancel` と `close` は、記録の待ち行列の先頭にある観測を返します。先に届いた応答があれば、その応答が先に返るのが仕様です。要求の終わりを決めるのは、期限、取り消し、close です。

接続の確立と名前の解決は、アダプターごとに一つ持つ上限付きの機構で行います。スレッド数の上限は、worker と同じく実行環境の並行度から導きます。スレッドは `rust-network-blocking` という名前で、必要な時に上限まで作られ、アダプターの生存期間中は使い回されます。仕事は待ち行列に入り、中断の要求で観測は返ります。実行の前に中断された仕事は取り出した時に破棄され、実行中の接続や解決は戻るまでスレッドを占有します。

## 記録の寿命

アダプターは `start` ごとに記録を一つ作ります。記録が削除される契機は次のとおりです。

- `release` が `Dematerialize` を返した時
- `release` が `Retain` を返した後、コアパッケージでその試行が終端に達しており、かつ worker が終わった時

関数 `release` は記録の状態だけを進めます。要求自体は、アダプターが観測を追加した時点で止められています。要求を止めた後の観測は、止めた時に追加された一つが最後です。

記録が削除された後の handle に対する応答を以下に示します。

| 操作 | 応答 |
| --- | --- |
| `observe` | `Err(UnknownExecution)` |
| `cancel` | `Err(UnknownExecution)` |
| `close` | `Err(UnknownExecution)` |

未開始の handle に対しても、同じ応答が返ります。

関数 `drive` は処理した試行に `release` を呼ぶため、結果が確定すれば記録は削除されています。試行を自分で進める場合は、`release` が破棄を認めるまで記録が残るのが仕様です。

## 検査

ディレクトリ `packages/rust/adapter/http` で、次のコマンドを実行します。

```sh
cargo test
```

## ライセンス

MIT
