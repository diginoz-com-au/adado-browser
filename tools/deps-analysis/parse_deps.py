import ast
import sys

with open("/tmp/chromium_DEPS.py") as f:
    src = f.read()

tree = ast.parse(src)

vars_dict_node = None
deps_dict_node = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "vars":
                vars_dict_node = node.value
            if isinstance(target, ast.Name) and target.id == "deps":
                deps_dict_node = node.value

# Extract vars' literal boolean/string defaults (skip anything that's a
# Var(...)/other call -- those are rare for top-level booleans, and we
# only need the ones gclient conditions actually reference).
gclient_vars = {}
if isinstance(vars_dict_node, ast.Dict):
    for k, v in zip(vars_dict_node.keys, vars_dict_node.values):
        if isinstance(k, ast.Constant):
            try:
                gclient_vars[k.value] = ast.literal_eval(v)
            except Exception:
                pass  # non-literal default (a Var()/call) -- leave unset, condition eval will error and we'll see it

print(f"Extracted {len(gclient_vars)} literal vars from DEPS's own vars{{}} block")

# Real gclient-derived vars for OUR exact config: target_os=["linux"],
# custom_vars={"non_git_source": True}. These OVERRIDE/supplement DEPS's
# own defaults, matching gclient's real resolution order.
TARGET_OS = ["linux"]
real_ns = dict(gclient_vars)
real_ns.update({
    "checkout_android": "android" in TARGET_OS,
    "checkout_chromeos": "chromeos" in TARGET_OS,
    "checkout_linux": "linux" in TARGET_OS,
    "checkout_mac": "mac" in TARGET_OS,
    "checkout_win": "win" in TARGET_OS,
    "checkout_fuchsia": "fuchsia" in TARGET_OS,
    "checkout_ios": "ios" in TARGET_OS,
    "host_os": "linux",
    "host_cpu": "x64",
    "checkout_x64": True,
    "checkout_x86": False,
    "checkout_arm": False,
    "checkout_arm64": False,
    "checkout_mips": False,
    "checkout_mips64": False,
    "checkout_ppc": False,
    "checkout_riscv64": False,
    "checkout_s390": False,
    "non_git_source": True,  # our custom_vars
})

results = []
if isinstance(deps_dict_node, ast.Dict):
    for k, v in zip(deps_dict_node.keys, deps_dict_node.values):
        if not isinstance(k, ast.Constant):
            continue
        path = k.value
        condition_src = None
        dep_type = None
        if isinstance(v, ast.Dict):
            for vk, vv in zip(v.keys, v.values):
                if isinstance(vk, ast.Constant) and vk.value == "condition":
                    condition_src = ast.get_source_segment(src, vv)
                    if isinstance(vv, ast.Constant):
                        condition_src = vv.value
                if isinstance(vk, ast.Constant) and vk.value == "dep_type":
                    if isinstance(vv, ast.Constant):
                        dep_type = vv.value
        results.append((path, condition_src, dep_type))

print(f"Total top-level deps entries: {len(results)}")

true_count = 0
false_count = 0
error_count = 0
true_entries = []
error_entries = []
for p, c, t in results:
    if c is None:
        continue  # ungated -- always fetched by a plain git checkout, not our problem class
    try:
        val = eval(c, {"__builtins__": {}}, real_ns)
    except Exception as e:
        error_count += 1
        error_entries.append((p, c, str(e)))
        continue
    if val:
        true_count += 1
        true_entries.append((p, c, t))
    else:
        false_count += 1

print(f"Conditions TRUE for our exact config (linux-only, non_git_source=True): {true_count}")
print(f"Conditions FALSE (not needed for us): {false_count}")
print(f"Conditions that failed to evaluate (undefined var): {error_count}")
print()
print("=== TRUE entries (these are the real, complete list of conditionally-gated deps our build needs) ===")
for p, c, t in sorted(true_entries):
    print(f"{p}  [{t or 'git'}]")
print()
print("=== Entries that errored (need manual check) ===")
for p, c, e in error_entries[:30]:
    print(f"{p}  condition={c!r}  error={e}")
