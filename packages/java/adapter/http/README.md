# Necoherence の HTTP アダプター (Java)

[プロジェクトの概要](../../../../README.md)

ネットワーク副作用コマンドを Java で実行する追加アダプターパッケージです。また、HTTP クライアントには標準の `java.net.http.HttpClient` を使用します。

必要な環境:

- Java 21
- クラスパス上のコアパッケージ `necoherence-0.3.0.jar`

公開先の Maven 座標は `io.github.barineco:necoherence-http-adapter:0.3.0` であり、同バージョンのコアパッケージに依存します。

## 使い方

アプリケーションではクラスパスに両 JAR を追加し、`necoherence.network.JavaHttpAdapter` をインスタンス化して使用します。

### drive で試行を最後まで進める

関数 `drive` は、コアパッケージの `SemanticExecution.start` が返した最初の進行を受け取り、結果が確定するまで処理を進めます。戻り値は、成功なら `DriveResult.Done`、失敗なら `DriveResult.Failed` です。

```java
import necoherence.composition.SemanticExecution;
import necoherence.network.JavaHttpAdapter;
import necoherence.network.NetworkEffect;

// admitted: SemanticExecution.AdmittedComposition, providers: SemanticExecution.Provider の List,
// arguments: SemanticExecution.ArgumentValue の List ( コアパッケージの手順で用意 )
// drive は InterruptedException を投げるので、呼び出し側のメソッドが throws を宣言する
try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
    SemanticExecution.RunResult run = SemanticExecution.start(
            admitted, providers, arguments, NetworkEffect.NetworkState.empty());
    SemanticExecution.Progress first = ((SemanticExecution.Progressed) run).progress();
    JavaHttpAdapter.DriveResult driven = JavaHttpAdapter.drive(adapter, first);
    if (driven instanceof JavaHttpAdapter.DriveResult.Done done) {
        SemanticExecution.ExecutionResult result = done.value().result();
        var retained = done.value().retained();
    } else if (driven instanceof JavaHttpAdapter.DriveResult.Failed failed) {
        JavaHttpAdapter.DriveCause cause = failed.failure().cause();
        var retained = failed.failure().retained();
    }
}
```

引数 `admitted` と `providers` は、コアパッケージの手順で用意します。関数 `drive` の挙動は次のとおりです。

- 送信の指示: `adapter.start` の呼び出し
- 観測の指示: worker からの通知による、観測が届くまでの待機
- コアパッケージへの反映のたび: 処理した試行の `release` の呼び出しと、記録の破棄
- 期限を持つ試行の待機: clock の `until` が返した時間で終了
- 結果の確定時: コアパッケージがまだ観測を要求する試行を `retained` に入れて返却

成功の値と失敗の値は、いずれも `retained` フィールドを持ちます。これは、`drive` が戻る時点でコアパッケージがまだ観測を要求している試行の `List` です。すでにコアパッケージ側で終端に達した試行は、worker が実行中でも `retained` には入りません。その試行の送信中だった要求は中断済みとなり、記録は worker が終わった時に削除されます。結果が確定した通常の場合は、空の `List` になります。

失敗の値に含まれる `cause` は、`DriveCause` の次の三種類です。

| cause | 意味 |
| --- | --- |
| `Run` | コアパッケージが観測の反映を拒否した |
| `Unknown` | 観測を待つ handle の記録が削除されていた |
| `DeadlineWaitUnavailable` | clock の `until` が空の値を返した |

原因が `DeadlineWaitUnavailable` の場合、`drive` は即座に制御を返します。このとき、記録は `retained` に入ります。

### start と observe を自分で呼ぶ

試行の進め方を自分で制御する場合、コアパッケージの関数とアダプターの関数は次の順に呼び出します。

1. 通信の指示の準備: `NetworkEffect.prepare`
2. 送信の命令の作成: `NetworkEffect.sendCommand`
3. 送信の開始: `adapter.start`
4. 開始の観測の反映: `NetworkEffect.observeStart`
5. 観測の取り出し: `adapter.observe`
6. 観測の反映と結果の確定: `NetworkEffect.observe`
7. 取り出しを終えた試行の記録の破棄: `adapter.release`

記録は `start` で作成され、`release` が破棄を認めるまで保持されます。取り出しを終えた試行は、次のように `release` に渡します。

```java
var decision = adapter.release(state, started);
```

引数 `state` はコアパッケージが返した最新の状態であり、`started` は開始の観測を反映した結果が持つ試行です。ここで `release` が返す破棄の判定は次のとおりです。

| 判定 | 意味 |
| --- | --- |
| `Dematerialize` | 破棄を認めた。記録が削除される |
| `Retain` ( 理由は `FutureUse` ) | コアパッケージがその試行をまだ待っている |
| `Retain` ( 理由は `OutstandingEffect` ) | worker がまだ動いている |

判定結果が `Retain` だった場合は、状態が進んだ後で同じ試行に対して `release` を呼び直します。関数 `drive` を使う場合は、この呼び出しを `drive` が自動で行います。

### 公開 API

```java
public final class JavaHttpAdapter implements AutoCloseable {
    public JavaHttpAdapter();
    public StartResult start(NetworkEffect.SendCommand command);
    public PollResult observe(NetworkEffect.StartedAttempt started);
    public PollResult cancel(NetworkEffect.CancelCommand command);
    public ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void,
            NetworkEffect.HostRecordObservation> release(
            NetworkEffect.NetworkState state, NetworkEffect.StartedAttempt started);
    public void close();
    public static DriveResult drive(JavaHttpAdapter adapter, SemanticExecution.Progress first)
            throws InterruptedException;
}

public record StartResult(
        NetworkEffect.StartObservation observation,
        Optional<NetworkEffect.StartedAttempt> started) {}

public sealed interface PollResult {
    record Pending(NetworkEffect.HostObservation observation) implements PollResult {}
    record Delivered(NetworkEffect.HostObservation observation) implements PollResult {}
    record Closed(NetworkEffect.HostObservation observation) implements PollResult {}
}

public record Driven(
        SemanticExecution.ExecutionResult result,
        List<NetworkEffect.StartedAttempt> retained) {}

public sealed interface DriveCause {
    record Run(SemanticExecution.RunFailure failure) implements DriveCause {}
    record Unknown(PollResult.Closed closed) implements DriveCause {}
    record DeadlineWaitUnavailable(NetworkEffect.StartedAttempt started) implements DriveCause {}
}

public record DriveFailure(DriveCause cause, List<NetworkEffect.StartedAttempt> retained) {}

public sealed interface DriveResult {
    record Done(Driven value) implements DriveResult {}
    record Failed(DriveFailure failure) implements DriveResult {}
}
```

メソッド `close` は無引数かつ `void` のメソッドであり、アダプターが保持している全ての記録を閉じます。

## port と capability

アダプターの作成には、既定の port を使う `new JavaHttpAdapter()` を呼び出します。各 port を受け取るコンストラクタは `necoherence.network` の内部宣言であり、そのインターフェースは次のとおりです。

```java
interface MonotonicClockPort {
    NetworkEffect.MonotonicClockCapability capability();
    Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe();
    default Optional<Duration> until(Nat limit) { return Optional.empty(); }
}

interface CancellationPort {
    NetworkEffect.CancellationCapability capability();
    Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle);
}
```

戻り値は `neco.quotient.Result` の値です。成功時は `Accepted`、失敗時は `Rejected` が値を保持します。

- 失敗の値の型: コアパッケージの `NetworkEffect.HostFailure`
- 取り消しの `request` の引数: handle だけ
- 取り消しの成功の値: `SemanticValues.Unit.VALUE`

取り消しの命令が持つ capability と port の capability の照合は、アダプターが `request` を呼ぶ前に行います。

既定の port と capability の対応は次のとおりです。

| 項目 | 値 |
| --- | --- |
| 既定の clock | 標準の clock |
| 既定の clock の capability | `java-system-monotonic-clock` |
| 既定の clock の basis | `system-nano` ( 単位はナノ秒 ) |
| 既定の取り消し | 協調的な取り消し ( 常に受理 ) |
| 既定の取り消しの capability | `java-cooperative-cancellation` |

時刻の port が失敗の値を返した時、アダプターはその失敗の値を原因とする `FailureObservation` を一度だけ追加し、段階は `Deadline` とします。同様に、取り消しの port が失敗の値を返した時も、その失敗の値を原因とし、段階を `Cancel` とする `FailureObservation` を追加します。なお、失敗の値が `Timeout` の場合の段階は、その値が持つ段階になります。

時刻の port が例外を出した時、アダプターは例外を捕捉し、次の値を持つ失敗の観測を一度だけ追加します。追加した後の `observe` が時刻の port を呼ぶ回数は 0 回です。

- 段階: `Deadline`
- 原因: `HostRuntimeFailure`
- 作用が不明になった理由: `HostFailure`

メソッド `until` の戻り値は、期限までの待機時間を表す `Optional<Duration>` です。空の `Optional` は、clock が待機時間を返せないことを表します。なお、`until` の既定の実装は、空の `Optional` を返します。

メソッド `start` における検査の順序と、失敗時の原因は次のとおりです。

1. アダプターの close 済みの検査: `HostClosed`
2. scheme の検査: `UnsupportedUriScheme`
3. コアパッケージ入力の検査: `InvalidHostConfiguration` ( 設定の clock の capability が期限の capability と異なる入力を含みます )
4. 期限 clock の検査: `DeadlineControlUnavailable`
5. 取り消し capability の検査: `InvalidHostConfiguration`
6. worker の開始: `ExecutionStartFailed`

最初に失敗した検査で、開始の失敗が返ります。このとき失敗の段階は `Start`、効果は `Unknown` です。期限 clock の検査が失敗するのは次の場合です。

- clock の capability が、期限の capability と異なる

取り消しの capability の検査は、設定の capability が port の capability と異なる場合に失敗します。設定の capability と port の capability が一致する入力のみが、worker の開始へ進みます。

## 期限、取り消し、close

アダプターは、期限到達、clock の失敗、取り消しの結果、close のいずれの契機でも、観測を追加した時点で送信中の要求を止めます。期限と取り消しの観測は、`observe` と `cancel` の戻り値として返ります。これに対して公開の `close` は値を返さず、観測は記録のキューに追加されます。また、close 後の `start` は `HostClosed` の開始失敗になり、その後に worker が得た結果は破棄されます。

観測の一覧は次のとおりです。

| 契機 | 観測 |
| --- | --- |
| clock が期限に達した | `DeadlineObservation` |
| clock の失敗の値 | `FailureObservation` と、その失敗の値 |
| clock の例外 | `FailureObservation` と `HostRuntimeFailure` |
| 取り消しの受理 | `CancellationObservation` |
| 取り消しの失敗の値 | `FailureObservation` と、その失敗の値 ( 拒否は `CancellationRejected` ) |
| 取り消しの命令の capability の不一致 | `FailureObservation` と `CancellationRejected` |
| 取り消しの port の例外 | `FailureObservation` と `HostRuntimeFailure` |
| アダプターの close | `FailureObservation` と `HostClosed` |

メソッド `observe` は期限への到達を確かめます。期限に関わる観測 ( `DeadlineObservation` と clock の例外 ) は、一つの試行で一度だけ返るのが仕様です。

失敗の段階について、取り消しの拒否、例外、close のいずれの場合も段階は `Cancel` です。これに対して clock の例外の段階は `Deadline` になります。効果の理由は期限が `Deadline`、取り消しが `Cancellation` です。なお、取り消しの port が拒否した場合と例外を出した場合も、要求は止まり、応答は破棄されます。

アダプターの `close` は、動いている試行ごとに `HostClosed` の観測を追加し、要求を中断します。また、取り消しの命令が持つ権限が取り消し機構の権限と一致した場合に限り、要求は機構へ渡されます。不一致の場合は取り消しの拒否と同じ観測が返り、要求が止まる仕組みです。ここで `cancel` は、記録の待ち行列の先頭の観測を返します。先に届いた応答があれば、その応答が先に返ります。

要求の終わりを決めるのは、期限、取り消し、close です。要求を中断する際は、`HttpClient` の送信中の交換を取り消す仕組みです。

## 記録の寿命

アダプターは `start` ごとに記録を一つ作ります。記録が削除される契機は次のとおりです。

- `release` が `Dematerialize` を返した時
- `release` が `Retain` を返した後、コアパッケージでその試行が終端に達しており、かつ worker が終わった時

メソッド `release` は記録の状態だけを進めます。要求自体は、アダプターが観測を追加した時点で止められています。要求を止めた後の観測は、止めた時に追加された一つが最後です。

記録が削除された後の handle に対する応答を以下に示します。

```java
adapter.observe(started); // PollResult.Closed
adapter.cancel(command);  // PollResult.Closed
```

未開始の handle に対しても、同じ応答が返ります。

関数 `drive` は処理した試行に `release` を呼ぶため、結果が確定すれば記録は削除されています。試行を自分で進める場合は、`release` が破棄を認めるまで記録が残るのが仕様です。

## テスト

テストを実行する際は、先にリポジトリのルートで `packages/java/build-maven.sh build` を実行し、コアパッケージとアダプターの JAR をビルドします。続けて `packages/java/adapter/http/` ディレクトリで次のコマンドを実行します。

```sh
mkdir -p build/test-classes
core=../build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar
adapter=../build/maven/io/github/barineco/necoherence-http-adapter/0.3.0/necoherence-http-adapter-0.3.0.jar
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac --release 21 -cp "$core:$adapter" -d build/test-classes
for test in NetworkEffectHttpSmoke NetworkEffectProgressionSmoke; do
  java -cp "$core:$adapter:build/test-classes" "necoherence.network.$test"
done
```

## ライセンス

[MIT License](LICENSE)
