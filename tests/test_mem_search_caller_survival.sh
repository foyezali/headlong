#!/usr/bin/env bash
# Regression: mem search's deadline must fire even when job control does not.
#
# bin/mem bounds a search with a sibling watchdog that kills the worker's
# PROCESS GROUP, and cancels the same way on TERM/INT. Both rely on `set -m`
# having put the worker in a group of its own. When job control does not take
# effect the worker shares the caller's group, so `kill -KILL -- -$pgid`
# signals a group the watchdog may not own: measured on the pre-fix binary
# with its `set -m` lines neutralised, a MEM_SEARCH_TIMEOUT_S=3 search ran the
# full 41s (the adapter's own sleep), never fired its deadline, and then told
# the user "the model returned no answer text", blaming the model for a
# timeout that silently did not happen. The fix walks the child tree when the
# child is not a group leader, so the bound holds either way.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO" <<'PY'
import subprocess, sys, tempfile, time
from pathlib import Path

repo = Path(sys.argv[1])
mem = repo / "bin" / "mem"
if not mem.exists():
    sys.exit("missing " + str(mem))

# The adapter outlives the deadline by a wide margin, so a search that returns
# quickly can only have done so by cancelling it.
ADAPTER = "#!/usr/bin/env bash\ncat >/dev/null; sleep 40\n"
DEADLINE_S = 3
# Generous: the fixed path returns in ~5s. The broken path ran 41s.
BOUNDED_S = 20

def run(neutralise_job_control: bool):
    """Return (survived, survived_at_least_seconds, output, elapsed)."""
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for sub in ("bin", "mem", "tmp", "home"):
            (root / sub).mkdir()
        (root / "mem" / "probe.md").write_text(
            "---\nsummary: probe\ntype: fact\n---\nprobe\n")
        adapter = root / "adapter"
        adapter.write_text(ADAPTER)
        adapter.chmod(0o755)

        target = mem
        if neutralise_job_control:
            # Simulate job control not taking effect: the child stays in the
            # caller's process group, the condition that makes an unchecked
            # group kill useless or dangerous.
            text = mem.read_text().replace("\n    set -m\n", "\n    set +m\n")
            assert "set +m" in text, "no `set -m` line to neutralise"
            target = root / "mem_neutered"
            target.write_text(text)
            target.chmod(0o755)

        driver = root / "driver.sh"
        driver.write_text(f"""#!/usr/bin/env bash
export PATH={root}/bin:$PATH MEM_DIR={root}/mem TMPDIR={root}/tmp \\
  HEADLONG_HOME={root}/home LLM_PROVIDER=adapter LLM_ADAPTER={adapter} \\
  LLM_MODEL=test LLM_MAX_TIME=90 LLM_RETRIES=0 \\
  MEM_SEARCH_TIMEOUT_S={DEADLINE_S} MEM_SEARCH_HEARTBEAT_S=0
start=$(date +%s)
"{target}" search probe
rc=$?
end=$(date +%s)
echo "DRIVER SURVIVED rc=$rc elapsed=$((end - start))s"
""")
        driver.chmod(0o755)

        t0 = time.time()
        # Own session, so a stray group kill cannot reach this test process.
        p = subprocess.run(
            ["setsid", "bash", str(driver)],
            capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        elapsed = time.time() - t0
        out = p.stdout + p.stderr
        return "DRIVER SURVIVED" in out, out, elapsed

checks = 0
failed = 0

def check(name, cond, detail=""):
    global checks, failed
    checks += 1
    if cond:
        print("ok  " + name)
    else:
        failed += 1
        print("FAIL " + name + ("\n    " + detail.replace("\n", "\n    ") if detail else ""))

# 1. The ordinary path: the caller lives through a bounded search.
survived, out, _ = run(neutralise_job_control=False)
check("caller survives a bounded search", survived, out)

# 2. The deadline must still hold the bound when job control does not take
#    effect. This is the check the pre-fix binary fails: it ran 41s.
survived, out, elapsed = run(neutralise_job_control=True)
check("caller survives when job control does not take effect", survived, out)
check(f"  and the {DEADLINE_S}s deadline still bounds the search "
      f"(<{BOUNDED_S}s)", elapsed < BOUNDED_S,
      f"took {elapsed:.1f}s\n" + out)

# 3. The defect's real signature was the WRONG DIAGNOSIS: an unbounded search
#    ended at last by saying "the model returned no answer text", blaming the
#    model for a timeout that never fired. Either honest outcome is fine here
#    (the timeout message, or llm reporting that its adapter was killed), and
#    what must never appear is the misdiagnosis.
check("  and a fired deadline is not misreported as a silent model",
      "returned no answer text" not in out, out)

print(f"{checks - failed} passed; {failed} failed")
sys.exit(bool(failed))
PY
