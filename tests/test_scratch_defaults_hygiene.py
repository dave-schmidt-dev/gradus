"""Swift test targets must not strand `UserDefaults` suites in `~/Library`.

Two rules, both source-level. A behavioral test cannot enforce either one: the
file a leaking suite leaves behind is written by cfprefsd on its own schedule,
seconds after the test process is gone, so there is no moment during a run at
which the damage is observable. Measured 2026-08-26 -- a run ended at 13:49:21
with every file deleted and cfprefsd recreated all thirteen at 13:49:30.

1. Suites are created through `scratchDefaults`, which clears the domain first.
2. Suite names are fixed, never UUID-derived. A UUID isolates but makes the
   suite unnameable afterwards, so each run strands a file nothing will ever
   reuse or clean up. That is how 800 `com.zerodelta.gradus.mac.tests.*` and 240
   `presence-*` plists accumulated before anyone noticed.
3. Whatever replaces the UUID has to isolate as well as the UUID did. On iOS
   that is the caller's `#function`, and a fixture swallows it two ways: by
   taking no scope parameter at all, or by defaulting one to another fixture
   call, since a default argument evaluates `#function` against the declaration
   it sits in rather than the call site. Four fixtures did exactly that and
   funnelled 13, 6, 4 and 3 concurrent tests into one shared suite -- and
   `scratchDefaults` clears on entry, so the tests were wiping each other
   mid-run. Rule 3 makes that unrepresentable.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
# Every Swift test target, not just the ones that create suites today. A target
# left off this list is one where the leak can come back unwatched, which is how
# `GradusiOSTests` reached 26,881 stranded files while the Mac side was clean.
TEST_TARGETS = (
    ROOT / "app" / "GradusMacTests",
    ROOT / "app" / "GradusMacUITests",
    ROOT / "app" / "GradusiOSTests",
    ROOT / "app" / "GradusiOSUITests",
    ROOT / "app" / "GradusWidgetTests",
    ROOT / "app" / "GradusKit" / "Tests" / "GradusKitTests",
    ROOT / "app" / "GradusCredentialBridgeTests",
)
# The only places allowed to touch the raw APIs. One per target that needs it;
# they are duplicated rather than shared because the targets span three modules.
HELPERS = {
    "SnapshotTestSupport.swift",
    "ScratchDefaults.swift",
    "DashboardSnapshotFixtures.swift",
}

RAW_CREATION = re.compile(r"UserDefaults\(suiteName:")
RAW_TEARDOWN = re.compile(r"\.removePersistentDomain\(forName:")
UUID_SUITE = re.compile(r'"[^"]*\\\(UUID\(\)\.uuidString\)[^"]*"')


def _swift_sources():
    for target in TEST_TARGETS:
        if not target.is_dir():
            continue
        yield from sorted(target.rglob("*.swift"))


def _offenders(pattern, *, skip_helpers):
    hits = []
    for path in _swift_sources():
        if skip_helpers and path.name in HELPERS:
            continue
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            if pattern.search(line):
                hits.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
    return hits


def test_the_test_targets_exist():
    # Guards the rest of the file: a renamed directory would silently make every
    # assertion below vacuous, since they all iterate over the same empty glob.
    found = [t for t in TEST_TARGETS if t.is_dir()]
    assert found, f"none of the Swift test targets were found under {ROOT}"
    assert list(_swift_sources()), "no Swift sources found in the test targets"


def test_suites_are_created_through_the_scratch_helper():
    offenders = _offenders(RAW_CREATION, skip_helpers=True)
    assert not offenders, (
        "`UserDefaults(suiteName:)` used directly; call `scratchDefaults(_:)` so the "
        "domain is cleared before use:\n  " + "\n  ".join(offenders)
    )


def test_only_the_helpers_remove_a_persistent_domain():
    offenders = _offenders(RAW_TEARDOWN, skip_helpers=True)
    assert not offenders, (
        "`removePersistentDomain(forName:)` clears keys but leaves the file; call "
        "`removeScratchDefaultsSuite(_:using:)`:\n  " + "\n  ".join(offenders)
    )


def test_no_suite_name_is_derived_from_a_uuid():
    offenders = []
    for path in _swift_sources():
        text = path.read_text()
        for match in UUID_SUITE.finditer(text):
            literal = match.group(0)
            # Only string literals that name a suite matter; a UUID inside test
            # data (a record id, a fixture) is unrelated to preference domains.
            context = text[max(0, match.start() - 120) : match.start()]
            if "suiteName" in context or "Suite =" in context or "suite =" in context:
                line = text.count("\n", 0, match.start()) + 1
                offenders.append(f"{path.relative_to(ROOT)}:{line}: {literal}")
    assert not offenders, (
        "UUID-derived suite name strands one preference file per run; use a fixed "
        "name unique to the test:\n  " + "\n  ".join(offenders)
    )


@pytest.mark.parametrize("helper", sorted(HELPERS))
def test_each_declared_helper_still_defines_the_scratch_api(helper):
    # The targets span three modules, so the helper is duplicated rather than
    # shared. If one copy is deleted its target silently loses the guarantee,
    # while the rules above keep passing because nothing there creates a suite.
    matches = [p for p in _swift_sources() if p.name == helper]
    assert matches, f"{helper} is missing; its test target has no scratch-suite helper"
    for path in matches:
        text = path.read_text()
        assert "func scratchDefaults(" in text, f"{path.relative_to(ROOT)} lost scratchDefaults"
        assert "func removeScratchDefaultsSuite(" in text, (
            f"{path.relative_to(ROOT)} lost removeScratchDefaultsSuite"
        )


# --- Rule 3: the caller's scope must survive every hop to the helper ---------

SCOPE_PARAM = re.compile(r"\b(\w+)\s*:\s*String\b")
FUNC_DECL = re.compile(r"(?:^|[\s}])func\s+(\w+)\s*(?:<[^>]*>)?\s*\(")
# The two entry points that turn a name into a cleared suite. Everything that
# reaches either one, however many hops away, owes the caller's scope.
SCRATCH_API = ("scratchDefaults", "scratchSuiteName")


def _swift_files(target: Path):
    if not target.is_dir():
        return []
    return sorted(target.rglob("*.swift"))


def _balanced(text: str, start: int, opener: str, closer: str) -> tuple[str, int]:
    """Return the substring bracketed by `opener`/`closer` at `start`, and its end."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == opener:
            depth += 1
        elif text[index] == closer:
            depth -= 1
            if depth == 0:
                return text[start : index + 1], index + 1
    return "", len(text)


def _is_test(source: str, offset: int, name: str) -> bool:
    """True for a Swift Testing `@Test` or an XCTest `testFoo()`.

    Both get a `#function` unique to the running test, so both are valid places
    for a scope to originate. Only the declaration line and the attribute lines
    directly above it are inspected -- scanning a fixed window backwards would
    inherit the `@Test` of whatever was declared before this function.
    """
    if name.startswith("test"):
        return True
    line_start = source.rfind("\n", 0, offset) + 1
    line_end = source.find("\n", offset)
    if "@Test" in source[line_start : line_end if line_end > 0 else len(source)]:
        return True
    for previous in reversed(source[:line_start].splitlines()):
        stripped = previous.strip()
        if not stripped.startswith("@"):
            return False
        if stripped.startswith("@Test"):
            return True
    return False


def _functions(path: Path):
    """Yield (name, signature, body, is_test) for each `func` in a Swift file."""
    source = path.read_text()
    for match in FUNC_DECL.finditer(source):
        signature, after_params = _balanced(source, match.end() - 1, "(", ")")
        brace = source.find("{", after_params)
        if brace < 0:
            continue
        body, _ = _balanced(source, brace, "{", "}")
        name = match.group(1)
        yield name, signature, body, _is_test(source, match.start(), name)


def _reaching(target: Path):
    """Every function in one module that reaches the scratch API, transitively."""
    functions = [(path, *rest) for path in _swift_files(target) for rest in _functions(path)]
    reaching = {
        name for _, name, _, body, _ in functions if any(f"{api}(" in body for api in SCRATCH_API)
    }
    reaching.update(SCRATCH_API)
    while True:
        grown = {
            name
            for _, name, _, body, _ in functions
            if any(re.search(rf"\b{callee}\s*\(", body) for callee in reaching)
        }
        if grown <= reaching:
            return functions, reaching
        reaching |= grown


def _forwards(body: str, reaching: set, scopes: set) -> bool:
    """True when the caller's scope reaches the suite, by either idiom.

    iOS passes it straight down (`scratchDefaults("sync", test)`); macOS
    interpolates it into a suite name first (`"...display.\\(name)"`). Both
    keep the suite named after the caller, which is the whole point.
    """
    interpolated = set(re.findall(r"\\\(([^)]*)\)", body))
    if any(re.search(rf"\b{scope}\b", chunk) for chunk in interpolated for scope in scopes):
        return True
    for callee in reaching:
        for match in re.finditer(rf"\b{callee}\s*\(", body):
            arguments, _ = _balanced(body, match.end() - 1, "(", ")")
            if any(re.search(rf"\b{scope}\b", arguments) for scope in scopes):
                return True
    return False


@pytest.mark.parametrize("target", TEST_TARGETS, ids=lambda path: path.name)
def test_fixtures_forward_the_callers_scope(target: Path) -> None:
    """A fixture that reaches the scratch API must carry its caller's scope.

    Swift evaluates `#function` in a default argument against the declaration
    that holds it, so `userDefaults: UserDefaults = syncIsolatedDefaults()`
    names the suite after the fixture. Every test calling it then shares one
    domain -- and `scratchDefaults` clears that domain on entry, so under Swift
    Testing's parallel execution the tests erase each other's state mid-run.
    """
    functions, reaching = _reaching(target)
    if reaching <= set(SCRATCH_API):
        pytest.skip(f"{target.name} creates no scratch suites")

    offenders = []
    for path, name, signature, body, is_test in functions:
        if is_test or name in SCRATCH_API or name not in reaching:
            continue
        scopes = set(SCOPE_PARAM.findall(signature))
        if not scopes:
            offenders.append(f"{path.name}:{name}() takes no caller-supplied suite scope")
        elif not _forwards(body, reaching, scopes):
            offenders.append(f"{path.name}:{name}() never forwards {'/'.join(sorted(scopes))}")

    assert not offenders, (
        "these fixtures reach a cleared scratch suite but cannot name it after "
        "the test that asked for it, so every caller collapses onto one shared "
        "suite. Take the scope as a parameter -- `test: String = #function` on "
        "iOS, an explicit suite name on macOS -- and pass it on:\n  " + "\n  ".join(offenders)
    )


@pytest.mark.parametrize("target", TEST_TARGETS, ids=lambda path: path.name)
def test_no_default_argument_swallows_a_scope(target: Path) -> None:
    """No default argument may call a scope-carrying fixture.

    This is the exact shape that hid the bug: the call runs, silently, with the
    enclosing declaration's `#function` instead of the caller's.
    """
    functions, reaching = _reaching(target)
    if reaching <= set(SCRATCH_API):
        pytest.skip(f"{target.name} creates no scratch suites")

    offenders = [
        f"{path.name}:{name}() defaults an argument to {callee}()"
        for path, name, signature, _, _ in functions
        for callee in reaching
        if re.search(rf"=\s*{callee}\s*\(", signature)
    ]

    assert not offenders, (
        "a default argument evaluates `#function` against its own declaration, "
        "so these name the suite after the fixture rather than the test:\n  "
        + "\n  ".join(offenders)
    )


def _arguments(call: str) -> list[str]:
    """Split a call's argument text on its top-level commas."""
    inner, depth, current, arguments = call[1:-1], 0, "", []
    for character in inner:
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        if character == "," and depth == 0:
            arguments.append(current.strip())
            current = ""
        else:
            current += character
    if current.strip():
        arguments.append(current.strip())
    return arguments


PARAMETER = re.compile(r"^\s*(?:(\w+|_)\s+)?(\w+)\s*:")


def _scope_argument(call: str, parameters, scopes: set) -> str:
    """The argument that decides which suite this call gets, or "" for the default.

    `scratchDefaults`/`scratchSuiteName` take the whole name, so every argument
    counts. A fixture instead has one scope parameter, and only what is passed
    there matters: two calls differing in any other argument still land in the
    same suite, which is exactly how the shared-suite bug stayed hidden.
    """
    arguments = _arguments(call)
    if parameters is None:
        return " ".join(arguments)
    for index, parameter in enumerate(parameters):
        names = PARAMETER.match(parameter)
        if not names or names.group(2) not in scopes:
            continue
        label = names.group(1) or names.group(2)
        if label != "_":
            for argument in arguments:
                if argument.startswith(f"{label}:"):
                    return argument
        elif index < len(arguments):
            return arguments[index]
    return ""


@pytest.mark.parametrize("target", TEST_TARGETS, ids=lambda path: path.name)
def test_a_test_never_takes_the_same_suite_twice(target: Path) -> None:
    """Two calls in one test must not both fall back to the same scope.

    A test's `#function` is one value, so a fixture called twice hands back the
    same suite -- and the helper clears it on entry, so the second call wipes
    the domain the first object is still using. The UUID scheme this replaced
    gave the two calls separate suites, so the hazard is new; the leftover files
    cannot show it, because two calls sharing a suite leave exactly one plist.
    """
    functions, reaching = _reaching(target)
    if reaching <= set(SCRATCH_API):
        pytest.skip(f"{target.name} creates no scratch suites")

    signatures = {
        callee: (None if callee in SCRATCH_API else _arguments(signature))
        for _, callee, signature, _, _ in functions
        if callee in reaching
    }
    scope_names = {
        callee: set(SCOPE_PARAM.findall(signature))
        for _, callee, signature, _, _ in functions
        if callee in reaching
    }

    offenders = []
    for path, name, _, body, is_test in functions:
        if not is_test:
            continue
        for callee in sorted(reaching):
            used = [
                _scope_argument(call, signatures.get(callee), scope_names.get(callee, set()))
                for match in re.finditer(rf"\b{callee}\s*\(", body)
                for call, _ in [_balanced(body, match.end() - 1, "(", ")")]
            ]
            repeated = {scope for scope in used if used.count(scope) > 1}
            if repeated:
                worst = max(used.count(scope) for scope in repeated)
                offenders.append(f"{path.name}:{name}() calls {callee}() {worst}x on one scope")

    assert not offenders, (
        "each of these takes the same cleared suite more than once in a single "
        "test, so the later call erases state the earlier object still holds. "
        'Pass a distinct scope, e.g. `test: "\\(#function).delta"`:\n  ' + "\n  ".join(offenders)
    )
