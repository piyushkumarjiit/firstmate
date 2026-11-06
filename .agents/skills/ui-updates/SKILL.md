---
name: ui-updates
description: >-
  Load before briefing, supervising, or promoting any task that changes a user interface; owns the mockup-scout → captain approval → promoted ship flow and the vrt gate expectations.
user-invocable: true
metadata:
  internal: true
---

# ui-updates

## 1. Scope

Load this skill before briefing, supervising, or promoting any task whose captain intent changes how a user interface looks or behaves.
Load this skill for any ship whose vrt gate parks.

## 2. Flow

1. Mockup as a scout.
   Firstmate dispatches a scout whose deliverable is a visual artifact under `.lavish/` or `mockups/`.
   No production files are touched.
   Follow `scout-completion`'s Lavish board contract for captain iteration.
2. Captain approval.
   This happens on the board, through firstmate.
   The scout never addresses the captain.
3. Promotion.
   `bin/fm-promote.sh` (`fm-promote`) turns the approved scout into a ship.
   The brief's Captain's intent includes the approved mockup's substance: what changes, on which components.
4. Implementation.
   The ship follows `references/css-isolation-rules.md`.
5. Validation.
   no-mistakes runs.
   The `vrt` gate parks on every visual difference with a report.
   The VR001/VR002/VR003 findings are captain decisions (captain preferences), never firstmate's.
   Firstmate relays the report path and the summary of changed components, highlighting any component not named in the intent.
6. Approval.
   The captain runs `fg vrt-approve <report> --key ...` for the intended keys, then answers the park.
   Unintended changes go back to the worker as a fix.

## 3. Brief injection

When firstmate briefs a UI ship, add this block to the brief:

```markdown
### UI implementation requirements
Follow `.agents/skills/ui-updates/references/css-isolation-rules.md`.
Do not edit VRT capture fixtures, mocks, or baselines unless the intent says so (SU003/SC001 will park it anyway).
Never attempt to approve visual changes.
```

## 4. Per-project details

Project-specific details live in each project's own documentation rather than this skill.
Consult the target project's documentation for its component prefix, component paths, and VRT capture command.
This skill contains no project-specific paths or prefixes.

## 5. References & Resources

- `references/css-isolation-rules.md`: Scoped BEM conventions, banned bare selectors, and layout containment rules.
- `references/fixture-matrix.md`: Deterministic route mocking patterns, scenario matrix guidelines, and VRT determinism requirements.
- `templates/Component.tsx.template`: Starter template for isolated, scoped React components. Replace `{{prefix}}` with the project prefix.
- `templates/Component.css.template`: Starter template for scoped BEM styling companion. Replace `{{prefix}}` with the project prefix.
