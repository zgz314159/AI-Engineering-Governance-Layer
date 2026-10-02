"""Pluggable Continuity persistent-memory backends (v1.4).

``beads`` is an OPTIONAL backend that drives the official ``bd`` CLI as a
subprocess. The Continuity Layer must keep working when it is absent, so every
backend here is fail-soft: it never raises into the caller and never gates
``aegl resume`` / ``aegl handoff``.
"""
from __future__ import annotations

__all__ = ["beads"]
