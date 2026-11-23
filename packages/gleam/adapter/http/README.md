# Necoherence の HTTP アダプター (Gleam)

[プロジェクトの概要](../../../../README.md)

ネットワーク副作用コマンドを Erlang ターゲット上で実行する追加アダプターパッケージです。また、HTTP クライアントには Erlang の `httpc` を使用します。

コアパッケージ ( `necoherence` ) のバージョン 0.3.x と組み合わせて使用します。副作用状態の管理はコアパッケージで行い、本アダプターは呼び出し元から渡されたホストポート経由で通信を実行します。

```bash
gleam add necoherence_http_adapter
```

## 使い方

関数合成ランタイムへ渡す場合は、次のようにホストポートを作ります。

```gleam
import necoherence_http_adapter as http

pub fn ports() {
  http.host_port(http.default_ports())
}
```

返されたポートから利用できる主な要素:

- `semantic_signature_http.Binding`
- 関数合成ランタイムが使用するネットワークオーナー

### drive で試行を最後まで進める

関数 `drive` は、ランタイムの `start_composition` が返した最初の進行を受け取り、結果が確定するまで処理を進めます。戻り値は、成功なら `Ok(Driven)`、失敗なら `Error(DriveFailure)` です。

```gleam
import necoherence/network_effect as network
import necoherence/semantic_generation_runtime as runtime
import necoherence_http_adapter as http_adapter

// checked: 検査済みの合成, providers: runtime.Provider の List ( コアパッケージの手順で用意 )
pub fn run(checked, providers) {
  let assert Ok(first) =
    runtime.start_composition(checked, providers, [], network.empty_state())
  case http_adapter.drive(http_adapter.default_ports(), first) {
    Ok(http_adapter.Driven(result, retained)) -> Ok(#(result, retained))
    Error(http_adapter.DriveFailure(cause, retained)) -> Error(#(cause, retained))
  }
}
```

引数 `checked` と `providers` は、コアパッケージの手順で用意します。関数 `drive` の挙動は次のとおりです。

- 送信の指示: `http_adapter.start_with_ports` の呼び出し
- 観測の指示: 試行の queue プロセスからの通知による、観測が届くまでの待機
- コアパッケージへの反映のたび: 処理した試行の `release` の呼び出しと、記録の破棄
- 期限を持つ試行の待機: clock の `until` が返した時間で終了
- 結果の確定時: コアパッケージがまだ観測を要求する試行を `retained` に入れて返却

成功の値と失敗の値は、いずれも `retained` フィールドを持ちます。これは、`drive` が戻る時点でコアパッケージがまだ観測を要求している試行の `List` です。すでにコアパッケージ側で終端に達した試行は、worker が実行中でも `retained` には入りません。その試行の送信中だった要求は中断済みとなり、記録は worker が終わった時に削除されます。結果が確定した通常の場合は、空の `List` になります。

失敗の値に含まれる `cause` は、`DriveCause` の次の三種類です。

| cause | 意味 |
| --- | --- |
| `RunFailed` | コアパッケージが観測の反映を拒否した |
| `ExecutionGone` | 観測を待つ handle の記録が削除されていた |
| `DeadlineWaitUnavailable` | clock の `until` が空の値を返した |

原因が `DeadlineWaitUnavailable` の場合、`drive` は即座に制御を返します。このとき、記録は `retained` に入ります。

### start と observe を自分で呼ぶ

通信処理を個別に制御する低水準関数も利用できます。

- `start`: 発行されたコマンドの実行を開始
- `observe`: 次の I/O 観測結果を取得
- `cancel`: リクエストのキャンセルを要求
- `close`: 実行コンテキストのクローズ
- `release`: 取り出しを終えた試行の記録の破棄

試行の進め方を自分で制御する場合の、コアパッケージの関数とアダプターの関数の呼び出し順は次のとおりです。

1. 通信の指示の準備: `network.prepare`
2. 送信の命令の作成: `network.send_command`
3. 送信の開始: `http_adapter.start`
4. 開始の観測の反映: `network.observe_start`
5. 観測の取り出し: `http_adapter.observe`
6. 観測の反映と結果の確定: `network.observe`
7. 取り出しを終えた試行の記録の破棄: `http_adapter.release`

記録は `start` で作成され、`release` が破棄を認めるまで保持される仕組みです。取り出しを終えた試行は、次のように `release` に渡します。

```gleam
let decision = http_adapter.release(state, execution)
```

引数 `state` はコアパッケージが返した最新の状態です。また、`execution` は `start` が返した試行になります。ここで `release` が返す破棄の判定は次のとおりです。

| 判定 | 意味 |
| --- | --- |
| `Dematerialize` | 破棄を認めた。記録が削除される |
| `Retain` ( 理由は `FutureUse` ) | コアパッケージがその試行をまだ待っている |
| `Retain` ( 理由は `OutstandingEffect` ) | worker がまだ動いている |

判定結果が `Retain` だった場合は、状態が進んだ後で同じ試行に対して `release` を呼び直します。関数 `drive` を使う場合は、この呼び出しを `drive` が自動で行います。

### 公開 API

```gleam
pub fn default_ports() -> AdapterPorts
pub fn start(command: effect.SendCommand) -> StartResult
pub fn start_with_ports(command: effect.SendCommand, ports: AdapterPorts) -> StartResult
pub fn observe(execution: Execution) -> Result(effect.HostObservation, UnknownExecution)
pub fn cancel(execution: Execution, command: effect.CancelCommand) -> Result(effect.HostObservation, UnknownExecution)
pub fn close(execution: Execution) -> Result(effect.HostObservation, UnknownExecution)
pub fn release(state: effect.NetworkState, execution: Execution) -> effect.HostRecordDecision
pub fn drive(ports: AdapterPorts, first: runtime.Progress) -> Result(Driven, DriveFailure)
pub fn handle(execution: Execution) -> effect.ExecutionHandle
pub fn host_port(ports: AdapterPorts) -> host.AdapterPorts

pub type StartResult {
  Started(Execution)
  StartFailed(effect.NetworkHostFailure, effect.EffectStatus)
}

pub type Driven {
  Driven(result: runtime.ExecutionResult, retained: List(Execution))
}

pub type DriveCause {
  RunFailed(runtime.RunFailure)
  ExecutionGone(effect.ExecutionHandle)
  DeadlineWaitUnavailable(effect.ExecutionHandle)
}

pub type DriveFailure {
  DriveFailure(cause: DriveCause, retained: List(Execution))
}

pub type UnknownExecution {
  UnknownExecution(handle: effect.ExecutionHandle)
}
```

## port と capability

既定の port は `default_ports` が返します。各関数での port の扱い方を以下に示します。

- `start`: 既定の port を使う開始
- `start_with_ports`: port を渡す開始
- `drive`: port を渡す進行
- `host_port`: port を渡すホストポートの作成

```gleam
let ports = http_adapter.AdapterPorts(clock: my_clock, cancellation: my_cancellation)
```

各 port の型定義は次のとおりです。

```gleam
pub type MonotonicClockPort {
  MonotonicClockPort(
    capability: effect.MonotonicClockCapability,
    observe: fn() -> Result(effect.MonotonicClockObservation, effect.HostFailure),
    until: fn(Int) -> Option(Int),
  )
}

pub type CancellationPort {
  CancellationPort(
    capability: effect.CancellationCapability,
    request: fn(effect.ExecutionHandle) -> Result(Nil, effect.HostFailure),
  )
}

pub type AdapterPorts {
  AdapterPorts(clock: MonotonicClockPort, cancellation: CancellationPort)
}
```

既定の port と capability の対応は次のとおりです。

| 項目 | 値 |
| --- | --- |
| 既定の clock の capability | `gleam-system-monotonic-clock` |
| 既定の clock の basis | `system` ( 単位はミリ秒 ) |
| 既定の取り消しの capability | `gleam-cooperative-cancellation` |
| 既定の取り消しの request | 常に `Ok(Nil)` |

時刻の port の `observe` は、時計の観測か、host の失敗の値を返します。取り消しの port の `request` は、試行の handle だけを受け取り、成功か、host の失敗の値を返します。これら host の失敗の値の型は、コアパッケージの `effect.HostFailure` です。なお、取り消しの capability の照合は、アダプターが port を呼ぶ前に行います。

時刻の port が失敗の値を返した時は、公開の `observe` の中でも、要求を送る worker の中の最初の観測でも、アダプターは次の値を持つ失敗の観測を一度だけ追加します。時刻の port が例外を出した時の観測は、原因が `HostRuntimeFailure` である点を除いて同じです。追加した後の `observe` が時刻の port を呼ぶ回数は 0 回です。

- 段階: `DeadlineStage` ( 原因が時間切れの場合は、その原因が持つ段階 )
- 原因: port が返した失敗の値。例外の場合は `HostRuntimeFailure`
- 作用が不明になった理由: `HostFailure`

関数 `until` は、期限までの待機時間をミリ秒の `Some` で返します。値が `None` の場合は、clock が待機時間を返せないことを表します。

関数 `start_with_ports` における検査の順序と、失敗時の原因は次のとおりです。

1. scheme の検査: `UnsupportedUriScheme`
2. コアパッケージ入力の検査: `InvalidHostConfiguration` ( 設定の clock の capability が期限の capability と異なる入力を含みます )
3. 期限 clock の検査: `DeadlineControlUnavailable`
4. 取り消し capability の検査: `InvalidHostConfiguration`
5. 要求の組み立て: `UnsupportedUriScheme` か `InvalidHostConfiguration`
6. worker の開始: `ExecutionStartFailed`

最初に失敗した検査で `StartFailed` が返ります。このとき失敗の段階は `Start`、効果は `Unknown` です。期限 clock の検査が失敗するのは次の場合です。

- clock の capability が、期限の capability と異なる

取り消しの capability の検査は、設定の capability が port の capability と異なる場合に失敗します。設定の capability と port の capability が一致する入力のみが、要求の組み立てへ進みます。ここで要求の組み立てとは、対象の URI とメソッドを解釈する処理です。また、worker の開始の失敗は、実行環境 ( `inets` と `ssl` ) の起動失敗を指します。

## 期限、取り消し、close

アダプターは、期限到達、clock の失敗、取り消しの結果、close のいずれの契機でも、観測を追加した時点で送信中の要求を止めます。観測の追加と、worker の結果を以後破棄する印を立てることと、worker への中断の通知は、queue プロセスが一つの message の処理として行います。その後に worker が得た結果は破棄されます。観測の一覧は次のとおりです。

| 契機 | 観測 |
| --- | --- |
| clock が期限に達した | `DeadlineObservation` |
| clock の失敗の値 | `FailureObservation` に port が返した原因を載せる |
| clock の例外 | `FailureObservation` と `HostRuntimeFailure` |
| 取り消しの受理 | `CancellationObservation` |
| 取り消しの拒否 ( 権限の不一致か、port の拒否の値 ) | `FailureObservation` と `CancellationRejected` |
| 取り消しの port の失敗の値 | `FailureObservation` に port が返した原因を載せる |
| 取り消しの port の例外 | `FailureObservation` と `HostRuntimeFailure` |
| close | `FailureObservation` と `HostClosed` |

関数 `observe` は期限への到達を確かめます。期限に関わる観測 ( `DeadlineObservation` と clock の失敗 ) は、一つの試行で一度だけ返るのが仕様です。

失敗の段階について、取り消しの拒否、失敗の値、例外、close のいずれの場合も段階は `Cancel` です。これに対して clock の失敗の段階は `DeadlineStage` になります。効果の理由は期限が `DeadlineReason`、取り消しが `CancellationReason` です。なお、取り消しの port が拒否した場合、失敗の値を返した場合、例外を出した場合も、要求は止まり、応答は破棄されます。

関数 `close` は、開始時に返された試行を引数に取り、待ち行列の先頭の観測か、未登録の handle に対する `UnknownExecution` を返します。閉じる対象は引数で渡された試行の送信中リクエストのみであり、他の試行とアダプターの動作は継続します。

関数 `cancel` は、記録と命令の試行および handle が一致した場合に限り、命令を受け付けます。不一致の場合は、未登録の handle と同じ `UnknownExecution` が返ります。命令が持つ権限が取り消し機構の権限と一致した場合に限り要求は機構へ渡され、不一致の場合と設定の取り消し権限が空の場合は、取り消しの拒否の観測が返って要求が止まります。なお、`cancel` と `close` は、記録の待ち行列の先頭にある観測を返します。先に届いた応答があれば、その応答が先に返る仕組みです。

要求の終わりを決めるのは、期限、取り消し、close です。要求の中断には `cancel_request` を呼び出し、また `httpc` の要求の待機時間は無期限に設定しています。

## 記録の寿命

本パッケージ ( Gleam ) の記録は、試行ごとの queue プロセスであり、`start` ごとに記録を一つ作ります。記録が削除される契機は次のとおりです。

- `release` が `Dematerialize` を返した時
- `release` が `Retain` を返した後、コアパッケージでその試行が終端に達しており、かつ worker が終わった時

関数 `release` は記録の状態だけを進めます。要求自体は、アダプターが観測を追加した時点で止められています。要求を止めた後の観測は、止めた時に追加された一つが最後です。

記録が削除された後の handle に対する応答を以下に示します。

```gleam
http_adapter.observe(execution) // Error(UnknownExecution(handle))
http_adapter.cancel(execution, command) // Error(UnknownExecution(handle))
http_adapter.close(execution) // Error(UnknownExecution(handle))
```

進行の中で開始した試行以外の handle を観測する場合は、`ExecutionGone` が返ります。

関数 `drive` は処理した試行に `release` を呼ぶため、結果が確定すれば記録は削除されています。試行を自分で進める場合は、`release` が破棄を認めるまで記録が残るのが仕様です。

## 検査

ディレクトリ `packages/gleam/adapter/http` で、次のコマンドを実行してフォーマット検査とビルドを行えます。

```bash
gleam format --check
gleam build --warnings-as-errors
```

## ライセンス

[MIT License](LICENSE)
