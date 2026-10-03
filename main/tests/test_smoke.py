import ast
import importlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def test_requirements_file_exists():
    assert (ROOT / "requirements.txt").is_file()


def test_entrypoint_exists():
    # Dockerfile sets FLASK_APP=run.py
    assert (ROOT / "run.py").is_file()


def test_app_package_exists():
    assert (ROOT / "app" / "__init__.py").is_file()


def test_all_python_sources_are_valid_syntax():
    errors = []
    for path in ROOT.rglob("*.py"):
        if "tests" in path.parts or "__pycache__" in path.parts:
            continue
        try:
            ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except SyntaxError as exc:
            errors.append(f"{path}: {exc}")
    assert not errors, "\n".join(errors)


def test_core_dependencies_installed():
    for module in ("flask", "flask_restx"):
        assert importlib.import_module(module) is not None
