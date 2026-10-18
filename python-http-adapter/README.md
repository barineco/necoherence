# Necoherence HTTP adapter for Python

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This optional MIT package executes Necoherence network-effect commands using the Python standard library.
It requires Python 3.12 or later and `necoherence==0.2.1`.
The core package contains the network-effect ledger and accepts caller-supplied observations.

Install this package when the application executes HTTP requests:

```bash
python -m pip install necoherence-http-adapter==0.2.1
```

Import the adapter explicitly:

```python
from necoherence_http_adapter import HttpHostAdapter

adapter = HttpHostAdapter()
```

From this source directory, install the core and test dependencies before running the tests:

```bash
python -m pip install ../python '.[dev]'
python -m pytest -q
python -m mypy src tests
python -m build
```

[MIT License](LICENSE)
