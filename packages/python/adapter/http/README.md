# Necoherence の HTTP アダプター (Python)

[プロジェクトの概要](../../../../README.md)

ネットワーク副作用コマンドを Python で実行する追加アダプターパッケージです。また、HTTP クライアントには標準ライブラリを使用し、実行には Python 3.14 以降および `necoherence==0.3.0` が必要です。コアパッケージ ( `necoherence` ) は副作用状態を記録し、本アダプターから渡された I/O 観測結果を受け取って状態機械を更新します。

```bash
python -m pip install necoherence-http-adapter==0.3.0
```

## 使い方

### drive で試行を最後まで進める

関数 `drive` は、コアパッケージの `se.start` が返した最初の進行を受け取り、結果が確定するまで処理を進めます。戻り値は、成功なら `Driven`、失敗なら `DriveFailure` です。

```python
from necoherence import network_effect as ne
from necoherence import semantic_execution as se
from necoherence_http_adapter import (
    DriveFailure,
    Driven,
    HttpHostAdapter,
    SystemMonotonicClock,
    drive,
)

# admitted: se.AdmittedComposition, providers: se.Provider の tuple ( コアパッケージの手順で用意 )
adapter = HttpHostAdapter(clock=SystemMonotonicClock())
first = se.start(admitted, providers, (), ne.empty_network_state())
assert isinstance(first, se.Progress)
driven = drive(adapter, first)
if isinstance(driven, Driven):
    result = driven.result
    retained = driven.retained
else:
    cause = driven.cause
    retained = driven.retained
```

引数 `admitted` と `providers` は、コアパッケージの手順で用意します。関数 `drive` の挙動は次のとおりです。

- 送信の指示: `adapter.start` の呼び出し
- 観測の指示: worker からの通知による、観測が届くまでの待機
- コアパッケージへの反映のたび: 処理した試行の `release` の呼び出しと、記録の破棄
- 期限を持つ試行の待機: clock の `until` が返した時間で終了
- 結果の確定時: コアパッケージがまだ観測を要求する試行を `retained` に入れて返却

成功の戻り値と失敗の戻り値は、いずれも `retained` フィールドを持ちます。これは、`drive` が戻る時点でコアパッケージがまだ観測を要求している試行の `tuple` です。すでにコアパッケージ側で終端に達した試行は、worker が実行中でも `retained` には入りません。その試行の送信中だった要求は中断済みとなり、記録は worker が終わった時に削除されます。なお、名前解決の途中にいる worker は、解決処理が完了するまで動作を続けます。結果が確定した通常の場合は空の `tuple` になります。

失敗の戻り値に含まれる `cause` は次の三種類です。

| cause | 意味 |
| --- | --- |
| `se.RunFailure` | コアパッケージが観測の反映を拒否した |
| `UnknownExecution` | 観測を待つ handle の記録が削除されていた |
| `DeadlineWaitUnavailable` | clock の `until` が空の値を返した |

原因が `DeadlineWaitUnavailable` の場合、`drive` は即座に制御を返します。このとき、記録は `retained` に入ります。

### start と observe を自分で呼ぶ

試行の進め方を自分で制御する場合、コアパッケージの関数とアダプターの関数は次の順に呼び出します。

1. 通信の指示の準備: `ne.prepare`
2. 送信の命令の作成: `ne.send_command`
3. 送信の開始: `adapter.start`
4. 開始の観測の反映: `ne.observe_start`
5. 観測の取り出し: `adapter.observe`
6. 観測の反映と結果の確定: `ne.observe`
7. 取り出しを終えた試行の記録の破棄: `adapter.release`

記録は `start` で作成され、`release` が破棄を認めるまで保持されます。取り出しを終えた試行は、次のように `release` に渡します。

```python
decision = adapter.release(state, started)
```

引数 `state` はコアパッケージが返した最新の状態であり、`started` は開始の観測を反映した結果が持つ試行です。ここで `release` が返す破棄の判定は次のとおりです。

| 判定 | 意味 |
| --- | --- |
| `Dematerialize` | 破棄を認めた。記録が削除される |
| `Retain` ( 理由は `FutureUse` ) | コアパッケージがその試行をまだ待っている |
| `Retain` ( 理由は `OutstandingEffect` ) | worker がまだ動いている |

判定結果が `Retain` だった場合は、状態が進んだ後で同じ試行に対して `release` を呼び直します。関数 `drive` を使う場合は、この呼び出しを `drive` が自動で行います。

### 公開 API

```python
class HttpHostAdapter:
    def __init__(
        self,
        clock: MonotonicClockPort | None = None,
        cancellation: CancellationPort | None = None,
    ) -> None: ...
    def start(self, command: ne.SendCommand) -> ne.Started | ne.StartFailed: ...
    def observe(self, started: ne.StartedAttempt) -> ne.HostObservation | UnknownExecution: ...
    def cancel(self, command: ne.CancelCommand) -> ne.HostObservation | UnknownExecution: ...
    def close(self, started: ne.StartedAttempt) -> ne.HostObservation | UnknownExecution: ...
    def release(
        self,
        state: ne.NetworkState,
        started: ne.StartedAttempt,
    ) -> ne.ErasureDecision[ne.AttemptIdentity, None, None, None, ne.HostRecordObservation]: ...

def drive(adapter: HttpHostAdapter, first: se.Progress) -> Driven | DriveFailure: ...
```

## port と capability

アダプターは、時刻の port と取り消しの port を受け取ります。

```python
adapter = HttpHostAdapter(
    clock=SystemMonotonicClock(),
    cancellation=EventCancellationPort(),
)
```

各 port のプロトコル定義は次のとおりです。

```python
class MonotonicClockPort(Protocol):
    def capability(self) -> ne.MonotonicClockCapability: ...
    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure: ...

class WaitingMonotonicClockPort(MonotonicClockPort, Protocol):
    def until(self, limit: int) -> float | None: ...

class CancellationPort(Protocol):
    def capability(self) -> ne.CancellationCapability: ...
    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None: ...
```

既定の port と capability の対応を以下に示します。

| 項目 | 値 |
| --- | --- |
| clock の既定 | 空 |
| 標準の clock | `SystemMonotonicClock()` |
| 標準の clock の capability | `python-system-monotonic-clock` |
| 標準の clock の basis | `python-monotonic` ( 単位はナノ秒 ) |
| 取り消しの既定 | `EventCancellationPort()` |
| 取り消しの capability | `python-event-cancellation` |

これら二つの port は、失敗を戻り値で表します。戻り値の型は次のとおりです。

- 時刻の `observe`: 時計の観測か、コアパッケージの `HostFailure` の値
- 取り消しの `request`: 引数は handle だけ。戻り値は、成功なら `None`、失敗ならコアパッケージの失敗の値

アダプターは、返された失敗の値を、呼び出した操作の段階に対応する失敗の観測に変換します。返された値が `Timeout` の場合の段階は、その `Timeout` 自身が持つ段階になります。

時刻の port が例外を発生させた場合、アダプターは例外を捕捉し、次の値を持つ失敗の観測を一度だけ追加します。追加した後の `observe` は、すでに追加済みのその観測をそのまま返す仕組みです。

- 段階: `Deadline`
- 原因: `HostRuntimeFailure`
- 作用が不明になった理由: `HostFailure`

メソッド `until` の戻り値は、期限までの待機時間を秒単位で表す `float` です。値が `None` の場合は、clock が待機時間を返せないことを表します。

なお、取り消しの port は、任意で次の二つのメソッドを持ちます。

- `register`: 試行の開始時にアダプターが呼ぶ
- `unregister`: 記録の破棄時にアダプターが呼ぶ

関数 `start` における検査の順序と、失敗時の原因は次のとおりです。

1. scheme の検査: `UnsupportedUriScheme`
2. コアパッケージ入力の検査: `InvalidHostConfiguration` ( 設定の clock の capability が期限の capability と異なる入力を含みます )
3. 期限 clock の検査: `DeadlineControlUnavailable`
4. 取り消し capability の検査: `InvalidHostConfiguration`
5. worker の開始: `ExecutionStartFailed`

最初に失敗した検査で、開始の失敗が返ります。このとき失敗の段階は `Start`、効果は `Unknown` です。期限 clock の検査が失敗するのは次の場合です。

- 期限があり、clock が空
- clock の capability が、期限の capability と異なる

取り消しの capability の検査は、設定の capability が port の capability と異なる場合に失敗します。設定の capability と port の capability が一致する入力のみが、worker の開始へ進みます。

## 期限、取り消し、close

アダプターは、期限到達、clock の失敗、取り消しの結果、close のいずれの契機でも、観測を追加した時点で送信中の要求を止めます。その後に worker が得た結果は破棄されます。観測の一覧は次のとおりです。

| 契機 | 観測 |
| --- | --- |
| clock が期限に達した | `DeadlineObservation` |
| clock の例外 | `FailureObservation` と `HostRuntimeFailure` |
| clock が返した失敗の値 | `FailureObservation` と、返された `HostFailure` |
| 取り消しの受理 | `CancellationObservation` |
| 取り消しの拒否 | `FailureObservation` と `CancellationRejected` |
| 取り消しの port が返した他の失敗の値 | `FailureObservation` と、返された `HostFailure` |
| 取り消しの port の例外 | `FailureObservation` と `HostRuntimeFailure` |
| close | `FailureObservation` と `HostClosed` |

関数 `observe` は期限への到達を確かめます。期限に関わる観測 ( `DeadlineObservation` と clock の例外 ) は、一つの試行で一度だけ返るのが仕様です。

失敗の段階について、取り消しの拒否、例外、close のいずれの場合も段階は `Cancel` です。これに対して clock の例外の段階は `Deadline` になります。効果の理由は期限が `Deadline`、取り消しが `Cancellation` です。なお、取り消しの port が拒否した場合と例外を出した場合も、要求は止まり、応答は破棄されます。

取り消しの命令が持つ権限が取り消し機構の権限と一致した場合に限り、要求は機構へ渡されます。不一致の場合は、取り消しの拒否と同じ観測が返り、要求は止まる仕組みです。

関数 `close` は、開始済みの試行を 1 件受け取り、その試行の要求を止めて、閉じた観測を追加し、待ち行列の先頭の観測を返します。閉じる範囲は、引数で渡された試行のみに限定されます。

関数 `cancel` と `close` は、記録の待ち行列の先頭にある観測を返します。先に届いた応答があれば、その応答が先に返るのが仕様です。要求の終わりを決めるのは、期限、取り消し、close です。

接続の確立は、中断の要求で終わります。一方で名前の解決は、解決処理が戻るまで worker が残り、観測は中断の時点で返ります。

## 記録の寿命

アダプターは `start` ごとに記録を一つ作ります。記録が削除される契機は次のとおりです。

- `release` が `Dematerialize` を返した時
- `release` が `Retain` を返した後、コアパッケージでその試行が終端に達しており、かつ worker が終わった時

関数 `release` は記録の状態だけを進めます。要求自体は、アダプターが観測を追加した時点で止められています。もし `release` が `Retain` を返し、コアパッケージ側でその試行が終端に達している時は、worker が終わった時に記録が削除されます。要求を止めた後の観測は、止めた時に追加された一つが最後です。

記録が削除された後の handle に対する応答を以下に示します。

| 操作 | 応答 |
| --- | --- |
| `observe` | `UnknownExecution` |
| `cancel` | `UnknownExecution` |
| `close` | `UnknownExecution` |

未開始の handle に対しても、同じ応答が返ります。

関数 `drive` は処理した試行に `release` を呼ぶため、結果が確定すれば記録は削除されています。試行を自分で進める場合は、`release` が破棄を認めるまで記録が残るのが仕様です。

## 検査

本ディレクトリでテストやビルドを行う場合の、コアパッケージおよび開発用依存関係のインストールと実行手順は次のとおりです。

```bash
python -m pip install .. '.[dev]'
python -m pytest -q
python -m mypy src tests
python -m build
```

## ライセンス

[MIT License](LICENSE)
