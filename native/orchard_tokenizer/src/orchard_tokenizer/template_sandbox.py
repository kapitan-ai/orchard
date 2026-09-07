from __future__ import annotations

from collections import Counter
from collections.abc import ItemsView, KeysView, Mapping, Sequence, ValuesView
from functools import wraps
from typing import Any

from jinja2 import Undefined, nodes
from jinja2.runtime import LoopContext, Macro, Namespace
from jinja2.sandbox import ImmutableSandboxedEnvironment
from jinja2.visitor import NodeTransformer

from orchard_tokenizer.safe_segmented import (
    MarkerPair,
    _MarkerString,
    _TaggedString,
    reject_marker_transform,
    walk_rendered,
)

_OBSERVATION_METHODS = frozenset(
    {
        "startswith",
        "endswith",
        "find",
        "rfind",
        "index",
        "rindex",
        "count",
        "isalnum",
        "isalpha",
        "isascii",
        "isdecimal",
        "isdigit",
        "isidentifier",
        "islower",
        "isnumeric",
        "isprintable",
        "isspace",
        "istitle",
        "isupper",
    }
)
_STRUCTURAL_FILTERS = frozenset(
    {
        "items",
        "list",
        "first",
        "last",
        "reverse",
        "random",
        "sort",
        "unique",
        "map",
        "select",
        "reject",
        "selectattr",
        "rejectattr",
        "batch",
        "slice",
        "groupby",
        "dictsort",
    }
)
_OBSERVATION_FILTERS = frozenset({"length", "count"})
_SERIALIZING_FILTERS = frozenset({"tojson", "string", "safe"})
_LITERAL_REPLACEMENTS = frozenset({("-", "_"), (" ", "_"), ("$", "")})


class MarkerPolicy:
    """Own the exact marker registry and the audited serialization boundary."""

    def __init__(self, marker_pairs: Sequence[MarkerPair]) -> None:
        self.pairs = tuple(marker_pairs)
        self.tokens = tuple(token for pair in self.pairs for token in (pair.begin, pair.end))

    def counts(self, value: Any) -> Counter[str]:
        if isinstance(value, str):
            return Counter({token: value.count(token) for token in self.tokens if token in value})
        if isinstance(value, Mapping):
            return self.counts(list(value.keys())) + self.counts(list(value.values()))
        if isinstance(value, (list, tuple, KeysView, ValuesView, ItemsView)):
            result: Counter[str] = Counter()
            for item in value:
                result.update(self.counts(item))
            return result
        return Counter()

    def sensitive(self, value: Any) -> bool:
        if not self.tokens:
            return False
        if isinstance(value, str):
            return bool(self.counts(value))
        if isinstance(value, Mapping):
            return any(self.sensitive(item) for pair in value.items() for item in pair)
        if isinstance(value, (list, tuple, KeysView, ValuesView, ItemsView)):
            return any(self.sensitive(item) for item in value)
        return not isinstance(value, (type(None), bool, int, float, Undefined))

    def track(self, value: Any) -> Any:
        if isinstance(value, str) and self.counts(value) and not isinstance(value, _MarkerString):
            return _MarkerString(value)
        return value

    def serialized(self, source: Any, result: str, operation: str) -> str:
        if self.counts(source) != self.counts(result):
            reject_marker_transform(operation)
        walk_rendered(result, self.pairs)
        return self.track(result)


class _GuardExpressions(NodeTransformer):
    def visit_Concat(self, node: nodes.Concat, *args: Any, **kwargs: Any) -> nodes.Call:
        node = self.generic_visit(node, *args, **kwargs)
        return self._call("concat_values", [nodes.List(node.nodes)], node)

    def visit_Getitem(self, node: nodes.Getitem, *args: Any, **kwargs: Any) -> nodes.Node:
        node = self.generic_visit(node, *args, **kwargs)
        if isinstance(node.arg, nodes.Slice):
            parts = [
                part if part is not None else nodes.Const(None)
                for part in (node.arg.start, node.arg.stop, node.arg.step)
            ]
            return self._call("getslice", [node.node, *parts], node)
        return node

    def visit_For(self, node: nodes.For, *args: Any, **kwargs: Any) -> nodes.For:
        node = self.generic_visit(node, *args, **kwargs)
        node.iter = self._call(
            "guard_iter", [node.iter, nodes.Const(self._pattern(node.target))], node
        )
        return node

    def visit_Assign(self, node: nodes.Assign, *args: Any, **kwargs: Any) -> nodes.Assign:
        node = self.generic_visit(node, *args, **kwargs)
        if isinstance(node.target, nodes.Tuple):
            node.node = self._call(
                "guard_unpack", [node.node, nodes.Const(self._pattern(node.target))], node
            )
        return node

    @staticmethod
    def _pattern(target: nodes.Node) -> Any:
        return (
            tuple(_GuardExpressions._pattern(item) for item in target.items)
            if isinstance(target, nodes.Tuple)
            else None
        )

    @staticmethod
    def _call(name: str, args: list[nodes.Node], source: nodes.Node) -> nodes.Call:
        return nodes.Call(nodes.EnvironmentAttribute(name), args, [], None, None).set_lineno(
            source.lineno
        )


class ProvenanceSandbox(ImmutableSandboxedEnvironment):
    """Restrict operations on marked caller text to audited render semantics."""

    intercepted_binops = frozenset({"+", "-", "*", "/", "//", "**", "%"})

    def __init__(self, *args: Any, marker_pairs: Sequence[MarkerPair] = (), **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.marker_policy = MarkerPolicy(marker_pairs)

    def guard_filters(self) -> None:
        self.filters = {
            name: self._guard_filter(name, function) for name, function in self.filters.items()
        }
        original_iterable = self.tests["iterable"]
        self.tests["iterable"] = lambda value: isinstance(value, str) or original_iterable(value)

    def _parse(self, source: str, name: str | None, filename: str | None) -> nodes.Template:
        parsed = super()._parse(source, name, filename)
        return _GuardExpressions().visit(parsed) if self.marker_policy.tokens else parsed

    def concat_values(self, values: Any) -> str:
        parts = [str(value) for value in values]
        return self.marker_policy.serialized(parts, "".join(parts), "concatenation")

    def concat(self, values: Any) -> str:
        return self.concat_values(values)

    def guard_iter(self, value: Any, pattern: Any = None) -> Any:
        if isinstance(value, str) and self.marker_policy.sensitive(value):
            reject_marker_transform("string_iteration")
        return (
            (self.guard_unpack(item, pattern) for item in value) if pattern is not None else value
        )

    def guard_unpack(self, value: Any, pattern: Any) -> Any:
        if pattern is not None:
            if isinstance(value, str) and self.marker_policy.sensitive(value):
                reject_marker_transform("string_unpack")
            if isinstance(value, (list, tuple)):
                for item, child_pattern in zip(value, pattern, strict=False):
                    self.guard_unpack(item, child_pattern)
            elif not isinstance(value, (str, Mapping)) and self.marker_policy.sensitive(value):
                reject_marker_transform("opaque_unpack")
        return value

    def literal_replace(self, value: str, args: tuple[Any, ...], kwargs: dict[str, Any]) -> str:
        if kwargs or len(args) != 2 or any(type(arg) is not str for arg in args):
            reject_marker_transform("replace_arguments")
        if args not in _LITERAL_REPLACEMENTS:
            reject_marker_transform("replace_literal")
        result = str(value).replace(*args)
        return self.marker_policy.serialized(value, result, "replace_literal")

    def getitem(self, obj: Any, argument: Any) -> Any:
        if (
            isinstance(obj, str)
            and self.marker_policy.sensitive(obj)
            and not isinstance(argument, str)
        ):
            reject_marker_transform("string_index")
        return super().getitem(obj, argument)

    def getslice(self, obj: Any, start: Any, stop: Any, step: Any) -> Any:
        if isinstance(obj, str) and self.marker_policy.sensitive(obj):
            reject_marker_transform("string_slice")
        return obj[slice(start, stop, step)]

    def call_binop(self, context: Any, operator: str, left: Any, right: Any) -> Any:
        if self.marker_policy.sensitive(left) or self.marker_policy.sensitive(right):
            if operator == "+" and isinstance(left, str) and isinstance(right, str):
                return self.concat_values([left, right])
            if operator == "+" and isinstance(left, list) and isinstance(right, list):
                return left + right
            reject_marker_transform("operator_" + operator)
        return super().call_binop(context, operator, left, right)

    def call(self, context: Any, obj: Any, *args: Any, **kwargs: Any) -> Any:
        if not self.is_safe_callable(obj):
            return super().call(context, obj, *args, **kwargs)
        receiver = getattr(obj, "__self__", None)
        name = getattr(obj, "__name__", "callable")
        involved = self.marker_policy.sensitive(receiver) or any(
            self.marker_policy.sensitive(value) for value in (*args, *kwargs.values())
        )
        if involved:
            if receiver is self and name in {
                "guard_iter",
                "guard_unpack",
                "getslice",
                "concat_values",
            }:
                pass
            elif isinstance(receiver, str):
                if name == "replace":
                    return self.literal_replace(receiver, args, kwargs)
                elif name in {"strip", "lstrip", "rstrip"} and isinstance(receiver, _TaggedString):
                    pass
                elif name not in _OBSERVATION_METHODS:
                    reject_marker_transform("method_" + name)
            elif isinstance(receiver, Mapping) and name in {
                "items",
                "keys",
                "values",
                "get",
                "copy",
            }:
                pass
            elif isinstance(obj, (Macro, LoopContext)) or obj in (dict, Namespace):
                pass
            else:
                reject_marker_transform("callable")
        return self.marker_policy.track(super().call(context, obj, *args, **kwargs))

    def _guard_filter(self, name: str, function: Any) -> Any:
        @wraps(function)
        def guarded(*args: Any, **kwargs: Any) -> Any:
            values = args[1:] if getattr(function, "jinja_pass_arg", None) is not None else args
            value = values[0] if values else None
            involved = any(
                self.marker_policy.sensitive(item) for item in (*values, *kwargs.values())
            )
            if not involved:
                return function(*args, **kwargs)
            if name == "trim" and isinstance(value, _TaggedString):
                return function(*args, **kwargs)
            if name == "replace" and isinstance(value, str):
                return self.literal_replace(value, values[1:], kwargs)
            if name in _OBSERVATION_FILTERS or name in {"default", "d", "attr"}:
                return function(*args, **kwargs)
            if name in _STRUCTURAL_FILTERS and not isinstance(value, str):
                return function(*args, **kwargs)
            if name in _SERIALIZING_FILTERS:
                result = function(*args, **kwargs)
                return self.marker_policy.serialized(value, result, "filter_" + name)
            reject_marker_transform("filter_" + name)

        return guarded
