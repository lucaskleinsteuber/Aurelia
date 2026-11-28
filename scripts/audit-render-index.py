"""Writes index.md for scripts/audit-render-screens.sh: every picture in the folder, grouped by
screen, the renders that failed or came out as one flat colour, and the screens the tool does not
draw, with the reason."""

import json
import pathlib
import sys

NOT_COVERED = {
    "Downloads with titles": "Offline downloads live in the app's own container; the render "
    "build's container has none, so only the empty Downloads page is drawn.",
    "Offline mode (Watch Downloads Offline)": "Needs downloaded titles on this Mac (see above).",
    "Download quality sheet": "Needs download options from a server; not faked.",
    "Artwork crop sheet": "Needs a picked image file (open panel); not reachable offscreen.",
    "Segment trim editor, subtitle download panel, import preview": "Need media analysis or "
    "server import data the fixture does not invent.",
    "Scene notes popover, remote (Mac mini) control": "Need notes or another device; popovers "
    "are separate windows.",
    "Alerts, confirmation dialogs, context menus, popovers, tooltips": "Separate windows that "
    "only appear on interaction; not captured by drawing a window's content view.",
    "Sheets in place": "Sheets are drawn on their own at their natural size (size label "
    "'sheet'), not attached to the window.",
    "Native materials with reduced transparency": "Only Tarven's own "
    "tarvenReduceTransparency is switched (hosting view environment). SwiftUI/AppKit "
    "materials follow the system setting, which is never changed.",
    "Window chrome": "Traffic-light buttons and the title bar belong to the window frame and are "
    "not part of the drawn content view.",
}


def main() -> None:
    output = pathlib.Path(sys.argv[1])
    pictures = sorted(p.name for p in output.glob("*.png"))
    failures, uniform, logs, unfinished = [], set(), [], []
    unanswered: dict[str, list[str]] = {}
    for manifest in sorted((output / ".manifests").glob("*.json")):
        run = json.loads(manifest.read_text())
        if not run.get("finished"):
            unfinished.append(manifest.stem)
        for entry in run.get("entries", []):
            if entry.get("error"):
                failures.append(f"{entry.get('screen')}: {entry['error']}")
            if entry.get("unanswered"):
                unanswered.setdefault(entry["screen"], []).append(entry["unanswered"])
            if entry.get("uniform") == "yes":
                uniform.add(entry["file"])
        logs += run.get("logs", [])
    screens: dict[str, list[str]] = {}
    for name in pictures:
        screens.setdefault(name.split("__")[0], []).append(name)
    lines = [
        "# Mac app offscreen renders",
        "",
        "Made by `scripts/audit-render-screens.sh` (DEBUG mode `TARVEN_UI_TEST_MODE=audit-render`)"
        " with an invented library (`AuditRenderFixture.swift`). File names are "
        "`<screen>__<size>__<appearance>.png`; sizes are window content sizes in points (the "
        "window minimum is 760x560), `1280x3000-tall` shows more of a scrolling page, `sheet` is a "
        "sheet at its own size. Appearances: `light`/`dark` set the window's system appearance "
        "(the app's root view asks for dark itself), `-contrast` adds the high-contrast "
        "appearance and Tarven's increased-contrast branch, `-reducedtransparency` Tarven's "
        "reduced-transparency branch. Pictures are drawn at 1 pixel per point unless "
        "TARVEN_AUDIT_RENDER_SCALE says otherwise.",
        "",
        f"{len(pictures)} pictures of {len(screens)} screens.",
        "",
        "## Pictures",
        "",
    ]
    for screen, names in screens.items():
        lines.append(f"- **{screen}**")
        for name in names:
            flag = " (one flat colour: probably not drawn)" if name in uniform else ""
            lines.append(f"  - [{name}]({name}){flag}")
    lines += ["", "## Renders that failed or look empty", ""]
    problems = failures + [f"{name}: one flat colour" for name in sorted(uniform)]
    problems += [f"run {run} did not finish" for run in unfinished] + logs
    lines += [f"- {problem}" for problem in problems] or ["- none"]
    lines += [
        "",
        "## Requests the fixture did not answer",
        "",
        "These screens asked for data `AuditRenderFixture` does not invent. An error message or "
        "missing section on them comes from the fixture, not necessarily from the app.",
        "",
    ]
    for screen, requests in sorted(unanswered.items()):
        lines.append(f"- **{screen}**: " + ", ".join(f"`{r}`" for r in sorted(set(requests))))
    if not unanswered:
        lines.append("- none")
    lines += ["", "## Not covered", ""]
    lines += [f"- **{name}**: {reason}" for name, reason in NOT_COVERED.items()]
    (output / "index.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
