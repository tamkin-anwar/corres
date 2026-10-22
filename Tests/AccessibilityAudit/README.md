# Accessibility audit

Runs Apple's accessibility audit (the same checks as Accessibility Inspector) on Corres's main screens, with sample mail.

1. Build Corres for the simulator and install it on a booted simulator.
2. Run, with that simulator's id:

```
xcodebuild test -project Tests/AccessibilityAudit/Audit.xcodeproj -scheme AuditTests -destination 'id=<simulator id>' | grep AUDIT
```

Every issue is printed as `AUDIT [screen] kind description :: element`. The tests don't fail on issues; read the list.
