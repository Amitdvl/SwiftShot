# SwiftShot native polish

## Scope and ownership

September 11, 2026: simplify the shipped screenshot tool, preserving attached editing and SwiftShot's identity. The lead owns integration, native UI, build/install, pixel verification and the final delivery decision. A read-only reviewer audits hierarchy, native layout and the final diff. No worker edits shared files or operates the user's UI.

Acceptance: capture → precise selection → annotation/redaction → Copy/Save → recent thumbnail works; matching chrome reaches Settings, History and pins. Check actual native light/dark and accessibility appearances, compact layout and keyboard/focus behavior. Run focused safety regressions and the full final Release suite, then verify/package/install the signed app and publish only intended changes.

Non-goals: architecture rewrite, new capture modes, cloud/video, a benchmark campaign or speculative OCR optimization. Preserve private capture, recovery, existing useful features, safety tests, user changes and captures.

## Observed inspiration

CleanShot X was not found in `/Applications`. Reviewed its [official features page](https://cleanshot.com/features), the Quick Access demonstration and its official quick-actions image in a browser. The visuals show a small screenshot thumbnail, compact Copy/Save pills, small annotation/pin controls and a context menu for additional actions. The annotation preview includes a central drag handle and compact handoff controls. These are observations of official media, not a hands-on review of the installed product.

Borrow the hierarchy: keep the image dominant, make completing a capture immediate, and reveal secondary actions in context. Do not copy branding, assets, cloud/video scope or feature breadth.

## Chrome and interaction decisions

- App-owned elongated controls and floating bars use capsules; icon-only targets are circles. Larger inspectors use continuous 28-point rounding with 20-point insets. Native window chrome and standard system structures remain native.
- A shared UI-only surface uses native Liquid Glass on macOS 26, material on macOS 14–25, and an opaque surface with a clear outline for Reduce Transparency or increased contrast. Related glass surfaces share one container. Remove stacked decorative shadows and borders before applying material.
- Hover/press feedback changes color over 80–100 ms, with no scaling or displacement. Reduce Motion removes those transitions. Inspector changes do not animate the toolbar's placement; reserve a stable attachment area and scroll overflowing inspector content.
- Copy and Save retain labels and their shortcuts. Annotation, solid redaction and crop remain directly accessible. Styling moves under More; advanced actions retain their implementations.
- Screenshot pixels, crop/selection geometry, annotation geometry and the renderer never use the chrome modifier. Existing explicitly chosen export styling is preserved. UI rounding never becomes a raw-export mask.
- Display and region captures include visible SwiftShot windows and panels. The capture filter no longer removes the app's own process, while the existing explicit window identity checks remain unchanged.

## Removal ledger

No functional feature or user data is being removed. Planned cleanup removes duplicate launch/marketing copy from Settings, repeated keyboard instructions from More, and everyday diagnostics entry points. Diagnostics remain accessible in secondary troubleshooting controls. No dead code has been proven by the bounded audit; do not remove recovery or advanced handlers merely because their UI moves.
