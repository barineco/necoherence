# Python 向けの Necoherence の HTTP アダプター

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

この任意のパッケージは、Necoherence のネットワーク副作用のコマンドを、Python の標準ライブラリを使って実行します。ライセンスは MIT です。
Python 3.12 以降と `necoherence==0.2.1` が必要です。
核のパッケージが持つのは、ネットワーク副作用の台帳と、呼び出し側が渡す観測を受け取る仕組みです。

アプリケーションが HTTP リクエストを実行する場合に、このパッケージを導入します。

```bash
python -m pip install necoherence-http-adapter==0.2.1
```

アダプターの読み込みは、次のように明示して書く形です。

```python
from necoherence_http_adapter import HttpHostAdapter

adapter = HttpHostAdapter()
```

このソースのディレクトリでは、核とテストの依存を導入してから、テストを実行します。

```bash
python -m pip install ../python '.[dev]'
python -m pytest -q
python -m mypy src tests
python -m build
```

[MIT ライセンス](LICENSE)
