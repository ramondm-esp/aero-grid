# SPDX-License-Identifier: GPL-2.0-only
"""Load hyphenated tool scripts without sharing mutable module state."""
import importlib.util
from pathlib import Path


def load_tool(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
